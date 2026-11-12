-- ============================================================
-- v2: พนักงานเข้าระบบด้วยชื่อตัวเอง + รหัส 4 หลัก · ประเภทการหยุด (หยุด / ลา / ลาป่วย / ครึ่งวัน)
-- รันต่อจาก supabase_setup.sql · รันซ้ำได้ · สำรองข้อมูลเดิมไว้ก่อนแก้ (backup_*_v1)
--
-- กติกา:
--   - ลงได้วันละ 4 คน (ไม่นับลาป่วย) · ลาป่วยลงได้แม้วันเต็ม/วันห้ามหยุด · ครึ่งวันนับ 1 คน
--   - ลงย้อนหลังไม่ได้ (ยกเว้นแอดมิน) · ลบ/ยกเลิก · เพิ่มเกิน 4 · ตั้งวันห้ามหยุด = แอดมินเท่านั้น
--   - แอดมิน = staff.is_admin (เซเว่น, อาย) · ตั้งรหัสครั้งแรกของแอดมินต้องใช้รหัสแอดมินเดิมของร้าน
--   - ใส่รหัสผิด 5 ครั้ง = ล็อก 15 นาที
-- ============================================================

-- ---------- 0) สำรองข้อมูลเดิม (ทำครั้งแรกครั้งเดียว) ----------
create table if not exists public.backup_leaves_v1  as table public.leaves;
create table if not exists public.backup_blocked_v1 as table public.blocked;
alter table public.backup_leaves_v1  enable row level security;
alter table public.backup_blocked_v1 enable row level security;
revoke all on public.backup_leaves_v1, public.backup_blocked_v1 from anon, authenticated;

-- ---------- 1) ประเภทการหยุด ----------
alter table public.leaves add column if not exists type text not null default 'off';
alter table public.leaves add column if not exists half text;          -- 'เช้า' / 'บ่าย' (เฉพาะครึ่งวัน)
alter table public.leaves add column if not exists orig_name text;     -- ชื่อตามที่พิมพ์ไว้เดิม ก่อนแยกประเภท
do $$ begin
  alter table public.leaves add constraint leaves_type_chk check (type in ('off','leave','sick','half'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.leaves add constraint leaves_half_chk check (half is null or half in ('เช้า','บ่าย'));
exception when duplicate_object then null; end $$;

-- ---------- 2) แยกประเภทจากชื่อเดิม เช่น "อ้น(ลาป่วย)" → อ้น + ลาป่วย, "เซเว่น ลาครึ่งวัน" → เซเว่น + ครึ่งวัน ----------
update public.leaves
set orig_name = name,
    type = case when name ~ 'ป่วย' then 'sick' else 'half' end,
    name = btrim(regexp_replace(name, '\s*\(?\s*(ลา)?(ครึ่งวัน|ป่วย)\s*\)?\s*$', ''))
where orig_name is null
  and name ~ '(ครึ่งวัน|ป่วย)\s*\)?\s*$'
  and btrim(regexp_replace(name, '\s*\(?\s*(ลา)?(ครึ่งวัน|ป่วย)\s*\)?\s*$', '')) <> '';

-- ---------- 3) พนักงาน + เครื่องที่เข้าระบบไว้ ----------
create table if not exists public.staff (
  name         text primary key,
  is_admin     boolean not null default false,
  pin_salt     text,
  pin_hash     text,
  failed       int not null default 0,
  locked_until timestamptz,
  created_at   timestamptz not null default now()
);
create unique index if not exists staff_name_lower_uniq on public.staff(lower(name));

create table if not exists public.sessions (     -- 1 แถว = 1 เครื่องที่จำว่าเป็นใคร
  token      text primary key,
  name       text not null references public.staff(name) on update cascade on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.staff    enable row level security;
alter table public.sessions enable row level security;
revoke all on public.staff, public.sessions from anon, authenticated;

insert into public.staff(name, is_admin) values ('เซเว่น', true), ('อาย', true)
  on conflict (name) do update set is_admin = true;

-- ---------- 4) ตัวช่วย (เรียกจากภายนอกไม่ได้) ----------
create or replace function public._today() returns text
language sql stable as $$
  select to_char((now() at time zone 'Asia/Bangkok')::date, 'YYYY-MM-DD');
$$;

create or replace function public._clean_name(p text) returns text
language sql immutable as $$
  select btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g'));
$$;

-- ชื่อมาตรฐาน: ตามที่ลงทะเบียนไว้ หรือตามข้อมูลเก่า (ตัวพิมพ์เล็ก/ใหญ่ไม่ต้องตรง เช่น book → Book)
create or replace function public._canon(p text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select name from public.staff  where lower(name) = lower(public._clean_name(p)) limit 1),
    (select name from public.leaves where lower(name) = lower(public._clean_name(p)) order by id desc limit 1),
    public._clean_name(p));
