const std = @import("std");
const doppio = @import("doppio");
const storage = @import("storage.zig");
const clickhouse = @import("backends/clickhouse.zig");
const build_options = @import("build_options");
const valkey = if (build_options.enable_valkey) @import("backends/valkey.zig") else struct {};
const ValkeyBackend = if (build_options.enable_valkey) valkey.ValkeyBackend else void;
const admin = @import("admin.zig");
const experiment = @import("experiment.zig");

const Io = std.Io;

pub const MessageType = enum {
    hello,
    snapshot,
    delta,
    ack,
    heartbeat,
    exposure,
};

pub const DeltaItem = struct {
    key: []const u8,
    deleted: bool,
    enabled: bool,
    rollout_percentage: u8,
    seq: u64,
};

pub const ExposureMessage = struct {
    flag_key: []const u8,
    unit_id: []const u8,
    enabled: bool,
    variation: ?[]const u8 = null,
    bucket: u32,
    timestamp: i64,
    reason: []const u8,
    idempotency_key: ?[]const u8 = null,
};

/// A parsed exposure submission handed to noteExposures.
pub const ExposureInput = struct {
    flag_key: []const u8,
    unit_id: []const u8,
    enabled: bool,
    variation: ?[]const u8 = null,
    bucket: u32,
    timestamp: i64,
    reason: []const u8,
    idempotency_key: []const u8,
};

/// Result of building a delta (or a full snapshot when the client is stale).
pub const DeltaResult = struct {
    json: []const u8,
    snapshot_required: bool,
    seq: u64,
};

/// Outcome of a single waitForSeqPast call.
pub const WaitResult = struct {
    delta: ?DeltaResult, // non-null when new changes arrived
    timeout: bool, // true when the timeout elapsed with no change
};

pub const FlushResult = struct {
    /// Records still queued after the trim.
    retained: usize,
    /// Records dropped by this flush.
    flushed: usize,
    batch_id: []const u8, // owned; caller frees
};

const history_max = 100;
const max_exposures = 100000;

/// Thread-safe sync hub. Owns the flag store plus the change history and the
/// exposure queue shared by HTTP (SSE, long-poll), WebSocket, and /collect.
/// One frame waiting to be written to a WebSocket client.
pub const OutboundFrame = struct {
    kind: Kind,
    payload: []const u8 = "",

    pub const Kind = enum { text, pong, close };
};

/// Outbound queue for one WebSocket client. The connection's writer thread is
/// the only thread that touches the socket, so every other producer pushes
/// frames here instead of writing directly.
pub const ConnHandle = struct {
    allocator: std.mem.Allocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    queue: std.ArrayList(OutboundFrame),
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) ConnHandle {
        return .{ .allocator = allocator, .queue = .empty };
    }

    pub fn deinit(self: *ConnHandle) void {
        for (self.queue.items) |frame| self.allocator.free(frame.payload);
        self.queue.deinit(self.allocator);
    }

    /// Enqueue one frame, copying it so the caller owns its buffer. Locking
    /// order is always hub mutex then this mutex, never the reverse.
    pub fn push(self: *ConnHandle, io: Io, frame: OutboundFrame) !void {
        try self.mutex.lock(io);
        const owned = try self.allocator.dupe(u8, frame.payload);
        errdefer self.allocator.free(owned);
        try self.queue.append(self.allocator, .{ .kind = frame.kind, .payload = owned });
        if (self.queue.items.len == 1) self.cond.signal(io);
        self.mutex.unlock(io);
    }

    /// Enqueue a text frame. Convenience for the common case.
    pub fn pushText(self: *ConnHandle, io: Io, text: []const u8) !void {
        return self.push(io, .{ .kind = .text, .payload = text });
    }

    /// Block until a frame is available, returning null once closed and
    /// drained. The returned frame's payload is owned by the caller.
    pub fn pop(self: *ConnHandle, io: Io) !?OutboundFrame {
        try self.mutex.lock(io);
        while (self.queue.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            try self.cond.wait(io, &self.mutex);
        }
        const frame = self.queue.orderedRemove(0);
        self.mutex.unlock(io);
        return frame;
    }

    pub fn close(self: *ConnHandle, io: Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.cond.broadcast(io);
        self.mutex.unlock(io);
    }

    pub fn isClosed(self: *ConnHandle, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.closed;
    }
};

