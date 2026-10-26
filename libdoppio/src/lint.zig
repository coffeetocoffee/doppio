const std = @import("std");
const schema = @import("schema.zig");

/// `doppio lint`: the CI gate described in the architecture doc's feature
/// lifecycle automation. Two checks ship here because both are a pure function
/// of source text plus the control-plane flag list:
///
/// - `flag_reference`: a flag key referenced in code is missing from the
///   control plane, so the code would silently evaluate to a disabled flag.
/// - `schema_drift`: the control plane declares a flag the code never
///   references, which is how stale flags accumulate.
///
/// The third check in the doc, environment drift, needs the environment
/// inheritance model to exist first and is deliberately not attempted here.
pub const Severity = enum {
    warning,
    err,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .warning => "warning",
            .err => "error",
        };
    }
};

pub const Finding = struct {
    rule: []const u8,
    severity: Severity,
    line: usize,
    message: []const u8,
};

pub const Report = struct {
    findings: []const Finding,

    pub fn errors(self: Report) usize {
        var n: usize = 0;
        for (self.findings) |finding| {
            if (finding.severity == .err) n += 1;
        }
        return n;
    }

    pub fn warnings(self: Report) usize {
        return self.findings.len - self.errors();
    }

    pub fn ok(self: Report) bool {
        return self.errors() == 0;
    }
};

/// The flag list the code is checked against.
pub const ControlPlane = struct {
    flag_keys: []const []const u8,

    pub fn contains(self: ControlPlane, key: []const u8) bool {
        for (self.flag_keys) |known| {
            if (std.mem.eql(u8, known, key)) return true;
        }
        return false;
    }

    /// Parse a control-plane config snapshot into the set of known flag keys.
    /// Tolerates a UTF-8 byte order mark, which Windows tooling commonly
    /// prepends and which would otherwise fail JSON parsing.
    pub fn parse(arena: std.mem.Allocator, config_json: []const u8) !ControlPlane {
        const text = if (std.mem.startsWith(u8, config_json, "\xEF\xBB\xBF"))
            config_json[3..]
        else
            config_json;

        const parsed = std.json.parseFromSlice(schema.Config, arena, text, .{}) catch
            return error.InvalidConfig;
        var keys: std.ArrayList([]const u8) = .empty;
        for (parsed.value.flags) |flag| {
            if (flag.key.len == 0) continue;
            try keys.append(arena, flag.key);
        }
        return .{ .flag_keys = try keys.toOwnedSlice(arena) };
    }
};

/// Call shapes whose first argument is a flag key. Language-agnostic on
/// purpose: the same list covers the JavaScript SDK, the Go/Rust/Python SDKs
/// planned for Phase 2, and our own control-plane tests.
pub const accessors = [_][]const u8{
    "doppio.get",
    "doppio.isEnabled",
    "getFlag",
    "isEnabled",
    "useFlag",
    "variation",
    "flag",
};

/// Member names distinctive enough to match on any receiver. Every real call
/// site is instance-qualified (`wasm.isEnabled`, `sdk.variation`), and no
/// unrelated API is likely to share these names.
pub const member_accessors = [_][]const u8{
    "isEnabled",
    "variation",
    "getFlag",
    "useFlag",
};

/// `get` is too common to accept on any receiver (`store.get("cache-key")`),
/// so it counts only when the receiver names a Doppio client.
pub const get_receiver_suffix = "doppio";

/// Source file extensions worth scanning. Everything else is skipped so the
/// walker does not read binaries or vendored bundles.
pub const scannable_extensions = [_][]const u8{
    ".zig", ".ts", ".js", ".mjs",  ".tsx",   ".jsx",
    ".go",  ".rs", ".py", ".java", ".swift", ".kt",
    ".php", ".rb",
};

pub const lint_default_ignores = [_][]const u8{
    "node_modules",
    ".git",
    "zig-out",
    ".zig-cache",
    "dist",
    "target",
    "vendor",
    ".opencode",
};

/// One source file handed to the linter.
pub const Source = struct {
    path: []const u8,
    contents: []const u8,
};

/// Result of scanning one file: its findings plus the flag keys it referenced,
/// so the caller can union them for the cross-file drift check.
pub const SourceResult = struct {
    findings: []const Finding,
    referenced: []const []const u8,
};

