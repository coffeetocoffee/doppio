const std = @import("std");
const server = @import("server.zig");
const sync = @import("sync.zig");
const websocket = @import("websocket.zig");

const Io = std.Io;

/// One accepted connection, handed to a dedicated thread.
///
/// Blocking socket operations block only the calling OS thread, so giving each
/// connection its own thread is what lets a long-lived WebSocket or SSE stream
/// hold the accept loop open instead of stalling it.
const ConnCtx = struct {
    io: std.Io,
    stream: std.Io.net.Stream,
    app_server: *server.Server,
    allocator: std.mem.Allocator,
};

const socket_in_size = 16384;
const socket_out_size = 16384;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var port: u16 = 8080;
    var host: []const u8 = "0.0.0.0";
    var db_path: []const u8 = "doppio.db";
    var clickhouse_url: ?[]const u8 = null;
    var valkey_host: ?[]const u8 = null;
    var postgres_conn: ?[]const u8 = null;
    var postgres_replica_conn: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--db") and i + 1 < args.len) {
            db_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--clickhouse") and i + 1 < args.len) {
            clickhouse_url = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--valkey") and i + 1 < args.len) {
            valkey_host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--postgres") and i + 1 < args.len) {
            postgres_conn = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--postgres-replica") and i + 1 < args.len) {
            postgres_replica_conn = args[i + 1];
            i += 1;
        }
    }

    var app_server = try server.Server.initWith(allocator, db_path);
    defer app_server.deinit();
    if (clickhouse_url) |url| try app_server.hub.enableClickHouse(url);
    if (valkey_host) |vh| try app_server.hub.enableValkey(vh, 6379);
    if (postgres_conn) |conninfo| try app_server.hub.store.openPostgres(conninfo, postgres_replica_conn);

    const addr = try std.Io.net.IpAddress.parse(host, port);
    var tcp_server = try addr.listen(init.io, .{ .reuse_address = true });
    defer tcp_server.deinit(init.io);

    std.debug.print("doppio-control-plane: listening on http://{s}:{d}\n", .{ host, port });
    std.debug.print("  OpenAPI 3.1: http://{s}:{d}/openapi.json\n", .{ host, port });
    std.debug.print("  Health: http://{s}:{d}/health\n", .{ host, port });
    std.debug.print("  Sync snapshot: http://{s}:{d}/sync/snapshot\n", .{ host, port });
    std.debug.print("  Sync updates:  http://{s}:{d}/sync/updates/{{after_seq}}\n", .{ host, port });
    std.debug.print("  Sync stream:   http://{s}:{d}/sync/stream (SSE)\n", .{ host, port });
    std.debug.print("  Sync socket:   http://{s}:{d}/sync/ws (WebSocket)\n", .{ host, port });
    std.debug.print("  Admin UI:      http://{s}:{d}/admin\n", .{ host, port });

    while (true) {
        const stream = tcp_server.accept(init.io) catch |err| {
            std.debug.print("Accept error: {s}\n", .{@errorName(err)});
            continue;
        };

        const ctx = allocator.create(ConnCtx) catch {
            stream.close(init.io);
            continue;
        };
        ctx.* = .{
            .io = init.io,
            .stream = stream,
            .app_server = &app_server,
            .allocator = allocator,
        };

        // A thread per connection keeps one idle stream from blocking accepts.
        const thread = std.Thread.spawn(.{}, serveConnection, .{ctx}) catch {
            // Fall back to inline handling so a spawn failure never drops a
            // live connection.
            serveConnection(ctx);
            continue;
        };
        thread.detach();
    }
}

