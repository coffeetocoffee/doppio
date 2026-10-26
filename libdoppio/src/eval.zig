const std = @import("std");
const cel = @import("cel.zig");
const hash = @import("hash.zig");
const schema = @import("schema.zig");

pub fn evaluate(flag: schema.Flag, context: schema.Context) schema.Evaluation {
    const config = schema.Config{
        .environment = "production",
        .version = 1,
        .flags = &[_]schema.Flag{flag},
    };
    return evaluateConfig(config, flag.key, context);
}

pub fn evaluateConfig(
    config: schema.Config,
    flag_key: []const u8,
    context: schema.Context,
) schema.Evaluation {
    const flag = config.findFlag(flag_key) orelse {
        return .{
            .flag_key = flag_key,
            .enabled = false,
            .bucket = 0,
            .reason = .error_occurred,
            .variation = null,
            .version = config.version,
        };
    };

    var visited_buf: [32][]const u8 = undefined;
    return evaluateInternal(config, flag, context, visited_buf[0..0]);
}

fn evaluateInternal(
    config: schema.Config,
    flag: schema.Flag,
    context: schema.Context,
    visited: []const []const u8,
) schema.Evaluation {
    // 1. If flag is not enabled, return disabled reason
    if (!flag.enabled) {
        return .{
            .flag_key = flag.key,
            .enabled = false,
            .bucket = hash.bucketUnit(flag.key, context.unit_id),
            .reason = .disabled,
            .variation = selectDefaultVariation(flag),
            .version = config.version,
        };
    }

    // 2. Evaluate prerequisites in topological order
    for (flag.prerequisites) |prereq| {
        for (visited) |v| {
            if (std.mem.eql(u8, v, prereq.flag_key)) {
                return .{
                    .flag_key = flag.key,
                    .enabled = false,
                    .bucket = 0,
                    .reason = .error_occurred,
                    .variation = selectDefaultVariation(flag),
                    .version = config.version,
                };
            }
        }

        const prereq_flag = config.findFlag(prereq.flag_key) orelse {
            return .{
                .flag_key = flag.key,
                .enabled = false,
                .bucket = 0,
                .reason = .error_occurred,
                .variation = selectDefaultVariation(flag),
                .version = config.version,
            };
        };

        if (visited.len >= 32) {
            return .{
                .flag_key = flag.key,
                .enabled = false,
                .bucket = 0,
                .reason = .error_occurred,
                .variation = selectDefaultVariation(flag),
                .version = config.version,
            };
        }

        var next_visited_buf: [32][]const u8 = undefined;
        @memcpy(next_visited_buf[0..visited.len], visited);
        next_visited_buf[visited.len] = flag.key;
        const next_visited = next_visited_buf[0 .. visited.len + 1];

        const prereq_result = evaluateInternal(config, prereq_flag, context, next_visited);
        const prereq_matched = prereq_result.enabled and
            prereq_result.variation != null and
            std.mem.eql(u8, prereq_result.variation.?.key, prereq.variation_key);

        if (!prereq_matched) {
            return .{
                .flag_key = flag.key,
                .enabled = false,
                .bucket = hash.bucketUnit(flag.key, context.unit_id),
                .reason = .prerequisite_failed,
                .variation = selectDefaultVariation(flag),
                .version = config.version,
            };
        }
    }

    // 3. Apply targeting rules in declared priority order
    for (flag.rules) |rule| {
        if (rule.expression.len > 0) {
            const matches = cel.evaluate(rule.expression, context) catch false;
            if (matches) {
                if (rule.variation) |var_idx| {
                    const selected = if (var_idx < flag.variations.len) flag.variations[var_idx] else null;
                    return .{
                        .flag_key = flag.key,
                        .enabled = true,
                        .bucket = hash.bucketUnit(flag.key, context.unit_id),
                        .reason = .target_match,
                        .variation = selected,
                        .version = config.version,
                    };
                }

                if (rule.rollout) |ro| {
                    const salt = if (ro.salt.len > 0) ro.salt else flag.key;
                    const b = hash.bucket(context.unit_id, salt, ro.buckets);
                    if (hash.inRolloutWithSalt(context.unit_id, salt, ro.percentage, ro.buckets)) {
                        const selected = selectRolloutVariation(flag, ro, b);
                        return .{
                            .flag_key = flag.key,
                            .enabled = true,
                            .bucket = b,
                            .reason = .target_match,
                            .variation = selected,
                            .version = config.version,
                        };
                    } else {
                        return .{
                            .flag_key = flag.key,
                            .enabled = false,
                            .bucket = b,
                            .reason = .default_variation,
                            .variation = selectDefaultVariation(flag),
                            .version = config.version,
                        };
                    }
                }
            }
        }
    }

    // 4. Default rollout bucketing
    if (flag.rollout) |ro| {
        const salt = if (ro.salt.len > 0) ro.salt else flag.key;
        const b = hash.bucket(context.unit_id, salt, ro.buckets);
        const in_rollout = hash.inRolloutWithSalt(context.unit_id, salt, ro.percentage, ro.buckets);
        if (in_rollout) {
            const selected = selectRolloutVariation(flag, ro, b);
            return .{
                .flag_key = flag.key,
                .enabled = true,
                .bucket = b,
                .reason = .rollout_match,
                .variation = selected,
                .version = config.version,
            };
        } else {
            return .{
                .flag_key = flag.key,
                .enabled = false,
                .bucket = b,
                .reason = .rollout_miss,
                .variation = selectDefaultVariation(flag),
                .version = config.version,
            };
        }
    }

    const b = hash.bucketUnit(flag.key, context.unit_id);
    const matched = hash.inRollout(flag.key, context.unit_id, flag.rollout_percentage);
    return .{
        .flag_key = flag.key,
        .enabled = matched,
        .bucket = b,
        .reason = if (matched) .rollout_match else .rollout_miss,
        .variation = if (matched) selectVariation(flag) else selectDefaultVariation(flag),
        .version = config.version,
    };
}

