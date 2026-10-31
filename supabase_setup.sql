-- ============================================================
-- ตั้งค่าฐานข้อมูล Supabase สำหรับ "หยุดงาน โลตัสมือถือ"
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมดนี้ → Run
--   👉 ก่อน Run แก้บรรทัด admin_key ให้เป็นรหัสแอดมินของหัวหน้า (รหัสเดียวกับที่ใช้อยู่)
-- Run ซ้ำได้ ไม่ทำให้ข้อมูลหาย
-- ============================================================

-- ---------- ตาราง ----------
create table if not exists public.leaves (
  id         bigint generated always as identity primary key,   -- ลำดับการลง (ใช้เรียงชื่อในแต่ละวัน)
  date       text        not null,          -- "YYYY-MM-DD"
  name       text        not null,
  created_at timestamptz not null default now()
);
create index if not exists leaves_date_idx on public.leaves(date);
create unique index if not exists leaves_date_name_uniq on public.leaves(date, lower(name));

create table if not exists public.blocked (   -- วันห้ามหยุด
  date text primary key
);

create table if not exists public.app_config ( -- เก็บรหัสแอดมิน (อ่านไม่ได้จากภายนอก)
  key   text primary key,
  value text
);

-- ---------- ตั้งรหัสแอดมิน (แก้ค่าตรงนี้!) ----------
insert into public.app_config(key, value) values ('admin_key', 'เปลี่ยนรหัสตรงนี้')
  on conflict (key) do update set value = excluded.value;

-- ลบฟังก์ชันเวอร์ชันเก่า (เปลี่ยนชนิดค่าที่คืน)
drop function if exists public.add_leave(text, text, text);
drop function if exists public.remove_leave(text, text);
drop function if exists public.remove_leave(text, text, text);
drop function if exists public.set_blocked(text, boolean, text);

-- ---------- ฟังก์ชัน (ทำงานฝั่ง DB — กฎทุกข้อบังคับที่นี่) ----------
create or replace function public.is_admin(p_key text)
returns boolean language sql security definer stable set search_path = public as $$
  select exists(
    select 1 from public.app_config
    where key = 'admin_key' and value <> 'เปลี่ยนรหัสตรงนี้'
      and coalesce(p_key,'') <> '' and value = p_key
  );
$$;

-- ข้อมูลทั้งหมดในครั้งเดียว: { data: {"2026-07-04":[{name,ts},...]}, blocked: ["2026-08-12",...] }
create or replace function public.get_all()
returns json language sql security definer stable set search_path = public as $$
  select json_build_object(
    'data', coalesce((
      select json_object_agg(date, items) from (
        select date, json_agg(json_build_object('name', name, 'ts', created_at) order by id) as items
        from public.leaves group by date
      ) t), '{}'::json),
    'blocked', coalesce((select json_agg(date order by date) from public.blocked), '[]'::json)
  );
$$;

-- เพิ่มชื่อ: กันวันห้ามหยุด, กันชื่อซ้ำ, จำกัด 4 คน/วัน (แอดมินเพิ่มเกินได้)
create or replace function public.add_leave(p_date text, p_name text, p_key text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  p_date := trim(coalesce(p_date,'')); p_name := trim(coalesce(p_name,''));
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' or p_name = '' or length(p_name) > 60 then raise exception 'invalid'; end if;
  perform pg_advisory_xact_lock(hashtext('leave:' || p_date));   -- ต่อคิวเฉพาะคนที่ลง "วันเดียวกัน"
  if exists(select 1 from public.blocked where date = p_date) then raise exception 'blocked'; end if;
  if exists(select 1 from public.leaves where date = p_date and lower(name) = lower(p_name))
    then raise exception 'duplicate'; end if;
  select count(*) into v_count from public.leaves where date = p_date;
  if v_count >= 4 and not public.is_admin(p_key) then raise exception 'full'; end if;
  insert into public.leaves(date, name) values (p_date, p_name);
  return public.get_all();
end; $$;

-- ลบชื่อ: เฉพาะแอดมิน
create or replace function public.remove_leave(p_date text, p_name text, p_key text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(p_key) then raise exception 'forbidden'; end if;
  delete from public.leaves where date = trim(p_date) and lower(name) = lower(trim(p_name));
  return public.get_all();
end; $$;

-- ตั้ง/ยกเลิกวันห้ามหยุด: เฉพาะแอดมิน
create or replace function public.set_blocked(p_date text, p_block boolean, p_key text default null)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin(p_key) then raise exception 'forbidden'; end if;
  if trim(coalesce(p_date,'')) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'invalid'; end if;
  if p_block then
    insert into public.blocked(date) values (trim(p_date)) on conflict do nothing;
  else
    delete from public.blocked where date = trim(p_date);
  end if;
  return public.get_all();
end; $$;

revoke all on function public.is_admin(text)                     from public;
revoke all on function public.get_all()                          from public;
revoke all on function public.add_leave(text, text, text)        from public;
revoke all on function public.remove_leave(text, text, text)     from public;
revoke all on function public.set_blocked(text, boolean, text)   from public;
grant execute on function public.is_admin(text)                   to anon, authenticated;
grant execute on function public.get_all()                        to anon, authenticated;
grant execute on function public.add_leave(text, text, text)      to anon, authenticated;
grant execute on function public.remove_leave(text, text, text)   to anon, authenticated;
grant execute on function public.set_blocked(text, boolean, text) to anon, authenticated;

-- ---------- ความปลอดภัย (RLS) ----------
alter table public.leaves     enable row level security;
alter table public.blocked    enable row level security;
alter table public.app_config enable row level security;

-- สิทธิ์ตาราง: อ่านได้อย่างเดียว (ใช้กับ realtime) — "เขียน" ต้องผ่านฟังก์ชันด้านบนเท่านั้น
-- (ตั้งเองตรงนี้ จึงใช้ได้ทั้งเปิด/ปิด "Automatically expose new tables" ตอนสร้างโปรเจกต์)
grant usage on schema public to anon, authenticated;
revoke all on public.leaves, public.blocked, public.app_config from anon, authenticated;
grant select on public.leaves, public.blocked to anon, authenticated;

drop policy if exists leaves_read  on public.leaves;
create policy leaves_read  on public.leaves  for select to anon, authenticated using (true);
drop policy if exists blocked_read on public.blocked;
create policy blocked_read on public.blocked for select to anon, authenticated using (true);
-- app_config ไม่มี policy = ห้ามอ่าน/เขียนจากภายนอก (รหัสแอดมินปลอดภัย)

-- ---------- เปิด Realtime (ทุกเครื่องเห็นการเปลี่ยนแปลงทันที) ----------
do $$
begin
  begin alter publication supabase_realtime add table public.leaves;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.blocked; exception when duplicate_object then null; end;
end $$;