fn serveConnection(ctx: *ConnCtx) void {
    defer ctx.allocator.destroy(ctx);
    defer ctx.stream.close(ctx.io);

    const in_buf = ctx.allocator.alloc(u8, socket_in_size) catch return;
    defer ctx.allocator.free(in_buf);
    const out_buf = ctx.allocator.alloc(u8, socket_out_size) catch return;
    defer ctx.allocator.free(out_buf);

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();

    var stream_reader = ctx.stream.reader(ctx.io, in_buf);
    var stream_writer = ctx.stream.writer(ctx.io, out_buf);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

    // One request per connection. The transports that need to outlive a single
    // request (WebSocket, SSE) are handed the raw stream after the head.
    var req = http_server.receiveHead() catch return;
    const target = arena.allocator().dupe(u8, req.head.target) catch return;
    const method = req.head.method;

    if (std.mem.eql(u8, target, "/sync/ws")) {
        serveWebsocket(ctx, &stream_reader.interface, &stream_writer.interface, &req, arena.allocator()) catch {
            // A client that vanishes mid-handshake is normal, not an error.
        };
        return;
    }

    if (std.mem.eql(u8, target, "/sync/stream")) {
        serveSse(ctx, &stream_writer.interface, arena.allocator()) catch {};
        return;
    }

    // Extract Authorization, X-Doppio-Key, and Cookie headers.
    var auth_header: ?[]const u8 = null;
    var cookie_header: ?[]const u8 = null;
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            auth_header = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "x-doppio-key") and auth_header == null) {
            auth_header = h.value;
        } else if (std.ascii.eqlIgnoreCase(h.name, "cookie")) {
            cookie_header = h.value;
        }
    }

    // Read the body when there is one.
    var body_str: ?[]const u8 = null;
    if (req.head.content_length) |len| {
        if (len > 0 and len <= 65536) {
            const body_buf = arena.allocator().alloc(u8, @intCast(len)) catch return;
            var transfer_buf: [8192]u8 = undefined;
            var body_reader = req.readerExpectNone(&transfer_buf);
            body_reader.readSliceAll(body_buf) catch return;
            body_str = body_buf;
        }
    }

    const resp: server.HttpResponse = respond(ctx, method, target, auth_header, cookie_header, body_str, arena.allocator()) catch |err| server.HttpResponse{
        .status = .internal_server_error,
        .content_type = "application/json",
        .body = std.fmt.allocPrint(arena.allocator(), "{{\"error\":\"internal_server_error\",\"message\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"internal\"}",
    };

    var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    headers.append(arena.allocator(), .{ .name = "content-type", .value = resp.content_type }) catch return;
    headers.append(arena.allocator(), .{ .name = "access-control-allow-origin", .value = "*" }) catch return;
    if (resp.set_cookie) |cookie| {
        headers.append(arena.allocator(), .{ .name = "set-cookie", .value = cookie }) catch return;
    }
    if (resp.location) |loc| {
        headers.append(arena.allocator(), .{ .name = "location", .value = loc }) catch return;
    }

    req.respond(resp.body, .{ .status = resp.status, .extra_headers = headers.items }) catch return;
}

/// Route a plain HTTP request to the JSON API or the admin UI.
fn respond(
    ctx: *ConnCtx,
    method: std.http.Method,
    target: []const u8,
    auth_header: ?[]const u8,
    cookie_header: ?[]const u8,
    body: ?[]const u8,
    arena: std.mem.Allocator,
) !server.HttpResponse {
    // CORS preflight for the public SDK and admin surface.
    if (method == .OPTIONS) {
        return .{
            .status = .no_content,
            .body = "",
            .content_type = "text/plain",
        };
    }

    if (std.mem.startsWith(u8, target, "/admin")) {
        const session_token = extractCookie(cookie_header, "doppio_admin") orelse auth_header;
        return ctx.app_server.handleAdmin(ctx.io, method, target, session_token, body, arena);
    }

    return ctx.app_server.handle(ctx.io, method, target, auth_header, body, arena);
}

/// Server-sent events transport. Writes a chunked response and then loops on
/// the same long-poll wait the HTTP fallback uses, emitting an event per
/// change and a comment heartbeat while idle.
fn serveSse(ctx: *ConnCtx, writer: *std.Io.Writer, arena: std.mem.Allocator) !void {
    _ = arena;
    const io = ctx.io;

    try writer.writeAll(
        "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/event-stream\r\n" ++
            "cache-control: no-cache\r\n" ++
            "connection: keep-alive\r\n" ++
            "access-control-allow-origin: *\r\n" ++
            "transfer-encoding: chunked\r\n\r\n",
    );
    try writer.flush();

    var last_seq: u64 = 0;
    while (true) {
        const waited = ctx.app_server.hub.waitForSeqPast(io, ctx.app_server.hub.allocator, last_seq, 15_000) catch |err| switch (err) {
            // A write failure means the client went away; ending the loop is
            // the only correct response.
            error.Canceled => return,
            else => return err,
        };

        if (waited.delta) |delta| {
            last_seq = @max(last_seq, delta.seq);
            var chunk: Io.Writer.Allocating = .init(ctx.app_server.hub.allocator);
            defer chunk.deinit();
            try chunk.writer.print("event: delta\ndata: {s}\n\n", .{delta.json});
            _ = try writeChunk(writer, chunk.writer.buffered());
            ctx.app_server.hub.allocator.free(delta.json);
            try writer.flush();
        } else {
            _ = try writeChunk(writer, ": heartbeat\n\n");
            try writer.flush();
        }
    }
}

