const std = @import("std");

pub const AuthType = enum {
    oidc_jwt,
    api_key,
    public_client_key,
    anonymous,
};

pub const AuthContext = struct {
    subject: []const u8,
    auth_type: AuthType,
    workspace: []const u8 = "default",
    environment: []const u8 = "production",
    roles: []const []const u8 = &.{},
    is_admin: bool = false,

    pub fn hasRole(self: AuthContext, role: []const u8) bool {
        if (self.is_admin) return true;
        for (self.roles) |r| {
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }
};

pub const ApiKeyScope = enum {
    admin,
    workspace,
    environment_write,
    environment_read,
    client_read,

    pub fn allowsWrite(self: ApiKeyScope) bool {
        return self == .admin or self == .workspace or self == .environment_write;
    }

    pub fn allowsRead(_: ApiKeyScope) bool {
        return true;
    }
};

pub const StoredApiKey = struct {
    id: []const u8,
    name: []const u8,
    key_hash: [32]u8,
    scope: ApiKeyScope,
    workspace: []const u8,
    environment: ?[]const u8 = null,
    created_at: i64,
};

pub fn hashApiKey(key: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &out, .{});
    return out;
}

pub fn parseJwtClaims(
    allocator: std.mem.Allocator,
    token: []const u8,
    current_time_secs: i64,
) !AuthContext {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidJwtFormat; // header
    const payload_b64 = parts.next() orelse return error.InvalidJwtFormat; // payload

    // Decode base64url payload
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return error.InvalidBase64;
    const payload_buf = try allocator.alloc(u8, decoded_len);
    defer allocator.free(payload_buf);

    try std.base64.url_safe_no_pad.Decoder.decode(payload_buf, payload_b64);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload_buf, .{}) catch return error.InvalidJson;
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;

    // Verify expiration if present
    if (obj.get("exp")) |exp_val| {
        if (exp_val == .integer) {
            if (exp_val.integer < current_time_secs) {
                return error.TokenExpired;
            }
        }
    }

    const sub = if (obj.get("sub")) |s| (if (s == .string) try allocator.dupe(u8, s.string) else "user") else "user";
    const is_admin = if (obj.get("admin")) |a| (a == .bool and a.bool) else false;

    return .{
        .subject = sub,
        .auth_type = .oidc_jwt,
        .is_admin = is_admin,
    };
}

pub fn verifyApiKey(
    raw_key: []const u8,
    stored_keys: []const StoredApiKey,
) ?AuthContext {
    const hash = hashApiKey(raw_key);
    for (stored_keys) |k| {
        if (std.mem.eql(u8, &k.key_hash, &hash)) {
            const is_admin = (k.scope == .admin);
            const auth_type: AuthType = if (k.scope == .client_read) .public_client_key else .api_key;
            return .{
                .subject = k.name,
                .auth_type = auth_type,
                .workspace = k.workspace,
                .environment = k.environment orelse "production",
                .is_admin = is_admin,
            };
        }
    }
    return null;
}

test "API key hashing and verification" {
    const key = "pk_live_doppio_secret_12345";
    const hash = hashApiKey(key);

    const stored = [_]StoredApiKey{
        .{
            .id = "key-1",
            .name = "backend-service",
            .key_hash = hash,
            .scope = .admin,
            .workspace = "default",
            .created_at = 1700000000,
        },
    };

    const ctx = verifyApiKey(key, &stored);
    try std.testing.expect(ctx != null);
    try std.testing.expectEqualStrings("backend-service", ctx.?.subject);
    try std.testing.expect(ctx.?.is_admin);

    const invalid_ctx = verifyApiKey("wrong_key", &stored);
    try std.testing.expect(invalid_ctx == null);
}

test "JWT claims parsing and expiration check" {
    // Header: {"alg":"none","typ":"JWT"} -> eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0
    // Payload: {"sub":"alice","exp":2000000000,"admin":true}
    // Base64url payload: eyJzdWIiOiJhbGljZSIsImV4cCI6MjAwMDAwMDAwMCwiYWRtaW4iOnRydWV9
    const test_jwt = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiJhbGljZSIsImV4cCI6MjAwMDAwMDAwMCwiYWRtaW4iOnRydWV9.signature";

    const ctx = try parseJwtClaims(std.testing.allocator, test_jwt, 1700000000);
    defer std.testing.allocator.free(ctx.subject);

    try std.testing.expectEqualStrings("alice", ctx.subject);
    try std.testing.expect(ctx.is_admin);

    // Test expired token
    try std.testing.expectError(
        error.TokenExpired,
        parseJwtClaims(std.testing.allocator, test_jwt, 2500000000),
    );
}
