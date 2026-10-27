// Netlify Edge adapter (Deno runtime) — shim over standard web APIs
export default async (request: Request, context: any) => {
  const url = new URL(request.url);
  if (url.pathname === "/snapshot") {
    // Netlify Blobs for state
    const store = await import("https://esm.sh/@netlify/blobs");
    const blobStore = store.getStore("flags");
    const flags = await blobStore.get("flags", { type: "json" });
    return new Response(JSON.stringify(flags ?? []), {
      headers: { "content-type": "application/json" },
    });
  }
  return new Response("not found", { status: 404 });
};