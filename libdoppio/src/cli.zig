const std = @import("std");
const eval = @import("eval.zig");
const schema = @import("schema.zig");
const version = @import("version.zig");
const lint = @import("lint.zig");

pub const RunError = error{
    InvalidArguments,
    InvalidValue,
    NoSpaceLeft,
    /// The lint check found errors. Reported separately from usage errors so a
    /// CI job can fail the build without a usage dump on stderr.
    LintFailed,
};

/// What a command produced, plus the process exit code it implies. Commands
/// that can detect a failure a CI check should gate on return a non-zero code
/// together with their report.
pub const Outcome = struct {
    output: []const u8,
    exit_code: u8 = 0,
};

pub const usage =
    \\Usage:
    \\  doppio version
    \\  doppio eval [--flag NAME] [--unit ID] [--rollout PERCENT] [--json STRING] [--config PATH] [--attr KEY=VAL...]
    \\  doppio validate [--flag NAME] [--rollout PERCENT] [--json STRING] [--config PATH]
    \\  doppio bench [--iterations N] [--flag NAME] [--unit ID] [--rollout PERCENT] [--json STRING] [--config PATH]
    \\  doppio lint --config PATH [--source PATH]... [--strict]
    \\
    \\Examples:
    \\  doppio eval --flag checkout-redesign --unit user-123 --rollout 25
    \\  doppio eval --flag ui-theme --unit user-1 --json '{"key":"ui-theme","enabled":true}' --attr account.plan=enterprise
    \\  doppio validate --flag checkout-redesign --rollout 25
    \\  doppio bench --iterations 1000000 --flag checkout-redesign
    \\  doppio lint --config ./config.json --source ./src --source ./app.ts
    \\  doppio lint --config ./config.json --strict
    \\
;

pub fn run(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError![]const u8 {
    const outcome = try runOutcome(args, buffer, io);
    if (outcome.exit_code != 0) return error.LintFailed;
    return outcome.output;
}

pub fn runOutcome(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError!Outcome {
    if (args.len < 2) return .{ .output = try copy(buffer, usage) };

    const command = args[1];
    if (std.mem.eql(u8, command, "version")) {
        const text = std.fmt.bufPrint(buffer, "doppio {s}\n", .{version.string}) catch return error.NoSpaceLeft;
        return .{ .output = text };
    }
    if (std.mem.eql(u8, command, "eval")) {
        return .{ .output = try runEval(args[2..], buffer, io) };
    }
    if (std.mem.eql(u8, command, "validate")) {
        return .{ .output = try runValidate(args[2..], buffer, io) };
    }
    if (std.mem.eql(u8, command, "bench")) {
        return .{ .output = try runBench(args[2..], buffer, io) };
    }
    if (std.mem.eql(u8, command, "lint")) {
        return runLint(args[2..], buffer, io);
    }
    return error.InvalidArguments;
}

fn runEval(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError![]const u8 {
    var flag_key: []const u8 = "demo";
    var unit_id: []const u8 = "anonymous";
    var rollout: u8 = 50;
    var json_str: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var attrs: std.ArrayList(schema.Attribute) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const name = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, name, "--flag")) {
            if (value.len == 0) return error.InvalidValue;
            flag_key = value;
        } else if (std.mem.eql(u8, name, "--unit")) {
            if (value.len == 0) return error.InvalidValue;
            unit_id = value;
        } else if (std.mem.eql(u8, name, "--rollout")) {
            rollout = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
            if (rollout > 100) return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "--json")) {
            json_str = value;
        } else if (std.mem.eql(u8, name, "--config") or std.mem.eql(u8, name, "--file")) {
            config_path = value;
        } else if (std.mem.eql(u8, name, "--attr")) {
            if (std.mem.indexOf(u8, value, "=")) |eq_idx| {
                const k = value[0..eq_idx];
                const v = value[eq_idx + 1 ..];
                attrs.append(allocator, .{ .key = k, .value = v }) catch return error.NoSpaceLeft;
            } else {
                return error.InvalidValue;
            }
        } else {
            return error.InvalidArguments;
        }
    }

    var file_buffer: [65536]u8 = undefined;
    if (config_path) |path| {
        if (io) |actual_io| {
            const bytes = std.Io.Dir.cwd().readFile(actual_io, path, &file_buffer) catch return error.InvalidValue;
            json_str = bytes;
        } else {
            return error.InvalidValue;
        }
    }

    const context = schema.Context{
        .unit_id = unit_id,
        .attributes = attrs.items,
    };

    if (json_str) |raw_json| {
        if (std.json.parseFromSlice(schema.Config, allocator, raw_json, .{})) |parsed_cfg| {
            const result = eval.evaluateConfig(parsed_cfg.value, flag_key, context);
            const variation_key = if (result.variation) |variation| variation.key else "-";
            return std.fmt.bufPrint(
                buffer,
                "flag={s} unit={s} enabled={} bucket={d} reason={s} variation={s}\n",
                .{ result.flag_key, unit_id, result.enabled, result.bucket, @tagName(result.reason), variation_key },
            ) catch error.NoSpaceLeft;
        } else |_| {
            if (std.json.parseFromSlice(schema.Flag, allocator, raw_json, .{})) |parsed_flag| {
                const result = eval.evaluate(parsed_flag.value, context);
                const variation_key = if (result.variation) |variation| variation.key else "-";
                return std.fmt.bufPrint(
                    buffer,
                    "flag={s} unit={s} enabled={} bucket={d} reason={s} variation={s}\n",
                    .{ result.flag_key, unit_id, result.enabled, result.bucket, @tagName(result.reason), variation_key },
                ) catch error.NoSpaceLeft;
            } else |_| {
                return error.InvalidValue;
            }
        }
    }

    const variations = [_]schema.Variation{
        .{ .key = "off", .value = "false" },
        .{ .key = "on", .value = "true" },
    };
    const flag = schema.Flag{
        .key = flag_key,
        .enabled = true,
        .rollout_percentage = rollout,
        .variations = &variations,
        .default_variation = 1,
    };
    const result = eval.evaluate(flag, context);
    const variation_key = if (result.variation) |variation| variation.key else "-";

    return std.fmt.bufPrint(
        buffer,
        "flag={s} unit={s} enabled={} bucket={d} reason={s} variation={s}\n",
        .{ result.flag_key, unit_id, result.enabled, result.bucket, @tagName(result.reason), variation_key },
    ) catch error.NoSpaceLeft;
}

