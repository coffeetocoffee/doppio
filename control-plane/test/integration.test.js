import test from "node:test";
import assert from "node:assert";
import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const exePath = path.resolve(__dirname, "../../zig-out/bin/doppio-control-plane.exe");

test("control plane live HTTP server: health, openapi, flags, eval", async () => {
  const proc = spawn(exePath, ["--port", "9095"], {
    stdio: ["ignore", "pipe", "pipe"],
  });

  let procErr = "";
  proc.stderr.on("data", (d) => { procErr += d.toString(); });

  // Wait for startup
  await new Promise((r) => setTimeout(r, 600));

  try {
    // 1. Check health
    const healthRes = await fetch("http://127.0.0.1:9095/health");
    assert.strictEqual(healthRes.status, 200);
    const healthJson = await healthRes.json();
    assert.strictEqual(healthJson.status, "ok");

    // 2. Check OpenAPI 3.1
    const openapiRes = await fetch("http://127.0.0.1:9095/openapi.json");
    assert.strictEqual(openapiRes.status, 200);
    const openapiJson = await openapiRes.json();
    assert.strictEqual(openapiJson.openapi, "3.1.0");

    // 3. List flags
    const flagsRes = await fetch("http://127.0.0.1:9095/api/v1/flags");
    assert.strictEqual(flagsRes.status, 200);
    const flagsJson = await flagsRes.json();
    assert.ok(Array.isArray(flagsJson.flags));

    // 4. Create flag with admin token
    const adminToken = "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";
    const createRes = await fetch("http://127.0.0.1:9095/api/v1/flags", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": adminToken,
      },
      body: JSON.stringify({
        key: "search-v2",
        enabled: true,
        rollout_percentage: 100,
      }),
    });
    assert.strictEqual(createRes.status, 201);

    // 5. Evaluate created flag
    const evalRes = await fetch("http://127.0.0.1:9095/api/v1/eval", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        flag_key: "search-v2",
        context: { unit_id: "user_live_test" },
      }),
    });
    assert.strictEqual(evalRes.status, 200);
    const evalJson = await evalRes.json();
    assert.strictEqual(evalJson.flag_key, "search-v2");
    assert.strictEqual(evalJson.enabled, true);
  } catch (err) {
    if (procErr) console.error("Process stderr:", procErr);
    throw err;
  } finally {
    proc.kill();
  }
});
