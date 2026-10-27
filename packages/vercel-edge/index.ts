// Vercel Edge adapter: Edge Config bootstrap, polling deltas
export interface EdgeConfig {
  get(key: string): Promise<any>;
}

export class EdgeConfigStorage {
  constructor(private ec: EdgeConfig) {}
  async get(key: string): Promise<string | null> {
    const v = await this.ec.get(key);
    return v == null ? null : JSON.stringify(v);
  }
  async set(key: string, value: string): Promise<void> {
    // Edge Config is read-only at runtime; writes go through the Vercel API
    throw new Error("Edge Config is read-only at runtime");
  }
  async remove(key: string): Promise<void> {
    throw new Error("Edge Config is read-only at runtime");
  }
}

export async function handler(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/bootstrap") {
    // read flags from Edge Config
    return new Response(JSON.stringify({ ok: true }), {
      headers: { "content-type": "application/json" },
    });
  }
  return new Response("not found", { status: 404 });
}

export default handler;