pub const SyncHub = struct {
    allocator: std.mem.Allocator,
    store: storage.Storage,
    mutex: Io.Mutex = .init,
    /// Guards only the exposure queue and its dedupe map. Telemetry writes must
    /// never take the hub mutex, or ingest volume would stall configuration
    /// delivery (D17).
    exposure_mutex: Io.Mutex = .init,
    generation: std.atomic.Value(u32) = .init(0),
    current_seq: u64 = 1,
    history_start_seq: u64 = 1,
    history: std.ArrayList(DeltaItem),
    exposures: std.ArrayList(ExposureMessage),
    idempotency_seen: std.StringHashMap(void),
    flushed_batches: std.ArrayList([]const u8),
    change_requests: admin.ChangeQueue,
    experiments: experiment.ExperimentRegistry,
    /// WebSocket clients, guarded by the hub mutex.
    connections: std.ArrayList(*ConnHandle),
    /// Optional ClickHouse backend for analytics/ exposure ingestion.
    clickhouse: ?clickhouse.ClickHouseBackend = null,
    /// Optional Valkey backend for multi-node pub/sub fan-out (only present
    /// when built with -Dvalkey, since it links libhiredis).
    valkey_backend: ?ValkeyBackend = null,

    pub fn init(allocator: std.mem.Allocator) SyncHub {
        return .{
            .allocator = allocator,
            .store = storage.Storage.init(allocator),
            .history = .empty,
            .exposures = .empty,
            .idempotency_seen = std.StringHashMap(void).init(allocator),
            .flushed_batches = .empty,
            .change_requests = .{ .allocator = allocator, .items = .empty },
            .experiments = experiment.ExperimentRegistry.init(allocator),
            .connections = .empty,
        };
    }

    pub fn initWith(allocator: std.mem.Allocator, db_path: []const u8) !SyncHub {
        var hub = try SyncHub.init(allocator);
        try hub.store.open(allocator, db_path);
        return hub;
    }

    /// Enable ClickHouse exposure forwarding for this hub.
    pub fn enableClickHouse(self: *SyncHub, endpoint: []const u8) !void {
        const owned = try self.allocator.dupe(u8, endpoint);
        self.clickhouse = clickhouse.ClickHouseBackend.init(owned);
    }

    /// Enable Valkey pub/sub fan-out. No-op unless built with -Dvalkey.
    pub const enableValkey = if (build_options.enable_valkey) enableValkeyImpl else enableValkeyNoop;

    fn enableValkeyImpl(self: *SyncHub, host: []const u8, port: c_int) !void {
        const owned = try std.fmt.allocPrintSentinel(self.allocator, "{s}", .{host}, 0);
        defer self.allocator.free(owned);
        var backend: ValkeyBackend = .{};
        try backend.connect(owned, port);
        self.valkey_backend = backend;
    }

    fn enableValkeyNoop(_: *SyncHub, _: []const u8, _: c_int) !void {}

    const publishValkey = if (build_options.enable_valkey) publishValkeyImpl else publishValkeyNoop;

    fn publishValkeyImpl(self: *SyncHub, seq: u64, key: []const u8, deleted: bool, enabled: bool, rollout: u8) void {
        if (self.valkey_backend) |*v| {
            const msg = std.fmt.allocPrintSentinel(self.allocator, "delta:{d}:{s}:{d}:{d}:{d}", .{ seq, key, @intFromBool(deleted), @intFromBool(enabled), rollout }, 0) catch return;
            defer self.allocator.free(msg);
            const chan = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{"doppio:flags"}, 0) catch return;
            defer self.allocator.free(chan);
            v.publish(chan, msg);
        }
    }

    fn publishValkeyNoop(_: *SyncHub, _: u64, _: []const u8, _: bool, _: bool, _: u8) void {}

    /// Blocking subscriber loop: consumes Valkey pub/sub messages on
    /// "doppio:flags" and applies each "delta:N" to the local store. Intended
    /// to be run on a dedicated thread. Returns when the connection drops.
    pub fn runValkeySubscriber(self: *SyncHub, io: Io, host: []const u8, port: c_int) void {
        if (!build_options.enable_valkey) return;
        const owned = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{host}, 0) catch return;
        defer self.allocator.free(owned);
        var backend: ValkeyBackend = .{};
        backend.connect(owned, port) catch return;
        defer backend.deinit();
        const channel = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{"doppio:flags"}, 0) catch return;
        defer self.allocator.free(channel);
        _ = backend.subscribe(channel);
        while (true) {
            var reply_ptr: ?*anyopaque = null;
            const rc = valkey.redisGetReply(backend.ctx, &reply_ptr);
            if (rc != 0) break;
            if (reply_ptr) |r| {
                const reply: *valkey.redisReply = @ptrCast(@alignCast(r));
                if (reply.type == 2 and reply.elements >= 3) {
                    const kind = reply.element[0];
                    const payload = reply.element[2];
                    if (kind.str != null and payload.str != null and
                        std.mem.eql(u8, kind.str[0..kind.len], "message"))
                    {
                        const msg = payload.str[0..payload.len];
                        // parse "delta:seq:key:deleted:enabled:rollout"
                        var it = std.mem.splitScalar(u8, msg, ':');
                        _ = it.next(); // "delta"
                        const seq_str = it.next() orelse "";
                        const key = it.next() orelse "";
                        const del_str = it.next() orelse "0";
                        const en_str = it.next() orelse "0";
                        const roll_str = it.next() orelse "100";
                        const seq = std.fmt.parseUnsigned(u64, seq_str, 10) catch 0;
                        const deleted = std.mem.eql(u8, del_str, "1");
                        const enabled = std.mem.eql(u8, en_str, "1");
                        const rollout: u8 = std.fmt.parseInt(u8, roll_str, 10) catch 100;
                        if (seq > 0 and key.len > 0 and seq != self.current_seq) {
                            self.lock(io);
                            _ = self.recordChangeLocked(io, key, deleted, enabled, rollout) catch {};
                            self.unlock(io);
                        }
                    }
                }
                valkey.freeReplyObject(r);
            }
        }
    }

    /// Cache a flag definition in Valkey (shared across nodes) with a 60s TTL.
    pub const cacheFlag = if (build_options.enable_valkey) cacheFlagImpl else cacheFlagNoop;

    fn cacheFlagImpl(self: *SyncHub, key: []const u8, value: []const u8) void {
        if (self.valkey_backend) |*v| {
            const prefix = std.fmt.allocPrintSentinel(self.allocator, "flag:{s}", .{key}, 0) catch return;
            defer self.allocator.free(prefix);
            const val = std.fmt.allocPrintSentinel(self.allocator, "{s}", .{value}, 0) catch return;
            defer self.allocator.free(val);
            v.set(prefix, val, 60);
        }
    }

    fn cacheFlagNoop(_: *SyncHub, _: []const u8, _: []const u8) void {}

    pub fn deinit(self: *SyncHub) void {
        for (self.history.items) |item| {
            self.allocator.free(item.key);
        }
        self.history.deinit(self.allocator);

        for (self.exposures.items) |exp| self.freeExposure(exp);
        self.exposures.deinit(self.allocator);
        self.idempotency_seen.deinit();
        for (self.flushed_batches.items) |b| self.allocator.free(b);
        self.flushed_batches.deinit(self.allocator);
        self.change_requests.deinit();
        self.experiments.deinit();
        // Connection handles are owned by their connection threads, which
        // unregister and destroy them. The hub only borrowed them here.
        self.connections.deinit(self.allocator);
        if (self.clickhouse) |ch| self.allocator.free(ch.endpoint);
        if (comptime build_options.enable_valkey) {
            if (self.valkey_backend) |*v| v.deinit();
        }
        self.store.deinit();
    }

    /// Lock the hub mutex. All mutations of the store must happen while the
    /// lock is held. Uses the non-cancelable variant so handlers never see a
    /// spurious cancellation error.
    pub fn lock(self: *SyncHub, io: Io) void {
        self.mutex.lockUncancelable(io);
    }

    pub fn unlock(self: *SyncHub, io: Io) void {
        self.mutex.unlock(io);
    }

    fn nowMs(io: Io) i64 {
        return Io.Timestamp.now(io, .awake).toMilliseconds();
    }

    /// Register a WebSocket client so it receives broadcasts.
    pub fn registerConnection(self: *SyncHub, io: Io, handle: *ConnHandle) !void {
        self.lock(io);
        defer self.unlock(io);
        try self.connections.append(self.allocator, handle);
    }

    /// Remove a client and close its queue so its writer thread exits.
    pub fn unregisterConnection(self: *SyncHub, io: Io, handle: *ConnHandle) void {
        self.lock(io);
        defer self.unlock(io);
        for (self.connections.items, 0..) |candidate, index| {
            if (candidate == handle) {
                _ = self.connections.orderedRemove(index);
                break;
            }
        }
        handle.close(io);
    }

    /// Push one frame to every registered client. Called with the hub mutex
    /// already held, so the hub lock is never re-entered.
    pub fn broadcastLocked(self: *SyncHub, io: Io, frame: []const u8) !void {
        for (self.connections.items) |handle| {
            handle.push(io, .{ .kind = .text, .payload = frame }) catch {
                // A client whose queue backed up is dropped rather than
                // blocking every other client on the hub lock.
                handle.close(io);
            };
        }
    }

    pub fn connectionCount(self: *const SyncHub) usize {
        return self.connections.items.len;
    }

    /// Record a change (create / update / delete of a flag) and wake long-poll,
    /// SSE and WebSocket waiters. Caller must hold the mutex.
    pub fn recordChangeLocked(
        self: *SyncHub,
        io: Io,
        key: []const u8,
        deleted: bool,
        enabled: bool,
        rollout_percentage: u8,
    ) !u64 {
        self.current_seq += 1;
        const owned_key = try self.allocator.dupe(u8, key);
        try self.history.append(self.allocator, .{
            .key = owned_key,
            .deleted = deleted,
            .enabled = enabled,
            .rollout_percentage = rollout_percentage,
            .seq = self.current_seq,
        });

        if (self.history.items.len > history_max) {
            const removed = self.history.orderedRemove(0);
            self.allocator.free(removed.key);
        }
        self.history_start_seq = if (self.history.items.len > 0)
            self.history.items[0].seq
        else
            self.current_seq;

        _ = self.generation.fetchAdd(1, .release);
        io.futexWake(u32, &self.generation.raw, std.math.maxInt(u32));

        // Notify the two push transports: long-poll and SSE waiters are woken
        // by the generation word above, while WebSocket clients get the delta
        // pushed onto their outbound queues.
        if (self.connections.items.len > 0) {
            const delta = try self.buildDeltaLocked(self.allocator, self.current_seq - 1);
            defer self.allocator.free(delta.json);
            try self.broadcastLocked(io, delta.json);
        }
        // Fan out to other nodes when Valkey is enabled.
        self.publishValkey(self.current_seq, key, deleted, enabled, rollout_percentage);
        // Warm the shared flag cache with the latest definition.
        {
            const cached = std.fmt.allocPrint(
                self.allocator,
                "{{\"enabled\":{d},\"rollout\":{d},\"deleted\":{d}}}",
                .{ @intFromBool(enabled), rollout_percentage, @intFromBool(deleted) },
            ) catch null;
            if (cached) |cv| {
                defer self.allocator.free(cv);
                self.cacheFlag(key, cv);
            }
        }

        return self.current_seq;
    }

    /// Convenience wrapper that locks around recordChangeLocked.
    pub fn recordChange(
        self: *SyncHub,
        io: Io,
        key: []const u8,
        deleted: bool,
        enabled: bool,
        rollout_percentage: u8,
    ) !u64 {
        self.lock(io);
        defer self.unlock(io);
        return try self.recordChangeLocked(io, key, deleted, enabled, rollout_percentage);
    }

    /// Build a full snapshot as JSON. Caller must hold the mutex.
    pub fn buildSnapshotLocked(self: *const SyncHub, allocator: std.mem.Allocator) ![]const u8 {
        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);

        try writer.print("{{\"type\":\"snapshot\",\"seq\":{d},\"flags\":[", .{self.current_seq});
        var first = true;
        var it = self.store.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print(
                "{{\"key\":\"{s}\",\"enabled\":{},\"rollout_percentage\":{d},\"version\":{d}}}",
                .{ entry.value_ptr.key, entry.value_ptr.enabled, entry.value_ptr.rollout_percentage, entry.value_ptr.version },
            );
        }
        try writer.writeAll("]}");

        return try allocator.dupe(u8, writer.buffered());
    }

    /// Build a delta of all changes after client_seq, or a full snapshot when
    /// the client is too stale. Caller must hold the mutex.
    pub fn buildDeltaLocked(
        self: *const SyncHub,
        allocator: std.mem.Allocator,
        client_seq: u64,
    ) !DeltaResult {
        if (client_seq >= self.current_seq) {
            return .{
                .json = try std.fmt.allocPrint(allocator, "{{\"type\":\"ack\",\"seq\":{d}}}", .{self.current_seq}),
                .snapshot_required = false,
                .seq = self.current_seq,
            };
        }

        if (self.history.items.len > 0 and client_seq + 1 < self.history.items[0].seq) {
            const snap = try self.buildSnapshotLocked(allocator);
            return .{ .json = snap, .snapshot_required = true, .seq = self.current_seq };
        }

        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);
        try writer.print("{{\"type\":\"delta\",\"seq\":{d},\"changes\":[", .{self.current_seq});
        var first = true;
        for (self.history.items) |item| {
            if (item.seq > client_seq) {
                if (!first) try writer.writeByte(',');
                first = false;
                try writer.print(
                    "{{\"key\":\"{s}\",\"deleted\":{},\"enabled\":{},\"rollout_percentage\":{d},\"seq\":{d}}}",
                    .{ item.key, item.deleted, item.enabled, item.rollout_percentage, item.seq },
                );
            }
        }
        try writer.writeAll("]}");

        return .{
            .json = try allocator.dupe(u8, writer.buffered()),
            .snapshot_required = false,
            .seq = self.current_seq,
        };
    }

    /// Block until new changes with seq > after_seq exist, or until timeout_ms
    /// elapses. Locks the mutex internally to build the delta; allocates the
    /// result via `allocator` so the caller controls its lifetime.
    pub fn waitForSeqPast(
        self: *SyncHub,
        io: Io,
        allocator: std.mem.Allocator,
        after_seq: u64,
        timeout_ms: u64,
    ) !WaitResult {
        const deadline = nowMs(io) + @as(i64, @intCast(timeout_ms));

        while (true) {
            self.lock(io);
            const current = self.current_seq;
            const delta = if (current > after_seq)
                try self.buildDeltaLocked(allocator, after_seq)
            else
                null;
            self.unlock(io);

            if (delta) |d| return .{ .delta = d, .timeout = false };

            const seen = self.generation.load(.acquire);
            const remaining = deadline - nowMs(io);
            if (remaining <= 0) return .{ .delta = null, .timeout = true };

            io.futexWaitTimeout(
                u32,
                &self.generation.raw,
                seen,
                .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(remaining), .clock = .awake } },
            ) catch |err| return err;
        }
    }

    /// Deduplicate and enqueue exposure records. Self-locking on the exposure
    /// mutex, so callers never touch the config hub lock.
    pub fn noteExposures(self: *SyncHub, io: Io, exps: []const ExposureInput) !usize {
        self.exposure_mutex.lockUncancelable(io);
        defer self.exposure_mutex.unlock(io);
        return self.noteExposuresLocked(exps);
    }

    /// Caller must hold the exposure mutex.
    fn noteExposuresLocked(self: *SyncHub, exps: []const ExposureInput) !usize {
        var added: usize = 0;
        for (exps) |e| {
            if (self.exposures.items.len >= max_exposures) break;

            // An empty key means the caller opted out of dedupe. Storing the
            // empty key itself would poison the map and silently drop every
            // later un-keyed event.
            const has_key = e.idempotency_key.len > 0;
            if (has_key and self.idempotency_seen.contains(e.idempotency_key)) continue;

            const record = ExposureMessage{
                .flag_key = try self.allocator.dupe(u8, e.flag_key),
                .unit_id = try self.allocator.dupe(u8, e.unit_id),
                .enabled = e.enabled,
                .variation = if (e.variation) |v| try self.allocator.dupe(u8, v) else null,
                .bucket = e.bucket,
                .timestamp = e.timestamp,
                .reason = try self.allocator.dupe(u8, e.reason),
                .idempotency_key = if (has_key) try self.allocator.dupe(u8, e.idempotency_key) else null,
            };

            self.exposures.append(self.allocator, record) catch |err| {
                self.freeExposure(record);
                return err;
            };
            if (record.idempotency_key) |key| {
                self.idempotency_seen.put(key, {}) catch {
                    _ = self.exposures.pop();
                    self.freeExposure(record);
                    return error.OutOfMemory;
                };
            }
            added += 1;
        }
        return added;
    }

    fn freeExposure(self: *SyncHub, exp: ExposureMessage) void {
        self.allocator.free(exp.flag_key);
        self.allocator.free(exp.unit_id);
        if (exp.variation) |v| self.allocator.free(v);
        self.allocator.free(exp.reason);
        if (exp.idempotency_key) |k| self.allocator.free(k);
    }

    /// Trim the queue to its newest `keep` records. Batch ingestion uses this
    /// to bound memory, and the returned `batch_id` is owned by the caller.
    pub fn flushExposures(self: *SyncHub, io: Io, allocator: std.mem.Allocator, keep: usize) !FlushResult {
        self.exposure_mutex.lockUncancelable(io);
        defer self.exposure_mutex.unlock(io);
        return self.flushExposuresLocked(io, allocator, keep);
    }

    /// Caller must hold the exposure mutex.
    fn flushExposuresLocked(self: *SyncHub, io: Io, allocator: std.mem.Allocator, keep: usize) !FlushResult {
        const total = self.exposures.items.len;
        const flushed = if (total > keep) total - keep else 0;
        const batch_id = try std.fmt.allocPrint(allocator, "batch_{d}", .{self.flushed_batches.items.len + 1});
        try self.flushed_batches.append(self.allocator, try self.allocator.dupe(u8, batch_id));

        if (flushed > 0) {
            // Durable write: the batch goes to SQLite inside one transaction and
            // the flush result only counts once the commit lands. The partial
            // unique index on idempotency_key is what turns a retried batch
            // into a no-op.
            var rows: std.ArrayList(storage.ExposureRow) = .empty;
            defer rows.deinit(self.allocator);
            for (self.exposures.items[0..flushed]) |exp| {
                try rows.append(self.allocator, .{
                    .workspace_id = "default",
                    .environment_id = "default",
                    .flag_key = exp.flag_key,
                    .unit_id = exp.unit_id,
                    .enabled = exp.enabled,
                    .variation = exp.variation,
                    .bucket = exp.bucket,
                    .reason = exp.reason,
                    .occurred_at = exp.timestamp,
                    .received_at = nowMs(io),
                    .idempotency_key = exp.idempotency_key,
                });
            }
            if (self.store.db != null) {
                _ = try self.store.insertExposureBatch(rows.items);
            }
            // Forward the batch to ClickHouse when configured.
            if (self.clickhouse) |*ch| {
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);
                for (rows.items) |row| {
                    const line = try std.fmt.allocPrint(
                        self.allocator,
                        "{{\"workspace_id\":\"{s}\",\"flag_key\":\"{s}\",\"unit_id\":\"{s}\",\"enabled\":{d}}}\n",
                        .{ row.workspace_id, row.flag_key, row.unit_id, @intFromBool(row.enabled) },
                    );
                    defer self.allocator.free(line);
                    try payload.appendSlice(self.allocator, line);
                }
                _ = ch.insertBatch(payload.items);
            }

            for (self.exposures.items[0..flushed]) |exp| {
                // Drop the dedupe entry before freeing the string it keys on, so
                // the map never holds a dangling pointer and flushed ids can be
                // reused after a client retry.
                if (exp.idempotency_key) |k| _ = self.idempotency_seen.remove(k);
                self.freeExposure(exp);
            }
            const remaining = total - flushed;
            std.mem.copyForwards(
                ExposureMessage,
                self.exposures.items[0..remaining],
                self.exposures.items[flushed..],
            );
            self.exposures.shrinkRetainingCapacity(remaining);
        }

        return .{
            .retained = self.exposures.items.len,
            .flushed = flushed,
            .batch_id = batch_id,
        };
    }

    pub fn exposureCount(self: *SyncHub, io: Io) usize {
        self.exposure_mutex.lockUncancelable(io);
        defer self.exposure_mutex.unlock(io);
        return self.exposures.items.len;
    }

    /// Handle an inbound WebSocket / long-poll control message and return the
    /// response JSON. Locks the mutex internally.
    pub fn handleMessage(
        self: *SyncHub,
        io: Io,
        allocator: std.mem.Allocator,
        msg_json: []const u8,
    ) ![]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, msg_json, .{}) catch {
            return "{\"type\":\"error\",\"message\":\"Invalid JSON message\"}";
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            return "{\"type\":\"error\",\"message\":\"Expected object message\"}";
        }

        const obj = parsed.value.object;
        const msg_type = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";

        if (std.mem.eql(u8, msg_type, "hello")) {
            const client_seq: u64 = if (obj.get("last_seq")) |s| (if (s == .integer) @intCast(s.integer) else 0) else 0;
            self.lock(io);
            defer self.unlock(io);
            if (client_seq == 0 or client_seq >= self.current_seq) {
                return try self.buildSnapshotLocked(allocator);
            } else {
                const d = try self.buildDeltaLocked(allocator, client_seq);
                return d.json;
            }
        } else if (std.mem.eql(u8, msg_type, "ack")) {
            self.lock(io);
            defer self.unlock(io);
            return try std.fmt.allocPrint(allocator, "{{\"type\":\"ack\",\"seq\":{d}}}", .{self.current_seq});
        } else if (std.mem.eql(u8, msg_type, "heartbeat")) {
            const ts = if (obj.get("timestamp")) |t| (if (t == .integer) t.integer else 0) else 0;
            self.lock(io);
            defer self.unlock(io);
            return try std.fmt.allocPrint(allocator, "{{\"type\":\"heartbeat\",\"client_timestamp\":{d},\"server_seq\":{d}}}", .{ ts, self.current_seq });
        } else if (std.mem.eql(u8, msg_type, "exposure")) {
            if (obj.get("exposures")) |exps| {
                if (exps == .array) {
                    var inputs: std.ArrayList(ExposureInput) = .empty;
                    defer inputs.deinit(allocator);
                    const received_at = nowMs(io);
                    for (exps.array.items) |e| {
                        if (e != .object) continue;
                        const eo = e.object;
                        const flag_key = if (eo.get("flagKey")) |k| (if (k == .string) k.string else "") else "";
                        const unit_id = if (eo.get("unitId")) |u| (if (u == .string) u.string else "") else "";
                        const enabled = if (eo.get("enabled")) |en| (en == .bool and en.bool) else false;
                        const bucket = if (eo.get("bucket")) |b| (if (b == .integer) @as(u32, @intCast(b.integer)) else 0) else 0;
                        const reason = if (eo.get("reason")) |r| (if (r == .string) r.string else "unknown") else "unknown";
                        var variation: ?[]const u8 = null;
                        if (eo.get("variation")) |v| {
                            if (v == .string) variation = v.string;
                        }
                        var idem: []const u8 = "";
                        if (eo.get("idempotencyKey")) |v| {
                            if (v == .string) idem = v.string;
                        }
                        try inputs.append(allocator, .{
                            .flag_key = flag_key,
                            .unit_id = unit_id,
                            .enabled = enabled,
                            .variation = variation,
                            .bucket = bucket,
                            // Without a client timestamp, receive time is the
                            // only honest value. Queue length is not a clock.
                            .timestamp = received_at,
                            .reason = reason,
                            .idempotency_key = idem,
                        });
                    }
                    const added = try self.noteExposures(io, inputs.items);
                    const count = self.exposureCount(io);
                    return try std.fmt.allocPrint(allocator, "{{\"type\":\"ack\",\"status\":\"recorded\",\"added\":{d},\"count\":{d}}}", .{ added, count });
                }
            }
            return "{\"type\":\"ack\",\"status\":\"noop\"}";
        }

        return "{\"type\":\"error\",\"message\":\"Unknown message type\"}";
    }
};

