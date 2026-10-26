const std = @import("std");
const schema = @import("schema.zig");

pub const MAGIC = [4]u8{ 'D', 'O', 'P', '1' };

pub const SerializationError = error{
    InvalidMagic,
    UnexpectedEof,
    InvalidEnumValue,
    OutOfMemory,
};

pub fn writeJson(writer: *std.Io.Writer, result: schema.Evaluation) !void {
    try writer.writeAll("{\"flag_key\":");
    try writeJsonString(writer, result.flag_key);
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (result.enabled) "true" else "false");
    try writer.print(",\"bucket\":{d},\"reason\":\"{s}\",\"variation\":", .{
        result.bucket,
        @tagName(result.reason),
    });

    if (result.variation) |variation| {
        try writer.writeAll("{\"key\":");
        try writeJsonString(writer, variation.key);
        try writer.writeAll(",\"value\":");
        try writeJsonString(writer, variation.value);
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.print(",\"version\":{d}", .{result.version});
    try writer.writeByte('}');
}

pub fn writeFlagJson(writer: *std.Io.Writer, flag: schema.Flag) !void {
    try writer.print("{f}", .{std.json.fmt(flag, .{})});
}

pub fn parseFlagJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(schema.Flag) {
    return std.json.parseFromSlice(schema.Flag, allocator, bytes, .{});
}

pub fn writeConfigJson(writer: *std.Io.Writer, config: schema.Config) !void {
    try writer.print("{f}", .{std.json.fmt(config, .{})});
}