/// Scan one source file against the control plane.
pub fn lintSource(
    arena: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    control_plane: ControlPlane,
) !SourceResult {
    var findings: std.ArrayList(Finding) = .empty;
    var referenced: std.ArrayList([]const u8) = .empty;

    try checkFlagReferences(arena, path, contents, control_plane, &findings, &referenced);

    return .{
        .findings = try findings.toOwnedSlice(arena),
        .referenced = try referenced.toOwnedSlice(arena),
    };
}

/// Scan a set of sources and run the cross-file checks once at the end.
pub fn lintAll(
    arena: std.mem.Allocator,
    sources: []const Source,
    control_plane: ControlPlane,
) !Report {
    var findings: std.ArrayList(Finding) = .empty;
    var referenced: std.ArrayList([]const u8) = .empty;

    for (sources) |source| {
        const result = try lintSource(arena, source.path, source.contents, control_plane);
        try findings.appendSlice(arena, result.findings);
        try referenced.appendSlice(arena, result.referenced);
    }

    try checkSchemaDrift(arena, referenced.items, control_plane, &findings);

    return .{ .findings = try findings.toOwnedSlice(arena) };
}

/// Accessor call sites whose key is not in the control plane, and the keys the
/// file does reference.
fn checkFlagReferences(
    arena: std.mem.Allocator,
    path: []const u8,
    contents: []const u8,
    control_plane: ControlPlane,
    findings: *std.ArrayList(Finding),
    referenced: *std.ArrayList([]const u8),
) !void {
    var line_no: usize = 1;
    var index: usize = 0;
    while (true) {
        const key = nextFlagKey(contents, &index, &line_no) orelse break;
        if (key.len == 0) continue;
        try referenced.append(arena, key);
        if (!control_plane.contains(key)) {
            try findings.append(arena, .{
                .rule = "flag_reference",
                .severity = .err,
                .line = line_no,
                .message = try std.fmt.allocPrint(arena, "flag \"{s}\" is referenced in {s} but absent from the control plane", .{ key, path }),
            });
        }
    }
}

/// Control-plane flags that no scanned source references. Only a warning,
/// because a flag can be legitimately consumed by an unscanned consumer.
fn checkSchemaDrift(
    arena: std.mem.Allocator,
    referenced: []const []const u8,
    control_plane: ControlPlane,
    out: *std.ArrayList(Finding),
) !void {
    for (control_plane.flag_keys) |key| {
        var used = false;
        for (referenced) |seen| {
            if (std.mem.eql(u8, seen, key)) {
                used = true;
                break;
            }
        }
        if (used) continue;
        try out.append(arena, .{
            .rule = "schema_drift",
            .severity = .warning,
            .line = 0,
            .message = try std.fmt.allocPrint(arena, "flag \"{s}\" is declared in the control plane but never referenced", .{key}),
        });
    }
}

/// Strip one flag key from a call site at or after `index`, advancing the
/// cursor past it. Returns null when there is no further call site.
///
/// A call site is an accessor identifier immediately followed by `(` and a
/// quote, so the closing quote of a key like `known-flag"` can never be
/// mistaken for a new call.
fn nextFlagKey(contents: []const u8, index: *usize, line_no: *usize) ?[]const u8 {
    var cursor = index.*;
    while (cursor < contents.len) {
        const paren = std.mem.indexOfScalarPos(u8, contents, cursor, '(') orelse return null;
        const open = paren + 1;
        if (open >= contents.len) return null;

        const quote = contents[open];
        if (quote != '"' and quote != '\'' and quote != '`') {
            cursor = open;
            continue;
        }
        if (!isAccessor(identBefore(contents, paren))) {
            cursor = open;
            continue;
        }

        const close = std.mem.indexOfScalarPos(u8, contents, open + 1, quote) orelse {
            cursor = open + 1;
            continue;
        };
        const key = contents[open + 1 .. close];
        advanceLine(contents, index, line_no, close + 1);
        if (isFlagKeyShape(key)) return key;
        // A quoted argument that cannot be a flag key (prose, an interpolated
        // expression, a unit id) is not a reference, so keep scanning past it.
        cursor = close + 1;
    }
    return null;
}

/// A flag key is a short slug: alphanumeric start, then alphanumerics,
/// hyphens, underscores, or dots. Anything else is a different argument that
/// happens to sit in a call position.
pub fn isFlagKeyShape(key: []const u8) bool {
    if (key.len == 0 or key.len > 128) return false;
    if (!std.ascii.isAlphanumeric(key[0])) return false;
    for (key) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }
    return true;
}

