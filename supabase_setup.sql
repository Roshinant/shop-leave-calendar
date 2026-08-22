-- ============================================================
-- ตั้งค่าฐานข้อมูล Supabase สำหรับ "หยุดงาน โลตัสมือถือ"
-- วิธีใช้: Supabase → SQL Editor → New query → วางทั้งหมดนี้ → Run
--   👉 ก่อน Run แก้บรรทัด admin_key ให้เป็นรหัสลับของหัวหน้า
-- ============================================================

-- ---------- ตาราง ----------
create table if not exists public.leaves (
  id         bigint generated always as identity primary key,
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

-- ---------- ฟังก์ชันบังคับกฎ (ทำงานฝั่ง DB) ----------
create or replace function public.is_admin(p_key text)
returns boolean language sql security definer stable as $$
  select exists(
    select 1 from public.app_config
    where key = 'admin_key' and coalesce(p_key,'') <> '' and value = p_key
  );
$$;

-- เพิ่มชื่อ: กันวันห้ามหยุด, กันชื่อซ้ำ, จำกัด 3 คน (แอดมินเกินได้)
create or replace function public.add_leave(p_date text, p_name text, p_key text default null)
returns void language plpgsql security definer as $$
declare v_admin boolean; v_count int;
begin
  p_date := trim(p_date); p_name := trim(p_name);
  if p_date = '' or p_name = '' then raise exception 'invalid'; end if;
  if exists(select 1 from public.blocked where date = p_date) then raise exception 'blocked'; end if;
  perform pg_advisory_xact_lock(hashtext(p_date));   -- กันเพิ่มพร้อมกันจนเกิน
  if exists(select 1 from public.leaves where date = p_date and lower(name) = lower(p_name))
    then raise exception 'duplicate'; end if;
  v_admin := public.is_admin(p_key);
  select count(*) into v_count from public.leaves where date = p_date;
  if v_count >= 3 and not v_admin then raise exception 'full'; end if;
  insert into public.leaves(date, name) values (p_date, p_name);
end; $$;

-- ลบชื่อ: ทุกคนลบได้
create or replace function public.remove_leave(p_date text, p_name text)
returns void language plpgsql security definer as $$
begin
  delete from public.leaves where date = trim(p_date) and lower(name) = lower(trim(p_name));
end; $$;

-- ตั้ง/ยกเลิกวันห้ามหยุด: เฉพาะแอดมิน
create or replace function public.set_blocked(p_date text, p_block boolean, p_key text)
returns void language plpgsql security definer as $$
begin
  if not public.is_admin(p_key) then raise exception 'forbidden'; end if;
  if p_block then
    insert into public.blocked(date) values (trim(p_date)) on conflict do nothing;
  else
    delete from public.blocked where date = trim(p_date);
  end if;
end; $$;

grant execute on function public.is_admin(text)                to anon;
grant execute on function public.add_leave(text, text, text)   to anon;
grant execute on function public.remove_leave(text, text)      to anon;
grant execute on function public.set_blocked(text, boolean, text) to anon;

-- ---------- ความปลอดภัย (RLS) ----------
alter table public.leaves     enable row level security;
alter table public.blocked    enable row level security;
alter table public.app_config enable row level security;

-- อ่านได้ทุกคน (ใช้แสดงผล + realtime) แต่ "เขียน" ต้องผ่านฟังก์ชันด้านบนเท่านั้น
drop policy if exists leaves_read  on public.leaves;
create policy leaves_read  on public.leaves  for select to anon using (true);
drop policy if exists blocked_read on public.blocked;
create policy blocked_read on public.blocked for select to anon using (true);
-- app_config ไม่มี policy = ห้ามอ่าน/เขียนจากภายนอก (รหัสแอดมินปลอดภัย)

-- ---------- เปิด Realtime ----------
alter publication supabase_realtime add table public.leaves;
alter publication supabase_realtime add table public.blocked;
