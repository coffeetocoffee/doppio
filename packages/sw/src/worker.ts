// Service worker implementation for Doppio offline cache and background sync
const CACHE_NAME = "doppio-sw-v1";
const CONFIG_CACHE_URL = "/doppio/cached-config";

export function initDoppioServiceWorker(swContext: any = globalThis): void {
  swContext.addEventListener("install", (event: any) => {
    event.waitUntil(swContext.skipWaiting());
  });

  swContext.addEventListener("activate", (event: any) => {
    event.waitUntil(swContext.clients.claim());
  });

  swContext.addEventListener("message", async (event: any) => {
    const { type, payload } = event.data || {};
    if (type === "DOPPIO_SAVE_CONFIG") {
      const cache = await caches.open(CACHE_NAME);
      const response = new Response(JSON.stringify(payload), {
        headers: { "Content-Type": "application/json" },
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

  swContext.addEventListener("sync", (event: any) => {
    if (event.tag === "doppio-sync-flags") {
      event.waitUntil(syncFlags());
    }
  });
}

async function syncFlags(): Promise<void> {
  try {
    const cache = await caches.open(CACHE_NAME);
    const cached = await cache.match(CONFIG_CACHE_URL);
    if (!cached) return;
    const config = await cached.json();
    if (config && config.endpoint) {
      const response = await fetch(`${config.endpoint}/config`, {
        headers: config.clientKey ? { Authorization: `Bearer ${config.clientKey}` } : {},
      });
      if (response.ok) {
        const fresh = await response.json();
        await cache.put(CONFIG_CACHE_URL, new Response(JSON.stringify(fresh)));
      }
    }
  } catch {
    // Retry on next background sync cycle
  }
}
