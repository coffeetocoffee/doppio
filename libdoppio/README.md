# libdoppio

Zig evaluation core for Doppio, an open source feature flags and A/B testing platform.

`libdoppio` owns deterministic bucketing, flag evaluation, and the native and WebAssembly bindings used by the SDKs. It has no network, database, or runtime configuration dependencies.

## Status

Phase 1a core library complete.

## Layout

```
build.zig          build graph for native, tests, CLI, and WebAssembly
build.zig.zon      package metadata
src/root.zig       public module entry point and Section 7.1 contract
src/schema.zig     flag, variation, rule, prerequisite, and comptime JSON Schema
src/hash.zig       deterministic bucketing with salt and custom bucket space
src/eval.zig       evaluation pipeline with prerequisites and targeting rules
src/cel.zig        pure Zig parser and evaluator for the CEL subset
src/serialize.zig  compact binary and JSON serialization
src/cli.zig        command line parsing and output
src/main.zig       native CLI entry point
src/wasm.zig       WebAssembly exports
```

## Build

Requires Zig 0.16.0.

```sh
zig build test
zig build
zig build wasm
```

Artifacts are written under `zig-out`. The WebAssembly module is installed as `zig-out/bin/doppio.wasm` and exports `memory`, `doppio_abi_version`, `doppio_bucket`, `doppio_enabled`, and `doppio_eval_cel`.

## CLI

```sh
zig build run -- version
zig build run -- eval --flag checkout-redesign --unit user-123 --rollout 25
zig build run -- validate --flag checkout-redesign --rollout 25
zig build run -- bench --iterations 1000000 --flag checkout-redesign
```

Example evaluation output:

```
flag=checkout-redesign unit=user-123 enabled=true bucket=20826 reason=rollout_match variation=on
```

Example validation output:

```
valid flag=checkout-redesign rollout=25%
```

Example benchmark output:

```
bench flag=checkout-redesign iters=1000000 total_ms=90 ns_per_op=90 ops_per_sec=11041866
```

Buckets are stable for a given flag key and unit ID. The default bucket space is 100,000 and uses XXH32 with a zero seed. The bucket derivation and rollout comparison are part of the compatibility contract and must not change without a versioned migration.

## Library use

```zig
const doppio = @import("doppio");

// 1. Single flag evaluation
const result = doppio.evaluate(.{
    .key = "checkout-redesign",
    .enabled = true,
    .rollout_percentage = 25,
}, .{ .unit_id = "user-123" });

// 2. Full config evaluation with targeting rules and prerequisites
const config = doppio.Config{
    .environment = "production",
    .version = 1,
    .flags = &[_]doppio.Flag{
        .{
            .key = "checkout-redesign",
            .enabled = true,
            .rollout_percentage = 25,
        },
    },
};
const config_result = doppio.evaluateConfig(config, "checkout-redesign", .{ .unit_id = "user-123" });

// 3. Deterministic bucketing with salt and custom bucket count
const b = doppio.bucket("user-123", "checkout-redesign", 100_000);

// 4. Binary serialization
var buf: [2048]u8 = undefined;
var writer = std.Io.Writer.fixed(&buf);
try doppio.encodeBinary(config, &writer);
```

`evaluate` performs no dynamic allocation. All slices in the input must remain valid for the duration of the call. The returned evaluation borrows strings from the flag definition.

## WebAssembly

The module is built for `wasm32-freestanding` with no imports and exported memory. Pointer and length pairs refer to UTF-8 bytes in the module memory. The ABI is versioned with `doppio_abi_version`; version 1 is experimental.

## License

Apache 2.0.