/// Emit one HTTP chunked-encoding body block.
fn writeChunk(writer: *std.Io.Writer, payload: []const u8) !void {
    if (payload.len == 0) return;
    var size_buf: [16]u8 = undefined;
    const size_text = try std.fmt.bufPrint(&size_buf, "{x}\r\n", .{payload.len});
    try writer.writeAll(size_text);
    try writer.writeAll(payload);
    try writer.writeAll("\r\n");
}

/// WebSocket transport. The connection thread only reads; a writer thread
/// owns every socket write, so broadcasts never race the read loop.
fn serveWebsocket(
    ctx: *ConnCtx,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    req: *std.http.Server.Request,
    arena: std.mem.Allocator,
) !void {
    const io = ctx.io;
    const hub = &ctx.app_server.hub;

    // Handshake, written raw because the connection upgrades past HTTP framing.
    const client_key = headerValue(req, "sec-websocket-key") orelse return error.BadHandshake;
    var accept_buf: [websocket.accept_len]u8 = undefined;
    const accept_key = try websocket.acceptKey(client_key, &accept_buf);

    var handshake: Io.Writer.Allocating = .init(arena);
    defer handshake.deinit();
    try handshake.writer.print(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "upgrade: websocket\r\n" ++
            "connection: Upgrade\r\n" ++
            "sec-websocket-accept: {s}\r\n\r\n",
        .{accept_key},
    );
    try writer.writeAll(handshake.writer.buffered());
    try writer.flush();

    const handle = arena.create(sync.ConnHandle) catch return error.OutOfMemory;
    handle.* = sync.ConnHandle.init(hub.allocator);

    // The writer thread is the only thread that writes to this socket, and it
    // borrows the writer that lives in serveConnection's frame. It is joined
    // before that frame goes away, rather than detached.
    const WriterCtx = struct {
        io: std.Io,
        writer: *std.Io.Writer,
        handle: *sync.ConnHandle,
        allocator: std.mem.Allocator,
    };
    const writer_ctx = arena.create(WriterCtx) catch return error.OutOfMemory;
    writer_ctx.* = .{ .io = io, .writer = writer, .handle = handle, .allocator = hub.allocator };

    const writer_thread = std.Thread.spawn(.{}, wsWriterLoop, .{writer_ctx}) catch return error.OutOfMemory;

    // Defers run in reverse declaration order, so this reads bottom-up: close
    // the queue first to wake the writer, join it, and only then release the
    // resources it borrows.
    defer {
        hub.unregisterConnection(io, handle);
        handle.deinit();
        arena.destroy(handle);
    }
    defer writer_thread.join();
    defer handle.close(io);

    try hub.registerConnection(io, handle);

    // The first frame a client receives is the state it needs to catch up.
    hub.lock(io);
    const snapshot = try hub.buildSnapshotLocked(hub.allocator);
    hub.unlock(io);
    defer hub.allocator.free(snapshot);
    try handle.pushText(io, snapshot);

    // Read loop: parse client frames and enqueue replies.
    var payload_buf: [websocket.max_frame_payload]u8 = undefined;
    while (true) {
        const frame = websocket.readFrame(reader, &payload_buf) catch |err| switch (err) {
            // The peer closed the stream: a clean disconnect, not a fault.
            error.EndOfStream, error.ReadFailed => return,
            else => return err,
        };

        switch (frame.opcode) {
            .close => return,
            .ping => try handle.push(io, .{ .kind = .pong }),
            .text => {
                // Replies are allocated by the hub and freed here, so the
                // writer thread only ever borrows them.
                if (try handleTextMessage(hub, io, arena, frame.payload)) |text| {
                    defer hub.allocator.free(text);
                    try handle.pushText(io, text);
                }
            },
            else => {
                // Pong, binary, and continuation frames carry nothing the
                // protocol needs to answer.
            },
        }
    }
}