/// The identifier immediately before `at`, including dots so `doppio.get`
/// compares as one name.
fn identBefore(contents: []const u8, at: usize) []const u8 {
    var start = at;
    while (start > 0 and (std.ascii.isAlphanumeric(contents[start - 1]) or contents[start - 1] == '_' or contents[start - 1] == '.')) {
        start -= 1;
    }
    return contents[start..at];
}

fn isAccessor(ident: []const u8) bool {
    for (accessors) |accessor| {
        if (std.mem.eql(u8, accessor, ident)) return true;
    }

    // Instance calls arrive as `receiver.member`. Matching only the exact
    // dotted name missed the dominant real-world shape (`wasm.isEnabled`).
    const dot = std.mem.lastIndexOfScalar(u8, ident, '.') orelse return false;
    const receiver = ident[0..dot];
    const member = ident[dot + 1 ..];

    for (member_accessors) |accessor| {
        if (std.mem.eql(u8, accessor, member)) return true;
    }

    if (!std.mem.eql(u8, member, "get")) return false;
    if (receiver.len < get_receiver_suffix.len) return false;
    const tail = receiver[receiver.len - get_receiver_suffix.len ..];
    return std.ascii.eqlIgnoreCase(tail, get_receiver_suffix);
}

fn advanceLine(contents: []const u8, index: *usize, line_no: *usize, next: usize) void {
    var i = index.*;
    while (i < next and i < contents.len) : (i += 1) {
        if (contents[i] == '\n') line_no.* += 1;
    }
    index.* = @min(next, contents.len);
}

fn containsKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

test "lint reports a flag referenced in code but missing from the control plane" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const control_plane = ControlPlane{ .flag_keys = &.{ "known-flag", "other-flag" } };

    const source =
        \\import { Doppio } from "@doppio/js";
        \\const on1 = doppio.get("known-flag", { unitId: "u1" });
        \\const on2 = doppio.isEnabled("orphan-flag");
        \\const on3 = doppio.get('single-quoted-flag');
        \\const on4 = doppio.get("known-flag", { unitId: "u2" });
        \\
    ;

    const result = try lintSource(arena.allocator(), "app.ts", source, control_plane);
    try std.testing.expectEqual(@as(usize, 2), result.findings.len);
    for (result.findings) |finding| {
        try std.testing.expectEqualStrings("flag_reference", finding.rule);
        try std.testing.expect(finding.severity == .err);
    }

    var orphan: ?[]const u8 = null;
    var single: ?[]const u8 = null;
    for (result.findings) |finding| {
        if (std.mem.indexOf(u8, finding.message, "orphan-flag") != null) orphan = finding.message;
        if (std.mem.indexOf(u8, finding.message, "single-quoted-flag") != null) single = finding.message;
    }
    try std.testing.expect(orphan != null);
    try std.testing.expect(single != null);
    try std.testing.expect(std.mem.indexOf(u8, orphan.?, "app.ts") != null);

    // Both quoted styles are handled, and repeated references are collected.
    try std.testing.expectEqual(@as(usize, 4), result.referenced.len);
    try std.testing.expect(containsKey(result.referenced, "known-flag"));
}

test "lint line numbers point at the offending call site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source = "a\nb\nc\ndoppio.isEnabled(\"missing\")\ne\n";
    const result = try lintSource(arena.allocator(), "f.ts", source, .{ .flag_keys = &.{} });
    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqual(@as(usize, 4), result.findings[0].line);
}

test "lint ignores quoted strings that are not flag keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\const greeting = "hello world";
        \\const label = doppio.get("not a flag key", {});
        \\const on = doppio.isEnabled("known-flag");
        \\
    ;

    // Prose in a call position is not a flag key, so it is skipped rather than
    // reported; the plain string literal and the non-accessor call are ignored.
    const result = try lintSource(arena.allocator(), "f.ts", source, .{ .flag_keys = &.{"known-flag"} });
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
    try std.testing.expectEqual(@as(usize, 1), result.referenced.len);
    try std.testing.expectEqualStrings("known-flag", result.referenced[0]);
}

