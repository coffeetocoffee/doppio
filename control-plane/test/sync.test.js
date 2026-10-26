import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../zig-out/bin/doppio-control-plane.exe");
const base = "http://127.0.0.1:9096";
const adminToken =
  "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

test("delta sync: snapshot, long-poll updates, and /collect exposure ingest", async () => {
  const proc = spawn(exePath, ["--port", "9096"], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  // Wait for startup
  await new Promise((r) => setTimeout(r, 600));

  try {
    // 1. Create a flag (advances the change seq).
    const create = await fetch(`${base}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "sync-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(create.status, 201);

    // 2. Snapshot contains the new flag.
    const snap = await fetch(`${base}/sync/snapshot`);
    assert.strictEqual(snap.status, 200);
    const snapJson = await snap.json();
    assert.strictEqual(snapJson.type, "snapshot");
    assert.ok(Array.isArray(snapJson.flags));
    assert.ok(snapJson.flags.some((f) => f.key === "sync-flag"));
    assert.ok(snapJson.seq >= 1);

    // 3. Long-poll /sync/updates/{after_seq} with a fresh client (seq 0)
    //    returns the delta for the flag immediately.
    const delta = await fetch(`${base}/sync/updates/0`);
    assert.strictEqual(delta.status, 200);
    const deltaJson = await delta.json();
    assert.ok(deltaJson.type === "delta" || deltaJson.type === "snapshot", `expected delta/snapshot, got ${deltaJson.type}`);
    if (deltaJson.type === "delta") {
      assert.ok(deltaJson.changes.some((c) => c.key === "sync-flag"));
    }

    // 4. A client already up to date (seq == current) gets an ack quickly.
    const upToDate = await fetch(`${base}/sync/updates/${snapJson.seq}`);
    assert.strictEqual(upToDate.status, 200);
    const ackJson = await upToDate.json();
    assert.strictEqual(ackJson.type, "ack");

    // 5. Ingest exposures via /collect.
    const collectBody = {
      events: [
        {
          flag_key: "sync-flag",
          user_id: "u-1",
          enabled: true,
          variation: "on",
          timestamp: 1700000001,
          idempotency_key: "idem-1",
        },
        {
          flag_key: "sync-flag",
          user_id: "u-2",
          enabled: false,
          variation: "off",
          timestamp: 1700000002,
          idempotency_key: "idem-2",
        },
      ],
    };
    const collect = await fetch(`${base}/collect`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(collectBody),
    });
    assert.strictEqual(collect.status, 200);
    const collectJson = await collect.json();
    assert.strictEqual(collectJson.accepted, 2);
    assert.strictEqual(collectJson.pending, 2);

    // 6. Re-sending the same idempotency keys is deduplicated (accepted 0).
    const dedup = await fetch(`${base}/collect`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(collectBody),
    });
    const dedupJson = await dedup.json();
    assert.strictEqual(dedupJson.accepted, 0);

    // 7. CORS preflight is allowed on the sync surface.
    const preflight = await fetch(`${base}/sync/snapshot`, { method: "OPTIONS" });
    assert.strictEqual(preflight.status, 204);
    assert.strictEqual(preflight.headers.get("access-control-allow-origin"), "*");
  } finally {
    proc.kill();
  }
});