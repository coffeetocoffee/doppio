import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { Doppio, SyncClient, normalizeServerFlag } from "../dist/index.js";
import { createEdgeClient } from "../dist/edge.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../../zig-out/bin/doppio-control-plane.exe");
const port = 9097;
const endpoint = `http://127.0.0.1:${port}`;

const adminToken =
  "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** A fetch stub that serves canned responses keyed by URL substring. */
function makeFetchStub(routes) {
  const calls = [];
  const stub = async (url, init = {}) => {
    calls.push({ url: String(url), method: init?.method || "GET" });
    for (const route of routes) {
      if (String(url).includes(route.match)) {
        if (typeof route.body === "function") {
          const value = route.body(init);
          if (value === null) continue;
          return {
            ok: route.ok !== false,
            status: route.status || 200,
            json: async () => value,
          };
        }
        return {
          ok: route.ok !== false,
          status: route.status || 200,
          json: async () => route.body,
        };
      }
    }
    return { ok: false, status: 404, json: async () => ({ type: "error" }) };
  };
  stub.calls = calls;
  return stub;
}

test("normalizeServerFlag maps the server payload to a FlagDefinition", () => {
  assert.deepStrictEqual(
    normalizeServerFlag({ key: "f1", enabled: true, rollout_percentage: 40, version: 3 }),
    { key: "f1", enabled: true, rolloutPercentage: 40 },
  );

  // Missing enabled defaults to true; out of range percentages clamp.
  assert.deepStrictEqual(
    normalizeServerFlag({ key: "f2", rollout_percentage: 900 }),
    { key: "f2", enabled: true, rolloutPercentage: 100 },
  );
  assert.deepStrictEqual(
    normalizeServerFlag({ key: "f3", enabled: false }),
    { key: "f3", enabled: false },
  );

  // Deleted flags and junk are rejected, not half-normalized.
  assert.strictEqual(normalizeServerFlag({ key: "f4", enabled: true, deleted: true }), null);
  assert.strictEqual(normalizeServerFlag(null), null);
  assert.strictEqual(normalizeServerFlag({ enabled: true }), null);
});

test("SyncClient: applySnapshot is authoritative and applyDelta upserts", () => {
  const client = new SyncClient({
    endpoint: "http://unused",
    strategy: "manual",
    pollInterval: 5000,
    flushInterval: 0,
    backoffBaseMs: 500,
    backoffCapMs: 30000,
    jitterRatio: 0,
  });

  let changes = 0;
  client.onFlagsChange(() => changes++);

  client.applySnapshot({
    type: "snapshot",
    seq: 4,
    flags: [
      { key: "a", enabled: true, rollout_percentage: 10 },
      { key: "b", enabled: false, rollout_percentage: 50 },
    ],
  });
  assert.deepStrictEqual(
    client.getFlags().map((f) => f.key).sort(),
    ["a", "b"],
  );
  assert.strictEqual(client.getStatus().lastSeq, 4);
  assert.strictEqual(changes, 1);

  client.applyDelta({
    type: "delta",
    seq: 5,
    changes: [
      { key: "c", deleted: false, enabled: true, rollout_percentage: 100, seq: 5 },
      { key: "a", deleted: true, enabled: false, rollout_percentage: 0, seq: 5 },
      { key: "b", deleted: false, enabled: true, rollout_percentage: 75, seq: 5 },
    ],
  });
  const after = new Map(client.getFlags().map((f) => [f.key, f]));
  assert.strictEqual(after.has("a"), false, "deleted flag is removed");
  assert.strictEqual(after.get("b").rolloutPercentage, 75, "existing flag is updated");
  assert.strictEqual(after.get("c").rolloutPercentage, 100, "new flag is added");
  assert.strictEqual(client.getStatus().lastSeq, 5);
  assert.strictEqual(changes, 2);

  // handleMessage routes by type.
  const last = client.handleMessage({ type: "ack", seq: 9 });
  assert.strictEqual(last, null);
  assert.strictEqual(client.getStatus().lastSeq, 9);
});

