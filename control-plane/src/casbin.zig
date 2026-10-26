const std = @import("std");

pub const Action = enum {
    read,
    write,
    delete,
    admin,
    all,

    pub fn fromString(s: []const u8) Action {
        if (std.mem.eql(u8, s, "read")) return .read;
        if (std.mem.eql(u8, s, "write")) return .write;
        if (std.mem.eql(u8, s, "delete")) return .delete;
        if (std.mem.eql(u8, s, "admin")) return .admin;
        if (std.mem.eql(u8, s, "*") or std.mem.eql(u8, s, "all")) return .all;
        return .read;
    }

    pub fn toString(self: Action) []const u8 {
        return switch (self) {
            .read => "read",
            .write => "write",
            .delete => "delete",
            .admin => "admin",
            .all => "*",
        };
    }

    pub fn allows(self: Action, requested: Action) bool {
        if (self == .all or self == .admin) return true;
        if (self == requested) return true;
        return false;
    }
};

pub const PolicyRule = struct {
    sub: []const u8,
    dom: []const u8,
    obj: []const u8,
    act: Action,
};

pub const RoleBinding = struct {
    user: []const u8,
    role: []const u8,
    dom: []const u8,
};

pub const Enforcer = struct {
    allocator: std.mem.Allocator,
    policies: std.ArrayList(PolicyRule),
    bindings: std.ArrayList(RoleBinding),

    pub fn init(allocator: std.mem.Allocator) Enforcer {
        return .{
            .allocator = allocator,
            .policies = .empty,
            .bindings = .empty,
        };
    }

    pub fn deinit(self: *Enforcer) void {
        self.policies.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
    }

    pub fn addPolicy(self: *Enforcer, sub: []const u8, dom: []const u8, obj: []const u8, act: Action) !void {
        try self.policies.append(self.allocator, .{
            .sub = sub,
            .dom = dom,
            .obj = obj,
            .act = act,
        });
    }

    pub fn addRoleForUser(self: *Enforcer, user: []const u8, role: []const u8, dom: []const u8) !void {
        try self.bindings.append(self.allocator, .{
            .user = user,
            .role = role,
            .dom = dom,
        });
    }

    pub fn loadDefaultRbac(self: *Enforcer, dom: []const u8) !void {
        // Owner permissions
        try self.addPolicy("Owner", dom, "*", .all);

        // Admin permissions
        try self.addPolicy("Admin", dom, "flags", .all);
        try self.addPolicy("Admin", dom, "segments", .all);
        try self.addPolicy("Admin", dom, "environments", .all);
        try self.addPolicy("Admin", dom, "change-requests", .all);
        try self.addPolicy("Admin", dom, "audit", .read);

        // Editor permissions
        try self.addPolicy("Editor", dom, "flags", .read);
        try self.addPolicy("Editor", dom, "flags", .write);
        try self.addPolicy("Editor", dom, "segments", .read);
        try self.addPolicy("Editor", dom, "segments", .write);
        try self.addPolicy("Editor", dom, "change-requests", .read);
        try self.addPolicy("Editor", dom, "change-requests", .write);
        try self.addPolicy("Editor", dom, "environments", .read);

        // Viewer permissions
        try self.addPolicy("Viewer", dom, "flags", .read);
        try self.addPolicy("Viewer", dom, "segments", .read);
        try self.addPolicy("Viewer", dom, "environments", .read);
        try self.addPolicy("Viewer", dom, "audit", .read);
    }

    pub fn enforce(self: *const Enforcer, sub: []const u8, dom: []const u8, obj: []const u8, act: Action) bool {
        // Check direct policy rules for subject
        if (self.checkPolicy(sub, dom, obj, act)) return true;

        // Check roles assigned to subject
        for (self.bindings.items) |b| {
            if (std.mem.eql(u8, b.user, sub) and (std.mem.eql(u8, b.dom, dom) or std.mem.eql(u8, b.dom, "*"))) {
                if (self.checkPolicy(b.role, dom, obj, act)) return true;

                // Handle role hierarchy
                if (std.mem.eql(u8, b.role, "Owner")) {
                    if (self.checkPolicy("Admin", dom, obj, act)) return true;
                    if (self.checkPolicy("Editor", dom, obj, act)) return true;
                    if (self.checkPolicy("Viewer", dom, obj, act)) return true;
                } else if (std.mem.eql(u8, b.role, "Admin")) {
                    if (self.checkPolicy("Editor", dom, obj, act)) return true;
                    if (self.checkPolicy("Viewer", dom, obj, act)) return true;
                } else if (std.mem.eql(u8, b.role, "Editor")) {
                    if (self.checkPolicy("Viewer", dom, obj, act)) return true;
                }
            }
        }

        return false;
    }

    fn checkPolicy(self: *const Enforcer, sub: []const u8, dom: []const u8, obj: []const u8, act: Action) bool {
        for (self.policies.items) |p| {
            if (!std.mem.eql(u8, p.sub, sub) and !std.mem.eql(u8, p.sub, "*")) continue;
            if (!std.mem.eql(u8, p.dom, dom) and !std.mem.eql(u8, p.dom, "*")) continue;

            const obj_match = std.mem.eql(u8, p.obj, "*") or
                std.mem.eql(u8, p.obj, obj) or
                (std.mem.endsWith(u8, p.obj, "*") and std.mem.startsWith(u8, obj, p.obj[0 .. p.obj.len - 1]));

            if (obj_match and p.act.allows(act)) {
                return true;
            }
        }
        return false;
    }
};

test "casbin RBAC: standard hierarchy and permission checks" {
    var enforcer = Enforcer.init(std.testing.allocator);
    defer enforcer.deinit();

    try enforcer.loadDefaultRbac("default");

    try enforcer.addRoleForUser("alice", "Owner", "default");
    try enforcer.addRoleForUser("bob", "Admin", "default");
    try enforcer.addRoleForUser("charlie", "Editor", "default");
    try enforcer.addRoleForUser("david", "Viewer", "default");

    // Viewer tests
    try std.testing.expect(enforcer.enforce("david", "default", "flags", .read));
    try std.testing.expect(!enforcer.enforce("david", "default", "flags", .write));
    try std.testing.expect(!enforcer.enforce("david", "default", "flags", .delete));

    // Editor tests
    try std.testing.expect(enforcer.enforce("charlie", "default", "flags", .read));
    try std.testing.expect(enforcer.enforce("charlie", "default", "flags", .write));
    try std.testing.expect(!enforcer.enforce("charlie", "default", "environments", .write));

    // Admin tests
    try std.testing.expect(enforcer.enforce("bob", "default", "flags", .delete));
    try std.testing.expect(enforcer.enforce("bob", "default", "environments", .write));

    // Owner tests
    try std.testing.expect(enforcer.enforce("alice", "default", "anything", .delete));
}
