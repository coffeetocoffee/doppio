const std = @import("std");
const doppio = @import("doppio");
const sigstore = @import("backends/sigstore.zig");
const build_options = @import("build_options");
const postgres = if (build_options.enable_postgres) @import("backends/postgres.zig") else struct {};
const PgBackend = if (build_options.enable_postgres) postgres.PostgresBackend else void;

const c = struct {
    pub const sqlite3 = opaque {};
    pub const sqlite3_stmt = opaque {};
    pub const SQLITE_OK: c_int = 0;
    pub const SQLITE_ROW: c_int = 100;
    pub const SQLITE_DONE: c_int = 101;
    extern "c" fn sqlite3_open(path: [*:0]const u8, ppDb: *?*sqlite3) callconv(.c) c_int;
    extern "c" fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?*const u8) callconv(.c) c_int;
    extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) callconv(.c) c_int;
    extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) callconv(.c) c_int;
    extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, value: [*:0]const u8, n: c_int, dtor: ?*const fn (?*anyopaque) callconv(.c) void) callconv(.c) c_int;
    extern "c" fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) callconv(.c) c_int;
    extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) callconv(.c) c_int;
    extern "c" fn sqlite3_reset(stmt: ?*sqlite3_stmt) callconv(.c) c_int;
    extern "c" fn sqlite3_changes(db: ?*sqlite3) callconv(.c) c_int;
};