$$;

create or replace function public._pin_hash(p_salt text, p_pin text) returns text
language sql immutable as $$
  select encode(sha256(convert_to(p_salt || ':' || p_pin, 'UTF8')), 'hex');
$$;

create or replace function public._me(p_token text) returns public.staff
language plpgsql stable security definer set search_path = public as $$
declare r public.staff;
begin
  select st.* into r from public.sessions s join public.staff st on st.name = s.name where s.token = p_token;
  if not found then raise exception 'auth'; end if;
  return r;
end; $$;

-- ---------- 5) ข้อมูลทั้งหมด (ใช้แสดงผล) ----------
create or replace function public.get_all()
returns json language sql security definer stable set search_path = public as $$
  select json_build_object(
    'data', coalesce((
      select json_object_agg(date, items) from (
        select date, json_agg(json_build_object(
                 'id', id, 'name', name, 'type', type, 'half', half, 'ts', created_at) order by id) as items
        from public.leaves group by date
      ) t), '{}'::json),
    'blocked', coalesce((select json_agg(date order by date) from public.blocked), '[]'::json),
    'admins',  coalesce((select json_agg(name order by name) from public.staff where is_admin), '[]'::json),
    'today',   public._today()
  );
$$;

-- ---------- 6) เข้าระบบ ----------
-- เช็คชื่อก่อนตั้ง/ใส่รหัส: ชื่อมาตรฐาน, เคยมีในร้านไหม, ตั้งรหัสแล้วหรือยัง
create or replace function public.staff_status(p_name text)
returns json language plpgsql stable security definer set search_path = public as $$
declare v text := public._canon(p_name); s public.staff;
begin
  select * into s from public.staff where name = v;
  return json_build_object(
    'name', v,
    'known', s.name is not null or exists(select 1 from public.leaves where lower(name) = lower(v)),
    'has_pin', s.pin_hash is not null,
    'is_admin', coalesce(s.is_admin, false),
    'need_admin_key', coalesce(s.is_admin, false) and s.pin_hash is null);
end; $$;

-- ตั้งรหัสครั้งแรก หรือใส่รหัสเพื่อเข้าระบบ → ได้ token จำเครื่องนี้ไว้
-- (คืน {ok:false, error} แทนการ raise เพื่อให้บันทึกจำนวนครั้งที่ใส่ผิดได้)
create or replace function public.staff_login(p_name text, p_pin text, p_admin_key text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v text := public._canon(p_name); s public.staff; v_salt text; v_tok text; v_fail int;
begin
  if v = '' or length(v) > 20 or v ~ '[()]' or v ~ '^[0-9 ]+$' then
    return json_build_object('ok', false, 'error', 'bad_name');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return json_build_object('ok', false, 'error', 'bad_pin_format');
  end if;

  insert into public.staff(name) values (v) on conflict do nothing;
  select * into s from public.staff where lower(name) = lower(v) for update;

  if s.pin_hash is null then
    if s.is_admin and not public.is_admin(p_admin_key) then
      return json_build_object('ok', false, 'error', 'need_admin_key');
    end if;
    v_salt := gen_random_uuid()::text;
    update public.staff set pin_salt = v_salt, pin_hash = public._pin_hash(v_salt, p_pin), failed = 0, locked_until = null
      where name = s.name;
  else
    if s.locked_until is not null and s.locked_until > now() then
      return json_build_object('ok', false, 'error', 'locked',
        'minutes', ceil(extract(epoch from s.locked_until - now()) / 60));
    end if;
    if public._pin_hash(s.pin_salt, p_pin) <> s.pin_hash then
      v_fail := s.failed + 1;
      update public.staff
        set failed = case when v_fail >= 5 then 0 else v_fail end,
            locked_until = case when v_fail >= 5 then now() + interval '15 minutes' else null end
        where name = s.name;
      if v_fail >= 5 then return json_build_object('ok', false, 'error', 'locked', 'minutes', 15); end if;
      return json_build_object('ok', false, 'error', 'bad_pin', 'left', 5 - v_fail);
    end if;
    update public.staff set failed = 0, locked_until = null where name = s.name;
  end if;

  v_tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.sessions(token, name) values (v_tok, s.name);
  return json_build_object('ok', true, 'token', v_tok, 'name', s.name, 'is_admin', s.is_admin);
end; $$;

-- เปิดแอป: เช็คว่าเครื่องนี้ยังเป็นของใคร (ถ้าแอดมินรีเซ็ตรหัส → คืน null ต้องเข้าใหม่)
create or replace function public.staff_whoami(p_token text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('name', st.name, 'is_admin', st.is_admin)
  from public.sessions s join public.staff st on st.name = s.name where s.token = p_token;
$$;

-- ---------- 7) ลงวัน / ลบ / วันห้ามหยุด / รีเซ็ตรหัส ----------
create or replace function public.leave_add(p_token text, p_date text, p_type text, p_half text default null)
returns json language plpgsql security definer set search_path = public as $$
declare me public.staff := public._me(p_token); v_count int;
begin
  p_date := btrim(coalesce(p_date, ''));
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_type, '') not in ('off','leave','sick','half') then
    raise exception 'invalid';
  end if;
  if p_type <> 'half' then p_half := null;
  elsif p_half is not null and p_half not in ('เช้า','บ่าย') then raise exception 'invalid'; end if;
  if p_date < public._today() and not me.is_admin then raise exception 'past'; end if;

  perform pg_advisory_xact_lock(hashtext('leave:' || p_date));   -- ต่อคิวเฉพาะคนที่ลง "วันเดียวกัน"
  if exists(select 1 from public.leaves where date = p_date and lower(name) = lower(me.name)) then
    raise exception 'duplicate';
  end if;
  if p_type <> 'sick' then                                         -- ลาป่วยไม่ติดวันห้ามหยุด/โควตา
    if exists(select 1 from public.blocked where date = p_date) then raise exception 'blocked'; end if;
    select count(*) into v_count from public.leaves where date = p_date and type <> 'sick';
    if v_count >= 4 and not me.is_admin then raise exception 'full'; end if;
  end if;
  insert into public.leaves(date, name, type, half) values (p_date, me.name, p_type, p_half);
  return public.get_all();