fn selectVariation(flag: schema.Flag) ?schema.Variation {
    if (flag.variations.len == 0) return null;
    const idx = if (flag.default_variation < flag.variations.len) flag.default_variation else 0;
    return flag.variations[idx];
}

fn selectDefaultVariation(flag: schema.Flag) ?schema.Variation {
    if (flag.variations.len == 0) return null;
    const idx = if (flag.default_variation < flag.variations.len) flag.default_variation else 0;
    return flag.variations[idx];
}

fn selectRolloutVariation(flag: schema.Flag, rollout: schema.Rollout, bucket_val: u32) ?schema.Variation {
    if (rollout.distributions.len > 0) {
        var total_weight: u32 = 0;
        for (rollout.distributions) |dist| {
            total_weight += dist.weight;
        }

        if (total_weight > 0) {
            const target_weight = bucket_val % total_weight;
            var cumulative: u32 = 0;
            for (rollout.distributions) |dist| {
                cumulative += dist.weight;
                if (target_weight < cumulative) {
                    if (dist.variation_index < flag.variations.len) {
                        return flag.variations[dist.variation_index];
                    }
                    break;
                }
            }
        }
    }
    return selectVariation(flag);
}

test "disabled flag always evaluates off" {
    const context = schema.Context{ .unit_id = "user-1" };
    const result = evaluate(.{ .key = "demo", .enabled = false }, context);

    try std.testing.expect(!result.enabled);
    try std.testing.expectEqual(schema.Reason.disabled, result.reason);
    try std.testing.expectEqualStrings("DISABLED", result.reason.code());
}

test "full rollout enables every unit" {
    const context = schema.Context{ .unit_id = "user-1" };
    const result = evaluate(.{
        .key = "demo",
        .enabled = true,
        .rollout_percentage = 100,
    }, context);

    try std.testing.expect(result.enabled);
    try std.testing.expectEqual(schema.Reason.rollout_match, result.reason);
    try std.testing.expectEqualStrings("ROLLOUT", result.reason.code());
}

test "zero rollout disables every unit" {
    const context = schema.Context{ .unit_id = "user-1" };
    const result = evaluate(.{
        .key = "demo",
        .enabled = true,
        .rollout_percentage = 0,
    }, context);

    try std.testing.expect(!result.enabled);
    try std.testing.expectEqual(schema.Reason.rollout_miss, result.reason);
}

