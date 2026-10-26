const std = @import("std");
const doppio = @import("doppio");
const openapi = @import("openapi.zig");
const casbin = @import("casbin.zig");
const auth = @import("auth.zig");
const storage = @import("storage.zig");
const sync = @import("sync.zig");
const ui = @import("ui.zig");
const admin = @import("admin.zig");

const Io = std.Io;

pub const HttpResponse = struct {
    status: std.http.Status,
    content_type: []const u8 = "application/json",
    body: []const u8,
    set_cookie: ?[]const u8 = null,
    location: ?[]const u8 = null,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    hub: sync.SyncHub,
    enforcer: casbin.Enforcer,
    api_keys: std.ArrayList(auth.StoredApiKey),

    pub fn init(allocator: std.mem.Allocator) !Server {
        const hb = sync.SyncHub.init(allocator);
        var enf = casbin.Enforcer.init(allocator);
        try enf.loadDefaultRbac("default");

        return .{
            .allocator = allocator,
            .hub = hb,
            .enforcer = enf,
            .api_keys = .empty,
        };
    }

    pub fn initWith(allocator: std.mem.Allocator, db_path: []const u8) !Server {
        var srv = try Server.init(allocator);
        try srv.hub.store.open(allocator, db_path);
        return srv;
    }

    pub fn deinit(self: *Server) void {
        self.hub.deinit();
        self.enforcer.deinit();
        self.api_keys.deinit(self.allocator);
    }

    pub fn handle(
        self: *Server,
        io: Io,
        method: std.http.Method,
        path: []const u8,
        auth_header: ?[]const u8,
        body: ?[]const u8,
        arena: std.mem.Allocator,
    ) !HttpResponse {
        // Public endpoints
        if (std.mem.eql(u8, path, "/health")) {
            return .{
                .status = .ok,
                .body = "{\"status\":\"ok\",\"version\":\"0.1.0\"}",
            };
        }

        if (std.mem.eql(u8, path, "/openapi.json")) {
            return .{
                .status = .ok,
                .body = openapi.getSpecJson(),
            };
        }

        // Evaluation endpoint is accessible to client SDKs
        if (std.mem.eql(u8, path, "/api/v1/eval")) {
            return self.handleEval(io, arena, body);
        }

        // Sync protocol endpoints (delta sync), public to SDKs
        if (std.mem.eql(u8, path, "/sync/snapshot")) {
            return self.handleSyncSnapshot(io, arena);
        }
        if (std.mem.startsWith(u8, path, "/sync/updates/")) {
            const after_seq = std.fmt.parseUnsigned(u64, path["/sync/updates/".len..], 10) catch 0;
            return self.handleSyncUpdates(io, arena, after_seq);
        }

        // Exposure collection endpoint, public to SDKs
        if (method == .POST and std.mem.eql(u8, path, "/collect")) {
            return self.handleCollect(io, arena, body);
        }

        // Authenticate request
        const auth_ctx = self.authenticate(arena, auth_header);

        // RBAC authorization
        const required_act: casbin.Action = switch (method) {
            .GET => .read,
            .POST, .PUT => .write,
            .DELETE => .delete,
            else => .read,
        };

        const resource = if (std.mem.startsWith(u8, path, "/api/v1/flags"))
            "flags"
        else if (std.mem.startsWith(u8, path, "/api/v1/segments"))
            "segments"
        else if (std.mem.startsWith(u8, path, "/api/v1/environments"))
            "environments"
        else if (std.mem.startsWith(u8, path, "/api/v1/audit"))
            "audit"
        else
            "general";

        if (!auth_ctx.is_admin and !self.enforcer.enforce(auth_ctx.subject, auth_ctx.workspace, resource, required_act)) {
            if ((auth_ctx.auth_type == .public_client_key or auth_ctx.auth_type == .anonymous) and required_act == .read) {
                // allowed public/SDK read
            } else if (!auth_ctx.is_admin and auth_ctx.auth_type == .anonymous) {
                return .{
                    .status = .unauthorized,
                    .body = "{\"error\":\"unauthorized\",\"message\":\"Authentication required\"}",
                };
            }
        }

        // Route: /api/v1/flags
        if (std.mem.eql(u8, path, "/api/v1/flags")) {
            if (method == .GET) {
                return self.handleListFlags(arena);
            } else if (method == .POST) {
                return self.handleCreateFlag(io, arena, body, auth_ctx.subject);
            }
        }

        // Route: /api/v1/flags/:key
        if (std.mem.startsWith(u8, path, "/api/v1/flags/")) {
            const flag_key = path["/api/v1/flags/".len..];
            if (method == .GET) {
                return self.handleGetFlag(arena, flag_key);
            } else if (method == .DELETE) {
                return self.handleDeleteFlag(io, flag_key, auth_ctx.subject);
            }
        }

        // Route: /api/v1/segments
        if (std.mem.eql(u8, path, "/api/v1/segments")) {
            if (method == .GET) {
                return self.handleListSegments(arena);
            } else if (method == .POST) {
                return self.handleCreateSegment(io, arena, body, auth_ctx.subject);
            }
        }

        // Route: /api/v1/environments
        if (std.mem.eql(u8, path, "/api/v1/environments")) {
            return self.handleListEnvironments(arena);
        }

        // Route: /api/v1/audit
        if (std.mem.eql(u8, path, "/api/v1/audit")) {
            return self.handleListAudit(arena);
        }

        // Route: /api/v1/eval
        if (std.mem.eql(u8, path, "/api/v1/eval")) {
            return self.handleEval(io, arena, body);
        }

        return .{
            .status = .not_found,
            .body = "{\"error\":\"not_found\",\"message\":\"Route not found\"}",
        };
    }

    fn authenticate(self: *Server, arena: std.mem.Allocator, auth_header: ?[]const u8) auth.AuthContext {
        const header = auth_header orelse return .{
            .subject = "anonymous",
            .auth_type = .anonymous,
            .workspace = "default",
            .environment = "production",
            .is_admin = false,
        };

        if (std.mem.startsWith(u8, header, "Bearer ")) {
            const token = header["Bearer ".len..];
            if (auth.parseJwtClaims(arena, token, 1700000000)) |ctx| {
                return ctx;
            } else |_| {}
        }

        if (auth.verifyApiKey(header, self.api_keys.items)) |ctx| {
            return ctx;
        }

        return .{
            .subject = "anonymous",
            .auth_type = .anonymous,
            .workspace = "default",
            .environment = "production",
            .is_admin = false,
        };
    }

    fn handleListFlags(self: *Server, arena: std.mem.Allocator) !HttpResponse {
        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);

        try writer.writeAll("{\"flags\":[");
        var first = true;
        var it = self.hub.store.flags.iterator();
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

        return .{
            .status = .ok,
            .body = try arena.dupe(u8, writer.buffered()),
        };
    }

    fn handleCreateFlag(self: *Server, io: Io, arena: std.mem.Allocator, body: ?[]const u8, actor: []const u8) !HttpResponse {
        const raw_json = body orelse return .{
            .status = .bad_request,
            .body = "{\"error\":\"bad_request\",\"message\":\"Missing request body\"}",
        };

        const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_json, .{}) catch {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Invalid JSON\"}",
            };
        };

        const obj = parsed.value.object;
        const key = if (obj.get("key")) |k| (if (k == .string) k.string else "") else "";
        if (key.len == 0) {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Key is required\"}",
            };
        }

        const enabled = if (obj.get("enabled")) |e| (e == .bool and e.bool) else false;
        const rollout: u8 = if (obj.get("rollout_percentage")) |r| (if (r == .integer) @intCast(@min(100, r.integer)) else 100) else 100;

        self.hub.lock(io);
        defer self.hub.unlock(io);
        try self.hub.store.putFlag(key, .{
            .key = key,
            .enabled = enabled,
            .rollout_percentage = rollout,
        }, actor);
        _ = try self.hub.recordChangeLocked(io, key, false, enabled, rollout);

        return .{
            .status = .created,
            .body = try std.fmt.allocPrint(arena, "{{\"status\":\"created\",\"key\":\"{s}\"}}", .{key}),
        };
    }

    fn handleGetFlag(self: *Server, arena: std.mem.Allocator, key: []const u8) !HttpResponse {
        const flag = self.hub.store.getFlag(key) orelse return .{
            .status = .not_found,
            .body = "{\"error\":\"not_found\",\"message\":\"Flag not found\"}",
        };

        const body = try std.fmt.allocPrint(
            arena,
            "{{\"key\":\"{s}\",\"enabled\":{},\"rollout_percentage\":{d},\"version\":{d}}}",
            .{ flag.key, flag.enabled, flag.rollout_percentage, flag.version },
        );

        return .{
            .status = .ok,
            .body = body,
        };
    }

    fn handleDeleteFlag(self: *Server, io: Io, key: []const u8, actor: []const u8) !HttpResponse {
        self.hub.lock(io);
        defer self.hub.unlock(io);
        const deleted = try self.hub.store.deleteFlag(key, actor);
        if (deleted) {
            _ = try self.hub.recordChangeLocked(io, key, true, false, 0);
            return .{
                .status = .no_content,
                .body = "",
            };
        }
        return .{
            .status = .not_found,
            .body = "{\"error\":\"not_found\",\"message\":\"Flag not found\"}",
        };
    }

    fn handleListSegments(self: *Server, arena: std.mem.Allocator) !HttpResponse {
        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);

        try writer.writeAll("{\"segments\":[");
        var first = true;
        var it = self.hub.store.segments.iterator();
        while (it.next()) |entry| {
            if (!first) try writer.writeByte(',');
            first = false;
            try writer.print(
                "{{\"key\":\"{s}\",\"expression\":\"{s}\"}}",
                .{ entry.value_ptr.key, entry.value_ptr.expression },
            );
        }
        try writer.writeAll("]}");

        return .{
            .status = .ok,
            .body = try arena.dupe(u8, writer.buffered()),
        };
    }

    fn handleCreateSegment(self: *Server, io: Io, arena: std.mem.Allocator, body: ?[]const u8, actor: []const u8) !HttpResponse {
        const raw_json = body orelse return .{
            .status = .bad_request,
            .body = "{\"error\":\"bad_request\",\"message\":\"Missing request body\"}",
        };

        const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_json, .{}) catch {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Invalid JSON\"}",
            };
        };

        const obj = parsed.value.object;
        const key = if (obj.get("key")) |k| (if (k == .string) k.string else "") else "";
        const expr = if (obj.get("expression")) |e| (if (e == .string) e.string else "") else "";

        if (key.len == 0 or expr.len == 0) {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Key and expression are required\"}",
            };
        }

        self.hub.lock(io);
        defer self.hub.unlock(io);
        try self.hub.store.putSegment(key, expr, actor);

        return .{
            .status = .created,
            .body = try std.fmt.allocPrint(arena, "{{\"status\":\"created\",\"key\":\"{s}\"}}", .{key}),
        };
    }

    fn handleListEnvironments(self: *Server, arena: std.mem.Allocator) !HttpResponse {
        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);

        try writer.writeAll("{\"environments\":[");
        for (self.hub.store.environments.items, 0..) |env, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print("{{\"name\":\"{s}\",\"order\":{d}}}", .{ env.name, env.order });
        }
        try writer.writeAll("]}");

        return .{
            .status = .ok,
            .body = try arena.dupe(u8, writer.buffered()),
        };
    }

    fn handleListAudit(self: *Server, arena: std.mem.Allocator) !HttpResponse {
        var buf: [65536]u8 = undefined;
        var writer = Io.Writer.fixed(&buf);

        try writer.writeAll("{\"audit_events\":[");
        for (self.hub.store.audit_events.items, 0..) |evt, i| {
            if (i > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"id\":\"{s}\",\"action\":\"{s}\",\"target\":\"{s}\",\"actor\":\"{s}\",\"timestamp\":{d}}}",
                .{ evt.id, evt.action, evt.target_id, evt.actor, evt.timestamp },
            );
        }
        try writer.writeAll("]}");

        return .{
            .status = .ok,
            .body = try arena.dupe(u8, writer.buffered()),
        };
    }

    fn handleEval(self: *Server, io: Io, arena: std.mem.Allocator, body: ?[]const u8) !HttpResponse {
        const raw_json = body orelse return .{
            .status = .bad_request,
            .body = "{\"error\":\"bad_request\",\"message\":\"Missing body\"}",
        };

        const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_json, .{}) catch {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Invalid JSON\"}",
            };
        };

        const obj = parsed.value.object;
        const flag_key = if (obj.get("flag_key")) |k| (if (k == .string) k.string else "") else "";
        self.hub.lock(io);
        const flag_record = self.hub.store.getFlag(flag_key) orelse {
            self.hub.unlock(io);
            return .{
                .status = .not_found,
                .body = "{\"error\":\"not_found\",\"message\":\"Flag not found\"}",
            };
        };
        self.hub.unlock(io);

        var unit_id: []const u8 = "anonymous";
        if (obj.get("context")) |ctx_val| {
            if (ctx_val == .object) {
                if (ctx_val.object.get("unit_id")) |u| {
                    if (u == .string) unit_id = u.string;
                }
            }
        }

        const flag = doppio.Flag{
            .key = flag_record.key,
            .enabled = flag_record.enabled,
            .rollout_percentage = flag_record.rollout_percentage,
        };

        const eval_res = doppio.evaluate(flag, .{ .unit_id = unit_id });

        const resp_body = try std.fmt.allocPrint(
            arena,
            "{{\"flag_key\":\"{s}\",\"enabled\":{},\"bucket\":{d},\"reason\":\"{s}\"}}",
            .{ eval_res.flag_key, eval_res.enabled, eval_res.bucket, @tagName(eval_res.reason) },
        );

        return .{
            .status = .ok,
            .body = resp_body,
        };
    }

    /// GET /sync/snapshot -> full flag snapshot for cold-start clients.
    fn handleSyncSnapshot(self: *Server, io: Io, arena: std.mem.Allocator) !HttpResponse {
        self.hub.lock(io);
        const json = try self.hub.buildSnapshotLocked(arena);
        self.hub.unlock(io);
        return .{
            .status = .ok,
            .body = json,
        };
    }

    /// GET /sync/updates/{after_seq} -> long-poll delta, returns ack on timeout.
    /// The wait is deliberately bounded: long-poll is the stateless HTTP
    /// option, and a bound keeps proxies and idle-connection reapers happy.
    /// Clients that want unbounded push use /sync/ws or /sync/stream, which
    /// hold the connection open on their own threads (see main.zig).
    fn handleSyncUpdates(self: *Server, io: Io, arena: std.mem.Allocator, after_seq: u64) !HttpResponse {
        const result = try self.hub.waitForSeqPast(io, arena, after_seq, 1000);
        if (result.delta) |d| {
            return .{
                .status = .ok,
                .body = d.json,
            };
        }
        return .{
            .status = .ok,
            .body = try std.fmt.allocPrint(arena, "{{\"type\":\"ack\",\"seq\":{d}}}", .{self.hub.current_seq}),
        };
    }

    /// POST /collect -> ingest exposure events from client SDKs.
    fn handleCollect(self: *Server, io: Io, arena: std.mem.Allocator, body: ?[]const u8) !HttpResponse {
        const raw_json = body orelse return .{
            .status = .bad_request,
            .body = "{\"error\":\"bad_request\",\"message\":\"Missing request body\"}",
        };

        const parsed = std.json.parseFromSlice(std.json.Value, arena, raw_json, .{}) catch {
            return .{
                .status = .bad_request,
                .body = "{\"error\":\"bad_request\",\"message\":\"Invalid JSON\"}",
            };
        };

        const obj = parsed.value.object;
        var inputs: std.ArrayList(sync.ExposureInput) = .empty;
        defer inputs.deinit(arena);

        if (obj.get("events")) |evts| {
            if (evts == .array) {
                for (evts.array.items) |e| {
                    if (e != .object) continue;
                    const eo = e.object;
                    const flag_key = if (eo.get("flag_key")) |k| (if (k == .string) k.string else "") else "";
                    var unit_id = if (eo.get("user_id")) |u| (if (u == .string) u.string else "") else "anonymous";
                    const enabled = if (eo.get("enabled")) |en| (en == .bool and en.bool) else false;
                    const variation = if (eo.get("variation")) |v| (if (v == .string) v.string else null) else null;
                    const reason = if (eo.get("reason")) |r| (if (r == .string) r.string else "SDK") else "SDK";
                    var timestamp: i64 = 0;
                    if (eo.get("timestamp")) |t| {
                        if (t == .integer) timestamp = t.integer;
                    }
                    const bucket: u32 = 0;
                    if (eo.get("context")) |c| {
                        if (c == .object) {
                            if (c.object.get("unit_id")) |u| {
                                if (u == .string and unit_id.len == 0) unit_id = u.string;
                            }
                        }
                    }
                    var idem: []const u8 = "";
                    if (eo.get("idempotency_key")) |v| {
                        if (v == .string) idem = v.string;
                    }
                    if (idem.len == 0) {
                        idem = try std.fmt.allocPrint(arena, "{s}:{s}:{d}", .{ unit_id, flag_key, timestamp });
                    }

                    try inputs.append(arena, .{
                        .flag_key = flag_key,
                        .unit_id = unit_id,
                        .enabled = enabled,
                        .variation = variation,
                        .bucket = bucket,
                        .timestamp = timestamp,
                        .reason = reason,
                        .idempotency_key = idem,
                    });
                }
            }
        }

        const added = try self.hub.noteExposures(io, inputs.items);
        const count = self.hub.exposureCount(io);

        return .{
            .status = .ok,
            .body = try std.fmt.allocPrint(arena, "{{\"accepted\":{d},\"pending\":{d}}}", .{ added, count }),
        };
    }
    // ---------------------------------------------------------------------
    // Admin UI (Phase 1e): server-rendered HTML with HTMX partials.
    // ---------------------------------------------------------------------

    const FormField = struct {
        name: []const u8,
        value: []const u8,
    };

    fn percentDecode(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c == '%' and i + 2 < raw.len) {
                const hi = std.fmt.charToDigit(raw[i + 1], 16) catch {
                    try out.append(arena, c);
                    continue;
                };
                const lo = std.fmt.charToDigit(raw[i + 2], 16) catch {
                    try out.append(arena, c);
                    continue;
                };
                try out.append(arena, @as(u8, hi) * 16 + lo);
                i += 2;
            } else if (c == '+') {
                try out.append(arena, ' ');
            } else {
                try out.append(arena, c);
            }
        }
        return out.toOwnedSlice(arena);
    }

    fn parseForm(arena: std.mem.Allocator, body: []const u8) ![]FormField {
        var fields: std.ArrayList(FormField) = .empty;
        var it = std.mem.splitScalar(u8, body, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..@min(eq, pair.len)];
            const raw_value = if (eq < pair.len) pair[@min(eq + 1, pair.len)..] else "";
            try fields.append(arena, .{
                .name = try percentDecode(arena, raw_name),
                .value = try percentDecode(arena, raw_value),
            });
        }
        return fields.toOwnedSlice(arena);
    }

    fn formGet(fields: []const FormField, name: []const u8) ?[]const u8 {
        for (fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        return null;
    }

    /// Resolve the admin UI session from the bearer token carried in the
    /// doppio_admin cookie. Only admins may open the UI.
    fn adminSession(arena: std.mem.Allocator, token: ?[]const u8) !auth.AuthContext {
        const raw = token orelse return error.Unauthorized;
        if (raw.len == 0) return error.Unauthorized;

        if (auth.parseJwtClaims(arena, raw, 1700000000)) |ctx| {
            if (ctx.is_admin) return ctx;
            return error.Forbidden;
        } else |_| {}

        if (auth.verifyApiKey(raw, &.{})) |ctx| {
            if (ctx.is_admin) return ctx;
            return error.Forbidden;
        }
        return error.Unauthorized;
    }

    /// Extract one query parameter from a request target, e.g. the `q` in
    /// `/admin/audit?q=CHANGE_REQUEST`. The value is copied into the arena.
    fn queryParam(arena: std.mem.Allocator, target: []const u8, name: []const u8) !?[]const u8 {
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
        const pairs = target[q + 1 ..];
        var it = std.mem.splitScalar(u8, pairs, '&');
        while (it.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (std.mem.eql(u8, pair[0..eq], name)) {
                return try percentDecode(arena, pair[eq + 1 ..]);
            }
        }
        return null;
    }

    /// Merge query-string parameters into a form field list, so GET pages can
    /// read their filters with the same formGet helper as POST pages.
    fn fieldsWithQuery(
        arena: std.mem.Allocator,
        target: []const u8,
        body: ?[]const u8,
    ) ![]const FormField {
        const form_fields: []const FormField = if (body) |b| try parseForm(arena, b) else &.{};
        const q = std.mem.indexOfScalar(u8, target, '?') orelse return form_fields;
        const pairs = target[q + 1 ..];

        var fields: std.ArrayList(FormField) = try .initCapacity(arena, form_fields.len);
        for (form_fields) |field| try fields.append(arena, field);

        var it = std.mem.splitScalar(u8, pairs, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const raw_name = pair[0..@min(eq, pair.len)];
            const raw_value = if (eq < pair.len) pair[@min(eq + 1, pair.len)..] else "";
            try fields.append(arena, .{
                .name = try percentDecode(arena, raw_name),
                .value = try percentDecode(arena, raw_value),
            });
        }
        return fields.toOwnedSlice(arena);
    }

    fn htmlResponse(page: ui.Page) HttpResponse {
        return .{ .status = .ok, .content_type = page.content_type, .body = page.html };
    }

    fn loginRedirect(token: []const u8, arena: std.mem.Allocator) !HttpResponse {
        const cookie = try std.fmt.allocPrint(arena, "doppio_admin={s}; Path=/admin; HttpOnly; SameSite=Strict", .{token});
        return .{
            .status = .see_other,
            .location = "/admin/flags",
            .body = "",
            .set_cookie = cookie,
        };
    }

    /// Handle every /admin route. Returns Unauthorized pages rather than JSON
    /// so the browser experience stays coherent on session expiry.
    pub fn handleAdmin(
        self: *Server,
        io: Io,
        method: std.http.Method,
        path: []const u8,
        session_token: ?[]const u8,
        body: ?[]const u8,
        arena: std.mem.Allocator,
    ) !HttpResponse {
        // Routing compares the path only, so strip any query string up front.
        const route = if (std.mem.indexOfScalar(u8, path, '?')) |q| path[0..q] else path;

        // Public: the login screen and token exchange.
        if (std.mem.eql(u8, route, "/admin/login")) {
            if (method == .POST) {
                const raw = body orelse "";
                const fields = try parseForm(arena, raw);
                const token = formGet(fields, "token") orelse "";
                _ = adminSession(arena, token) catch {
                    return htmlResponse(try ui.loginPage(arena, "Invalid or non-admin token"));
                };
                return try loginRedirect(token, arena);
            }
            return htmlResponse(try ui.loginPage(arena, null));
        }

        const session = adminSession(arena, session_token) catch {
            return htmlResponse(try ui.loginPage(arena, "Admin session required"));
        };
        const actor: []const u8 = if (session.subject.len > 0) session.subject else "admin";
        const fields = try fieldsWithQuery(arena, path, body);

        // Pages
        if (method == .GET and (std.mem.eql(u8, route, "/admin") or std.mem.eql(u8, route, "/admin/"))) {
            return htmlResponse(try ui.dashboardPage(arena, &self.hub, Io.Timestamp.now(io, .real).toMilliseconds()));
        }
        if (method == .GET and std.mem.eql(u8, route, "/admin/flags")) {
            return htmlResponse(try ui.flagsPage(arena, &self.hub));
        }
        if (method == .GET and std.mem.startsWith(u8, route, "/admin/flags/new")) {
            return htmlResponse(try ui.newFlagPage(arena, null));
        }
        if (method == .GET and std.mem.eql(u8, route, "/admin/change-requests")) {
            return htmlResponse(try ui.changeRequestsPage(arena, &self.hub));
        }
        if (method == .GET and std.mem.eql(u8, route, "/admin/segments")) {
            return htmlResponse(try ui.segmentsPage(arena, &self.hub));
        }
        if (method == .GET and std.mem.eql(u8, route, "/admin/audit")) {
            return htmlResponse(try ui.auditPage(arena, &self.hub, .{
                .query = formGet(fields, "q") orelse "",
                .action = formGet(fields, "action") orelse "",
                .actor = formGet(fields, "actor") orelse "",
            }));
        }
        if (method == .GET and std.mem.startsWith(u8, route, "/admin/experiments")) {
            return self.handleExperiments(io, method, path, fields, arena, actor);
        }
        if (method == .POST and std.mem.startsWith(u8, route, "/admin/experiments")) {
            return self.handleExperiments(io, method, path, fields, arena, actor);
        }

        // HTMX fragment: filtered flag table.
        if (std.mem.startsWith(u8, path, "/admin/frag/flags")) {
            const frag = try renderFlagsFragment(arena, &self.hub, fields);
            return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = frag };
        }

        // Apply any scheduled change whose time has arrived before rendering,
        // so a release never needs a separate poller.
        _ = try admin.resolveDue(&self.hub, io, Io.Timestamp.now(io, .real).toMilliseconds(), actor);

        // Flag change requests
        if (method == .POST and std.mem.eql(u8, route, "/admin/flags")) {
            const key = formGet(fields, "key") orelse "";
            const is_enabled = if (formGet(fields, "enabled")) |v| std.mem.eql(u8, v, "on") else true;
            const rollout: u8 = if (formGet(fields, "rollout_percentage")) |v| (std.fmt.parseInt(u8, v, 10) catch 100) else 100;
            const required: u8 = if (formGet(fields, "required_approvals")) |v| (std.fmt.parseInt(u8, v, 10) catch 1) else 1;
            const schedule_ms = parseSchedule(io, fields);

            if (key.len == 0) {
                return htmlFragment(try ui.crResultFragment(arena, "Flag key is required", false));
            }

            self.hub.lock(io);
            const cr = try self.hub.change_requests.submit(.{
                .kind = .create,
                .flag_key = key,
                .enabled = is_enabled,
                .rollout_percentage = rollout,
                .actor = actor,
                .after = .{ .enabled = is_enabled, .rollout_percentage = rollout },
                .required_approvals = if (required == 0) 1 else required,
                .scheduled_at = schedule_ms,
                .now_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
            });
            try self.hub.store.recordAudit("CHANGE_REQUEST_CREATED", "flag", key, actor);
            self.hub.unlock(io);

            return htmlFragment(try crSummary(arena, cr));
        }

        // Flag delete (staged as a change request).
        if (method == .POST and std.mem.startsWith(u8, route, "/admin/flags/") and std.mem.endsWith(u8, path, "/delete")) {
            const key = path["/admin/flags/".len .. path.len - "/delete".len];
            self.hub.lock(io);
            _ = try self.hub.change_requests.submit(.{
                .kind = .delete,
                .flag_key = key,
                .actor = actor,
                .now_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
            });
            try self.hub.store.recordAudit("CHANGE_REQUEST_CREATED", "flag", key, actor);
            self.hub.unlock(io);

            return htmlFragment(try renderFlagsFragment(arena, &self.hub, &.{}));
        }

        // Flag detail page and the edit form.
        if (std.mem.startsWith(u8, route, "/admin/flags/") and std.mem.endsWith(u8, path, "/edit")) {
            const key = path["/admin/flags/".len .. path.len - "/edit".len];
            if (method == .POST) {
                const is_delete = if (formGet(fields, "delete")) |v| std.mem.eql(u8, v, "on") else false;
                const is_enabled = if (formGet(fields, "enabled")) |v| std.mem.eql(u8, v, "on") else true;
                const rollout: u8 = if (formGet(fields, "rollout_percentage")) |v| (std.fmt.parseInt(u8, v, 10) catch 100) else 100;
                const required: u8 = if (formGet(fields, "required_approvals")) |v| (std.fmt.parseInt(u8, v, 10) catch 1) else 1;
                const rules = formGet(fields, "rules");
                const prereqs = formGet(fields, "prerequisites");

                self.hub.lock(io);
                const cr = if (is_delete)
                    try self.hub.change_requests.submit(.{
                        .kind = .delete,
                        .flag_key = key,
                        .actor = actor,
                        .before = currentState(&self.hub, key),
                        .now_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
                    })
                else
                    try self.hub.change_requests.submit(.{
                        .kind = .update,
                        .flag_key = key,
                        .enabled = is_enabled,
                        .rollout_percentage = rollout,
                        .actor = actor,
                        .before = currentState(&self.hub, key),
                        .after = .{
                            .enabled = is_enabled,
                            .rollout_percentage = rollout,
                            .rules_json = rules,
                            .prerequisites_json = prereqs,
                        },
                        .required_approvals = if (required == 0) 1 else required,
                        .scheduled_at = parseSchedule(io, fields),
                        .now_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
                    });
                try self.hub.store.recordAudit("CHANGE_REQUEST_CREATED", "flag", key, actor);
                self.hub.unlock(io);

                return htmlFragment(try crSummary(arena, cr));
            }

            self.hub.lock(io);
            const record = self.hub.store.getFlag(key);
            const copy = if (record) |r| r else null;
            self.hub.unlock(io);
            return htmlResponse(try ui.editFlagPage(arena, key, copy, null));
        }

        // Flag detail: dependency graph, history, and blast radius.
        if (std.mem.startsWith(u8, route, "/admin/flags/")) {
            const key = path["/admin/flags/".len..];
            return htmlResponse(try ui.flagDetailPage(arena, &self.hub, key));
        }

        // Change request review: approve, reject, or roll a change back.
        if (method == .POST and std.mem.startsWith(u8, route, "/admin/change-requests/")) {
            const rest = path["/admin/change-requests/".len..];
            const approved = std.mem.endsWith(u8, rest, "/approve");
            const rejected = std.mem.endsWith(u8, rest, "/reject");
            const rolled_back = std.mem.endsWith(u8, rest, "/rollback");
            if (approved or rejected) {
                const id = rest[0 .. rest.len - if (approved) "/approve".len else "/reject".len];
                const now_ms = Io.Timestamp.now(io, .real).toMilliseconds();

                var message: []const u8 = "change request not found or already closed";
                var ok = false;
                var scheduled = false;

                if (rejected) {
                    ok = try admin.resolve(&self.hub, io, id, false, actor, now_ms);
                    if (ok) message = "change request rejected";
                } else {
                    self.hub.lock(io);
                    const outcome = self.hub.change_requests.approve(id, actor);
                    const required = if (self.hub.change_requests.find(id)) |cr| cr.required_approvals else 0;
                    const recorded = if (self.hub.change_requests.find(id)) |cr| cr.approvalCount() else 0;
                    const scheduled_at = if (self.hub.change_requests.find(id)) |cr| cr.scheduled_at else 0;
                    self.hub.unlock(io);

                    switch (outcome) {
                        .closed => message = "change request not found or already closed",
                        .duplicate => {
                            ok = true;
                            message = "you already approved this change request";
                        },
                        .recorded => {
                            ok = true;
                            message = try std.fmt.allocPrint(arena, "approval recorded ({d} of {d} required)", .{ recorded, required });
                        },
                        .ready => {
                            ok = try admin.resolve(&self.hub, io, id, true, actor, now_ms);
                            scheduled = scheduled_at > now_ms;
                            message = if (scheduled) "approved and scheduled for its release time" else "approved and applied";
                        },
                    }
                }

                self.hub.lock(io);
                const body_row = if (self.hub.change_requests.find(id)) |cr|
                    try ui.changeRequestRowFragment(arena, cr.*)
                else
                    try ui.crResultFragment(arena, message, ok);
                self.hub.unlock(io);
                return htmlFragment(body_row);
            }
            if (rolled_back) {
                const flag_key = rest[0 .. rest.len - "/rollback".len];
                const staged = try admin.stageRollback(&self.hub, io, flag_key, actor, 1, Io.Timestamp.now(io, .real).toMilliseconds());
                if (staged) |cr| {
                    self.hub.lock(io);
                    try self.hub.store.recordAudit("CHANGE_REQUEST_CREATED", "flag", flag_key, actor);
                    self.hub.unlock(io);
                    return htmlFragment(try crSummary(arena, cr));
                }
                return htmlFragment(try ui.crResultFragment(arena, "no applied change to roll back", false));
            }
        }

        // Segments: create, delete, and the CEL console.
        if (method == .POST and std.mem.eql(u8, route, "/admin/segments")) {
            const key = formGet(fields, "key") orelse "";
            const expression = formGet(fields, "expression") orelse "";
            if (key.len == 0 or expression.len == 0) {
                return htmlFragment(try ui.crResultFragment(arena, "Segment key and expression are required", false));
            }

            // Reject a broken CEL expression before it reaches the store.
            // Parse errors surface from the same engine the SDKs use.
            const context = doppio.Context{ .unit_id = "doppio-validate" };
            const well_formed = if (doppio.cel.evaluate(expression, context)) |_| true else |_| false;
            if (!well_formed) {
                return htmlFragment(try ui.crResultFragment(arena, "Expression is not valid CEL", false));
            }

            self.hub.lock(io);
            try self.hub.store.putSegment(key, expression, actor);
            self.hub.unlock(io);

            return htmlFragment(try renderSegmentRow(arena, key, expression));
        }

        if (method == .POST and std.mem.eql(u8, route, "/admin/segments/console")) {
            const expression = formGet(fields, "expression") orelse "";
            const unit_id = formGet(fields, "unit_id") orelse "";
            const attrs = try ui.parseConsoleAttributes(arena, formGet(fields, "attributes") orelse "");
            return htmlFragment(try ui.consoleResult(arena, expression, unit_id, attrs));
        }

        if (method == .POST and std.mem.startsWith(u8, route, "/admin/segments/") and std.mem.endsWith(u8, path, "/delete")) {
            const key = path["/admin/segments/".len .. path.len - "/delete".len];
            self.hub.lock(io);
            _ = self.hub.store.removeSegment(key);
            try self.hub.store.recordAudit("SEGMENT_DELETE", "segment", key, actor);
            self.hub.unlock(io);
            return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = "" };
        }

        // Audit log: searchable, filterable, and exportable as CSV.
        if (std.mem.eql(u8, route, "/admin/audit/export")) {
            self.hub.lock(io);
            const csv = try self.hub.store.exportAuditCsv(arena, .{
                .query = formGet(fields, "q") orelse "",
                .action = formGet(fields, "action") orelse "",
                .actor = formGet(fields, "actor") orelse "",
            });
            self.hub.unlock(io);
            return .{ .status = .ok, .content_type = "text/csv; charset=utf-8", .body = csv };
        }

        // Hash-chain verification of the append-only audit log.
        if (std.mem.eql(u8, route, "/admin/audit/verify")) {
            self.hub.lock(io);
            const report = self.hub.store.verifyAuditChain();
            const frag = try ui.auditVerifyFragment(arena, report);
            self.hub.unlock(io);
            return htmlFragment(frag);
        }

        return .{
            .status = .not_found,
            .body = "{\"error\":\"not_found\",\"message\":\"Admin route not found\"}",
        };
    }

    fn htmlFragment(body: []const u8) HttpResponse {
        return .{ .status = .ok, .content_type = "text/html; charset=utf-8", .body = body };
    }

    /// Experiment wizard: list, create, detail, and lifecycle transitions.
    fn handleExperiments(
        self: *Server,
        io: Io,
        method: std.http.Method,
        path: []const u8,
        fields: []const FormField,
        arena: std.mem.Allocator,
        actor: []const u8,
    ) !HttpResponse {
        const rest = path["/admin/experiments".len..];

        // Create.
        if (method == .POST and std.mem.eql(u8, rest, "")) {
            const hypothesis = formGet(fields, "hypothesis") orelse "";
            const flag_key = formGet(fields, "flag_key") orelse "";
            const primary_metric = formGet(fields, "primary_metric") orelse "";
            if (hypothesis.len == 0 or flag_key.len == 0 or primary_metric.len == 0) {
                return htmlFragment(try ui.crResultFragment(arena, "Hypothesis, flag key, and primary metric are required", false));
            }

            const baseline = std.fmt.parseFloat(f64, formGet(fields, "baseline_rate") orelse "0") catch 0;
            const mde = std.fmt.parseFloat(f64, formGet(fields, "mde") orelse "0") catch 0;
            const power = std.fmt.parseFloat(f64, formGet(fields, "power") orelse "0.8") catch 0.8;
            const guardrails = try ui.parseGuardrails(arena, formGet(fields, "guardrails") orelse "");

            if (baseline <= 0 or baseline >= 1 or mde <= 0) {
                return htmlFragment(try ui.crResultFragment(arena, "Baseline rate must be between 0 and 1, and the effect must be positive", false));
            }

            self.hub.lock(io);
            const exp = try self.hub.experiments.submit(.{
                .hypothesis = hypothesis,
                .flag_key = flag_key,
                .primary_metric = primary_metric,
                .owner = actor,
                .baseline_rate = baseline,
                .mde = mde,
                .power = power,
                .guardrails = guardrails,
                .now_ms = Io.Timestamp.now(io, .real).toMilliseconds(),
            });
            const copy = exp;
            self.hub.unlock(io);

            const message = try std.fmt.allocPrint(arena, "{s} created: {d} units per arm", .{ copy.id, copy.required_sample });
            return htmlFragment(try ui.crResultFragment(arena, message, true));
        }

        // New experiment form.
        if (method == .GET and std.mem.eql(u8, rest, "/new")) {
            return htmlResponse(try ui.newExperimentPage(arena, null));
        }

        // Lifecycle advance.
        if (method == .POST and std.mem.endsWith(u8, rest, "/advance")) {
            const id = rest[0 .. rest.len - "/advance".len];
            self.hub.lock(io);
            const advanced = self.hub.experiments.advance(id);
            const detail = if (self.hub.experiments.find(id)) |exp| try arena.dupe(u8, exp.id) else null;
            self.hub.unlock(io);
            if (!advanced or detail == null) {
                return htmlFragment(try ui.crResultFragment(arena, "Experiment is already concluded", false));
            }
            return htmlFragment(try ui.crResultFragment(arena, "status updated", true));
        }

        // Detail page.
        if (method == .GET and rest.len > 1) {
            const id = rest[1..];
            self.hub.lock(io);
            const found = if (self.hub.experiments.find(id)) |exp| exp.* else null;
            self.hub.unlock(io);
            if (found) |exp| {
                return htmlResponse(try ui.experimentDetailPage(arena, exp));
            }
        }

        // List.
        if (method == .GET) {
            return htmlResponse(try ui.experimentsPage(arena, &self.hub));
        }

        return .{
            .status = .not_found,
            .body = "{\"error\":\"not_found\",\"message\":\"Admin route not found\"}",
        };
    }

    /// Read a scheduled apply time from the form. Three shapes are accepted:
    /// an empty value (apply now), a delay in seconds (`+3600`), or an
    /// absolute epoch-milliseconds value.
    fn parseSchedule(io: Io, fields: []const FormField) i64 {
        const raw = formGet(fields, "scheduled_at") orelse return 0;
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) return 0;
        if (trimmed[0] == '+') {
            const seconds = std.fmt.parseInt(i64, trimmed[1..], 10) catch return 0;
            if (seconds <= 0) return 0;
            return Io.Timestamp.now(io, .real).toMilliseconds() + seconds * 1000;
        }
        const absolute = std.fmt.parseInt(i64, trimmed, 10) catch return 0;
        return if (absolute > 10_000_000_000) absolute else 0;
    }

    /// Snapshot the live state of a flag for the change-request diff.
    fn currentState(hub: *sync.SyncHub, key: []const u8) ?admin.FlagState {
        const record = hub.store.getFlag(key) orelse return null;
        return .{
            .enabled = record.enabled,
            .rollout_percentage = record.rollout_percentage,
            .rules_json = record.rules_json,
            .prerequisites_json = record.prerequisites_json,
        };
    }

    fn crSummary(arena: std.mem.Allocator, cr: admin.ChangeRequest) ![]const u8 {
        const message = try std.fmt.allocPrint(arena, "{s} staged: {s} ({s})", .{ cr.kind.label(), cr.detail, cr.id });
        return ui.crResultFragment(arena, message, true);
    }

    fn renderFlagsFragment(arena: std.mem.Allocator, hub: *const sync.SyncHub, fields: []const FormField) ![]const u8 {
        var alloc: Io.Writer.Allocating = .init(arena);
        const out: *Io.Writer = &alloc.writer;

        const query = formGet(fields, "q") orelse "";
        try out.writeAll("<table><thead><tr><th>Key</th><th>State</th><th>Rollout</th><th>Version</th><th></th></tr></thead><tbody id=\"flag-rows\">\n");
        var any = false;
        var it = hub.store.flags.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.deleted) continue;
            if (query.len > 0 and std.mem.indexOf(u8, entry.value_ptr.key, query) == null) continue;
            any = true;
            try out.writeAll("<tr><td><code>");
            try ui.escapeHtml(out, entry.value_ptr.key);
            try out.writeAll("</code></td><td>");
            if (entry.value_ptr.enabled) {
                try out.writeAll("<span class=\"pill on\">on</span>");
            } else {
                try out.writeAll("<span class=\"pill off\">off</span>");
            }
            try out.writeAll("</td>");
            try out.print("<td>{d}%</td><td>v{d}</td>", .{ entry.value_ptr.rollout_percentage, entry.value_ptr.version });
            try out.writeAll("<td class=\"actions\"><span class=\"muted\">filtered</span></td></tr>\n");
        }
        if (!any) {
            try out.writeAll("<tr><td colspan=\"5\" class=\"empty\">No matching flags.</td></tr>\n");
        }
        try out.writeAll("</tbody></table>\n");

        var list = alloc.toArrayList();
        return list.toOwnedSlice(arena);
    }

    fn renderSegmentRow(arena: std.mem.Allocator, key: []const u8, expression: []const u8) ![]const u8 {
        var alloc: Io.Writer.Allocating = .init(arena);
        const out: *Io.Writer = &alloc.writer;
        try out.writeAll("<tr><td><code>");
        try ui.escapeHtml(out, key);
        try out.writeAll("</code></td><td><code>");
        try ui.escapeHtml(out, expression);
        try out.writeAll("</code></td><td class=\"actions\"><span class=\"muted\">created</span></td></tr>\n");
        var list = alloc.toArrayList();
        return list.toOwnedSlice(arena);
    }
};