test "isFlagKeyShape accepts slugs and rejects other arguments" {
    try std.testing.expect(isFlagKeyShape("checkout-redesign"));
    try std.testing.expect(isFlagKeyShape("ui_theme"));
    try std.testing.expect(isFlagKeyShape("a"));
    try std.testing.expect(!isFlagKeyShape("not a flag key"));
    try std.testing.expect(!isFlagKeyShape("-leading-hyphen"));
    try std.testing.expect(!isFlagKeyShape("has/slash"));
    try std.testing.expect(!isFlagKeyShape(""));
    try std.testing.expect(!isFlagKeyShape("${interpolated}"));
}

test "lintAll unions references across files before checking drift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const control_plane = ControlPlane{ .flag_keys = &.{ "alpha", "beta", "ghost" } };
    const sources = [_]Source{
        .{ .path = "a.ts", .contents = "doppio.get(\"alpha\");" },
        .{ .path = "b.ts", .contents = "doppio.isEnabled(\"beta\");" },
    };

    const report = try lintAll(arena.allocator(), &sources, control_plane);
    // alpha and beta are used somewhere, so only ghost is drift.
    var drift: usize = 0;
    for (report.findings) |finding| {
        if (std.mem.eql(u8, finding.rule, "schema_drift")) drift += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), drift);
    try std.testing.expectEqual(@as(usize, 1), report.warnings());
    // Warnings alone do not fail the check.
    try std.testing.expect(report.ok());
    try std.testing.expect(std.mem.indexOf(u8, report.findings[0].message, "ghost") != null);
}

test "control plane config parses flag keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const config_json =
        \\{"environment":"production","version":1,"flags":[
        \\  {"key":"alpha","enabled":true},
        \\  {"key":"beta","enabled":false}
        \\],"segments":[]}
    ;
    const plane = try ControlPlane.parse(arena.allocator(), config_json);
    try std.testing.expectEqual(@as(usize, 2), plane.flag_keys.len);
    try std.testing.expect(plane.contains("alpha"));
    try std.testing.expect(!plane.contains("gamma"));

    // A UTF-8 byte order mark is tolerated, since Windows editors add one.
    const bom_json = "\xEF\xBB\xBF" ++ config_json;
    const bom_plane = try ControlPlane.parse(arena.allocator(), bom_json);
    try std.testing.expectEqual(@as(usize, 2), bom_plane.flag_keys.len);
    try std.testing.expect(bom_plane.contains("beta"));

    // A non-config payload is rejected rather than silently yielding an empty
    // flag list, which would make every reference look like an error.
    try std.testing.expectError(error.InvalidConfig, ControlPlane.parse(arena.allocator(), "{\"nope\":true}"));
}

test "report counts errors and warnings separately" {
    const rows = [_]Finding{
        .{ .rule = "flag_reference", .severity = .err, .line = 1, .message = "a" },
        .{ .rule = "schema_drift", .severity = .warning, .line = 0, .message = "b" },
        .{ .rule = "schema_drift", .severity = .warning, .line = 0, .message = "c" },
    };
    const report = Report{ .findings = &rows };
    try std.testing.expectEqual(@as(usize, 1), report.errors());
    try std.testing.expectEqual(@as(usize, 2), report.warnings());
    try std.testing.expect(!report.ok());

    const clean = Report{ .findings = &.{} };
    try std.testing.expect(clean.ok());
}

test "instance-qualified accessors are recognised" {
    try std.testing.expect(isAccessor("doppio.get"));
    try std.testing.expect(isAccessor("edgeDoppio.get"));
    try std.testing.expect(isAccessor("wasm.isEnabled"));
    try std.testing.expect(isAccessor("edge.isEnabled"));
    try std.testing.expect(isAccessor("sdk.variation"));
    try std.testing.expect(isAccessor("getFlag"));
    try std.testing.expect(isAccessor("useFlag"));

    // A generic `.get` on an unrelated object is not a flag read.
    try std.testing.expect(!isAccessor("store.get"));
    try std.testing.expect(!isAccessor("after.get"));
    try std.testing.expect(!isAccessor("doppio.getExposures"));
}

test "lint reads a flag through an instance receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const source =
        \\const a = wasm.isEnabled("missing-flag", "u1", 25);
        \\const b = edgeDoppio.get("known-flag");
        \\const c = store.get("cache-entry");
        \\
    ;

    const result = try lintSource(arena.allocator(), "f.ts", source, .{ .flag_keys = &.{"known-flag"} });
    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("flag_reference", result.findings[0].rule);
    try std.testing.expect(std.mem.indexOf(u8, result.findings[0].message, "missing-flag") != null);
    try std.testing.expectEqual(@as(usize, 2), result.referenced.len);
}
