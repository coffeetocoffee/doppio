import test from "node:test";
import assert from "node:assert";
import { Doppio, WasmCore } from "../dist/index.js";
import { createEdgeClient } from "../dist/edge.js";

test("WASM core: ABI and deterministic bucketing parity with Zig", async () => {
  const wasm = await WasmCore.init();
  assert.strictEqual(wasm.getAbiVersion(), 1);

  // Cross-platform parity test: must match 20826 from Zig core
  const bucket = wasm.computeBucket("checkout-redesign", "user-123");
  assert.strictEqual(bucket, 20826);

  // Rollout checks
  assert.strictEqual(wasm.isEnabled("checkout-redesign", "user-123", 25), true); // 20826 < 25000
  assert.strictEqual(wasm.isEnabled("checkout-redesign", "user-123", 20), false); // 20826 >= 20000
  assert.strictEqual(wasm.isEnabled("checkout-redesign", "user-123", 100), true);
  assert.strictEqual(wasm.isEnabled("checkout-redesign", "user-123", 0), false);
});

test("Doppio client: evaluation, variations, and exposures", async () => {
  const doppio = await Doppio.init({
    clientKey: "test_key",
    flags: [
      {
        key: "checkout-redesign",
        enabled: true,
        rolloutPercentage: 25,
        variations: [
          { key: "off", value: "false" },
          { key: "on", value: "true" },
        ],
        defaultVariation: 1,
      },
      {
        key: "theme",
        enabled: true,
        rules: [
          {
            id: "vip-rule",
            priority: 1,
            expression: 'account.plan == "enterprise"',
            variation: 1,
          },
        ],
        variations: [
          { key: "standard", value: "blue" },
          { key: "vip", value: "gold" },
        ],
        defaultVariation: 0,
      },
    ],
  });

  // Evaluate checkout-redesign
  const res = doppio.get("checkout-redesign", { userId: "user-123" });
  assert.strictEqual(res.enabled, true);
  assert.strictEqual(res.bucket, 20826);
  assert.strictEqual(res.reason, "ROLLOUT");
  assert.strictEqual(res.value, true);

  // Evaluate targeting rule for enterprise
  const enterpriseRes = doppio.get("theme", { userId: "user-1", plan: "enterprise" });
  assert.strictEqual(enterpriseRes.enabled, true);
  assert.strictEqual(enterpriseRes.reason, "TARGET_MATCH");
  assert.strictEqual(enterpriseRes.variation, "vip");
  assert.strictEqual(enterpriseRes.value, "gold");

  // Evaluate non-enterprise
  const regularRes = doppio.get("theme", { userId: "user-2", plan: "free" });
  assert.strictEqual(regularRes.enabled, true);
  assert.strictEqual(regularRes.variation, "standard");
  assert.strictEqual(regularRes.value, "blue");

  // Exposures queue
  const exposures = doppio.getExposures();
  assert.strictEqual(exposures.length, 3);
  assert.strictEqual(exposures[0].flagKey, "checkout-redesign");
  assert.strictEqual(exposures[0].unitId, "user-123");

  const flushed = doppio.flushExposures();
  assert.strictEqual(flushed.length, 3);
  assert.strictEqual(doppio.getExposures().length, 0);

  // Telemetry track
  doppio.track("purchase", { amount: 99.0 });
  const metrics = doppio.flushMetrics();
  assert.strictEqual(metrics.length, 1);
  assert.strictEqual(metrics[0].eventName, "purchase");
  assert.strictEqual(metrics[0].payload.amount, 99.0);
});

test("Doppio client: change events on setFlags", async () => {
  const doppio = await Doppio.init();
  let changedCount = 0;
  let changedKeys = [];

  doppio.on("change", (keys) => {
    changedCount++;
    changedKeys = keys;
  });

  await doppio.setFlags([
    {
      key: "new-feature",
      enabled: true,
      rolloutPercentage: 100,
    },
  ]);

  assert.strictEqual(changedCount, 1);
  assert.deepStrictEqual(changedKeys, ["new-feature"]);
  assert.strictEqual(doppio.isEnabled("new-feature", { userId: "any" }), true);
});

test("Edge client: creates ready client with delta-poll strategy", async () => {
  const edgeDoppio = await createEdgeClient({
    clientKey: "edge_key",
    flags: [
      {
        key: "edge-flag",
        enabled: true,
        rolloutPercentage: 100,
      },
    ],
  });

  assert.strictEqual(edgeDoppio.isEnabled("edge-flag", { unitId: "edge-user" }), true);
});