pub const SQLITE_SCHEMA_DDL =
    \\CREATE TABLE IF NOT EXISTS organizations (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS workspaces (
    \\    id TEXT PRIMARY KEY,
    \\    org_id TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    FOREIGN KEY(org_id) REFERENCES organizations(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS environments (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    name TEXT NOT NULL,
    \\    order_index INTEGER NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    FOREIGN KEY(workspace_id) REFERENCES workspaces(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS flags (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT NOT NULL,
    \\    key TEXT NOT NULL,
    \\    enabled INTEGER NOT NULL DEFAULT 0,
    \\    rollout_percentage INTEGER NOT NULL DEFAULT 100,
    \\    flag_type TEXT NOT NULL DEFAULT 'boolean',
    \\    default_variation INTEGER NOT NULL DEFAULT 0,
    \\    variations_json TEXT,
    \\    rules_json TEXT,
    \\    prerequisites_json TEXT,
    \\    version INTEGER NOT NULL DEFAULT 1,
    \\    deleted_at INTEGER,
    \\    created_at INTEGER NOT NULL,
    \\    updated_at INTEGER NOT NULL,
    \\    UNIQUE(workspace_id, environment_id, key)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS flag_versions (
    \\    id TEXT PRIMARY KEY,
    \\    flag_id TEXT NOT NULL,
    \\    version INTEGER NOT NULL,
    \\    definition_json TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    created_by TEXT NOT NULL,
    \\    FOREIGN KEY(flag_id) REFERENCES flags(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS segments (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    key TEXT NOT NULL,
    \\    expression TEXT NOT NULL,
    \\    created_at INTEGER NOT NULL,
    \\    UNIQUE(workspace_id, key)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS audit_events (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    action TEXT NOT NULL,
    \\    target_type TEXT NOT NULL,
    \\    target_id TEXT NOT NULL,
    \\    actor TEXT NOT NULL,
    \\    payload_json TEXT,
    \\    signature TEXT,
    \\    timestamp INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS api_keys (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    key_hash TEXT NOT NULL,
    \\    scope TEXT NOT NULL,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT,
    \\    created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_flags_key ON flags(workspace_id, environment_id, key);
    \\CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_events(workspace_id, timestamp);
;

pub const EXPOSURES_DDL =
    \\CREATE TABLE IF NOT EXISTS exposures (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT NOT NULL,
    \\    flag_key TEXT NOT NULL,
    \\    unit_id TEXT NOT NULL,
    \\    enabled INTEGER NOT NULL,
    \\    variation TEXT,
    \\    bucket INTEGER NOT NULL DEFAULT 0,
    \\    reason TEXT,
    \\    occurred_at INTEGER NOT NULL,
    \\    received_at INTEGER NOT NULL,
    \\    idempotency_key TEXT
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_exposures_dedupe
    \\    ON exposures(workspace_id, environment_id, idempotency_key)
    \\    WHERE idempotency_key <> '';
    \\CREATE INDEX IF NOT EXISTS idx_exposures_occurred_at ON exposures(occurred_at);
;

pub const AuditRecord = struct {
    id: []const u8,
    action: []const u8,
    target_type: []const u8,
    target_id: []const u8,
    actor: []const u8,
    timestamp: i64,
    /// SHA-256 over the previous record's hash plus this record's fields, so
    /// any edit or removal breaks every later link in the chain.
    hash: [32]u8,
    prev_hash: [32]u8,
    /// HMAC-SHA256 signature over the record (Sigstore-style audit signing).
    signature: ?[]const u8 = null,
};

pub const FlagRecord = struct {
    key: []const u8,
    enabled: bool = false,
    rollout_percentage: u8 = 0,
    variations_json: ?[]const u8 = null,
    rules_json: ?[]const u8 = null,
    prerequisites_json: ?[]const u8 = null,
    version: u64 = 1,
    deleted: bool = false,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};

/// A flag this one depends on, derived from prerequisites_json.
pub const DependencyEdge = struct {
    from_key: []const u8,
    to_key: []const u8,
    variation_key: []const u8,
};

pub const SegmentRecord = struct {
    key: []const u8,
    expression: []const u8,
};

pub const EnvironmentRecord = struct {
    name: []const u8,
    order: u32,
};

/// One accepted exposure row as it enters the durable store.
pub const ExposureRow = struct {
    workspace_id: []const u8,
    environment_id: []const u8,
    flag_key: []const u8,
    unit_id: []const u8,
    enabled: bool,
    variation: ?[]const u8,
    bucket: u32,
    reason: []const u8,
    occurred_at: i64,
    received_at: i64,
    idempotency_key: ?[]const u8,
};

fn noop_destructor(_: ?*anyopaque) callconv(.c) void {}

/// Selects the durable storage implementation. SQLite remains the default for
/// dev/tests; Postgres is the production primary (see backends/postgres.zig).
pub const BackendKind = enum { sqlite, postgres };

pub const Storage = struct {
    allocator: std.mem.Allocator,
    flags: std.StringHashMap(FlagRecord),
    segments: std.StringHashMap(SegmentRecord),
    environments: std.ArrayList(EnvironmentRecord),
    audit_events: std.ArrayList(AuditRecord),
    /// Active durable backend selection.
    backend: BackendKind = .sqlite,
    /// Open SQLite handle for durable exposure storage. Null while the
    /// in-memory maps above are the only state, which is the case in tests.
    db: ?*c.sqlite3 = null,
    db_path: []const u8 = "",
    /// Optional Postgres connection (only present when built with -Dpostgres).
    pg: ?PgBackend = null,

    /// Choose the durable backend. Postgres wiring lives in backends/postgres.zig;
    /// callers should open the corresponding connection after selecting it.
    pub fn selectBackend(self: *Storage, kind: BackendKind) void {
        self.backend = kind;
    }

    /// Connect to Postgres and apply the schema. Requires -Dpostgres.
    pub const openPostgres = if (build_options.enable_postgres) openPostgresImpl else openPostgresDisabled;

    fn openPostgresImpl(self: *Storage, conninfo: []const u8) !void {
        const owned = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{conninfo}, 0);
        defer self.allocator.free(owned);
        var backend: PgBackend = .{};
        try backend.connect(owned);
        backend.initSchema();
        self.pg = backend;
        self.backend = .postgres;
        try self.hydrateFromPostgres();
    }

    /// Populate the in-memory working maps from Postgres so reads reflect
    /// durable state after a restart. Reads continue to be served from memory.
    const hydrateFromPostgres = if (build_options.enable_postgres) hydrateFromPostgresImpl else hydrateFromPostgresNoop;

    fn hydrateFromPostgresImpl(self: *Storage) !void {
        if (self.pg) |*backend| {
            const flags_sql = try std.fmt.allocPrintSentinel(
                self.allocator,
                "SELECT key, enabled, rollout_percentage, version, created_at, updated_at FROM flags WHERE deleted_at IS NULL",
                .{},
                0,
            );
            defer self.allocator.free(flags_sql);
            const res = backend.query(flags_sql);
            if (res) |r| {
                defer PgBackend.freeResult(r);
                const n = PgBackend.rowCount(r);
                var i: c_int = 0;
                while (i < n) : (i += 1) {
                    const key_raw = PgBackend.rowValue(r, i, 0) orelse continue;
                    const owned = try self.allocator.dupe(u8, key_raw);
                    const gop = try self.flags.getOrPut(owned);
                    if (gop.found_existing) {
                        self.allocator.free(owned);
                    } else {
                        gop.key_ptr.* = owned;
                    }
                    gop.value_ptr.* = .{
                        .key = gop.key_ptr.*,
                        .enabled = std.mem.eql(u8, PgBackend.rowValue(r, i, 1) orelse "f", "t"),
                        .rollout_percentage = std.fmt.parseInt(u8, PgBackend.rowValue(r, i, 2) orelse "100", 10) catch 100,
                        .version = std.fmt.parseInt(u64, PgBackend.rowValue(r, i, 3) orelse "1", 10) catch 1,
                        .created_at = std.fmt.parseInt(i64, PgBackend.rowValue(r, i, 4) orelse "0", 10) catch 0,
                        .updated_at = std.fmt.parseInt(i64, PgBackend.rowValue(r, i, 5) orelse "0", 10) catch 0,
                    };
                }
            }

            const seg_sql = try std.fmt.allocPrintSentinel(
                self.allocator,
                "SELECT key, expression FROM segments",
                .{},
                0,
            );
            defer self.allocator.free(seg_sql);
            const seg_res = backend.query(seg_sql);
            if (seg_res) |r| {
                defer PgBackend.freeResult(r);
                const n = PgBackend.rowCount(r);
                var i: c_int = 0;
                while (i < n) : (i += 1) {
                    const key_raw = PgBackend.rowValue(r, i, 0) orelse continue;
                    const expr_raw = PgBackend.rowValue(r, i, 1) orelse "";
                    const owned_key = try self.allocator.dupe(u8, key_raw);
                    const owned_expr = try self.allocator.dupe(u8, expr_raw);
                    const gop = try self.segments.getOrPut(owned_key);
                    if (gop.found_existing) {
                        self.allocator.free(owned_key);
                        self.allocator.free(gop.value_ptr.expression);
                    } else {
                        gop.key_ptr.* = owned_key;
                    }
                    gop.value_ptr.* = .{ .key = gop.key_ptr.*, .expression = owned_expr };
                }
            }
        }
    }

    fn hydrateFromPostgresNoop(_: *Storage) !void {}

    fn openPostgresDisabled(_: *Storage, _: []const u8) !void {
        return error.PostgresNotEnabled;
    }

    /// Mirror a flag row into Postgres when that backend is active.
    const persistFlag = if (build_options.enable_postgres) persistFlagImpl else persistFlagNoop;

    fn persistFlagImpl(self: *Storage, rec: FlagRecord) void {
        if (self.backend != .postgres) return;
        if (self.pg) |*backend| {
            const sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "INSERT INTO flags (id, workspace_id, environment_id, key, enabled, rollout_percentage, version, created_at, updated_at) " ++
                    "VALUES ('{s}', 'default', 'default', '{s}', {s}, {d}, {d}, {d}, {d}) " ++
                    "ON CONFLICT (workspace_id, environment_id, key) DO UPDATE SET enabled = EXCLUDED.enabled, " ++
                    "rollout_percentage = EXCLUDED.rollout_percentage, version = EXCLUDED.version, updated_at = EXCLUDED.updated_at",
                .{
                    rec.key,
                    rec.key,
                    if (rec.enabled) "TRUE" else "FALSE",
                    rec.rollout_percentage,
                    rec.version,
                    rec.created_at,
                    rec.updated_at,
                },
                0,
            ) catch return;
            defer self.allocator.free(sql);
            backend.exec(sql) catch {};
        }
    }

    fn persistFlagNoop(_: *Storage, _: FlagRecord) void {}

    pub fn init(allocator: std.mem.Allocator) Storage {
        var s = Storage{
            .allocator = allocator,
            .flags = std.StringHashMap(FlagRecord).init(allocator),
            .segments = std.StringHashMap(SegmentRecord).init(allocator),
            .environments = .empty,
            .audit_events = .empty,
        };

        // Seed default environments
        s.environments.append(allocator, .{ .name = "development", .order = 1 }) catch {};
        s.environments.append(allocator, .{ .name = "staging", .order = 2 }) catch {};
        s.environments.append(allocator, .{ .name = "production", .order = 3 }) catch {};

        return s;
    }

    pub fn open(self: *Storage, allocator: std.mem.Allocator, db_path: []const u8) !void {
        const owned = try allocator.alloc(u8, db_path.len + 1);
        defer allocator.free(owned);
        @memcpy(owned[0..db_path.len], db_path);
        owned[db_path.len] = 0;

        var db: ?*c.sqlite3 = undefined;
        const rc = c.sqlite3_open(@as([*c]const u8, @ptrCast(owned.ptr)), &db);
        if (rc != c.SQLITE_OK) return error.SqliteOpenFailed;
        self.db = db;
        self.db_path = db_path;

        try self.execSql("PRAGMA journal_mode=WAL;");
        try self.execSql("PRAGMA synchronous=NORMAL;");
        try self.execSql("PRAGMA foreign_keys=ON;");
        try self.execSql(SQLITE_SCHEMA_DDL);
        try self.execSql(EXPOSURES_DDL);
    }

    fn execSql(self: *Storage, sql: []const u8) !void {
        const db = self.db orelse return error.NoDatabase;
        var stmt: ?*c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(db, @as([*c]const u8, @ptrCast(sql.ptr)), @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        var step_rc = c.sqlite3_step(stmt);
        while (step_rc == c.SQLITE_ROW) step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return error.SqliteStepFailed;
    }

    fn bindText(stmt: ?*c.sqlite3_stmt, idx: c_int, value: ?[]const u8) !void {
        if (value) |v| {
            const rc = c.sqlite3_bind_text(stmt, idx, @as([*c]const u8, @ptrCast(v.ptr)), @intCast(v.len), &noop_destructor);
            if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
        } else {
            const rc = c.sqlite3_bind_null(stmt, idx);
            if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
        }
    }

    fn bindInt64(stmt: ?*c.sqlite3_stmt, idx: c_int, value: i64) !void {
        const rc = c.sqlite3_bind_int64(stmt, idx, value);
        if (rc != c.SQLITE_OK) return error.SqliteBindFailed;
    }

    fn bindBool(stmt: ?*c.sqlite3_stmt, idx: c_int, value: bool) !void {
        try bindInt64(stmt, idx, if (value) 1 else 0);
    }

    /// Append one exposure batch inside a single transaction and return how
    /// many rows actually landed. The partial unique index on
    /// (workspace_id, environment_id, idempotency_key) makes the insert the
    /// source of truth for dedupe, so retries that survived a restart store
    /// nothing.
    pub fn insertExposureBatch(self: *Storage, rows: []const ExposureRow) !usize {
        const db = self.db orelse return error.NoDatabase;
        try self.execSql("BEGIN IMMEDIATE;");
        defer _ = self.execSql("ROLLBACK;") catch {};
        {
            var stmt: ?*c.sqlite3_stmt = undefined;
            const rc = c.sqlite3_prepare_v2(
                db,
                "INSERT OR IGNORE INTO exposures (workspace_id, environment_id, flag_key, unit_id, enabled, variation, bucket, reason, occurred_at, received_at, idempotency_key) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                -1,
                &stmt,
                null,
            );
            if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);

            for (rows) |row| {
                try bindText(stmt, 1, row.workspace_id);
                try bindText(stmt, 2, row.environment_id);
                try bindText(stmt, 3, row.flag_key);
                try bindText(stmt, 4, row.unit_id);
                try bindBool(stmt, 5, row.enabled);
                try bindText(stmt, 6, row.variation);
                try bindInt64(stmt, 7, @intCast(row.bucket));
                try bindText(stmt, 8, row.reason);
                try bindInt64(stmt, 9, row.occurred_at);
                try bindInt64(stmt, 10, row.received_at);
                try bindText(stmt, 11, row.idempotency_key);
                const rc2 = c.sqlite3_step(stmt);
                if (rc2 != c.SQLITE_DONE) return error.SqliteStepFailed;
                _ = c.sqlite3_reset(stmt);
            }
        }
        try self.execSql("COMMIT;");
        const changes: c_int = c.sqlite3_changes(db);
        self.persistExposureBatch(rows);
        return @intCast(changes);
    }

    /// Mirror an exposure batch into Postgres when that backend is active. The
    /// partial unique index makes the insert the dedupe source of truth, so a
    /// replayed batch stores nothing new.
    const persistExposureBatch = if (build_options.enable_postgres) persistExposureBatchImpl else persistExposureBatchNoop;

    fn persistExposureBatchImpl(self: *Storage, rows: []const ExposureRow) void {
        if (self.backend != .postgres) return;
        if (self.pg) |*backend| {
            for (rows) |row| {
                const sql = std.fmt.allocPrintSentinel(
                    self.allocator,
                    "INSERT INTO exposures (workspace_id, environment_id, flag_key, unit_id, enabled, variation, bucket, reason, occurred_at, received_at, idempotency_key) " ++
                        "VALUES ('{s}', '{s}', '{s}', '{s}', {s}, {s}, {d}, '{s}', {d}, {d}, '{s}') " ++
                        "ON CONFLICT (workspace_id, environment_id, idempotency_key) DO NOTHING",
                    .{
                        row.workspace_id,
                        row.environment_id,
                        row.flag_key,
                        row.unit_id,
                        if (row.enabled) "TRUE" else "FALSE",
                        if (row.variation) |v| v else "NULL",
                        row.bucket,
                        row.reason,
                        row.occurred_at,
                        row.received_at,
                        row.idempotency_key orelse "",
                    },
                    0,
                ) catch return;
                defer self.allocator.free(sql);
                backend.exec(sql) catch {};
            }
        }
    }

    fn persistExposureBatchNoop(_: *Storage, _: []const ExposureRow) void {}

    /// Delete exposures older than `max_age_ms` from the oldest side. Returns
    /// the number of rows removed.
    pub fn retentionSweep(self: *Storage, now_ms: i64, max_age_ms: i64) !usize {
        const db = self.db orelse return error.NoDatabase;
        var stmt: ?*c.sqlite3_stmt = undefined;
        const rc = c.sqlite3_prepare_v2(db, "DELETE FROM exposures WHERE occurred_at < ?", -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try self.bindInt64(self, stmt, 1, now_ms - max_age_ms);
        const rc2 = c.sqlite3_step(stmt);
        if (rc2 != c.SQLITE_DONE) return error.SqliteStepFailed;
        const changes: c_int = c.sqlite3_changes(db);
        return @intCast(changes);
    }

    pub fn deinit(self: *Storage) void {
        var fit = self.flags.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.flags.deinit();
        var sit = self.segments.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.value_ptr.expression);
            self.allocator.free(entry.key_ptr.*);
        }
        self.segments.deinit();
        self.environments.deinit(self.allocator);
        for (self.audit_events.items) |evt| {
            self.allocator.free(evt.id);
            if (evt.signature) |s| self.allocator.free(s);
        }
        self.audit_events.deinit(self.allocator);
        if (comptime build_options.enable_postgres) {
            if (self.pg) |*p| p.deinit();
        }
    }

    pub fn putFlag(self: *Storage, key: []const u8, record: FlagRecord, actor: []const u8) !void {
        const gop = try self.flags.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.* = applyVersion(gop.value_ptr.*, record, null, 0);
        } else {
            const owned = try self.allocator.dupe(u8, key);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = applyVersion(null, record, owned, 0);
        }
        self.persistFlag(gop.value_ptr.*);
        self.persistFlagVersion(gop.value_ptr.*, actor);
        try self.recordAudit("FLAG_UPDATE", "flag", key, actor);
    }

    /// Mirror a flag version row into Postgres when that backend is active.
    const persistFlagVersion = if (build_options.enable_postgres) persistFlagVersionImpl else persistFlagVersionNoop;

    fn persistFlagVersionImpl(self: *Storage, rec: FlagRecord, actor: []const u8) void {
        if (self.backend != .postgres) return;
        if (self.pg) |*backend| {
            const sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "INSERT INTO flag_versions (id, flag_id, version, definition_json, created_at, created_by) " ++
                    "VALUES ('{s}_v{d}', '{s}', {d}, '{{\"key\":\"{s}\",\"enabled\":{s},\"rollout_percentage\":{d}}}', {d}, '{s}')",
                .{
                    rec.key,
                    rec.version,
                    rec.key,
                    rec.version,
                    rec.key,
                    if (rec.enabled) "true" else "false",
                    rec.rollout_percentage,
                    rec.updated_at,
                    actor,
                },
                0,
            ) catch return;
            defer self.allocator.free(sql);
            backend.exec(sql) catch {};
        }
    }

    fn persistFlagVersionNoop(_: *Storage, _: FlagRecord, _: []const u8) void {}

    /// Free the owned strings inside edges produced by flagDependencies.
    pub fn freeDependencyEdges(self: *const Storage, edges: []const DependencyEdge) void {
        for (edges) |edge| {
            self.allocator.free(edge.from_key);
            self.allocator.free(edge.variation_key);
        }
    }

    /// Same as putFlag, but stamps created/updated timestamps so staleness and
    /// the flag history view have real dates to work with.
    pub fn putFlagVersioned(self: *Storage, key: []const u8, record: FlagRecord, actor: []const u8, now_ms: i64) !void {
        const gop = try self.flags.getOrPut(key);
        if (gop.found_existing) {
            gop.value_ptr.* = applyVersion(gop.value_ptr.*, record, null, now_ms);
        } else {
            const owned = try self.allocator.dupe(u8, key);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = applyVersion(null, record, owned, now_ms);
        }
        self.persistFlag(gop.value_ptr.*);
        self.persistFlagVersion(gop.value_ptr.*, actor);
        try self.recordAudit("FLAG_UPDATE", "flag", key, actor);
    }

    /// Merge an incoming record into the stored one, reusing the existing
    /// owned key so a replace never orphans the previous allocation.
    fn applyVersion(existing: ?FlagRecord, incoming: FlagRecord, owned_key: ?[]const u8, now_ms: i64) FlagRecord {
        var rec = incoming;
        rec.key = owned_key orelse existing.?.key;
        if (now_ms > 0) {
            rec.updated_at = now_ms;
            rec.created_at = if (existing) |prev| (if (prev.created_at > 0) prev.created_at else now_ms) else now_ms;
        } else if (existing) |prev| {
            rec.created_at = prev.created_at;
            rec.updated_at = prev.updated_at;
        }
        if (rec.version == 0) rec.version = if (existing) |prev| prev.version + 1 else 1;
        return rec;
    }

    /// Flags live for more than `max_age_ms` since their last update, oldest
    /// first. Feeds the lifecycle automation described in the architecture doc.
    pub fn staleFlags(self: *Storage, now_ms: i64, max_age_ms: i64, out: *std.ArrayList(FlagRecord)) !void {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            const age = now_ms - entry.value_ptr.updated_at;
            if (age > max_age_ms) try out.append(self.allocator, entry.value_ptr.*);
        }
        std.mem.sort(FlagRecord, out.items, {}, struct {
            fn lessThan(_: void, a: FlagRecord, b: FlagRecord) bool {
                return a.updated_at < b.updated_at;
            }
        }.lessThan);
    }

    /// Flags sitting at a 100 percent rollout, which the architecture doc
    /// treats as a removal candidate.
    pub fn fullRolloutFlags(self: *Storage, out: *std.ArrayList(FlagRecord)) !void {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            if (entry.value_ptr.rollout_percentage >= 100) try out.append(self.allocator, entry.value_ptr.*);
        }
    }

    pub fn listFlags(self: *const Storage, out: *std.ArrayList(FlagRecord)) !void {
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            try out.append(self.allocator, entry.value_ptr.*);
        }
        std.mem.sort(FlagRecord, out.items, {}, struct {
            fn lessThan(_: void, a: FlagRecord, b: FlagRecord) bool {
                return std.mem.order(u8, a.key, b.key) == .lt;
            }
        }.lessThan);
    }

    /// Dependency edges derived by static analysis: prerequisites declared by
    /// the flag, plus every segment whose key appears in one of its targeting
    /// rules. Referencing segments by key is how rules compose with segments.
    pub fn flagDependencies(
        self: *const Storage,
        flag_key: []const u8,
        out: *std.ArrayList(DependencyEdge),
        seg_out: *std.ArrayList([]const u8),
    ) !void {
        // Prerequisites.
        if (self.flags.get(flag_key)) |flag| {
            if (flag.prerequisites_json) |pj| {
                const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, pj, .{}) catch return;
                defer parsed.deinit();
                if (parsed.value == .array) {
                    for (parsed.value.array.items) |item| {
                        if (item != .object) continue;
                        const dep = item.object.get("flagKey") orelse continue;
                        const variation = item.object.get("variationKey") orelse continue;
                        if (dep != .string or variation != .string) continue;
                        const from_owned = try self.allocator.dupe(u8, dep.string);
                        const variation_owned = try self.allocator.dupe(u8, variation.string);
                        try out.append(self.allocator, .{
                            .from_key = from_owned,
                            .to_key = flag_key,
                            .variation_key = variation_owned,
                        });
                    }
                }
            }
        }

        // Segments referenced from targeting rules.
        var seg_it = self.segments.iterator();
        while (seg_it.next()) |seg_entry| {
            const reference_found = blk: {
                if (self.flags.get(flag_key)) |flag| {
                    if (flag.rules_json) |rj| {
                        if (std.mem.indexOf(u8, rj, seg_entry.key_ptr.*) != null) break :blk true;
                    }
                    if (flag.prerequisites_json) |pj| {
                        if (std.mem.indexOf(u8, pj, seg_entry.key_ptr.*) != null) break :blk true;
                    }
                }
                break :blk false;
            };
            if (reference_found) try seg_out.append(self.allocator, seg_entry.key_ptr.*);
        }
    }

    /// Every flag that depends on `flag_key`, directly or transitively. Used
    /// for the dependency graph and the blast-radius boundary.
    pub fn dependentsOf(self: *const Storage, flag_key: []const u8) !std.ArrayList([]const u8) {
        var out: std.ArrayList([]const u8) = .empty;
        var visited = std.StringHashMap(void).init(self.allocator);
        defer visited.deinit();

        var frontier: std.ArrayList([]const u8) = .empty;
        defer frontier.deinit(self.allocator);
        try frontier.append(self.allocator, flag_key);

        while (frontier.items.len > 0) {
            const current = frontier.orderedRemove(0);
            var it = self.flags.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.deleted) continue;
                if (std.mem.eql(u8, entry.key_ptr.*, current)) continue;

                var edges: std.ArrayList(DependencyEdge) = .empty;
                defer edges.deinit(self.allocator);
                var segs: std.ArrayList([]const u8) = .empty;
                defer segs.deinit(self.allocator);
                try self.flagDependencies(entry.key_ptr.*, &edges, &segs);

                for (edges.items) |edge| {
                    if (std.mem.eql(u8, edge.from_key, current)) {
                        if (!visited.contains(entry.key_ptr.*)) {
                            try visited.put(entry.key_ptr.*, {});
                            try out.append(self.allocator, entry.key_ptr.*);
                            try frontier.append(self.allocator, entry.key_ptr.*);
                        }
                        break;
                    }
                }
                self.freeDependencyEdges(edges.items);
            }
        }
        return out;
    }

    pub fn getFlag(self: *const Storage, key: []const u8) ?FlagRecord {
        const item = self.flags.get(key) orelse return null;
        if (item.deleted) return null;
        return item;
    }

    pub fn deleteFlag(self: *Storage, key: []const u8, actor: []const u8) !bool {
        if (self.flags.getPtr(key)) |ptr| {
            ptr.deleted = true;
            ptr.version += 1;
            try self.recordAudit("FLAG_DELETE", "flag", key, actor);
            return true;
        }
        return false;
    }

    pub fn putSegment(self: *Storage, key: []const u8, expression: []const u8, actor: []const u8) !void {
        const expr_owned = try self.allocator.dupe(u8, expression);
        errdefer self.allocator.free(expr_owned);

        const gop = try self.segments.getOrPut(key);
        if (gop.found_existing) {
            // Keep the existing owned key, replace the expression copy.
            self.allocator.free(gop.value_ptr.expression);
            gop.value_ptr.* = .{ .key = gop.key_ptr.*, .expression = expr_owned };
        } else {
            const owned = try self.allocator.dupe(u8, key);
            gop.key_ptr.* = owned;
            gop.value_ptr.* = .{ .key = owned, .expression = expr_owned };
        }
        self.persistSegment(key, expression);
        try self.recordAudit("SEGMENT_CREATE", "segment", key, actor);
    }

    /// Mirror a segment row into Postgres when that backend is active.
    const persistSegment = if (build_options.enable_postgres) persistSegmentImpl else persistSegmentNoop;

    fn persistSegmentImpl(self: *Storage, key: []const u8, expression: []const u8) void {
        if (self.backend != .postgres) return;
        if (self.pg) |*backend| {
            const sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "INSERT INTO segments (id, workspace_id, key, expression, created_at) VALUES ('{s}', 'default', '{s}', '{s}', 0) " ++
                    "ON CONFLICT (workspace_id, key) DO UPDATE SET expression = EXCLUDED.expression",
                .{ key, key, expression },
                0,
            ) catch return;
            defer self.allocator.free(sql);
            backend.exec(sql) catch {};
        }
    }

    fn persistSegmentNoop(_: *Storage, _: []const u8, _: []const u8) void {}

    /// Remove a segment and release the copies the store owns. Returns false
    /// when the key was not present.
    pub fn removeSegment(self: *Storage, key: []const u8) bool {
        const entry = self.segments.fetchRemove(key) orelse return false;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value.expression);
        return true;
    }

    pub fn recordAudit(self: *Storage, action: []const u8, target_type: []const u8, target_id: []const u8, actor: []const u8) !void {
        const id = try std.fmt.allocPrint(self.allocator, "evt_{d}", .{self.audit_events.items.len + 1});
        errdefer self.allocator.free(id);

        const prev_hash: [32]u8 = if (self.audit_events.items.len > 0)
            self.audit_events.items[self.audit_events.items.len - 1].hash
        else
            @as([32]u8, @splat(0));
        const timestamp = @as(i64, @intCast(self.audit_events.items.len + 1));
        const hash = try computeAuditHash(self.allocator, prev_hash, id, action, target_type, target_id, actor, timestamp);

        // Sigstore-style: sign the record hash via the Sigstore backend.
        const mac = sigstore.SigstoreSigner.sign(&hash);
        const sig = try self.allocator.dupe(u8, &mac);

        try self.audit_events.append(self.allocator, .{
            .id = id,
            .action = action,
            .target_type = target_type,
            .target_id = target_id,
            .actor = actor,
            .timestamp = timestamp,
            .hash = hash,
            .prev_hash = prev_hash,
            .signature = sig,
        });
        self.persistAudit(id, action, target_type, target_id, actor, timestamp);
    }

    /// Mirror an audit event into Postgres when that backend is active.
    const persistAudit = if (build_options.enable_postgres) persistAuditImpl else persistAuditNoop;

    fn persistAuditImpl(
        self: *Storage,
        id: []const u8,
        action: []const u8,
        target_type: []const u8,
        target_id: []const u8,
        actor: []const u8,
        timestamp: i64,
    ) void {
        if (self.backend != .postgres) return;
        if (self.pg) |*backend| {
            const sql = std.fmt.allocPrintSentinel(
                self.allocator,
                "INSERT INTO audit_events (id, workspace_id, action, target_type, target_id, actor, timestamp) " ++
                    "VALUES ('{s}', 'default', '{s}', '{s}', '{s}', '{s}', {d})",
                .{ id, action, target_type, target_id, actor, timestamp },
                0,
            ) catch return;
            defer self.allocator.free(sql);
            backend.exec(sql) catch {};
        }
    }

    fn persistAuditNoop(_: *Storage, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: i64) void {}

    /// Deterministic hash chain link. Recomputed by verifyAuditChain to detect
    /// tampering with any past record.
    fn computeAuditHash(
        allocator: std.mem.Allocator,
        prev_hash: [32]u8,
        id: []const u8,
        action: []const u8,
        target_type: []const u8,
        target_id: []const u8,
        actor: []const u8,
        timestamp: i64,
    ) ![32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&prev_hash);
        hasher.update(id);
        hasher.update("\x1f");
        hasher.update(action);
        hasher.update("\x1f");
        hasher.update(target_type);
        hasher.update("\x1f");
        hasher.update(target_id);
        hasher.update("\x1f");
        hasher.update(actor);
        hasher.update("\x1f");
        var ts_buf: [24]u8 = undefined;
        const ts_text = std.fmt.bufPrint(&ts_buf, "{d}", .{timestamp}) catch "0";
        hasher.update(ts_text);
        _ = allocator;
        var out: [32]u8 = undefined;
        hasher.final(&out);
        return out;
    }

    pub const AuditVerification = struct {
        ok: bool,
        checked: usize,
        first_broken_id: ?[]const u8,
        head_hash: [32]u8,
    };

    /// Recompute the whole chain and report the first record that no longer
    /// matches its stored link.
    pub fn verifyAuditChain(self: *const Storage) AuditVerification {
        var prev_hash = @as([32]u8, @splat(0));
        for (self.audit_events.items) |evt| {
            const expected = computeAuditHash(
                self.allocator,
                prev_hash,
                evt.id,
                evt.action,
                evt.target_type,
                evt.target_id,
                evt.actor,
                evt.timestamp,
            ) catch {
                return .{ .ok = false, .checked = 0, .first_broken_id = evt.id, .head_hash = prev_hash };
            };
            if (!std.mem.eql(u8, &expected, &evt.hash)) {
                return .{ .ok = false, .checked = 0, .first_broken_id = evt.id, .head_hash = prev_hash };
            }
            // Verify Sigstore signature when present.
            if (evt.signature) |sigbytes| {
                if (sigbytes.len == 32) {
                    var sigarr: [32]u8 = undefined;
                    @memcpy(&sigarr, sigbytes[0..32]);
                    if (!sigstore.SigstoreSigner.verify(&evt.hash, sigarr)) {
                        return .{ .ok = false, .checked = 0, .first_broken_id = evt.id, .head_hash = prev_hash };
                    }
                }
            }
            prev_hash = evt.hash;
        }
        return .{
            .ok = true,
            .checked = self.audit_events.items.len,
            .first_broken_id = null,
            .head_hash = prev_hash,
        };
    }

    pub const AuditFilter = struct {
        query: []const u8 = "",
        action: []const u8 = "",
        actor: []const u8 = "",
    };

    /// Append the audit events matching the filter, newest first, into the
    /// caller's list. Case-insensitive substring match on the query.
    pub fn searchAudit(self: *const Storage, filter: AuditFilter, out: *std.ArrayList(AuditRecord)) !void {
        var i = self.audit_events.items.len;
        while (i > 0) {
            i -= 1;
            const evt = self.audit_events.items[i];
            if (filter.query.len > 0) {
                if (!containsIgnoreCase(evt.action, filter.query) and
                    !containsIgnoreCase(evt.target_id, filter.query) and
                    !containsIgnoreCase(evt.actor, filter.query) and
                    !containsIgnoreCase(evt.id, filter.query))
                {
                    continue;
                }
            }
            if (filter.action.len > 0 and !std.mem.eql(u8, evt.action, filter.action)) continue;
            if (filter.actor.len > 0 and !std.mem.eql(u8, evt.actor, filter.actor)) continue;
            try out.append(self.allocator, evt);
        }
    }

    /// Render matching audit events as CSV (RFC 4180 quoting).
    pub fn exportAuditCsv(self: *const Storage, allocator: std.mem.Allocator, filter: AuditFilter) ![]const u8 {
        var matches: std.ArrayList(AuditRecord) = .empty;
        defer matches.deinit(self.allocator);
        try self.searchAudit(filter, &matches);

        var alloc: std.Io.Writer.Allocating = .init(allocator);
        const out: *std.Io.Writer = &alloc.writer;
        try out.writeAll("id,action,target_type,target_id,actor,timestamp,hash\n");
        for (matches.items) |evt| {
            try csvField(out, evt.id);
            try out.writeByte(',');
            try csvField(out, evt.action);
            try out.writeByte(',');
            try csvField(out, evt.target_type);
            try out.writeByte(',');
            try csvField(out, evt.target_id);
            try out.writeByte(',');
            try csvField(out, evt.actor);
            try out.writeByte(',');
            try out.print("{d}", .{evt.timestamp});
            try out.writeByte(',');
            var hex_buf: [64]u8 = undefined;
            try out.writeAll(hexEncode(&evt.hash, &hex_buf));
            try out.writeByte('\n');
        }

        var list = alloc.toArrayList();
        return list.toOwnedSlice(allocator);
    }

    /// Lowercase hex of a digest, written into a caller-provided buffer.
    fn hexEncode(bytes: []const u8, out: []u8) []const u8 {
        const digits = "0123456789abcdef";
        for (bytes, 0..) |byte, i| {
            out[i * 2] = digits[byte >> 4];
            out[i * 2 + 1] = digits[byte & 0x0f];
        }
        return out[0 .. bytes.len * 2];
    }

    /// Quote one CSV field per RFC 4180 when it contains a separator, a quote,
    /// or a newline.
    fn csvField(out: *std.Io.Writer, value: []const u8) !void {
        const needs_quotes = std.mem.indexOfScalar(u8, value, ',') != null or
            std.mem.indexOfScalar(u8, value, '"') != null or
            std.mem.indexOfAny(u8, value, "\r\n") != null;
        if (!needs_quotes) {
            try out.writeAll(value);
            return;
        }
        try out.writeByte('"');
        for (value) |ch| {
            if (ch == '"') try out.writeByte('"');
            try out.writeByte(ch);
        }
        try out.writeByte('"');
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var same = true;
            for (needle, 0..) |n, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(n)) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }

    pub fn toConfig(self: *const Storage, allocator: std.mem.Allocator, environment: []const u8) !doppio.Config {
        var flag_list: std.ArrayList(doppio.Flag) = .empty;
        var it = self.flags.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.deleted) {
                try flag_list.append(allocator, .{
                    .key = entry.value_ptr.key,
                    .enabled = entry.value_ptr.enabled,
                    .rollout_percentage = entry.value_ptr.rollout_percentage,
                });
            }
        }

        var seg_list: std.ArrayList(doppio.Segment) = .empty;
        var seg_it = self.segments.iterator();
        while (seg_it.next()) |entry| {
            try seg_list.append(allocator, .{
                .key = entry.value_ptr.key,
                .expression = entry.value_ptr.expression,
            });
        }

        return .{
            .environment = environment,
            .version = 1,
            .flags = try flag_list.toOwnedSlice(allocator),
            .segments = try seg_list.toOwnedSlice(allocator),
        };
    }
};

