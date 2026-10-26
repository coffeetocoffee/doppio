import test from "node:test";
import assert from "node:assert";
import { Doppio } from "../dist/index.js";
import { DoppioProvider } from "../dist/openfeature.js";

// OpenFeature Conformance Suite
// Based on OpenFeature specification: https://openfeature.dev/specification

test("Conformance: Provider metadata", async () => {
  const doppio = await Doppio.init({ flags: [] });
  const provider = new DoppioProvider({ doppio });
  const metadata = provider.metadata;
  assert.ok(metadata.name, "metadata has name");
  assert.strictEqual(typeof metadata.name, "string", "name is string");
});

test("Conformance: Boolean evaluation with default value", async () => {
  const doppio = await Doppio.init({
    flags: [
      { key: "enabled-flag", enabled: true, rolloutPercentage: 100 },
      { key: "disabled-flag", enabled: false, rolloutPercentage: 0 },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  // Enabled flag returns true
  const res1 = await provider.resolveBooleanEvaluation("enabled-flag", false, { targetingKey: "user-1" });
  assert.strictEqual(res1.value, true, "enabled flag -> true");

  // Disabled flag returns false
  const res2 = await provider.resolveBooleanEvaluation("disabled-flag", true, { targetingKey: "user-1" });
  assert.strictEqual(res2.value, false, "disabled flag -> false");

  // Missing flag returns default
  const res3 = await provider.resolveBooleanEvaluation("missing-flag", true, { targetingKey: "user-1" });
  assert.strictEqual(res3.value, true, "missing flag -> default");
});

test("Conformance: Targeting context is respected", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "targeted-flag",
        enabled: true,
        rules: [
          {
            id: "vip-rule",
            expression: 'user.plan == "premium"',
            variation: 1,
          },
        ],
        variations: [
          { key: "standard", value: "false" },
          { key: "premium", value: "true" },
        ],
        defaultVariation: 0,
        rolloutPercentage: 100,
      },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const premiumRes = await provider.resolveBooleanEvaluation(
    "targeted-flag",
    false,
    { targetingKey: "user-1", custom: { plan: "premium" } }
  );
  assert.strictEqual(premiumRes.value, true, "premium user -> true");

  const standardRes = await provider.resolveBooleanEvaluation(
    "targeted-flag",
    false,
    { targetingKey: "user-2", custom: { plan: "free" } }
  );
  assert.strictEqual(standardRes.value, false, "free user -> false");
});

test("Conformance: Deterministic evaluation", async () => {
  const doppio = await Doppio.init({
    flags: [{ key: "deterministic-flag", enabled: true, rolloutPercentage: 50 }],
  });
  const provider = new DoppioProvider({ doppio });

  const res1 = await provider.resolveBooleanEvaluation("deterministic-flag", false, { targetingKey: "user-123" });
  const res2 = await provider.resolveBooleanEvaluation("deterministic-flag", false, { targetingKey: "user-123" });

  assert.strictEqual(res1.value, res2.value, "same context -> same result");
  assert.strictEqual(res1.reason, res2.reason, "same context -> same reason");
});

test("Conformance: Reason mapping", async () => {
  const doppio = await Doppio.init({
    flags: [
      { key: "disabled-flag", enabled: false, rolloutPercentage: 0 },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const res = await provider.resolveBooleanEvaluation("disabled-flag", false, { targetingKey: "user-1" });
  assert.strictEqual(res.reason, "DISABLED", "disabled flag -> DISABLED reason");
});

test("Conformance: Empty context handling", async () => {
  const doppio = await Doppio.init({
    flags: [{ key: "ctx-flag", enabled: true, rolloutPercentage: 100 }],
  });
  const provider = new DoppioProvider({ doppio });

  // No context provided
  const res1 = await provider.resolveBooleanEvaluation("ctx-flag", false);
  assert.strictEqual(res1.value, true, "no context -> evaluates with anonymous");

  // Empty context
  const res2 = await provider.resolveBooleanEvaluation("ctx-flag", false, {});
  assert.strictEqual(res2.value, true, "empty context -> evaluates");
});

test("Conformance: String evaluation", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "string-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [{ key: "on", value: "hello world" }],
        defaultVariation: 0,
      },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const res = await provider.resolveStringEvaluation("string-flag", "default", { targetingKey: "user-1" });
  assert.strictEqual(res.value, "hello world", "string variation value");
});

test("Conformance: Number evaluation", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "number-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [{ key: "on", value: "42" }],
        defaultVariation: 0,
      },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const res = await provider.resolveNumberEvaluation("number-flag", 0, { targetingKey: "user-1" });
  assert.strictEqual(res.value, 42, "number variation value");
});

test("Conformance: Object evaluation", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "object-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [{ key: "on", value: '{"feature": true}' }],
        defaultVariation: 0,
      },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const res = await provider.resolveObjectEvaluation("object-flag", {}, { targetingKey: "user-1" });
  assert.deepStrictEqual(res.value, { feature: true }, "object variation value");
});

test("Conformance: Variant returned", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "variant-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [{ key: "test-variant", value: "true" }],
        defaultVariation: 0,
      },
    ],
  });
  const provider = new DoppioProvider({ doppio });

  const res = await provider.resolveBooleanEvaluation("variant-flag", false, { targetingKey: "user-1" });
  assert.strictEqual(res.variant, "test-variant", "variant key returned");
});