pub fn parseConfigJson(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(schema.Config) {
    return std.json.parseFromSlice(schema.Config, allocator, bytes, .{});
}

pub fn encodeBinary(config: schema.Config, writer: anytype) !void {
    try writer.writeAll(&MAGIC);
    try writeBytes(writer, config.environment);
    try writeU64(writer, config.version);

    try writeU32(writer, @intCast(config.flags.len));
    for (config.flags) |flag| {
        try writeBytes(writer, flag.key);
        try writeU8(writer, if (flag.enabled) 1 else 0);
        try writeU8(writer, @intFromEnum(flag.type));
        try writeU8(writer, flag.rollout_percentage);
        try writeU32(writer, @intCast(flag.default_variation));

        try writeU32(writer, @intCast(flag.variations.len));
        for (flag.variations) |v| {
            try writeBytes(writer, v.key);
            try writeBytes(writer, v.value);
        }

        try writeU32(writer, @intCast(flag.prerequisites.len));
        for (flag.prerequisites) |p| {
            try writeBytes(writer, p.flag_key);
            try writeBytes(writer, p.variation_key);
        }

        try writeU32(writer, @intCast(flag.rules.len));
        for (flag.rules) |r| {
            try writeBytes(writer, r.id);
            try writeU32(writer, r.priority);
            try writeBytes(writer, r.expression);
            if (r.variation) |v_idx| {
                try writeU8(writer, 1);
                try writeU32(writer, @intCast(v_idx));
            } else {
                try writeU8(writer, 0);
            }

            if (r.rollout) |ro| {
                try writeU8(writer, 1);
                try encodeRollout(ro, writer);
            } else {
                try writeU8(writer, 0);
            }
        }

        if (flag.rollout) |ro| {
            try writeU8(writer, 1);
            try encodeRollout(ro, writer);
        } else {
            try writeU8(writer, 0);
        }
    }

    try writeU32(writer, @intCast(config.segments.len));
    for (config.segments) |seg| {
        try writeBytes(writer, seg.key);
        try writeBytes(writer, seg.expression);
    }
}

pub fn decodeBinary(allocator: std.mem.Allocator, reader: anytype) !schema.Config {
    var magic: [4]u8 = undefined;
    try readFull(reader, &magic);
    if (!std.mem.eql(u8, &magic, &MAGIC)) return error.InvalidMagic;

    const env = try readBytes(allocator, reader);
    const ver = try readU64(reader);

    const flag_count = try readU32(reader);
    const flags = try allocator.alloc(schema.Flag, flag_count);
    errdefer allocator.free(flags);

    for (flags) |*flag| {
        const key = try readBytes(allocator, reader);
        const enabled = (try readU8(reader)) != 0;
        const type_raw = try readU8(reader);
        const flag_type: schema.FlagType = switch (type_raw) {
            0 => .boolean,
            1 => .string,
            2 => .number,
            3 => .json,
            else => return error.InvalidEnumValue,
        };
        const rollout_percentage = try readU8(reader);
        const default_variation = try readU32(reader);

        const var_count = try readU32(reader);
        const variations = try allocator.alloc(schema.Variation, var_count);
        for (variations) |*v| {
            v.key = try readBytes(allocator, reader);
            v.value = try readBytes(allocator, reader);
        }

        const prereq_count = try readU32(reader);
        const prereqs = try allocator.alloc(schema.Prerequisite, prereq_count);
        for (prereqs) |*p| {
            p.flag_key = try readBytes(allocator, reader);
            p.variation_key = try readBytes(allocator, reader);
        }

        const rule_count = try readU32(reader);
        const rules = try allocator.alloc(schema.Rule, rule_count);
        for (rules) |*r| {
            r.id = try readBytes(allocator, reader);
            r.priority = try readU32(reader);
            r.expression = try readBytes(allocator, reader);

            const has_var = (try readU8(reader)) != 0;
            if (has_var) {
                r.variation = try readU32(reader);
            } else {
                r.variation = null;
            }

            const has_ro = (try readU8(reader)) != 0;
            if (has_ro) {
                r.rollout = try decodeRollout(allocator, reader);
            } else {
                r.rollout = null;
            }
        }

        const has_flag_ro = (try readU8(reader)) != 0;
        const flag_ro: ?schema.Rollout = if (has_flag_ro) try decodeRollout(allocator, reader) else null;

        flag.* = .{
            .key = key,
            .enabled = enabled,
            .type = flag_type,
            .rollout_percentage = rollout_percentage,
            .default_variation = @intCast(default_variation),
            .variations = variations,
            .prerequisites = prereqs,
            .rules = rules,
            .rollout = flag_ro,
        };
    }

    const seg_count = try readU32(reader);
    const segments = try allocator.alloc(schema.Segment, seg_count);
    for (segments) |*seg| {
        seg.key = try readBytes(allocator, reader);
        seg.expression = try readBytes(allocator, reader);
    }

    return .{
        .environment = env,
        .version = ver,
        .flags = flags,
        .segments = segments,
    };
}

fn encodeRollout(ro: schema.Rollout, writer: anytype) !void {
    try writeBytes(writer, ro.salt);
    try writeU32(writer, ro.buckets);
    try writeU8(writer, ro.percentage);
    try writeU32(writer, @intCast(ro.distributions.len));
    for (ro.distributions) |d| {
        try writeU32(writer, @intCast(d.variation_index));
        try writeU32(writer, d.weight);
    }
}

fn decodeRollout(allocator: std.mem.Allocator, reader: anytype) !schema.Rollout {
    const salt = try readBytes(allocator, reader);
    const buckets = try readU32(reader);
    const percentage = try readU8(reader);
    const dist_count = try readU32(reader);
    const distributions = try allocator.alloc(schema.RolloutDistribution, dist_count);
    for (distributions) |*d| {
        d.variation_index = try readU32(reader);
        d.weight = try readU32(reader);
    }
    return .{
        .salt = salt,
        .buckets = buckets,
        .percentage = percentage,
        .distributions = distributions,
    };
}

fn writeU8(writer: anytype, val: u8) !void {
    try writer.writeByte(val);
}

fn writeU32(writer: anytype, val: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, val, .little);
    try writer.writeAll(&buf);
}

fn writeU64(writer: anytype, val: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, val, .little);
    try writer.writeAll(&buf);
}

fn writeBytes(writer: anytype, bytes: []const u8) !void {
    try writeU32(writer, @intCast(bytes.len));
    try writer.writeAll(bytes);
}

fn readU8(reader: anytype) !u8 {
    var b: [1]u8 = undefined;
    try readFull(reader, &b);
    return b[0];
}

