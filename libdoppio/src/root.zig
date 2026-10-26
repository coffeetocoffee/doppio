const std = @import("std");

pub const schema = @import("schema.zig");
pub const hash = @import("hash.zig");
pub const eval = @import("eval.zig");
pub const cel = @import("cel.zig");
pub const cli = @import("cli.zig");
pub const lint = @import("lint.zig");
pub const serialize = @import("serialize.zig");
pub const version = @import("version.zig").string;

// Public types
pub const Config = schema.Config;
pub const Flag = schema.Flag;
pub const FlagType = schema.FlagType;
pub const Variation = schema.Variation;
pub const Context = schema.Context;
pub const Attribute = schema.Attribute;
pub const Evaluation = schema.Evaluation;
pub const Reason = schema.Reason;
pub const Rule = schema.Rule;
pub const Rollout = schema.Rollout;
pub const RolloutDistribution = schema.RolloutDistribution;
pub const Prerequisite = schema.Prerequisite;
pub const Segment = schema.Segment;
pub const Schema = schema.Schema;
pub const ValidationResult = schema.ValidationResult;
pub const Ast = cel.Ast;

// Public functions per Section 7.1
pub const validateSchema = schema.validateSchema;
pub const evaluate = eval.evaluate;
pub const evaluateConfig = eval.evaluateConfig;
pub const bucket = hash.bucket;
pub const evaluateExpression = cel.evaluateExpression;
pub const encodeBinary = serialize.encodeBinary;
pub const decodeBinary = serialize.decodeBinary;

test {
    _ = schema;
    _ = hash;
    _ = eval;
    _ = cel;
    _ = cli;
    _ = lint;
    _ = serialize;
}

test "public interface: Section 7.1 contract compliance" {
    // 1. validateSchema
    const config = Config{
        .environment = "production",
        .version = 1,
        .flags = &[_]Flag{
            .{
                .key = "checkout-redesign",
                .enabled = true,
                .rollout_percentage = 25,
            },
        },
    };
    const val_res = validateSchema(.{}, config);
    try std.testing.expect(val_res.valid);

    // 2. evaluate
    const eval_res = evaluate(config.flags[0], .{ .unit_id = "user-123" });
    try std.testing.expectEqual(true, eval_res.enabled);
    try std.testing.expectEqual(@as(u32, 20826), eval_res.bucket);
    try std.testing.expectEqual(Reason.rollout_match, eval_res.reason);

    // 3. evaluateConfig
    const cfg_res = evaluateConfig(config, "checkout-redesign", .{ .unit_id = "user-123" });
    try std.testing.expectEqual(eval_res.enabled, cfg_res.enabled);
    try std.testing.expectEqual(eval_res.bucket, cfg_res.bucket);

    // 4. bucket
    const b = bucket("user-123", "checkout-redesign", 100_000);
    try std.testing.expectEqual(@as(u32, 20826), b);

    // 5. evaluateExpression via AST
    var ast = try cel.parse(std.testing.allocator, "user.plan == \"enterprise\" || user.tier == \"gold\"");
    defer ast.deinit();

    const ctx1 = Context{
        .unit_id = "u1",
        .attributes = &[_]Attribute{.{ .key = "user.tier", .value = "gold" }},
    };
    try std.testing.expect(try evaluateExpression(&ast, ctx1));

    const ctx2 = Context{
        .unit_id = "u2",
        .attributes = &[_]Attribute{.{ .key = "user.tier", .value = "bronze" }},
    };
    try std.testing.expect(!try evaluateExpression(&ast, ctx2));

    // 6. encodeBinary and decodeBinary
    var buf: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try encodeBinary(config, &writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try decodeBinary(arena.allocator(), &reader);
    try std.testing.expectEqualStrings("production", decoded.environment);
    try std.testing.expectEqual(@as(usize, 1), decoded.flags.len);
    try std.testing.expectEqualStrings("checkout-redesign", decoded.flags[0].key);
}

test "topological prerequisite multi-level chain" {
    const variations = [_]Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const flags = [_]Flag{
        .{
            .key = "root-feature",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
        },
        .{
            .key = "intermediate-feature",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
            .prerequisites = &[_]Prerequisite{
                .{ .flag_key = "root-feature", .variation_key = "on" },
            },
        },
        .{
            .key = "leaf-feature",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
            .prerequisites = &[_]Prerequisite{
                .{ .flag_key = "intermediate-feature", .variation_key = "on" },
            },
        },
    };
    const config = Config{ .flags = &flags };
    const res = evaluateConfig(config, "leaf-feature", .{ .unit_id = "user-chain" });
    try std.testing.expect(res.enabled);
    try std.testing.expectEqual(Reason.rollout_match, res.reason);
}