test "server admin routes: login gate, staged change request, and approval" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const admin_token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

    // Unauthenticated access bounces to the login page, never the data.
    const gated = try srv.handleAdmin(io, .GET, "/admin/flags", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, gated.status);
    try std.testing.expect(std.mem.indexOf(u8, gated.body, "Admin session required") != null);
    try std.testing.expect(std.mem.indexOf(u8, gated.body, "login") != null);

    // A non-admin token is rejected the same way.
    const non_admin = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJncmVlZHkiLCJleHAiOjIwMDAwMDAwMDAwfQ.sig";
    const rejected = try srv.handleAdmin(io, .GET, "/admin/flags", non_admin, null, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, rejected.body, "Admin session required") != null);

    // Login exchanges the token for a session cookie.
    const login = try srv.handleAdmin(
        io,
        .POST,
        "/admin/login",
        null,
        try std.fmt.allocPrint(arena.allocator(), "token={s}", .{admin_token}),
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.see_other, login.status);
    try std.testing.expect(login.set_cookie != null);
    try std.testing.expect(std.mem.indexOf(u8, login.set_cookie.?, "doppio_admin=") != null);
    try std.testing.expectEqualStrings("/admin/flags", login.location.?);

    // Flags page renders for the session.
    const flags_page = try srv.handleAdmin(io, .GET, "/admin/flags", admin_token, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, flags_page.status);
    try std.testing.expect(std.mem.indexOf(u8, flags_page.body, "Feature flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, flags_page.body, "aria-current") != null);
    try std.testing.expect(flags_page.content_type.len > 0 and std.mem.startsWith(u8, flags_page.content_type, "text/html"));

    // Staging a create does not touch the store until approval.
    const staged = try srv.handleAdmin(
        io,
        .POST,
        "/admin/flags",
        admin_token,
        "key=staged-flag&enabled=on&rollout_percentage=80",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, staged.body, "staged") != null);
    try std.testing.expect(std.mem.indexOf(u8, staged.body, "cr-1") != null);
    try std.testing.expect(srv.hub.store.getFlag("staged-flag") == null);
    try std.testing.expectEqual(@as(usize, 1), srv.hub.change_requests.counts().pending);

    // Approval applies it and advances the sync sequence.
    const approved = try srv.handleAdmin(io, .POST, "/admin/change-requests/cr-1/approve", admin_token, "", arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, approved.body, "applied") != null);
    try std.testing.expect(std.mem.indexOf(u8, approved.body, "staged-flag") != null);
    const flag = srv.hub.store.getFlag("staged-flag");
    try std.testing.expect(flag != null);
    try std.testing.expect(flag.?.enabled);
    try std.testing.expectEqual(@as(u8, 80), flag.?.rollout_percentage);
    try std.testing.expectEqual(@as(usize, 0), srv.hub.change_requests.counts().pending);

    // The approval is recorded in the audit log.
    const audit = try srv.handleAdmin(io, .GET, "/admin/audit", admin_token, null, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, audit.body, "CHANGE_REQUEST_APPROVED") != null);

    // A second approve is a no-op: the row reflects the already closed state
    // and the applied change is untouched.
    const twice = try srv.handleAdmin(io, .POST, "/admin/change-requests/cr-1/approve", admin_token, "", arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, twice.body, "closed") != null);
    try std.testing.expect(std.mem.indexOf(u8, twice.body, "Approve") == null);
    const after = srv.hub.store.getFlag("staged-flag");
    try std.testing.expect(after != null);
    try std.testing.expectEqual(@as(u8, 80), after.?.rollout_percentage);
}