pub fn generateLitestreamConfig(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    s3_bucket: []const u8,
    s3_endpoint: []const u8,
    s3_region: []const u8,
) ![]const u8 {
    const config = try std.fmt.allocPrint(
        allocator,
        "dbs:\n  - path: {s}\n    replicas:\n      - type: s3\n        bucket: {s}\n        path: db\n        endpoint: {s}\n        region: {s}\n        sync-interval: 1s\n",
        .{ db_path, s3_bucket, s3_endpoint, s3_region },
    );
    return try allocator.dupe(u8, config);
}

test "storage CRUD and audit tracking" {
    var store = Storage.init(std.testing.allocator);
    defer store.deinit();

    try store.putFlag("flag-alpha", .{
        .key = "flag-alpha",
        .enabled = true,
        .rollout_percentage = 50,
    }, "admin@doppio.local");

    const item = store.getFlag("flag-alpha");
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("flag-alpha", item.?.key);
    try std.testing.expect(item.?.enabled);

    try std.testing.expectEqual(@as(usize, 1), store.audit_events.items.len);
    try std.testing.expectEqualStrings("FLAG_UPDATE", store.audit_events.items[0].action);

    const deleted = try store.deleteFlag("flag-alpha", "admin@doppio.local");
    try std.testing.expect(deleted);
    try std.testing.expect(store.getFlag("flag-alpha") == null);
    try std.testing.expectEqual(@as(usize, 2), store.audit_events.items.len);
}

test "storage defaults to sqlite and can select postgres" {
    var store = Storage.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(BackendKind.sqlite, store.backend);
    store.selectBackend(.postgres);
    try std.testing.expectEqual(BackendKind.postgres, store.backend);
}

test "openPostgres reports disabled unless built with -Dpostgres" {
    if (build_options.enable_postgres) return;
    var store = Storage.init(std.testing.allocator);
    defer store.deinit();
    try std.testing.expectError(error.PostgresNotEnabled, store.openPostgres("host=localhost"));
}