test "ConnHandle queues frames and unblocks the writer on close" {
    const io = std.testing.io;
    var handle = ConnHandle.init(std.testing.allocator);
    defer handle.deinit();

    try handle.pushText(io, "{\"type\":\"ack\"}");
    try handle.push(io, .{ .kind = .pong });

    const first = (try handle.pop(io)).?;
    defer std.testing.allocator.free(first.payload);
    try std.testing.expectEqual(OutboundFrame.Kind.text, first.kind);
    try std.testing.expectEqualStrings("{\"type\":\"ack\"}", first.payload);

    const pong = (try handle.pop(io)).?;
    defer std.testing.allocator.free(pong.payload);
    try std.testing.expectEqual(OutboundFrame.Kind.pong, pong.kind);

    try std.testing.expect(!handle.isClosed(io));

    // Closing drains the queue before reporting null, so a queued goodbye is
    // still delivered.
    try handle.pushText(io, "{\"type\":\"bye\"}");
    handle.close(io);
    try std.testing.expect(handle.isClosed(io));

    const bye = (try handle.pop(io)).?;
    defer std.testing.allocator.free(bye.payload);
    try std.testing.expectEqualStrings("{\"type\":\"bye\"}", bye.payload);
    try std.testing.expect((try handle.pop(io)) == null);
}