/// Translate one client text frame into the reply the writer thread sends.
/// Returns null when the frame needs no reply at all.
fn handleTextMessage(
    hub: *sync.SyncHub,
    io: std.Io,
    arena: std.mem.Allocator,
    msg_json: []const u8,
) !?[]const u8 {
    if (msg_json.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, msg_json, .{}) catch {
        return "{\"type\":\"error\",\"message\":\"Invalid JSON message\"}";
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return "{\"type\":\"error\",\"message\":\"Expected object message\"}";
    }

    const obj = parsed.value.object;
    const msg_type = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";

    if (std.mem.eql(u8, msg_type, "hello")) {
        const client_seq: u64 = if (obj.get("last_seq")) |s| (if (s == .integer) @intCast(@max(0, s.integer)) else 0) else 0;
        hub.lock(io);
        defer hub.unlock(io);
        const delta = try hub.buildDeltaLocked(hub.allocator, client_seq);
        return delta.json;
    }

    if (std.mem.eql(u8, msg_type, "ack") or std.mem.eql(u8, msg_type, "heartbeat")) {
        hub.lock(io);
        const seq = hub.current_seq;
        hub.unlock(io);
        return try std.fmt.allocPrint(hub.allocator, "{{\"type\":\"ack\",\"seq\":{d}}}", .{seq});
    }

    if (std.mem.eql(u8, msg_type, "exposure")) {
        if (obj.get("exposures")) |exps| {
            if (exps == .array) {
                var inputs: std.ArrayList(sync.ExposureInput) = .empty;
                defer inputs.deinit(arena);
                for (exps.array.items) |e| {
                    if (e != .object) continue;
                    const eo = e.object;
                    try inputs.append(arena, .{
                        .flag_key = if (eo.get("flagKey")) |k| (if (k == .string) k.string else "") else "",
                        .unit_id = if (eo.get("unitId")) |u| (if (u == .string) u.string else "") else "",
                        .enabled = if (eo.get("enabled")) |en| (en == .bool and en.bool) else false,
                        .variation = if (eo.get("variation")) |v| (if (v == .string) v.string else null) else null,
                        .bucket = if (eo.get("bucket")) |b| (if (b == .integer) @as(u32, @intCast(b.integer)) else 0) else 0,
                        .timestamp = if (eo.get("timestamp")) |t| (if (t == .integer) t.integer else 0) else 0,
                        .reason = if (eo.get("reason")) |r| (if (r == .string) r.string else "unknown") else "unknown",
                        .idempotency_key = if (eo.get("idempotencyKey")) |v| (if (v == .string) v.string else "") else "",
                    });
                }
                const added = try hub.noteExposures(io, inputs.items);
                const count = hub.exposureCount(io);
                return try std.fmt.allocPrint(hub.allocator, "{{\"type\":\"ack\",\"status\":\"recorded\",\"added\":{d},\"count\":{d}}}", .{ added, count });
            }
        }
        return "{\"type\":\"ack\",\"status\":\"noop\"}";
    }

    return "{\"type\":\"error\",\"message\":\"Unknown message type\"}";
}

/// Drain the outbound queue to the socket until the connection closes, then
/// echo a close frame so the peer sees a clean shutdown instead of a reset.
fn wsWriterLoop(writer_ctx: anytype) void {
    const io = writer_ctx.io;
    const handle = writer_ctx.handle;
    const writer = writer_ctx.writer;
    const allocator = writer_ctx.allocator;

    while (true) {
        const frame = handle.pop(io) catch break;
        if (frame) |outbound| {
            defer allocator.free(outbound.payload);
            const opcode: websocket.Opcode = switch (outbound.kind) {
                .text => .text,
                .pong => .pong,
                .close => .close,
            };
            websocket.writeFrame(writer, opcode, outbound.payload) catch {
                handle.close(io);
                return;
            };
            writer.flush() catch {
                handle.close(io);
                return;
            };
        } else break;
    }
}

/// Read one header value from a request head.
fn headerValue(req: *std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// Pull one cookie out of a Cookie header value.
fn extractCookie(cookie_header: ?[]const u8, name: []const u8) ?[]const u8 {
    const header = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
    }
    return null;
}