fn runValidate(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError![]const u8 {
    var flag_key: []const u8 = "demo";
    var rollout: u8 = 100;
    var json_str: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const name = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, name, "--flag")) {
            flag_key = value;
        } else if (std.mem.eql(u8, name, "--rollout")) {
            rollout = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "--json")) {
            json_str = value;
        } else if (std.mem.eql(u8, name, "--config") or std.mem.eql(u8, name, "--file")) {
            config_path = value;
        } else {
            return error.InvalidArguments;
        }
    }

    var file_buffer: [65536]u8 = undefined;
    if (config_path) |path| {
        if (io) |actual_io| {
            const bytes = std.Io.Dir.cwd().readFile(actual_io, path, &file_buffer) catch return error.InvalidValue;
            json_str = bytes;
        } else {
            return error.InvalidValue;
        }
    }

    if (json_str) |raw_json| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        if (std.json.parseFromSlice(schema.Config, arena.allocator(), raw_json, .{})) |parsed_cfg| {
            schema.validateConfig(parsed_cfg.value) catch return error.InvalidValue;
            return std.fmt.bufPrint(
                buffer,
                "valid config flags={d} segments={d}\n",
                .{ parsed_cfg.value.flags.len, parsed_cfg.value.segments.len },
            ) catch error.NoSpaceLeft;
        } else |_| {
            if (std.json.parseFromSlice(schema.Flag, arena.allocator(), raw_json, .{})) |parsed_flag| {
                schema.validateFlag(parsed_flag.value) catch return error.InvalidValue;
                return std.fmt.bufPrint(
                    buffer,
                    "valid flag={s} rollout={d}%\n",
                    .{ parsed_flag.value.key, parsed_flag.value.rollout_percentage },
                ) catch error.NoSpaceLeft;
            } else |_| {
                return error.InvalidValue;
            }
        }
    }

    const flag = schema.Flag{
        .key = flag_key,
        .rollout_percentage = rollout,
    };
    schema.validateFlag(flag) catch return error.InvalidValue;

    return std.fmt.bufPrint(
        buffer,
        "valid flag={s} rollout={d}%\n",
        .{ flag.key, flag.rollout_percentage },
    ) catch error.NoSpaceLeft;
}

