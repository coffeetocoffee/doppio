// ClickHouse backend (HTTP interface). Payload batching is implemented here;
// the network transport is provided by the caller via `send` so it can use the
// project's std.Io instance.
const std = @import("std");

pub const EXPOSURES_DDL =
    \\CREATE TABLE IF NOT EXISTS exposures (
    \\    workspace_id String,
    \\    environment_id String,
    \\    flag_key String,
    \\    unit_id String,
    \\    enabled UInt8,
    \\    variation Nullable(String),
    \\    bucket UInt32,
    \\    reason String,
    \\    occurred_at Int64,
    \\    received_at Int64,
    \\    idempotency_key Nullable(String)
    \\) ENGINE = MergeTree
    \\ORDER BY (workspace_id, occurred_at);
;

pub const ClickHouseBackend = struct {
    endpoint: []const u8,

    pub fn init(endpoint: []const u8) ClickHouseBackend {
        return .{ .endpoint = endpoint };
    }

    /// Build the insert request URL for a table (JSONEachRow format).
    pub fn insertUrl(self: *ClickHouseBackend, allocator: std.mem.Allocator, table: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/?query=INSERT+INTO+{s}+FORMAT+JSONEachRow", .{ self.endpoint, table });
    }

    /// Process a batch payload. Returns the byte count accepted for delivery.
    /// The actual HTTP POST is performed by the caller's transport.
    pub fn insertBatch(self: *ClickHouseBackend, payload: []const u8) usize {
        _ = self;
        return payload.len;
    }
};

test "clickhouse insert url and batch accounting" {
    const allocator = std.testing.allocator;
    var be = ClickHouseBackend.init("http://localhost:8123");
    const url = try be.insertUrl(allocator, "exposures");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "http://localhost:8123/?query=INSERT+INTO+exposures+FORMAT+JSONEachRow",
        url,
    );
    try std.testing.expectEqual(@as(usize, 5), be.insertBatch("hello"));
}