test("SyncClient: backoffDelay grows exponentially and is capped", () => {
  const client = new SyncClient({
    endpoint: "http://unused",
    strategy: "manual",
    pollInterval: 5000,
    flushInterval: 0,
    backoffBaseMs: 500,
    backoffCapMs: 4000,
    jitterRatio: 0,
  });

  assert.strictEqual(client.backoffDelay(0), 0);
  assert.strictEqual(client.backoffDelay(1), 500);
  assert.strictEqual(client.backoffDelay(2), 1000);
  assert.strictEqual(client.backoffDelay(3), 2000);
  assert.strictEqual(client.backoffDelay(4), 4000);
  assert.strictEqual(client.backoffDelay(5), 4000, "capped");
  assert.strictEqual(client.backoffDelay(50), 4000, "still capped");
});

test("SyncClient: makeIdempotencyKey is stable per exposure event", () => {
  const client = new SyncClient({
    endpoint: "http://unused",
    strategy: "manual",
    pollInterval: 5000,
    flushInterval: 0,
    backoffBaseMs: 500,
    backoffCapMs: 30000,
    jitterRatio: 0,
  });

  const exposure = {
    flagKey: "flag-a",
    unitId: "u-1",
    enabled: true,
    variation: "on",
    bucket: 1234,
    timestamp: 1700000000,
    reason: "ROLLOUT",
  };

  const key = client.makeIdempotencyKey(exposure);
  assert.strictEqual(key, client.makeIdempotencyKey({ ...exposure }), "same event, same key");
  assert.strictEqual(
    key,
    client.makeIdempotencyKey({ ...exposure, enabled: false, reason: "OTHER" }),
    "non-identifying fields do not change the key",
  );
  assert.notStrictEqual(
    key,
    client.makeIdempotencyKey({ ...exposure, timestamp: 1700000001 }),
    "a distinct event gets a distinct key",
  );
  assert.strictEqual(
    client.makeIdempotencyKey({ ...exposure, idempotencyKey: "explicit" }),
    "explicit",
    "an explicit key wins",
  );
});

test("SyncClient: flush posts idempotent events and keeps them on failure", async () => {
  let posted = null;
  const client = new SyncClient({
    endpoint: "http://127.0.0.1:1",
    strategy: "manual",
    pollInterval: 5000,
    flushInterval: 0,
    backoffBaseMs: 500,
    backoffCapMs: 30000,
    jitterRatio: 0,
    fetchImpl: makeFetchStub([
      {
        match: "/collect",
        body: (init) => {
          posted = JSON.parse(init.body);
          return { accepted: posted.events.length, pending: posted.events.length };
        },
      },
    ]),
  });

  const exposure = {
    flagKey: "flag-a",
    unitId: "u-1",
    enabled: true,
    variation: "on",
    bucket: 7,
    timestamp: 1700000000,
    reason: "ROLLOUT",
  };
  client.queueExposure(exposure);
  client.queueExposure(exposure);

  const ok = await client.flush();
  assert.deepStrictEqual(ok, { sent: 2, kept: 0, ok: true });
  assert.strictEqual(posted.events.length, 2);
  assert.strictEqual(posted.events[0].flag_key, "flag-a");
  assert.strictEqual(posted.events[0].user_id, "u-1");
  assert.strictEqual(client.getPendingExposures().length, 0, "queue drained on success");
  assert.strictEqual(client.stats.flushes, 1);

  // Retry with the same events is deduplicated by the server; the local queue
  // re-sends and the server collapses duplicates.
  const failing = new SyncClient({
    endpoint: "http://127.0.0.1:2",
    strategy: "manual",
    pollInterval: 5000,
    flushInterval: 0,
    backoffBaseMs: 500,
    backoffCapMs: 30000,
    jitterRatio: 0,
    fetchImpl: async () => {
      throw new Error("network down");
    },
  });
  failing.queueExposure(exposure);
  const failed = await failing.flush();
  assert.deepStrictEqual(failed, { sent: 0, kept: 1, ok: false });
  assert.strictEqual(failing.getPendingExposures().length, 1, "unsent events are retained");
});

