/* Service Worker — ออนไลน์ = โหลดของล่าสุดเสมอ, ออฟไลน์ = ใช้ของที่เก็บไว้ */
const CACHE = "leave-cal-v10";
const ASSETS = [
  "./",
  "./index.html",
  "./manifest.webmanifest",
  "./logo/logo.jpg",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-maskable-512.png",
  "./icons/apple-touch-icon.png"
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
  const req = e.request;
  const url = new URL(req.url);

  // ข้อมูลจาก Google (Apps Script) ให้วิ่งเน็ตตรง ไม่ยุ่ง
  if (url.hostname.includes("google.com") || url.hostname.includes("googleusercontent.com")) return;

  const isDoc = req.mode === "navigate" || req.destination === "document" || url.pathname.endsWith(".html");

  if (isDoc) {
    // หน้าเว็บ = network-first: ออนไลน์เอาของล่าสุดเสมอ, เน็ตหลุดค่อยใช้ของเก่า
    e.respondWith(
      fetch(req)
        .then((resp) => {
          caches.open(CACHE).then((c) => c.put("./index.html", resp.clone()));
          return resp;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match("./index.html")))
    );
    return;
  }

  // ไฟล์อื่น (ไอคอน/manifest) = ใช้ของที่เก็บไว้ก่อนแล้วอัปเดตเบื้องหลัง
  e.respondWith(
    caches.match(req).then((cached) => {
      const fresh = fetch(req)
        .then((resp) => { caches.open(CACHE).then((c) => c.put(req, resp.clone())); return resp; })
        .catch(() => cached);
      return cached || fresh;
    })
  );
});
