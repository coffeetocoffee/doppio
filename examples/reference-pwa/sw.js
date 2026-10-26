// Doppio Reference PWA Service Worker
const CACHE_NAME = "doppio-pwa-v1";
const STATIC_ASSETS = ["/", "/index.html", "/app.js", "/manifest.json"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("fetch", (event) => {
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request).catch(() => caches.match("/index.html")))
  );
});

self.addEventListener("message", async (event) => {
  const { type, payload } = event.data || {};
  if (type === "DOPPIO_SAVE_CONFIG") {
    const cache = await caches.open(CACHE_NAME);
    await cache.put("/doppio/cached-config", new Response(JSON.stringify(payload)));
  }
});
