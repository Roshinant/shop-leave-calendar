-- ============================================================
-- ตั้งค่าฐานข้อมูล Supabase สำหรับ "หยุดงาน โลตัสมือถือ"
-- วิธีใช้: Supabase → เมนู SQL Editor → New query → วางทั้งหมดนี้ → Run
-- ============================================================

-- ตารางเก็บวันหยุด
create table if not exists public.leaves (
  id         bigint generated always as identity primary key,
  date       text        not null,          -- รูปแบบ "YYYY-MM-DD"
  name       text        not null,
  created_at timestamptz not null default now()
);

-- กันชื่อซ้ำในวันเดียวกัน (ไม่สนตัวพิมพ์เล็ก/ใหญ่)
create unique index if not exists leaves_date_name_uniq on public.leaves (date, lower(name));
-- ช่วยค้นหาตามวันที่ให้เร็ว
create index if not exists leaves_date_idx on public.leaves (date);

-- จำกัดวันละ 3 คน (เช็คที่ฐานข้อมูล + ล็อกกันเขียนชนกันต่อวัน)
create or replace function public.enforce_leave_limit()
returns trigger language plpgsql as $$
declare cnt int;
begin
  perform pg_advisory_xact_lock(hashtext(new.date));   -- กันสองคนเพิ่มพร้อมกันจนเกิน 3
  select count(*) into cnt from public.leaves where date = new.date;
  if cnt >= 3 then
    raise exception 'LEAVE_LIMIT_REACHED';
  end if;
  return new;
end; $$;

drop trigger if exists trg_leave_limit on public.leaves;
create trigger trg_leave_limit
  before insert on public.leaves
  for each row execute function public.enforce_leave_limit();

-- เปิด Row Level Security แล้วอนุญาตให้ทุกคน (ไม่ต้องล็อกอิน) อ่าน/เพิ่ม/ลบ ได้
alter table public.leaves enable row level security;

drop policy if exists "public read"   on public.leaves;
drop policy if exists "public insert" on public.leaves;
drop policy if exists "public delete" on public.leaves;

create policy "public read"   on public.leaves for select to anon using (true);
create policy "public insert" on public.leaves for insert to anon with check (true);
create policy "public delete" on public.leaves for delete to anon using (true);