test "evaluation returns the configured variation" {
    const variations = [_]schema.Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const result = evaluate(.{
        .key = "demo",
        .enabled = true,
        .rollout_percentage = 100,
        .variations = &variations,
        .default_variation = 1,
    }, .{ .unit_id = "user-1" });

    try std.testing.expect(result.variation != null);
    try std.testing.expectEqualStrings("on", result.variation.?.key);
    try std.testing.expectEqualStrings("true", result.variation.?.value);
}

test "partial rollout is stable for a unit" {
    const flag = schema.Flag{
        .key = "demo",
        .enabled = true,
        .rollout_percentage = 50,
    };
    const context = schema.Context{ .unit_id = "user-1" };
    const first = evaluate(flag, context);
    const second = evaluate(flag, context);

    try std.testing.expectEqual(first.enabled, second.enabled);
    try std.testing.expectEqual(first.bucket, second.bucket);
}

test "prerequisites in evaluation pipeline" {
    const variations = [_]schema.Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const flags = [_]schema.Flag{
        .{
            .key = "parent-flag",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
        },
        .{
            .key = "child-flag",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
            .prerequisites = &[_]schema.Prerequisite{
                .{ .flag_key = "parent-flag", .variation_key = "on" },
            },
        },
    };
    const config = schema.Config{ .flags = &flags };

    const child_res = evaluateConfig(config, "child-flag", .{ .unit_id = "user-1" });
    try std.testing.expect(child_res.enabled);
    try std.testing.expectEqual(schema.Reason.rollout_match, child_res.reason);

    const flags_failing = [_]schema.Flag{
        .{
            .key = "parent-flag",
            .enabled = false,
            .variations = &variations,
            .default_variation = 0,
        },
        .{
            .key = "child-flag",
            .enabled = true,
            .rollout_percentage = 100,
            .variations = &variations,
            .default_variation = 1,
            .prerequisites = &[_]schema.Prerequisite{
                .{ .flag_key = "parent-flag", .variation_key = "on" },
            },
        },
    };
    const config_failing = schema.Config{ .flags = &flags_failing };
    const failing_res = evaluateConfig(config_failing, "child-flag", .{ .unit_id = "user-1" });
    try std.testing.expect(!failing_res.enabled);
    try std.testing.expectEqual(schema.Reason.prerequisite_failed, failing_res.reason);
    try std.testing.expectEqualStrings("PREREQUISITE_FAILED", failing_res.reason.code());
}

test "targeting rules in evaluation pipeline" {
    const variations = [_]schema.Variation{
        .{ .key = "standard", .value = "blue" },
        .{ .key = "vip", .value = "gold" },
    };
    const rules = [_]schema.Rule{
        .{
            .id = "vip-rule",
            .priority = 1,
            .expression = "account.plan == \"enterprise\"",
            .variation = 1,
        },
    };
    const flag = schema.Flag{
        .key = "ui-theme",
        .enabled = true,
        .variations = &variations,
        .default_variation = 0,
        .rules = &rules,
    };
    const config = schema.Config{ .flags = &[_]schema.Flag{flag} };

    const vip_ctx = schema.Context{
        .unit_id = "user-vip",
        .attributes = &[_]schema.Attribute{
            .{ .key = "account.plan", .value = "enterprise" },
        },
    };
    const vip_res = evaluateConfig(config, "ui-theme", vip_ctx);
    try std.testing.expect(vip_res.enabled);
    try std.testing.expectEqual(schema.Reason.target_match, vip_res.reason);
    try std.testing.expectEqualStrings("TARGET_MATCH", vip_res.reason.code());
    try std.testing.expectEqualStrings("vip", vip_res.variation.?.key);

    const normal_ctx = schema.Context{
        .unit_id = "user-regular",
        .attributes = &[_]schema.Attribute{
            .{ .key = "account.plan", .value = "free" },
        },
    };
    const normal_res = evaluateConfig(config, "ui-theme", normal_ctx);
    try std.testing.expect(normal_res.enabled);
    try std.testing.expectEqualStrings("standard", normal_res.variation.?.key);
}