test "server admin routes: delete and rejection keep the store untouched" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const admin_token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

    // Seed a live flag through the API first.
    const created = try srv.handle(
        io,
        .POST,
        "/api/v1/flags",
        "Bearer " ++ admin_token,
        "{\"key\":\"keep-me\",\"enabled\":true,\"rollout_percentage\":100}",
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.created, created.status);

    // Stage a delete, then reject it: the flag survives.
    const staged = try srv.handleAdmin(io, .POST, "/admin/flags/keep-me/delete", admin_token, "", arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, staged.status);

    _ = try srv.handleAdmin(io, .POST, "/admin/change-requests/cr-1/reject", admin_token, "", arena.allocator());
    try std.testing.expect(srv.hub.store.getFlag("keep-me") != null);

    // Approving a delete removes the flag.
    _ = try srv.handleAdmin(io, .POST, "/admin/flags/keep-me/delete", admin_token, "", arena.allocator());
    _ = try srv.handleAdmin(io, .POST, "/admin/change-requests/cr-2/approve", admin_token, "", arena.allocator());
    try std.testing.expect(srv.hub.store.getFlag("keep-me") == null);
}

test "server admin routes: segment create, console evaluation, and delete" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const admin_token = "eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.sig";

    // A valid CEL segment is created and rendered as a row.
    const created = try srv.handleAdmin(
        io,
        .POST,
        "/admin/segments",
        admin_token,
        "key=enterprise&expression=account.plan+%3D%3D+%22enterprise%22",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, created.body, "created") != null);
    try std.testing.expect(srv.hub.store.segments.contains("enterprise"));

    // A malformed expression is refused and leaves the store alone.
    const bad = try srv.handleAdmin(
        io,
        .POST,
        "/admin/segments",
        admin_token,
        "key=broken&expression=this+%28%28is+not+valid",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, bad.body, "not valid CEL") != null);
    try std.testing.expect(!srv.hub.store.segments.contains("broken"));

    // The console evaluates a matching expression to TRUE.
    const yes = try srv.handleAdmin(
        io,
        .POST,
        "/admin/segments/console",
        admin_token,
        "expression=unit_id+%3D%3D+%22user-123%22&unit_id=user-123",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, yes.body, "TRUE") != null);

    // Extra attributes make segment expressions testable, not just unit_id.
    const withAttrs = try srv.handleAdmin(
        io,
        .POST,
        "/admin/segments/console",
        admin_token,
        "expression=account.plan+%3D%3D+%22enterprise%22&unit_id=u-1&attributes=account.plan%3Denterprise",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, withAttrs.body, "TRUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, withAttrs.body, "account.plan = enterprise") != null);

    const no = try srv.handleAdmin(
        io,
        .POST,
        "/admin/segments/console",
        admin_token,
        "expression=unit_id+%3D%3D+%22other%22&unit_id=user-123",
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, no.body, "FALSE") != null);

    // Deleting frees the segment copy and records the action.
    _ = try srv.handleAdmin(io, .POST, "/admin/segments/enterprise/delete", admin_token, "", arena.allocator());
    try std.testing.expect(!srv.hub.store.segments.contains("enterprise"));
}

