// Valkey backend (extern declarations for hiredis). Scaffold + cache helpers
// + sentinel-mode HA (primary/replica, read/write split, retry failover).
const std = @import("std");

extern "c" fn redisConnect(ip: [*:0]const u8, port: c_int) callconv(.c) ?*anyopaque;
extern "c" fn redisCommand(ctx: ?*anyopaque, format: [*:0]const u8, ...) callconv(.c) ?*anyopaque;
extern "c" fn redisGetReply(ctx: ?*anyopaque, reply: *?*anyopaque) callconv(.c) c_int;
extern "c" fn freeReplyObject(obj: ?*anyopaque) callconv(.c) void;
extern "c" fn redisFree(ctx: ?*anyopaque) callconv(.c) void;

pub const redisReply = extern struct {
    type: c_int,
    integer: c_longlong,
    dval: f64,
    str: [*c]u8,
    len: usize,
    elements: usize,
    element: [*c]*redisReply,
};

pub const ValkeyBackend = struct {
    primary_ctx: ?*anyopaque = null,
    replica_ctx: ?*anyopaque = null,
    role: Role = .primary,
    mode: Mode = .standalone,

    pub const Role = enum { primary, replica };
    pub const Mode = enum { standalone, sentinel, cluster };

    // Backward-compatible single-node connect (master/direct).
    pub fn connect(self: *ValkeyBackend, host: [:0]const u8, port: c_int) !void {
        self.primary_ctx = redisConnect(host.ptr, port);
        if (self.primary_ctx == null) return error.ValkeyConnectFailed;
        self.role = .primary;
        self.mode = .standalone;
    }

    pub fn connectWithRetry(self: *ValkeyBackend, host: [:0]const u8, port: c_int, max_attempts: u32, backoff_ms: u32) !void {
        var attempt: u32 = 0;
        var delay = backoff_ms;
        while (attempt < max_attempts) : (attempt += 1) {
            if (self.connect(host, port)) |_| return else |_| {}
            if (attempt + 1 < max_attempts) {
                std.Thread.sleep(@as(u64, delay) * std.time.ns_per_ms);
                delay = delay * 2;
                if (delay > 1600) delay = 1600;
            }
        }
        return error.ValkeyConnectFailed;
    }

    /// Sentinel mode: resolve the current master via a sentinel, then connect.
    /// `replica_host`/`replica_port` are optional static replica endpoints for
    /// read splitting; when omitted, reads also go to the primary.
    pub fn connectSentinel(
        self: *ValkeyBackend,
        master_name: [:0]const u8,
        sentinel_host: [:0]const u8,
        sentinel_port: c_int,
        replica_host: ?[:0]const u8,
        replica_port: c_int,
    ) !void {
        // Ask sentinel for the master address.
        const sctx = redisConnect(sentinel_host.ptr, sentinel_port);
        if (sctx == null) return error.ValkeyConnectFailed;
        const reply = redisCommand(sctx, "SENTINEL get-master-addr-by-name %s", master_name.ptr);
        var master_host_buf: [256]u8 = undefined;
        var master_port: c_int = 0;
        if (reply) |r| {
            const rr: *redisReply = @ptrCast(@alignCast(r));
            if (rr.type == 2 and rr.elements >= 2) {
                const host_reply = rr.element[0];
                const port_reply = rr.element[1];
                const hlen = @min(host_reply.len, master_host_buf.len - 1);
                @memcpy(master_host_buf[0..hlen], host_reply.str[0..hlen]);
                master_host_buf[hlen] = 0;
                // parse port
                const pstr = port_reply.str[0..port_reply.len];
                master_port = std.fmt.parseInt(c_int, pstr, 10) catch 0;
            }
            freeReplyObject(r);
        }
        redisFree(sctx);
        if (master_port == 0) return error.ValkeySentinelResolveFailed;

        const host_ptr: [*:0]const u8 = @ptrCast(&master_host_buf);
        self.primary_ctx = redisConnect(host_ptr, master_port);
        if (self.primary_ctx == null) return error.ValkeyConnectFailed;
        self.role = .primary;
        self.mode = .sentinel;

        if (replica_host) |rh| {
            self.replica_ctx = redisConnect(rh.ptr, replica_port);
            if (self.replica_ctx == null) {
                // Degrade honestly: no replica; reads go to primary.
                self.replica_ctx = null;
            } else {
                self.role = .replica;
            }
        }
    }

    /// Cluster mode scaffold: connect to the first reachable seed node. Full
    /// slot routing/redirect handling requires hiredis-cluster and is not yet
    /// wired; this keeps the backend honest about operating in cluster mode.
    pub fn connectCluster(self: *ValkeyBackend, seed_host: [:0]const u8, seed_port: c_int) !void {
        self.primary_ctx = redisConnect(seed_host.ptr, seed_port);
        if (self.primary_ctx == null) return error.ValkeyConnectFailed;
        self.mode = .cluster;
        self.role = .primary;
    }

    // CRC16 (XMODEM) used by Valkey/Redis cluster key hashing.
    pub fn keySlot(key: []const u8) u16 {
        // strip hash tag
        var start: usize = 0;
        var end: usize = key.len;
        if (std.mem.indexOfScalar(u8, key, '{')) |i| {
            if (std.mem.indexOfScalarPos(u8, key, i + 1, '}')) |j| {
                if (j > i + 1) {
                    start = i + 1;
                    end = j;
                }
            }
        }
        const slice = key[start..end];
        var crc: u16 = 0;
        for (slice) |b| {
            crc ^= @as(u16, b) << 8;
            var k: u8 = 0;
            while (k < 8) : (k += 1) {
                if (crc & 0x8000 != 0) {
                    crc = (crc << 1) ^ 0x1021;
                } else {
                    crc <<= 1;
                }
            }
        }
        return crc % 16384;
    }

    pub fn isHealthy(self: *ValkeyBackend) bool {
        // hiredis has no PING extern declared; treat non-null ctx as connected.
        return self.primary_ctx != null;
    }

    fn writeCtx(self: *ValkeyBackend) ?*anyopaque {
        return self.primary_ctx;
    }

    fn readCtx(self: *ValkeyBackend) ?*anyopaque {
        return if (self.replica_ctx) |c| c else self.primary_ctx;
    }

    pub fn publish(self: *ValkeyBackend, channel: [:0]const u8, message: [:0]const u8) void {
        if (self.writeCtx()) |c| {
            const reply = redisCommand(c, "PUBLISH %s %s", channel.ptr, message.ptr);
            if (reply) |r| freeReplyObject(r);
        }
    }

    pub fn set(self: *ValkeyBackend, key: [:0]const u8, value: [:0]const u8, ttl_seconds: c_int) void {
        if (self.writeCtx()) |c| {
            const reply = redisCommand(c, "SETEX %s %d %s", key.ptr, ttl_seconds, value.ptr);
            if (reply) |r| freeReplyObject(r);
        }
    }

    pub fn get(self: *ValkeyBackend, key: [:0]const u8) ?*anyopaque {
        if (self.readCtx()) |c| {
            return redisCommand(c, "GET %s", key.ptr);
        }
        return null;
    }

    pub fn subscribe(self: *ValkeyBackend, channel: [:0]const u8) ?*anyopaque {
        if (self.primary_ctx) |c| {
            return redisCommand(c, "SUBSCRIBE %s", channel.ptr);
        }
        return null;
    }

    pub fn deinit(self: *ValkeyBackend) void {
        if (self.primary_ctx) |c| redisFree(c);
        if (self.replica_ctx) |c| redisFree(c);
        self.primary_ctx = null;
        self.replica_ctx = null;
    }
};
