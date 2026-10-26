// Valkey backend (extern declarations for hiredis). Scaffold + cache helpers.
const std = @import("std");

extern "c" fn redisConnect(ip: [*:0]const u8, port: c_int) callconv(.c) ?*anyopaque;
extern "c" fn redisCommand(ctx: ?*anyopaque, format: [*:0]const u8, ...) callconv(.c) ?*anyopaque;
extern "c" fn freeReplyObject(obj: ?*anyopaque) callconv(.c) void;
extern "c" fn redisFree(ctx: ?*anyopaque) callconv(.c) void;

pub const ValkeyBackend = struct {
    ctx: ?*anyopaque = null,

    pub fn connect(self: *ValkeyBackend, host: [:0]const u8, port: c_int) !void {
        self.ctx = redisConnect(host.ptr, port);
        if (self.ctx == null) return error.ValkeyConnectFailed;
    }

    pub fn publish(self: *ValkeyBackend, channel: [:0]const u8, message: [:0]const u8) void {
        if (self.ctx) |c| {
            const reply = redisCommand(c, "PUBLISH %s %s", channel.ptr, message.ptr);
            if (reply) |r| freeReplyObject(r);
        }
    }

    pub fn set(self: *ValkeyBackend, key: [:0]const u8, value: [:0]const u8, ttl_seconds: c_int) void {
        if (self.ctx) |c| {
            const reply = redisCommand(c, "SETEX %s %d %s", key.ptr, ttl_seconds, value.ptr);
            if (reply) |r| freeReplyObject(r);
        }
    }

    pub fn get(self: *ValkeyBackend, key: [:0]const u8) ?*anyopaque {
        if (self.ctx) |c| {
            return redisCommand(c, "GET %s", key.ptr);
        }
        return null;
    }

    pub fn deinit(self: *ValkeyBackend) void {
        if (self.ctx) |c| redisFree(c);
        self.ctx = null;
    }
};