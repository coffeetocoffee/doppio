import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../zig-out/bin/doppio-control-plane.exe");
const port = 9070;
const base = `http://127.0.0.1:${port}`;

const adminToken =
  "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";
const bearer = { "Content-Type": "application/json", Authorization: `Bearer ${adminToken}` };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test("threaded sync: WebSocket, SSE, and non-blocking accepts", async () => {
  const proc = spawn(exePath, ["--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  // Held open for the whole test so the concurrency check has a live stream.
  let ws = null;
  let sseReader = null;

  try {
    await sleep(700);

    // 1. WebSocket: handshake delivers a snapshot.
    ws = new WebSocket(`ws://127.0.0.1:${port}/sync/ws`);
    const frames = [];
    ws.onmessage = (e) => frames.push(String(e.data));
    await new Promise((res, rej) => {
      ws.onopen = res;
      setTimeout(() => rej(new Error("ws open timeout")), 5000);
    });

    ws.send(JSON.stringify({ type: "hello", last_seq: 0 }));
    await sleep(500);
    assert.match(frames[0], /"type":"snapshot"/, "first frame is a snapshot");
    assert.ok(frames[0].includes('"seq"'), "snapshot carries a sequence");

    // 2. An API change is pushed to the open socket.
    const created = await fetch(`${base}/api/v1/flags`, {
      method: "POST", headers: bearer,
      body: JSON.stringify({ key: "stream-flag", enabled: true, rollout_percentage: 100 }),
    });
    assert.strictEqual(created.status, 201);
    await sleep(900);
    const delta = frames.find((f) => f.includes("stream-flag"));
    assert.ok(delta, "a delta reached the socket");
    assert.match(delta, /"type":"delta"/);

    // 3. Exposure submission over the socket is deduplicated.
    const exposure = {
      type: "exposure",
      exposures: [
        { flagKey: "stream-flag", unitId: "u-1", enabled: true, bucket: 11, reason: "ROLLOUT", idempotencyKey: "ws-idem-1" },
      ],
    };
    const acks = () => frames.filter((f) => f.includes("recorded"));

    ws.send(JSON.stringify(exposure));
    await sleep(600);
    assert.match(acks().at(-1) || "", /"added":1/, "first submission is accepted");

    ws.send(JSON.stringify(exposure));
    await sleep(600);
    assert.match(acks().at(-1) || "", /"added":0/, "the duplicate is deduplicated");
    assert.match(acks().at(-1) || "", /"count":1/, "only one exposure is stored");

    // 4. SSE delivers the same delta as chunked events.
    const sse = await fetch(`${base}/sync/stream`);
    assert.strictEqual(sse.status, 200);
    assert.match(sse.headers.get("content-type"), /text\/event-stream/);
    sseReader = sse.body.getReader();

    const changed = await fetch(`${base}/api/v1/flags`, {
      method: "POST", headers: bearer,
      body: JSON.stringify({ key: "stream-flag", enabled: false, rollout_percentage: 0 }),
    });
    assert.strictEqual(changed.status, 201);

    const decoder = new TextDecoder();
    let sseBuf = "";
    let sseEvent = null;
    const deadline = Date.now() + 6000;
    while (Date.now() < deadline && !sseEvent) {
      const { done, value } = await sseReader.read();
      if (done) break;
      sseBuf += decoder.decode(value, { stream: true });
      let boundary;
      while ((boundary = sseBuf.indexOf("\n\n")) !== -1) {
        const raw = sseBuf.slice(0, boundary);
        sseBuf = sseBuf.slice(boundary + 2);
        if (raw.includes("stream-flag")) {
          sseEvent = raw;
          break;
        }
      }
    }
    assert.ok(sseEvent, "the change arrived as an SSE event");
    assert.match(sseEvent, /^event: delta/);
    // A cold client starting at seq 0 is stale, so the first message is a
    // full snapshot; later ones are deltas.
    assert.match(sseEvent, /"type":"(snapshot|delta)"/);
    assert.ok(sseEvent.includes("stream-flag"), "the event names the changed flag");

    // 5. A long-lived stream does not stall the accept loop. With an SSE
    //    connection and a WebSocket both open, concurrent requests must not
    //    queue behind them.
    const started = Date.now();
    const responses = await Promise.all(
      Array.from({ length: 5 }, () => fetch(`${base}/health`).then((r) => r.status)),
    );
    const elapsed = Date.now() - started;
    assert.deepStrictEqual(responses, [200, 200, 200, 200, 200]);
    assert.ok(elapsed < 1000, `5 concurrent requests took ${elapsed}ms, expected under 1000ms`);

    // 6. A WebSocket survives the client closing cleanly.
    ws.close();
    await sleep(400);
    assert.strictEqual(ws.readyState, WebSocket.CLOSED, "socket closed cleanly");
    ws = null;

    // The server is still healthy after a disconnect.
    const afterClose = await fetch(`${base}/health`);
    assert.strictEqual(afterClose.status, 200);
  } catch (err) {
    if (procErr) console.error("Process stderr:", procErr);
    throw err;
  } finally {
    // Always release the sockets, or the runner's event loop stays alive.
    if (ws) ws.close();
    if (sseReader) sseReader.cancel().catch(() => {});
    proc.kill();
  }
});
