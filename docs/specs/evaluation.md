# Evaluation Specification

Version: 1.0.0

This document is the canonical source of truth for flag evaluation behavior across all Doppio SDKs. SDKs MUST NOT implement behavior absent from this spec. Conflicts between code and this document are resolved in favor of this document.

## 1. Context

An evaluation context is an object with an optional `targetingKey` (string) and an optional `custom` map of attributes. If `targetingKey` is absent or empty, the SDK MUST treat the unit id as the empty string `""`.

## 2. Bucketing

Bucketing determines rollout membership. The algorithm:

1. Input: `flagKey` (string), `unitId` (string), `percentage` (integer 0..100).
2. Clamp `percentage` to [0, 100].
3. Compute `bucket = xxh32(flagKey + "\x00" + unitId, seed=0) mod 100000`.
4. Threshold `= percentage * 1000` (integer).
5. The unit is in rollout iff `bucket < threshold`.

Hashing MUST use xxHash32 with seed 0. Byte order: flagKey bytes, then a single 0x00 byte, then unitId bytes (UTF-8). The result is interpreted as an unsigned 32-bit integer modulo 100000.

## 3. Evaluation order

For a flag `F` and context `C`:

1. If `F` is not found in the flag set, return default value with reason `DEFAULT`.
2. If `F.enabled` is false, return default value with reason `DISABLED`.
3. Evaluate prerequisites in declaration order. If any prerequisite fails, return default value with reason `PREREQUISITE_FAILED`.
4. Evaluate rules in declaration order. The first rule whose `expression` evaluates to true wins; apply its `variation` (if set) and `rolloutPercentage` (if set, else 100). Return with reason `RULE_MATCH`.
5. If no rule matched, apply top-level rollout: if `inRollout(flagKey, unitId, rolloutPercentage)` then return the default variation value with reason `DEFAULT`; else default value with reason `DEFAULT`.

## 4. Variation resolution

- `defaultVariation` indexes into `variations`. If null, variation 0 is used.
- A variation's `value` is a string; SDKs MUST coerce to the requested type (boolean, number, string, object) per the evaluation method called.
- If coercion fails, return the provided default value with reason `ERROR`.

## 5. Rollout percentage

- `rolloutPercentage` is an integer 0..100. Missing implies 100.
- Rollout uses bucketing (section 2) with the flag key and unit id.

## 6. Config precedence

When multiple config sources exist, precedence (highest to lowest):
1. Remote sync (server snapshot/delta)
2. Local override (dev mode)
3. Bundled default

## 7. Error and fallback semantics

- Missing flag: return caller-provided default, reason `DEFAULT`.
- Evaluation exception: return caller-provided default, reason `ERROR`, never throw.
- Type mismatch on variation coercion: return caller-provided default, reason `ERROR`.

## 8. Delta application

Deltas MUST be applied in seq order. Out-of-order deltas MUST be buffered and applied when the gap is filled, or trigger a full snapshot resync if the gap exceeds history depth. See `docs/specs/sync.md`.

## 9. Determinism

Evaluation MUST be deterministic: identical inputs (flag config + context) MUST produce identical outputs including bucket. SDKs MUST NOT use randomness or wall-clock time in evaluation.