fn readU32(reader: anytype) !u32 {
    var buf: [4]u8 = undefined;
    try readFull(reader, &buf);
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(reader: anytype) !u64 {
    var buf: [8]u8 = undefined;
    try readFull(reader, &buf);
    return std.mem.readInt(u64, &buf, .little);
}

fn readBytes(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const len = try readU32(reader);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try readFull(reader, buf);
    return buf;
}

fn readFull(reader: anytype, buf: []u8) !void {
    const T = @TypeOf(reader);
    if (@typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (@hasDecl(Child, "readSliceAll")) {
            return reader.readSliceAll(buf) catch error.UnexpectedEof;
        }
        if (@hasDecl(Child, "readAll")) {
            const n = try reader.readAll(buf);
            if (n != buf.len) return error.UnexpectedEof;
            return;
        }
    }
    if (@hasDecl(T, "readSliceAll")) {
        return reader.readSliceAll(buf) catch error.UnexpectedEof;
    }
    if (@hasDecl(T, "readAll")) {
        const n = try reader.readAll(buf);
        if (n != buf.len) return error.UnexpectedEof;
        return;
    }
    return error.UnexpectedEof;
}

fn writeJsonString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...8, 11, 12, 14...0x1f => try writer.print("\\u{x:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

test "writeJson renders a complete evaluation" {
    const variations = [_]schema.Variation{
        .{ .key = "on", .value = "{\"color\":\"blue\"}" },
    };
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeJson(&writer, .{
        .flag_key = "checkout",
        .enabled = true,
        .bucket = 42,
        .reason = .rollout_match,
        .variation = variations[0],
        .version = 5,
    });

    try std.testing.expectEqualStrings(
        "{\"flag_key\":\"checkout\",\"enabled\":true,\"bucket\":42,\"reason\":\"rollout_match\",\"variation\":{\"key\":\"on\",\"value\":\"{\\\"color\\\":\\\"blue\\\"}\"},\"version\":5}",
        writer.buffered(),
    );
}

test "flag json round trip" {
    const variations = [_]schema.Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const flag = schema.Flag{
        .key = "dark-mode",
        .enabled = true,
        .rollout_percentage = 40,
        .variations = &variations,
        .default_variation = 1,
    };

    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFlagJson(&writer, flag);

    const parsed = try parseFlagJson(std.testing.allocator, writer.buffered());
    defer parsed.deinit();

    try std.testing.expectEqualStrings("dark-mode", parsed.value.key);
    try std.testing.expect(parsed.value.enabled);
    try std.testing.expectEqual(@as(u8, 40), parsed.value.rollout_percentage);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.variations.len);
    try std.testing.expectEqualStrings("on", parsed.value.variations[1].key);
}

test "binary encode and decode round trip" {
    const variations = [_]schema.Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const rules = [_]schema.Rule{
        .{
            .id = "beta-users",
            .priority = 1,
            .expression = "user.tier == \"beta\"",
            .variation = 1,
        },
    };
    const prereqs = [_]schema.Prerequisite{
        .{ .flag_key = "parent-toggle", .variation_key = "on" },
    };
    const flags = [_]schema.Flag{
        .{
            .key = "new-search",
            .enabled = true,
            .type = .string,
            .rollout_percentage = 50,
            .default_variation = 0,
            .variations = &variations,
            .prerequisites = &prereqs,
            .rules = &rules,
        },
    };
    const segments = [_]schema.Segment{
        .{ .key = "eu-users", .expression = "user.country in [\"FR\", \"DE\"]" },
    };
    const original_config = schema.Config{
        .environment = "production",
        .version = 42,
        .flags = &flags,
        .segments = &segments,
    };

    var buf: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try encodeBinary(original_config, &writer);

    var reader = std.Io.Reader.fixed(writer.buffered());
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const decoded = try decodeBinary(arena.allocator(), &reader);

    try std.testing.expectEqualStrings("production", decoded.environment);
    try std.testing.expectEqual(@as(u64, 42), decoded.version);
    try std.testing.expectEqual(@as(usize, 1), decoded.flags.len);
    try std.testing.expectEqualStrings("new-search", decoded.flags[0].key);
    try std.testing.expect(decoded.flags[0].enabled);
    try std.testing.expectEqual(schema.FlagType.string, decoded.flags[0].type);
    try std.testing.expectEqual(@as(usize, 2), decoded.flags[0].variations.len);
    try std.testing.expectEqualStrings("on", decoded.flags[0].variations[1].key);
    try std.testing.expectEqual(@as(usize, 1), decoded.flags[0].rules.len);
    try std.testing.expectEqualStrings("beta-users", decoded.flags[0].rules[0].id);
    try std.testing.expectEqual(@as(usize, 1), decoded.segments.len);
    try std.testing.expectEqualStrings("eu-users", decoded.segments[0].key);
}