test "hub broadcasts to registered connections and unregisters them" {
    const io = std.testing.io;
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    var alice = ConnHandle.init(std.testing.allocator);
    defer alice.deinit();
    var bob = ConnHandle.init(std.testing.allocator);
    defer bob.deinit();

    try hub.registerConnection(io, &alice);
    try hub.registerConnection(io, &bob);
    try std.testing.expectEqual(@as(usize, 2), hub.connectionCount());

    // A flag change reaches both clients.
    hub.lock(io);
    try hub.store.putFlag("bcast-flag", .{ .key = "bcast-flag", .enabled = true }, "admin");
    _ = try hub.recordChangeLocked(io, "bcast-flag", false, true, 100);
    try std.testing.expectEqual(@as(usize, 2), hub.connectionCount());
    hub.unlock(io);

    // pop blocks when empty, so each expected frame is drained once.
    const alice_frame = (try alice.pop(io)).?;
    defer std.testing.allocator.free(alice_frame.payload);
    try std.testing.expect(std.mem.indexOf(u8, alice_frame.payload, "bcast-flag") != null);

    const bob_frame = (try bob.pop(io)).?;
    defer std.testing.allocator.free(bob_frame.payload);
    try std.testing.expect(std.mem.indexOf(u8, bob_frame.payload, "bcast-flag") != null);

    // Unregistering drops the client and closes its queue.
    hub.unregisterConnection(io, &alice);
    try std.testing.expectEqual(@as(usize, 1), hub.connectionCount());
    try std.testing.expect(alice.isClosed(io));
    try std.testing.expect(!bob.isClosed(io));
}

