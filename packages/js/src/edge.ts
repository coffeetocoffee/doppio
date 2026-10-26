import { Doppio } from "./client.js";
import { DoppioOptions } from "./types.js";

export { Doppio };

export async function createEdgeClient(options: DoppioOptions): Promise<Doppio> {
  const edgeOptions: DoppioOptions = {
    ...options,
    offline: false, // Edge runtimes do not use IndexedDB
    syncStrategy: options.syncStrategy || "delta-poll",
    pollInterval: options.pollInterval || 5000,
  };

  const client = await Doppio.init(edgeOptions);

  // If an endpoint is provided, warm the flag set from the delta-sync
  // surface. The long-poll /sync/updates/{after_seq} route doubles as a
  // resolution-tolerant initial fetch, and /sync/snapshot covers the case
  // where we need a full rebuild.
  if (edgeOptions.endpoint) {
    try {
      const flags = await client.syncOnce();
      if (flags.length > 0) return client;
    } catch {
      // Fall through to flags supplied by the caller
    }

    try {
      const resp = await fetch(`${edgeOptions.endpoint}/sync/snapshot`, {
        headers: edgeOptions.clientKey ? { Authorization: `Bearer ${edgeOptions.clientKey}` } : {},
      });
      if (resp.ok) {
        const data = await resp.json();
        if (data.flags && data.flags.length > 0) {
          await client.setFlags(
            data.flags.map((f: Record<string, unknown>) => ({
              key: f.key as string,
              enabled: (f.enabled as boolean) ?? true,
              rolloutPercentage: f.rollout_percentage as number | undefined,
            })),
          );
        }
      }
    } catch {
      // Continue with provided flags on fetch error
    }
  }

  return client;
}
