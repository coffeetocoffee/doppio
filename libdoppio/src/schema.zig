const std = @import("std");

pub const FlagType = enum {
    boolean,
    string,
    number,
    json,
};

pub const Variation = struct {
    key: []const u8,
    value: []const u8,
};

pub const Context = struct {
    unit_id: []const u8,
    attributes: []const Attribute = &.{},

    pub fn getAttribute(self: Context, key: []const u8) ?[]const u8 {
        for (self.attributes) |attr| {
            if (std.mem.eql(u8, attr.key, key)) {
                return attr.value;
            }
        }
        return null;
    }
};

pub const Attribute = struct {
    key: []const u8,
    value: []const u8,
};

pub const Prerequisite = struct {
    flag_key: []const u8,
    variation_key: []const u8,
};

pub const RolloutDistribution = struct {
    variation_index: usize = 0,
    weight: u32 = 0,
};

pub const Rollout = struct {
    salt: []const u8 = "",
    buckets: u32 = 100_000,
    percentage: u8 = 100,
    distributions: []const RolloutDistribution = &.{},
};

pub const Rule = struct {
    id: []const u8 = "",
    priority: u32 = 0,
    expression: []const u8 = "",
    variation: ?usize = null,
    rollout: ?Rollout = null,
};

pub const Segment = struct {
    key: []const u8,
    expression: []const u8,
};

pub const Flag = struct {
    key: []const u8,
    enabled: bool = false,
    type: FlagType = .boolean,
    rollout_percentage: u8 = 100,
    variations: []const Variation = &.{},
    default_variation: usize = 0,
    prerequisites: []const Prerequisite = &.{},
    rules: []const Rule = &.{},
    rollout: ?Rollout = null,
};

pub const Config = struct {
    environment: []const u8 = "production",
    version: u64 = 1,
    flags: []const Flag = &.{},
    segments: []const Segment = &.{},

    pub fn findFlag(self: Config, key: []const u8) ?Flag {
        for (self.flags) |flag| {
            if (std.mem.eql(u8, flag.key, key)) {
                return flag;
            }
        }
        return null;
    }

    pub fn findSegment(self: Config, key: []const u8) ?Segment {
        for (self.segments) |seg| {
            if (std.mem.eql(u8, seg.key, key)) {
                return seg;
            }
        }
        return null;
    }
};

pub const Reason = enum {
    disabled,
    target_match,
    rollout_match,
    rollout_miss,
    default_variation,
    prerequisite_failed,
    error_occurred,

    pub fn code(self: Reason) []const u8 {
        return switch (self) {
            .disabled => "DISABLED",
            .target_match => "TARGET_MATCH",
            .rollout_match => "ROLLOUT",
            .rollout_miss => "ROLLOUT_MISS",
            .default_variation => "DEFAULT",
            .prerequisite_failed => "PREREQUISITE_FAILED",
            .error_occurred => "ERROR",
        };
    }
};

pub const Evaluation = struct {
    flag_key: []const u8,
    enabled: bool,
    bucket: u32,
    reason: Reason,
    variation: ?Variation,
    version: u64 = 0,
};

pub const FlagError = error{
    EmptyFlagKey,
    RolloutOutOfRange,
    InvalidDefaultVariation,
};

pub const ConfigError = error{
    EmptyFlagKey,
    RolloutOutOfRange,
    InvalidDefaultVariation,
    CyclicPrerequisite,
    MissingPrerequisiteFlag,
};

pub fn validateFlag(flag: Flag) FlagError!void {
    if (flag.key.len == 0) return error.EmptyFlagKey;
    if (flag.rollout_percentage > 100) return error.RolloutOutOfRange;
    if (flag.rollout) |ro| {
        if (ro.percentage > 100) return error.RolloutOutOfRange;
    }
    if (flag.variations.len > 0 and flag.default_variation >= flag.variations.len) {
        return error.InvalidDefaultVariation;
    }
}

pub fn validateConfig(config: Config) ConfigError!void {
    for (config.flags) |flag| {
        validateFlag(flag) catch |err| switch (err) {
            error.EmptyFlagKey => return error.EmptyFlagKey,
            error.RolloutOutOfRange => return error.RolloutOutOfRange,
            error.InvalidDefaultVariation => return error.InvalidDefaultVariation,
        };

        for (flag.prerequisites) |prereq| {
            if (std.mem.eql(u8, prereq.flag_key, flag.key)) {
                return error.CyclicPrerequisite;
            }
            if (config.findFlag(prereq.flag_key) == null) {
                return error.MissingPrerequisiteFlag;
            }
        }
    }
}

pub const ValidationResult = struct {
    valid: bool,
    error_message: ?[]const u8 = null,
};

pub const Schema = struct {
    version: u32 = 1,
};