test "SyncHub snapshot and delta sequence tracking" {
    const io = std.testing.io;
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    hub.lock(io);
    try hub.store.putFlag("flag-1", .{
        .key = "flag-1",
        .enabled = true,
        .rollout_percentage = 50,
    }, "admin");
    _ = try hub.recordChangeLocked(io, "flag-1", false, true, 50);
    hub.unlock(io);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const hello_res = try hub.handleMessage(io, arena.allocator(), "{\"type\":\"hello\",\"last_seq\":0}");
    try std.testing.expect(std.mem.indexOf(u8, hello_res, "\"type\":\"snapshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, hello_res, "flag-1") != null);

    const new_seq = try hub.recordChange(io, "flag-2", false, true, 100);
    try std.testing.expectEqual(@as(u64, 3), new_seq);

    const delta_res = try hub.handleMessage(io, arena.allocator(), "{\"type\":\"hello\",\"last_seq\":2}");
    try std.testing.expect(std.mem.indexOf(u8, delta_res, "\"type\":\"delta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, delta_res, "flag-2") != null);
}

fn sampleExposure(flag_key: []const u8, idem: []const u8) ExposureInput {
    return .{
        .flag_key = flag_key,
        .unit_id = "user-1",
        .enabled = true,
        .bucket = 1200,
        .timestamp = 1_700_000_000_000,
        .reason = "RULE_MATCH",
        .idempotency_key = idem,
    };
}

test "exposure ingest dedupes keyed records and keeps every unkeyed one" {
    const io = std.testing.io;
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    const first = [_]ExposureInput{
        sampleExposure("flag-a", "idem-1"),
        sampleExposure("flag-a", ""),
        sampleExposure("flag-b", ""),
    };
    try std.testing.expectEqual(@as(usize, 3), try hub.noteExposures(io, &first));

    // The repeated key is dropped, and the empty keys are not treated as one
    // shared key.
    const second = [_]ExposureInput{
        sampleExposure("flag-b", "idem-1"),
        sampleExposure("flag-c", ""),
    };
    try std.testing.expectEqual(@as(usize, 1), try hub.noteExposures(io, &second));
    try std.testing.expectEqual(@as(usize, 4), hub.exposureCount(io));
}

test "flushExposures releases dedupe keys so a retry is accepted again" {
    const io = std.testing.io;
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    try std.testing.expectEqual(
        @as(usize, 2),
        try hub.noteExposures(io, &.{ sampleExposure("flag-a", "retry-me"), sampleExposure("flag-b", "") }),
    );

    const result = try hub.flushExposures(io, std.testing.allocator, 0);
    std.testing.allocator.free(result.batch_id);
    try std.testing.expectEqual(@as(usize, 2), result.flushed);
    try std.testing.expectEqual(@as(usize, 0), result.retained);
    try std.testing.expectEqual(@as(usize, 0), hub.exposureCount(io));

    // The key was removed with its record, so a client retry is not silently
    // swallowed by a stale dedupe entry.
    try std.testing.expectEqual(@as(usize, 1), try hub.noteExposures(io, &.{sampleExposure("flag-a", "retry-me")}));
}

test "exposure ingest never requires the hub lock" {
    const io = std.testing.io;
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    // Holding the exposure lock must not block a configuration change, which
    // takes the hub lock. A single shared mutex would deadlock here.
    hub.exposure_mutex.lockUncancelable(io);
    defer hub.exposure_mutex.unlock(io);

    const seq = try hub.recordChange(io, "seam-flag", false, true, 100);
    try std.testing.expectEqual(@as(u64, 2), seq);
}

test "enableClickHouse configures the analytics backend" {
    var hub = SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    try std.testing.expect(hub.clickhouse == null);
    try hub.enableClickHouse("http://localhost:8123");
    try std.testing.expect(hub.clickhouse != null);
    try std.testing.expectEqualStrings("http://localhost:8123", hub.clickhouse.?.endpoint);
}
