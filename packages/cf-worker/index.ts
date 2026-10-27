// Cloudflare Workers adapter: KV-backed state, Cache API for snapshots
export interface Env {
  FLAGS_KV: KVNamespace;
  CACHE: Cache;
}

export class KvStorage {
  constructor(private kv: KVNamespace) {}
  async get(key: string): Promise<string | null> {
    return this.kv.get(key);
  }
  async set(key: string, value: string): Promise<void> {
    await this.kv.put(key, value);
  }
  async remove(key: string): Promise<void> {
    await this.kv.delete(key);
  }
}

export async function handleRequest(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/snapshot") {
    const cache = env.CACHE;
    const cacheKey = new Request(url.toString());
    let resp = await cache.match(cacheKey);
    if (!resp) {
      const flags = await env.FLAGS_KV.get("flags", "json");
      resp = new Response(JSON.stringify(flags ?? []), {
        headers: { "content-type": "application/json", "cache-control": "max-age=60" },
      });
      await cache.put(cacheKey, resp.clone());
    }
    return resp;
  }
  return new Response("not found", { status: 404 });
}

export default { fetch: handleRequest };