pub fn validateSchema(_: Schema, config: Config) ValidationResult {
    validateConfig(config) catch |err| {
        return .{
            .valid = false,
            .error_message = @errorName(err),
        };
    };
    return .{
        .valid = true,
        .error_message = null,
    };
}

pub fn generateJsonSchema(comptime T: type) []const u8 {
    return "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"title\":\"" ++
        @typeName(T) ++ "\"," ++ generateTypeSchema(T) ++ "}";
}

fn generateTypeSchema(comptime T: type) []const u8 {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return "\"type\":\"boolean\"",
        .int => return "\"type\":\"integer\"",
        .float => return "\"type\":\"number\"",
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return "\"type\":\"string\"";
            } else if (ptr.size == .slice) {
                return "\"type\":\"array\",\"items\":{" ++ generateTypeSchema(ptr.child) ++ "}";
            } else {
                return "\"type\":\"string\"";
            }
        },
        .optional => |opt| {
            return generateTypeSchema(opt.child);
        },
        .@"enum" => |en| {
            comptime var enum_vals: []const u8 = "";
            inline for (en.fields, 0..) |field, idx| {
                if (idx > 0) enum_vals = enum_vals ++ ",";
                enum_vals = enum_vals ++ "\"" ++ field.name ++ "\"";
            }
            return "\"type\":\"string\",\"enum\":[" ++ enum_vals ++ "]";
        },
        .@"struct" => |st| {
            comptime var props: []const u8 = "";
            comptime var reqs: []const u8 = "";
            comptime var req_count: usize = 0;
            inline for (st.fields, 0..) |field, idx| {
                if (idx > 0) props = props ++ ",";
                props = props ++ "\"" ++ field.name ++ "\":{" ++ generateTypeSchema(field.type) ++ "}";
                if (@typeInfo(field.type) != .optional and field.default_value_ptr == null) {
                    if (req_count > 0) reqs = reqs ++ ",";
                    reqs = reqs ++ "\"" ++ field.name ++ "\"";
                    req_count += 1;
                }
            }
            if (req_count > 0) {
                return "\"type\":\"object\",\"properties\":{" ++ props ++ "},\"required\":[" ++ reqs ++ "]";
            } else {
                return "\"type\":\"object\",\"properties\":{" ++ props ++ "}";
            }
        },
        else => return "\"type\":\"string\"",
    }
}

test "comptime JSON Schema generation" {
    const flag_schema = comptime generateJsonSchema(Flag);
    try std.testing.expect(std.mem.indexOf(u8, flag_schema, "\"type\":\"object\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, flag_schema, "\"key\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, flag_schema, "\"enabled\":{\"type\":\"boolean\"}") != null);

    const config_schema = comptime generateJsonSchema(Config);
    try std.testing.expect(std.mem.indexOf(u8, config_schema, "\"environment\":{\"type\":\"string\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, config_schema, "\"version\":{\"type\":\"integer\"}") != null);
}

test "validateFlag accepts a well-formed flag" {
    const variations = [_]Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const flag = Flag{
        .key = "checkout-redesign",
        .enabled = true,
        .rollout_percentage = 25,
        .variations = &variations,
        .default_variation = 1,
    };
    try validateFlag(flag);
}

test "validateFlag rejects invalid flags" {
    try std.testing.expectError(error.EmptyFlagKey, validateFlag(.{ .key = "" }));
    try std.testing.expectError(
        error.RolloutOutOfRange,
        validateFlag(.{ .key = "demo", .rollout_percentage = 101 }),
    );

    const variations = [_]Variation{.{ .key = "on", .value = "true" }};
    try std.testing.expectError(
        error.InvalidDefaultVariation,
        validateFlag(.{
            .key = "demo",
            .variations = &variations,
            .default_variation = 1,
        }),
    );
}

test "validateConfig and validateSchema" {
    const flags = [_]Flag{
        .{
            .key = "flag-a",
            .enabled = true,
        },
        .{
            .key = "flag-b",
            .enabled = true,
            .prerequisites = &[_]Prerequisite{
                .{ .flag_key = "flag-a", .variation_key = "on" },
            },
        },
    };
    const config = Config{
        .environment = "staging",
        .version = 2,
        .flags = &flags,
    };

    try validateConfig(config);
    const result = validateSchema(.{}, config);
    try std.testing.expect(result.valid);
}

test "validateConfig detects cyclic prerequisites" {
    const flags = [_]Flag{
        .{
            .key = "self-dep",
            .enabled = true,
            .prerequisites = &[_]Prerequisite{
                .{ .flag_key = "self-dep", .variation_key = "on" },
            },
        },
    };
    const config = Config{ .flags = &flags };
    try std.testing.expectError(error.CyclicPrerequisite, validateConfig(config));
}