fn runBench(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError![]const u8 {
    var flag_key: []const u8 = "demo";
    var unit_id: []const u8 = "anonymous";
    var rollout: u8 = 50;
    var iterations: u64 = 1_000_000;
    var json_str: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const name = args[i];
        const value = args[i + 1];

        if (std.mem.eql(u8, name, "--flag")) {
            if (value.len == 0) return error.InvalidValue;
            flag_key = value;
        } else if (std.mem.eql(u8, name, "--unit")) {
            if (value.len == 0) return error.InvalidValue;
            unit_id = value;
        } else if (std.mem.eql(u8, name, "--rollout")) {
            rollout = std.fmt.parseInt(u8, value, 10) catch return error.InvalidValue;
            if (rollout > 100) return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "--iterations")) {
            iterations = std.fmt.parseInt(u64, value, 10) catch return error.InvalidValue;
            if (iterations == 0) return error.InvalidValue;
        } else if (std.mem.eql(u8, name, "--json")) {
            json_str = value;
        } else if (std.mem.eql(u8, name, "--config") or std.mem.eql(u8, name, "--file")) {
            config_path = value;
        } else {
            return error.InvalidArguments;
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var file_buffer: [65536]u8 = undefined;
    if (config_path) |path| {
        if (io) |actual_io| {
            const bytes = std.Io.Dir.cwd().readFile(actual_io, path, &file_buffer) catch return error.InvalidValue;
            json_str = bytes;
        } else {
            return error.InvalidValue;
        }
    }

    var target_flag: schema.Flag = undefined;
    var target_config: ?schema.Config = null;

    if (json_str) |raw_json| {
        if (std.json.parseFromSlice(schema.Config, arena.allocator(), raw_json, .{})) |parsed| {
            target_config = parsed.value;
        } else |_| {
            if (std.json.parseFromSlice(schema.Flag, arena.allocator(), raw_json, .{})) |parsed| {
                target_flag = parsed.value;
            } else |_| {
                return error.InvalidValue;
            }
        }
    } else {
        const variations = [_]schema.Variation{
            .{ .key = "off", .value = "false" },
            .{ .key = "on", .value = "true" },
        };
        target_flag = schema.Flag{
            .key = flag_key,
            .enabled = true,
            .rollout_percentage = rollout,
            .variations = &variations,
            .default_variation = 1,
        };
    }

    const context = schema.Context{ .unit_id = unit_id };

    if (io) |actual_io| {
        const t0 = std.Io.Timestamp.now(actual_io, .awake);
        var j: u64 = 0;
        var enabled_count: u64 = 0;
        while (j < iterations) : (j += 1) {
            const res = if (target_config) |cfg|
                eval.evaluateConfig(cfg, flag_key, context)
            else
                eval.evaluate(target_flag, context);
            if (res.enabled) enabled_count += 1;
        }
        const t1 = std.Io.Timestamp.now(actual_io, .awake);
        const dur = t0.durationTo(t1);
        const ns = dur.toNanoseconds();
        const ns_per_op = @divTrunc(ns, @as(i96, @intCast(iterations)));
        const ops_sec = if (ns > 0) @divTrunc(@as(i96, @intCast(iterations)) * 1_000_000_000, ns) else 0;

        return std.fmt.bufPrint(
            buffer,
            "bench flag={s} iters={d} total_ms={d} ns_per_op={d} ops_per_sec={d}\n",
            .{ flag_key, iterations, dur.toMilliseconds(), ns_per_op, ops_sec },
        ) catch error.NoSpaceLeft;
    } else {
        var j: u64 = 0;
        while (j < iterations) : (j += 1) {
            _ = if (target_config) |cfg|
                eval.evaluateConfig(cfg, flag_key, context)
            else
                eval.evaluate(target_flag, context);
        }
        return std.fmt.bufPrint(
            buffer,
            "bench flag={s} iters={d}\n",
            .{ flag_key, iterations },
        ) catch error.NoSpaceLeft;
    }
}

fn copy(buffer: []u8, text: []const u8) RunError![]const u8 {
    if (buffer.len < text.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..text.len], text);
    return buffer[0..text.len];
}

