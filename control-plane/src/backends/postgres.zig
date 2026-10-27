// Postgres backend (extern declarations for libpq). Scaffold only.
const std = @import("std");

// libpq externs
extern "c" fn PQconnectdb(conninfo: [*:0]const u8) callconv(.c) ?*anyopaque;
extern "c" fn PQstatus(conn: ?*anyopaque) callconv(.c) c_int;
extern "c" fn PQexec(conn: ?*anyopaque, query: [*:0]const u8) callconv(.c) ?*anyopaque;
extern "c" fn PQexecParams(conn: ?*anyopaque, command: [*:0]const u8, nParams: c_int, paramTypes: ?*anyopaque, paramValues: ?[*]?[*]const u8, paramLengths: ?[*]c_int, paramFormats: ?[*]c_int, resultFormat: c_int) callconv(.c) ?*anyopaque;
extern "c" fn PQclear(res: ?*anyopaque) callconv(.c) void;
extern "c" fn PQfinish(conn: ?*anyopaque) callconv(.c) void;
extern "c" fn PQresultStatus(res: ?*anyopaque) callconv(.c) c_int;
extern "c" fn PQerrorMessage(conn: ?*anyopaque) callconv(.c) [*:0]const u8;

pub const PG_CONN_OK: c_int = 0;
pub const PGRES_COMMAND_OK: c_int = 1;
pub const PGRES_TUPLES_OK: c_int = 2;

/// Postgres-flavored schema (JSONB, SERIAL, TIMESTAMPTZ-free integer epochs).
pub const PG_SCHEMA_DDL =
    \\CREATE TABLE IF NOT EXISTS organizations (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    created_at BIGINT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS workspaces (
    \\    id TEXT PRIMARY KEY,
    \\    org_id TEXT NOT NULL REFERENCES organizations(id),
    \\    name TEXT NOT NULL,
    \\    created_at BIGINT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS environments (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL REFERENCES workspaces(id),
    \\    name TEXT NOT NULL,
    \\    order_index BIGINT NOT NULL,
    \\    created_at BIGINT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS flags (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT NOT NULL,
    \\    key TEXT NOT NULL,
    \\    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    \\    rollout_percentage INTEGER NOT NULL DEFAULT 100,
    \\    flag_type TEXT NOT NULL DEFAULT 'boolean',
    \\    default_variation INTEGER NOT NULL DEFAULT 0,
    \\    variations_json JSONB,
    \\    rules_json JSONB,
    \\    prerequisites_json JSONB,
    \\    version BIGINT NOT NULL DEFAULT 1,
    \\    deleted_at BIGINT,
    \\    created_at BIGINT NOT NULL,
    \\    updated_at BIGINT NOT NULL,
    \\    UNIQUE(workspace_id, environment_id, key)
    \\);
    \\CREATE TABLE IF NOT EXISTS flag_versions (
    \\    id TEXT PRIMARY KEY,
    \\    flag_id TEXT NOT NULL REFERENCES flags(id),
    \\    version BIGINT NOT NULL,
    \\    definition_json JSONB NOT NULL,
    \\    created_at BIGINT NOT NULL,
    \\    created_by TEXT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS segments (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    key TEXT NOT NULL,
    \\    expression TEXT NOT NULL,
    \\    created_at BIGINT NOT NULL,
    \\    UNIQUE(workspace_id, key)
    \\);
    \\CREATE TABLE IF NOT EXISTS audit_events (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    action TEXT NOT NULL,
    \\    target_type TEXT NOT NULL,
    \\    target_id TEXT NOT NULL,
    \\    actor TEXT NOT NULL,
    \\    payload_json JSONB,
    \\    signature TEXT,
    \\    timestamp BIGINT NOT NULL
    \\);
    \\CREATE TABLE IF NOT EXISTS api_keys (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    key_hash TEXT NOT NULL,
    \\    scope TEXT NOT NULL,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT,
    \\    created_at BIGINT NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_flags_key ON flags(workspace_id, environment_id, key);
    \\CREATE INDEX IF NOT EXISTS idx_audit_time ON audit_events(workspace_id, timestamp);
    \\CREATE TABLE IF NOT EXISTS exposures (
    \\    id TEXT PRIMARY KEY,
    \\    workspace_id TEXT NOT NULL,
    \\    environment_id TEXT NOT NULL,
    \\    flag_key TEXT NOT NULL,
    \\    unit_id TEXT NOT NULL,
    \\    enabled BOOLEAN NOT NULL,
    \\    variation TEXT,
    \\    bucket INTEGER NOT NULL,
    \\    reason TEXT NOT NULL,
    \\    occurred_at BIGINT NOT NULL,
    \\    received_at BIGINT NOT NULL,
    \\    idempotency_key TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_exposures_dedupe ON exposures(workspace_id, environment_id, idempotency_key) WHERE idempotency_key <> '';
;
pub const PostgresBackend = struct {
    conn: ?*anyopaque = null,

    pub fn connect(self: *PostgresBackend, conninfo: [:0]const u8) !void {
        self.conn = PQconnectdb(conninfo.ptr);
        if (self.conn == null or PQstatus(self.conn) != PG_CONN_OK) {
            if (self.conn) |c| PQfinish(c);
            self.conn = null;
            return error.PostgresConnectFailed;
        }
    }

    pub fn exec(self: *PostgresBackend, sql: [:0]const u8) !void {
        if (self.conn) |conn| {
            const res = PQexec(conn, sql.ptr);
            if (res) |r| {
                const status = PQresultStatus(r);
                if (status != PGRES_COMMAND_OK and status != PGRES_TUPLES_OK) {
                    PQclear(r);
                    return error.PostgresExecFailed;
                }
                PQclear(r);
            } else {
                return error.PostgresExecFailed;
            }
        } else {
            return error.PostgresNotConnected;
        }
    }

    pub fn errorMessage(self: *PostgresBackend) []const u8 {
        if (self.conn) |c| {
            return std.mem.span(PQerrorMessage(c));
        }
        return "not connected";
    }

    pub fn query(self: *PostgresBackend, sql: [:0]const u8) ?*anyopaque {
        if (self.conn) |c| {
            const res = PQexec(c, sql.ptr);
            if (res) |r| {
                if (PQresultStatus(r) == PGRES_TUPLES_OK or PQresultStatus(r) == PGRES_COMMAND_OK) {
                    return r;
                }
                PQclear(r);
            }
        }
        return null;
    }

    pub fn initSchema(self: *PostgresBackend) void {
        self.exec(PG_SCHEMA_DDL) catch {};
    }

    pub fn deinit(self: *PostgresBackend) void {
        if (self.conn) |c| PQfinish(c);
        self.conn = null;
    }
};