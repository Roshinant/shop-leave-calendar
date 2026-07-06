/* Service Worker — ทำให้เปิดออฟไลน์ได้ (เก็บหน้าเว็บไว้ในเครื่อง) */
const CACHE = "leave-cal-v3";
const ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./icon.svg",
  "./logo/logo.jpg"
];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);

  // ข้อมูลจาก Google (Apps Script) ให้วิ่งเน็ตตรง ไม่ cache
  if (url.hostname.includes("google.com") || url.hostname.includes("googleusercontent.com")) {
    return;
  }

  // ไฟล์หน้าเว็บ: ใช้ cache ก่อน (เปิดเร็ว + ออฟไลน์ได้) แล้วค่อยอัปเดตเบื้องหลัง
  e.respondWith(
    caches.match(e.request).then((cached) => {
      const fresh = fetch(e.request)
        .then((resp) => {
          caches.open(CACHE).then((c) => c.put(e.request, resp.clone()));
          return resp;
        })
        .catch(() => cached || caches.match("./index.html"));
      return cached || fresh;
    })
  );
});
