import test from "node:test";
import assert from "node:assert";
import { Doppio } from "../dist/index.js";
import { DoppioProvider } from "../dist/openfeature.js";

test("OpenFeature Provider: maps Doppio evaluation results to OpenFeature resolution", async () => {
  const doppio = await Doppio.init({
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

  const provider = new DoppioProvider({ doppio });

  // Boolean evaluation
  const boolResult = await provider.resolveBooleanEvaluation(
    "checkout-redesign",
    false,
    { targetingKey: "user-123" }
  );
  assert.strictEqual(boolResult.value, true, "boolean value from Doppio");
  assert.strictEqual(boolResult.reason, "SPLIT", "rollout reason mapped");
  assert.strictEqual(boolResult.variant, "on", "variation mapped");

  // Targeting match
  const enterpriseResult = await provider.resolveBooleanEvaluation(
    "theme",
    false,
    { targetingKey: "user-1", custom: { plan: "enterprise" } }
  );
  assert.strictEqual(enterpriseResult.value, true);
  assert.strictEqual(enterpriseResult.reason, "TARGETING_MATCH");
  assert.strictEqual(enterpriseResult.variant, "vip");

  // Default fallback
  const unknownResult = await provider.resolveBooleanEvaluation(
    "nonexistent-flag",
    true,
    { targetingKey: "user-1" }
  );
  assert.strictEqual(unknownResult.value, true, "falls back to default");
  assert.strictEqual(unknownResult.reason, "ERROR", "unknown flag -> error");
});

test("OpenFeature Provider: context conversion maps targetingKey", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "test-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [{ key: "on", value: "true" }],
        defaultVariation: 0,
      },
    ],
  });

  const provider = new DoppioProvider({ doppio });

  // targetingKey should map to unitId
  const result = await provider.resolveBooleanEvaluation(
    "test-flag",
    false,
    { targetingKey: "targeting-user-1" }
  );
  assert.strictEqual(result.value, true, "targetingKey converted to unitId");
});

test("OpenFeature Provider: string and number evaluation", async () => {
  const doppio = await Doppio.init({
    flags: [
      {
        key: "theme-flag",
        enabled: true,
        rolloutPercentage: 100,
        variations: [
          { key: "standard", value: "blue" },
          { key: "vip", value: "gold" },
        ],
        defaultVariation: 0,
      },
    ],
  });

  const provider = new DoppioProvider({ doppio });

  const stringResult = await provider.resolveStringEvaluation(
    "theme-flag",
    "default",
    { targetingKey: "user-1" }
  );
  assert.strictEqual(stringResult.value, "blue", "string variation value");
  assert.strictEqual(stringResult.variant, "standard");

  // Unknown flag returns default
  const unknownString = await provider.resolveStringEvaluation(
    "missing-flag",
    "fallback",
    { targetingKey: "user-1" }
  );
  assert.strictEqual(unknownString.value, "fallback", "string default fallback");
});

test("OpenFeature Provider: factory function", async () => {
  const doppio = await Doppio.init({
    flags: [{ key: "factory-flag", enabled: true, rolloutPercentage: 100 }],
  });

  const provider = createDoppioProvider({ doppio });
  assert.ok(provider instanceof DoppioProvider, "factory returns provider instance");

  const result = await provider.resolveBooleanEvaluation(
    "factory-flag",
    false,
    { targetingKey: "user-1" }
  );
  assert.strictEqual(result.value, true);
});