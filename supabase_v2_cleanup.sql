-- ============================================================
-- v2 (ขั้นสุดท้าย): ปิดฟังก์ชันของแอปเวอร์ชันเก่า — รัน "หลัง" ขึ้นเว็บเวอร์ชันใหม่แล้วเท่านั้น
-- แอปเก่าลงชื่อใครก็ได้โดยไม่ต้องเข้าระบบ จึงต้องปิด ไม่งั้นข้ามระบบรหัสได้
-- ============================================================
drop function if exists public.add_leave(text, text, text);
drop function if exists public.remove_leave(text, text, text);
drop function if exists public.set_blocked(text, boolean, text);
-- is_admin ยังใช้ภายใน (ยืนยันแอดมินตอนตั้งรหัสครั้งแรก) แต่ไม่ให้เรียกจากภายนอกแล้ว
revoke all on function public.is_admin(text) from public, anon, authenticated;
