-- ============================================================
-- v3: แอดมินเพิ่ม "คนอื่น" ลงวันได้ แม้วันเต็มแล้ว / วันผ่านมาแล้ว / วันห้ามหยุด
-- รันต่อจาก supabase_v2_staff.sql · รันซ้ำได้
-- (ใช้ตอนพนักงานแจ้งด้วยปากว่าขอหยุด แล้วแอดมินลงให้)
-- ============================================================

create or replace function public.leave_add_for(p_token text, p_name text, p_date text, p_type text, p_half text default null)
returns json language plpgsql security definer set search_path = public as $$
declare me public.staff := public._me(p_token); v text := public._canon(p_name);
begin
  if not me.is_admin then raise exception 'forbidden'; end if;
  if v = '' or length(v) > 20 or v ~ '[()]' or v ~ '^[0-9 ]+$' then raise exception 'bad_name'; end if;
  p_date := btrim(coalesce(p_date, ''));
  if p_date !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p_type, '') not in ('off','leave','sick','half') then
    raise exception 'invalid';
  end if;
  if p_type <> 'half' then p_half := null;
  elsif p_half is not null and p_half not in ('เช้า','บ่าย') then raise exception 'invalid'; end if;

  perform pg_advisory_xact_lock(hashtext('leave:' || p_date));
  if exists(select 1 from public.leaves where date = p_date and lower(name) = lower(v)) then
    raise exception 'duplicate_other';
  end if;
  -- แอดมินเพิ่มให้ได้ทุกกรณี: ไม่เช็คโควตา 4 คน / วันห้ามหยุด / ย้อนหลัง
  insert into public.leaves(date, name, type, half) values (p_date, v, p_type, p_half);
  return public.get_all();
end; $$;

revoke all on function public.leave_add_for(text, text, text, text, text) from public;
grant execute on function public.leave_add_for(text, text, text, text, text) to anon, authenticated;