/// `doppio lint --config PATH [--source PATH]... [--strict]`
///
/// Errors fail the command; warnings only do under `--strict`. Without a
/// `--source` the current directory is walked, skipping build output and
/// vendored trees so a repo lint does not read its own artifacts.
fn runLint(args: []const []const u8, buffer: []u8, io: ?std.Io) RunError!Outcome {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config_path: ?[]const u8 = null;
    var source_paths: std.ArrayList([]const u8) = .empty;
    var strict = false;

    // `--strict` is a bare switch, so this loop advances one argument at a time
    // and steps over the value itself for the options that take one.
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const name = args[i];
        if (std.mem.eql(u8, name, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            config_path = args[i];
        } else if (std.mem.eql(u8, name, "--source")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            source_paths.append(allocator, args[i]) catch return error.NoSpaceLeft;
        } else if (std.mem.eql(u8, name, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, name, "--no-strict")) {
            strict = false;
        } else {
            return error.InvalidArguments;
        }
    }

    const path = config_path orelse return error.InvalidArguments;
    const actual_io = io orelse return error.InvalidValue;

    var config_buffer: [1 << 20]u8 = undefined;
    const config_bytes = std.Io.Dir.cwd().readFile(actual_io, path, &config_buffer) catch return error.InvalidValue;
    const control_plane = lint.ControlPlane.parse(allocator, config_bytes) catch return error.InvalidValue;

    var scanned: std.ArrayList(lint.Source) = .empty;
    if (source_paths.items.len == 0) {
        collectSources(allocator, actual_io, ".", &scanned);
    } else {
        for (source_paths.items) |source_path| {
            collectSources(allocator, actual_io, source_path, &scanned);
        }
    }

    const report = lint.lintAll(allocator, scanned.items, control_plane) catch return error.NoSpaceLeft;
    const text = try renderLintReport(allocator, buffer, report, strict);
    const failed = !report.ok() or (strict and report.warnings() > 0);
    return .{ .output = text, .exit_code = if (failed) 1 else 0 };
}

/// Gather scannable files under `path`. A file is read directly; a directory
/// is walked recursively with build output and vendored trees skipped.
/// Allocation failures skip a file rather than failing the whole run, so a
/// large tree still produces a useful report.
fn collectSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.ArrayList(lint.Source),
) void {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return;
    if (stat.kind != .directory) {
        if (!isScannable(path)) return;
        var buffer: [1 << 20]u8 = undefined;
        const bytes = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return;
        out.append(allocator, .{
            .path = allocator.dupe(u8, path) catch return,
            .contents = allocator.dupe(u8, bytes) catch return,
        }) catch return;
        return;
    }

    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (isIgnoredPath(entry.path)) continue;
        if (!isScannable(entry.path)) continue;
        var entry_buffer: [1 << 20]u8 = undefined;
        const bytes = entry.dir.readFile(io, entry.basename, &entry_buffer) catch continue;
        const display = std.fs.path.join(allocator, &.{ path, entry.path }) catch continue;
        out.append(allocator, .{
            .path = display,
            .contents = allocator.dupe(u8, bytes) catch continue,
        }) catch continue;
    }
}

fn isScannable(path: []const u8) bool {
    for (lint.scannable_extensions) |extension| {
        if (std.mem.endsWith(u8, path, extension)) return true;
    }
    return false;
}

fn isIgnoredPath(path: []const u8) bool {
    for (lint.lint_default_ignores) |ignored| {
        if (std.mem.indexOf(u8, path, ignored) != null) return true;
    }
    return false;
}

fn renderLintReport(
    allocator: std.mem.Allocator,
    buffer: []u8,
    report: lint.Report,
    strict: bool,
) RunError![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (report.findings) |finding| {
        const line = std.fmt.allocPrint(
            allocator,
            "{s}: {s}:{d}: {s} [{s}]\n",
            .{ finding.severity.label(), finding.rule, finding.line, finding.message, finding.rule },
        ) catch return error.NoSpaceLeft;
        text.appendSlice(allocator, line) catch return error.NoSpaceLeft;
    }
    const summary = std.fmt.allocPrint(
        allocator,
        "lint {d} error(s), {d} warning(s){s}\n",
        .{ report.errors(), report.warnings(), if (strict) " (strict)" else "" },
    ) catch return error.NoSpaceLeft;
    text.appendSlice(allocator, summary) catch return error.NoSpaceLeft;

    if (text.items.len > buffer.len) return error.NoSpaceLeft;
    @memcpy(buffer[0..text.items.len], text.items);
    return buffer[0..text.items.len];
}

