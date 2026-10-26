export { initDoppioServiceWorker } from "./worker.js";

export async function registerServiceWorker(
  swPath = "/doppio-sw.js",
  options?: RegistrationOptions
): Promise<ServiceWorkerRegistration | null> {
  if (typeof window === "undefined" || !("serviceWorker" in navigator)) {
    return null;
  }

  try {
    const registration = await navigator.serviceWorker.register(swPath, options);
    return registration;
  } catch (err) {
    console.warn("Doppio service worker registration failed:", err);
    return null;
  }
}

export async function unregisterServiceWorker(): Promise<boolean> {
  if (typeof window === "undefined" || !("serviceWorker" in navigator)) {
    return false;
  }

  try {
    const registration = await navigator.serviceWorker.getRegistration();
    if (registration) {
      return await registration.unregister();
    }
    return false;
  } catch {
    return false;
  }
}

export function createServiceWorkerScript(): string {
  return `// Doppio Service Worker (Auto-generated)
const CACHE_NAME = "doppio-sw-v1";
const CONFIG_CACHE_URL = "/doppio/cached-config";

self.addEventListener("install", (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("message", async (event) => {
  const { type, payload } = event.data || {};
  if (type === "DOPPIO_SAVE_CONFIG") {
    const cache = await caches.open(CACHE_NAME);
    const response = new Response(JSON.stringify(payload), {
      headers: { "Content-Type": "application/json" }
    });
    await cache.put(CONFIG_CACHE_URL, response);
    if (event.ports && event.ports[0]) {
      event.ports[0].postMessage({ success: true });
    }
  } else if (type === "DOPPIO_GET_CONFIG") {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(CONFIG_CACHE_URL);
    const data = cached ? await cached.json() : null;
    if (event.ports && event.ports[0]) {
      event.ports[0].postMessage({ config: data });
    }
  }
});
`;
}