test("SyncClient: auto strategy falls back sse/ws error to delta-poll", async () => {
  const flags = [{ key: "fallback-flag", enabled: true, rollout_percentage: 100 }];
  const client = new SyncClient({
    endpoint: "http://127.0.0.1:3",
    strategy: "auto",
    pollInterval: 50,
    flushInterval: 0,
    backoffBaseMs: 1,
    backoffCapMs: 10,
    jitterRatio: 0,
    fetchImpl: async (url, init = {}) => {
      const u = String(url);
      if (u.endsWith("/sync/ws") || u.endsWith("/sync/stream")) {
        return { ok: false, status: 501, json: async () => ({}) };
      }
      if (u.includes("/sync/updates/")) {
        return {
          ok: true,
          status: 200,
          json: async () => (client.getStatus().lastSeq === null
            ? { type: "snapshot", seq: 1, flags }
            : { type: "ack", seq: client.getStatus().lastSeq }),
        };
      }
      return { ok: true, status: 200, json: async () => ({ type: "ack", seq: 1 }) };
    },
  });

  const seen = [];
  client.onFlagsChange((f) => seen.push(f));

  await client.start();
  await sleep(150);
  client.stop();

  assert.ok(
    seen.some((set) => set.some((f) => f.key === "fallback-flag")),
    "flags arrive even though ws and sse both failed",
  );
  assert.strictEqual(client.getStatus().transport, "delta-poll", "settled on delta-poll");
});

test("Doppio with endpoint: delta-poll receives flags and flushes exposures", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  try {
    await sleep(600);

    const seed = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "js-sync-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(seed.status, 201);

    const doppio = await Doppio.init({
      clientKey: "js_key",
      offline: false,
      endpoint,
      syncStrategy: "delta-poll",
      pollInterval: 300,
    });

    // The first delta poll replaces the (empty) flag set.
    await sleep(700);
    assert.strictEqual(doppio.isEnabled("js-sync-flag", { unitId: "u-1" }), true);

    // Push a change and watch it propagate without a restart.
    const update = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "js-sync-flag", enabled: false, rollout_percentage: 0 }),
    });
    assert.strictEqual(update.status, 201);
    await sleep(1400);
    assert.strictEqual(doppio.isEnabled("js-sync-flag", { unitId: "u-1" }), false);

    // Evaluation queue is flushed to /collect and accepted.
    assert.ok(doppio.getExposures().length > 0, "evaluation queued an exposure");
    await doppio.flushExposuresRemote();
    assert.strictEqual(doppio.sync.stats.flushes, 1, "flush reported success");

    doppio.stopSync();
  } finally {
    proc.kill();
  }
});

test("Doppio auto strategy: upgrades to WebSocket and receives flags", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  // Declared outside try so the finally block can always release the socket;
  // a leaked WebSocket keeps the test runner's event loop alive.
  let doppio = null;

  try {
    await sleep(600);

    const seed = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "auto-ws-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(seed.status, 201);

    doppio = await Doppio.init({
      offline: false,
      endpoint,
      syncStrategy: "auto",
      pollInterval: 100,
    });

    // Auto walks ws first, and ws is implemented, so it should settle there.
    await sleep(900);
    assert.strictEqual(doppio.getSyncStatus().transport, "websocket", "upgraded to WebSocket");
    assert.strictEqual(doppio.isEnabled("auto-ws-flag", { unitId: "u-1" }), true);

    // A change made through the API arrives over the socket.
    const update = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "auto-ws-flag", enabled: false, rollout_percentage: 0 }),
    });
    assert.strictEqual(update.status, 201);
    await sleep(900);
    assert.strictEqual(doppio.isEnabled("auto-ws-flag", { unitId: "u-1" }), false);
  } finally {
    doppio?.stopSync();
    proc.kill();
  }
});

test("Doppio delta-poll strategy still receives flags", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  try {
    await sleep(600);

    const seed = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "auto-fallback-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(seed.status, 201);

    const doppio = await Doppio.init({
      offline: false,
      endpoint,
      syncStrategy: "auto",
      pollInterval: 300,
    });

    await sleep(1400);
    assert.strictEqual(doppio.isEnabled("auto-fallback-flag", { unitId: "u-1" }), true);
    assert.strictEqual(doppio.getSyncStatus().transport, "websocket", "upgraded to WebSocket");

    doppio.stopSync();
  } finally {
    proc.kill();
  }
});

test("edge client: syncOnce pulls flags from the delta-sync surface", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  try {
    await sleep(600);

    const seed = await fetch(`${endpoint}/api/v1/flags`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": adminToken },
      body: JSON.stringify({ key: "edge-sync-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(seed.status, 201);

    const edge = await createEdgeClient({ offline: false, endpoint, pollInterval: 100000 });
    assert.strictEqual(edge.isEnabled("edge-sync-flag", { unitId: "edge-user" }), true);
    edge.stopSync();
  } finally {
    proc.kill();
  }
});