test "lint command is documented in usage" {
    try std.testing.expect(std.mem.indexOf(u8, usage, "doppio lint") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--config") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--strict") != null);
}

test "lint rejects a missing config" {
    var buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.InvalidArguments,
        runOutcome(&.{ "doppio", "lint" }, &buffer, null),
    );
}

test "lint needs io because it reads files" {
    var buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.InvalidValue,
        runOutcome(&.{ "doppio", "lint", "--config", "c.json" }, &buffer, null),
    );
}

test "lint accepts a bare --strict after options that take a value" {
    var buffer: [4096]u8 = undefined;
    // Parsing succeeds, so the failure is the missing io rather than a usage
    // error. Before the fix `--strict` consumed the next argv slot as a value.
    try std.testing.expectError(
        error.InvalidValue,
        runOutcome(&.{ "doppio", "lint", "--config", "c.json", "--strict" }, &buffer, null),
    );
    try std.testing.expectError(
        error.InvalidValue,
        runOutcome(
            &.{ "doppio", "lint", "--source", "a.ts", "--config", "c.json", "--strict" },
            &buffer,
            null,
        ),
    );
}

test "lint rejects an option missing its value" {
    var buffer: [4096]u8 = undefined;
    try std.testing.expectError(
        error.InvalidArguments,
        runOutcome(&.{ "doppio", "lint", "--config" }, &buffer, null),
    );
    try std.testing.expectError(
        error.InvalidArguments,
        runOutcome(&.{ "doppio", "lint", "--config", "c.json", "--source" }, &buffer, null),
    );
}

test "version command" {
    var buffer: [256]u8 = undefined;
    const output = try run(&.{ "doppio", "version" }, &buffer, null);
    try std.testing.expectEqualStrings("doppio 0.1.0-dev\n", output);
}

test "eval command reports a deterministic decision" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{ "doppio", "eval", "--flag", "checkout", "--unit", "user-1", "--rollout", "100" },
        &buffer,
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "variation=on") != null);
}

test "eval command with attributes and json" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{
            "doppio",
            "eval",
            "--flag",
            "custom-test",
            "--unit",
            "user-vip",
            "--json",
            "{\"key\":\"custom-test\",\"enabled\":true,\"rollout_percentage\":100}",
            "--attr",
            "tier=gold",
        },
        &buffer,
        null,
    );
    try std.testing.expect(std.mem.indexOf(u8, output, "enabled=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "flag=custom-test") != null);
}

test "eval command rejects unknown arguments" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(
        error.InvalidArguments,
        run(&.{ "doppio", "eval", "--wat", "1" }, &buffer, null),
    );
}

test "eval command rejects invalid rollout values" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(
        error.InvalidValue,
        run(&.{ "doppio", "eval", "--rollout", "101" }, &buffer, null),
    );
}

test "validate command verifies valid flag" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{ "doppio", "validate", "--flag", "dark-mode", "--rollout", "30" },
        &buffer,
        null,
    );
    try std.testing.expectEqualStrings("valid flag=dark-mode rollout=30%\n", output);
}

test "validate command rejects empty flag key" {
    var buffer: [512]u8 = undefined;
    try std.testing.expectError(
        error.InvalidValue,
        run(&.{ "doppio", "validate", "--flag", "" }, &buffer, null),
    );
}

test "validate command parses and checks JSON flag" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{ "doppio", "validate", "--json", "{\"key\":\"nav-test\",\"rollout_percentage\":75}" },
        &buffer,
        null,
    );
    try std.testing.expectEqualStrings("valid flag=nav-test rollout=75%\n", output);
}

test "validate command parses and checks JSON config" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{ "doppio", "validate", "--json", "{\"environment\":\"prod\",\"version\":1,\"flags\":[{\"key\":\"nav-test\"}]}" },
        &buffer,
        null,
    );
    try std.testing.expectEqualStrings("valid config flags=1 segments=0\n", output);
}

test "bench command runs evaluations" {
    var buffer: [512]u8 = undefined;
    const output = try run(
        &.{ "doppio", "bench", "--iterations", "10", "--flag", "perf" },
        &buffer,
        null,
    );
    try std.testing.expectEqualStrings("bench flag=perf iters=10\n", output);
}