end; $$;

create or replace function public.leave_remove(p_token text, p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare me public.staff := public._me(p_token);
begin
  if not me.is_admin then raise exception 'forbidden'; end if;
  delete from public.leaves where id = p_id;
  return public.get_all();
end; $$;

create or replace function public.day_block(p_token text, p_date text, p_block boolean)
returns json language plpgsql security definer set search_path = public as $$
declare me public.staff := public._me(p_token);
begin
  if not me.is_admin then raise exception 'forbidden'; end if;
  if btrim(coalesce(p_date, '')) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid'; end if;
  if p_block then
    insert into public.blocked(date) values (btrim(p_date)) on conflict do nothing;
  else
    delete from public.blocked where date = btrim(p_date);
  end if;
  return public.get_all();
end; $$;

-- พนักงานลืมรหัส → แอดมินรีเซ็ต (ทุกเครื่องของคนนั้นต้องเข้าใหม่)
create or replace function public.staff_reset_pin(p_token text, p_name text)
returns json language plpgsql security definer set search_path = public as $$
declare me public.staff := public._me(p_token); v text := public._canon(p_name);
begin
  if not me.is_admin then raise exception 'forbidden'; end if;
  if not exists(select 1 from public.staff where name = v and pin_hash is not null) then raise exception 'not_found'; end if;
  update public.staff set pin_salt = null, pin_hash = null, failed = 0, locked_until = null where name = v;
  delete from public.sessions where name = v;
  return json_build_object('ok', true, 'name', v);
end; $$;

-- ---------- 8) สิทธิ์ ----------
revoke all on function public._today()                        from public, anon, authenticated;
revoke all on function public._clean_name(text)               from public, anon, authenticated;
revoke all on function public._canon(text)                    from public, anon, authenticated;
revoke all on function public._pin_hash(text, text)           from public, anon, authenticated;
revoke all on function public._me(text)                       from public, anon, authenticated;

revoke all on function public.get_all()                                  from public;
revoke all on function public.staff_status(text)                         from public;
revoke all on function public.staff_login(text, text, text)              from public;
revoke all on function public.staff_whoami(text)                         from public;
revoke all on function public.leave_add(text, text, text, text)          from public;
revoke all on function public.leave_remove(text, bigint)                 from public;
revoke all on function public.day_block(text, text, boolean)             from public;
revoke all on function public.staff_reset_pin(text, text)                from public;
grant execute on function public.get_all()                               to anon, authenticated;
grant execute on function public.staff_status(text)                      to anon, authenticated;
grant execute on function public.staff_login(text, text, text)           to anon, authenticated;
grant execute on function public.staff_whoami(text)                      to anon, authenticated;
grant execute on function public.leave_add(text, text, text, text)       to anon, authenticated;
grant execute on function public.leave_remove(text, bigint)              to anon, authenticated;
grant execute on function public.day_block(text, text, boolean)          to anon, authenticated;
grant execute on function public.staff_reset_pin(text, text)             to anon, authenticated;