test "parseForm decodes percent escapes and plus signs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const fields = try Server.parseForm(arena.allocator(), "key=a+b%20c&expression=x+%3D%3D+%22y%22&empty=");
    try std.testing.expectEqual(@as(usize, 3), fields.len);
    try std.testing.expectEqualStrings("a b c", Server.formGet(fields, "key").?);
    try std.testing.expectEqualStrings("x == \"y\"", Server.formGet(fields, "expression").?);
    try std.testing.expectEqualStrings("", Server.formGet(fields, "empty").?);
    try std.testing.expect(Server.formGet(fields, "missing") == null);
}

test "server handles health check and openapi spec" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const health = try srv.handle(io, .GET, "/health", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, health.status);
    try std.testing.expect(std.mem.indexOf(u8, health.body, "\"status\":\"ok\"") != null);

    const spec = try srv.handle(io, .GET, "/openapi.json", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, spec.status);
    try std.testing.expect(std.mem.indexOf(u8, spec.body, "3.1.0") != null);
}

test "server flag lifecycle: create, list, get, eval, delete" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create flag as Admin
    try srv.enforcer.addRoleForUser("admin-user", "Admin", "default");
    const create_res = try srv.handle(
        io,
        .POST,
        "/api/v1/flags",
        "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMH0.sig",
        "{\"key\":\"feature-dark-mode\",\"enabled\":true,\"rollout_percentage\":100}",
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.created, create_res.status);

    // List flags
    const list_res = try srv.handle(io, .GET, "/api/v1/flags", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, list_res.status);
    try std.testing.expect(std.mem.indexOf(u8, list_res.body, "feature-dark-mode") != null);

    // Evaluate flag
    const eval_res = try srv.handle(
        io,
        .POST,
        "/api/v1/eval",
        null,
        "{\"flag_key\":\"feature-dark-mode\",\"context\":{\"unit_id\":\"u-42\"}}",
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.ok, eval_res.status);
    try std.testing.expect(std.mem.indexOf(u8, eval_res.body, "\"enabled\":true") != null);

    // Delete flag
    const del_res = try srv.handle(
        io,
        .DELETE,
        "/api/v1/flags/feature-dark-mode",
        "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMH0.sig",
        null,
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.no_content, del_res.status);

    // Check audit log
    const audit_res = try srv.handle(
        io,
        .GET,
        "/api/v1/audit",
        "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMH0.sig",
        null,
        arena.allocator(),
    );
    try std.testing.expect(std.mem.indexOf(u8, audit_res.body, "FLAG_UPDATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, audit_res.body, "FLAG_DELETE") != null);
}

test "server sync endpoints: snapshot, updates long-poll, collect" {
    const io = std.testing.io;
    var srv = try Server.init(std.testing.allocator);
    defer srv.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Create a flag (admin), which advances the seq.
    const create_res = try srv.handle(
        io,
        .POST,
        "/api/v1/flags",
        "Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbi11c2VyIiwiZXhwIjoyMDAwMDAwMDAwMH0.sig",
        "{\"key\":\"sync-flag\",\"enabled\":true,\"rollout_percentage\":100}",
        arena.allocator(),
    );
    try std.testing.expectEqual(std.http.Status.created, create_res.status);

    // Snapshot includes the new flag.
    const snap = try srv.handle(io, .GET, "/sync/snapshot", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, snap.status);
    try std.testing.expect(std.mem.indexOf(u8, snap.body, "sync-flag") != null);

    // Ingest an exposure via /collect.
    const collect_body =
        "{\"events\":[{\"flag_key\":\"sync-flag\",\"user_id\":\"u-1\",\"enabled\":true,\"variation\":\"on\",\"timestamp\":1700000001,\"idempotency_key\":\"k-1\"}]}";
    const collect_res = try srv.handle(io, .POST, "/collect", null, collect_body, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, collect_res.status);
    try std.testing.expect(std.mem.indexOf(u8, collect_res.body, "\"accepted\":1") != null);

    // Re-send the same idempotency key -> deduplicated, accepted 0.
    const dedup_res = try srv.handle(io, .POST, "/collect", null, collect_body, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, dedup_res.body, "\"accepted\":0") != null);

    // Long-poll /sync/updates/1 returns the pending delta immediately.
    const updates = try srv.handle(io, .GET, "/sync/updates/1", null, null, arena.allocator());
    try std.testing.expectEqual(std.http.Status.ok, updates.status);
    try std.testing.expect(std.mem.indexOf(u8, updates.body, "\"type\":\"delta\"") != null);
}
