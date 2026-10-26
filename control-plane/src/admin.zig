const std = @import("std");
const sync = @import("sync.zig");
const storage = @import("storage.zig");

const Io = std.Io;

pub const ChangeKind = enum {
    create,
    update,
    delete,
    segment,

    pub fn label(self: ChangeKind) []const u8 {
        return @tagName(self);
    }
};

pub const ChangeStatus = enum {
    pending,
    approved,
    rejected,
    applied,
    expired,
};

/// Immutable snapshot of the fields the diff view renders.
pub const FlagState = struct {
    enabled: bool = false,
    rollout_percentage: u8 = 0,
    rules_json: ?[]const u8 = null,
    prerequisites_json: ?[]const u8 = null,
};

pub const ApprovalOutcome = enum {
    /// Approval recorded but the request still needs more approvers.
    recorded,
    /// The last required approval landed; the request is ready to apply.
    ready,
    /// The request is closed, so no approval was recorded.
    closed,
    /// The same subject already approved this request.
    duplicate,
};

/// A staged, reviewable mutation. Nothing touches the flag store until a
/// change request reaches its required approval count.
pub const ChangeRequest = struct {
    id: []const u8,
    kind: ChangeKind,
    flag_key: []const u8,
    detail: []const u8,
    actor: []const u8,
    enabled: bool = true,
    rollout_percentage: u8 = 100,
    expression: ?[]const u8 = null,
    status: ChangeStatus = .pending,
    /// Diff pair: the state before the change and the state after. The before
    /// side is null for a create, which has no prior state.
    before: ?FlagState = null,
    after: FlagState = .{},
    approvals: std.ArrayList([]const u8),
    required_approvals: u8 = 1,
    /// Monotonic milliseconds when the approved change should be applied.
    /// Zero means apply immediately.
    scheduled_at: i64 = 0,
    applied_at: i64 = 0,
    created_at: i64 = 0,
    idempotency_key: ?[]const u8 = null,

    pub fn approvalCount(self: *const ChangeRequest) usize {
        return self.approvals.items.len;
    }
};

pub const ChangeRequestCounts = struct {
    pending: usize = 0,
    approved: usize = 0,
    applied: usize = 0,
    rejected: usize = 0,
    scheduled: usize = 0,
    total: usize = 0,
};

/// Everything needed to stage a change request.
pub const ChangeSpec = struct {
    kind: ChangeKind,
    flag_key: []const u8,
    enabled: bool = true,
    rollout_percentage: u8 = 100,
    expression: ?[]const u8 = null,
    actor: []const u8,
    before: ?FlagState = null,
    after: FlagState = .{},
    required_approvals: u8 = 1,
    /// Monotonic milliseconds when the approved change should be applied.
    /// Zero means apply immediately.
    scheduled_at: i64 = 0,
    /// Overrides the generated detail line, used by rollback to say so.
    detail_override: ?[]const u8 = null,
    /// Zero means now.
    now_ms: i64 = 0,
};

pub const ChangeQueue = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ChangeRequest),
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) ChangeQueue {
        return .{ .allocator = allocator, .items = .empty };
    }

    pub fn deinit(self: *ChangeQueue) void {
        for (self.items.items) |*cr| self.freeFields(cr);
        self.items.deinit(self.allocator);
    }

    fn freeFields(self: *ChangeQueue, cr: *ChangeRequest) void {
        self.allocator.free(cr.id);
        self.allocator.free(cr.flag_key);
        self.allocator.free(cr.detail);
        self.allocator.free(cr.actor);
        if (cr.expression) |expr| self.allocator.free(expr);
        if (cr.before) |before| {
            if (before.rules_json) |json| self.allocator.free(json);
            if (before.prerequisites_json) |json| self.allocator.free(json);
        }
        if (cr.after.rules_json) |json| self.allocator.free(json);
        if (cr.after.prerequisites_json) |json| self.allocator.free(json);
        for (cr.approvals.items) |approver| self.allocator.free(approver);
        cr.approvals.deinit(self.allocator);
    }

    /// Stage a change request, copying every string into the queue's own
    /// storage so the result stays valid after the request arena is freed.
    pub fn submit(self: *ChangeQueue, spec: ChangeSpec) !ChangeRequest {
        const id = try std.fmt.allocPrint(self.allocator, "cr-{d}", .{self.next_id});
        errdefer self.allocator.free(id);
        const owned_key = try self.allocator.dupe(u8, spec.flag_key);
        errdefer self.allocator.free(owned_key);
        const owned_actor = try self.allocator.dupe(u8, spec.actor);
        errdefer self.allocator.free(owned_actor);
        const owned_expr = if (spec.expression) |expr| try self.allocator.dupe(u8, expr) else null;
        errdefer if (owned_expr) |expr| self.allocator.free(expr);

        var before: ?FlagState = null;
        if (spec.before) |b| {
            before = .{
                .enabled = b.enabled,
                .rollout_percentage = b.rollout_percentage,
                .rules_json = if (b.rules_json) |json| try self.allocator.dupe(u8, json) else null,
            };
        }
        errdefer if (before) |b| {
            if (b.rules_json) |json| self.allocator.free(json);
        };

        const after: FlagState = .{
            .enabled = spec.after.enabled,
            .rollout_percentage = spec.after.rollout_percentage,
            .rules_json = if (spec.after.rules_json) |json| try self.allocator.dupe(u8, json) else null,
            .prerequisites_json = if (spec.after.prerequisites_json) |json| try self.allocator.dupe(u8, json) else null,
        };
        errdefer if (after.rules_json) |json| self.allocator.free(json);
        errdefer if (after.prerequisites_json) |json| self.allocator.free(json);

        const detail = if (spec.detail_override) |override|
            try self.allocator.dupe(u8, override)
        else
            try buildDetail(
                self.allocator,
                spec.kind,
                owned_key,
                owned_expr,
                spec.enabled,
                spec.rollout_percentage,
            );
        errdefer self.allocator.free(detail);

        var approvals: std.ArrayList([]const u8) = .empty;
        errdefer approvals.deinit(self.allocator);

        try self.items.append(self.allocator, .{
            .id = id,
            .kind = spec.kind,
            .flag_key = owned_key,
            .detail = detail,
            .actor = owned_actor,
            .enabled = spec.enabled,
            .rollout_percentage = spec.rollout_percentage,
            .expression = owned_expr,
            .before = before,
            .after = after,
            .approvals = approvals,
            .required_approvals = spec.required_approvals,
            .scheduled_at = spec.scheduled_at,
            .created_at = spec.now_ms,
        });
        self.next_id += 1;

        return self.items.items[self.items.items.len - 1];
    }

    fn buildDetail(
        allocator: std.mem.Allocator,
        kind: ChangeKind,
        key: []const u8,
        expression: ?[]const u8,
        enabled: bool,
        rollout: u8,
    ) ![]const u8 {
        return switch (kind) {
            .create => std.fmt.allocPrint(allocator, "create {s} ({s}, rollout {d}%)", .{
                key, if (enabled) "enabled" else "disabled", rollout,
            }),
            .update => std.fmt.allocPrint(allocator, "update {s} ({s}, rollout {d}%)", .{
                key, if (enabled) "enabled" else "disabled", rollout,
            }),
            .delete => std.fmt.allocPrint(allocator, "delete {s}", .{key}),
            .segment => std.fmt.allocPrint(allocator, "segment {s} matches {s}", .{
                key, expression orelse "(no expression)",
            }),
        };
    }

    pub fn find(self: *ChangeQueue, id: []const u8) ?*ChangeRequest {
        for (self.items.items) |*cr| {
            if (std.mem.eql(u8, cr.id, id)) return cr;
        }
        return null;
    }

    /// Record an approval. The request only leaves pending once its distinct
    /// approver count reaches `required_approvals`.
    pub fn approve(self: *ChangeQueue, id: []const u8, subject: []const u8) ApprovalOutcome {
        const cr = self.find(id) orelse return .closed;
        if (cr.status != .pending and cr.status != .approved) return .closed;
        for (cr.approvals.items) |approver| {
            if (std.mem.eql(u8, approver, subject)) return .duplicate;
        }
        const owned = self.allocator.dupe(u8, subject) catch return .closed;
        cr.approvals.append(self.allocator, owned) catch {
            self.allocator.free(owned);
            return .closed;
        };
        if (cr.approvals.items.len >= cr.required_approvals) {
            cr.status = .approved;
            return .ready;
        }
        return .recorded;
    }

    pub fn reject(self: *ChangeQueue, id: []const u8) bool {
        const cr = self.find(id) orelse return false;
        if (cr.status != .pending and cr.status != .approved) return false;
        cr.status = .rejected;
        return true;
    }

    pub fn setStatus(self: *ChangeQueue, id: []const u8, status: ChangeStatus) bool {
        const cr = self.find(id) orelse return false;
        cr.status = status;
        return true;
    }

    pub fn counts(self: *const ChangeQueue) ChangeRequestCounts {
        var c = ChangeRequestCounts{};
        for (self.items.items) |cr| {
            c.total += 1;
            switch (cr.status) {
                .pending => c.pending += 1,
                .approved => c.approved += 1,
                .applied => c.applied += 1,
                .rejected => c.rejected += 1,
                .expired => {},
            }
            if (cr.status == .approved and cr.scheduled_at > 0) c.scheduled += 1;
        }
        return c;
    }

    /// Most recent approved or applied change for a flag, used to build a
    /// rollback request that restores the earlier state.
    pub fn lastAppliedFor(self: *const ChangeQueue, flag_key: []const u8) ?*const ChangeRequest {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const cr = &self.items.items[i];
            if (std.mem.eql(u8, cr.flag_key, flag_key) and
                (cr.status == .applied or cr.status == .approved))
            {
                return cr;
            }
        }
        return null;
    }

    /// Every change request touching a flag, newest first. Feeds the flag
    /// detail history table.
    pub fn historyFor(self: *const ChangeQueue, flag_key: []const u8, out: *std.ArrayList(*const ChangeRequest)) !void {
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const cr = &self.items.items[i];
            if (std.mem.eql(u8, cr.flag_key, flag_key)) try out.append(self.allocator, cr);
        }
    }
};

/// Close a change request and, when approved and due, apply it to the store.
/// The store mutation, sync change record, and audit entry land under one lock.
pub fn resolve(
    hub: *sync.SyncHub,
    io: Io,
    id: []const u8,
    approved: bool,
    actor: []const u8,
    now_ms: i64,
) !bool {
    hub.lock(io);
    const cr = hub.change_requests.find(id) orelse {
        hub.unlock(io);
        return false;
    };
    if (cr.status != .pending and cr.status != .approved) {
        hub.unlock(io);
        return false;
    }

    if (approved) {
        if (cr.status == .pending) {
            cr.status = .approved;
            try hub.store.recordAudit("CHANGE_REQUEST_APPROVED", "change_request", cr.id, actor);
        }
        if (cr.scheduled_at > now_ms) {
            // Approved but scheduled for a future time; nothing to apply yet.
            hub.unlock(io);
            return true;
        }
        try applyLocked(hub, io, cr, actor, now_ms);
    } else {
        cr.status = .rejected;
        try hub.store.recordAudit("CHANGE_REQUEST_REJECTED", "change_request", cr.id, actor);
    }

    hub.unlock(io);
    return true;
}

fn applyLocked(hub: *sync.SyncHub, io: Io, cr: *ChangeRequest, actor: []const u8, now_ms: i64) !void {
    switch (cr.kind) {
        .create, .update => {
            // The queue owns these strings for the lifetime of the hub, so the
            // store can reference them without a second copy.
            try hub.store.putFlagVersioned(cr.flag_key, .{
                .key = cr.flag_key,
                .enabled = cr.enabled,
                .rollout_percentage = cr.rollout_percentage,
                .rules_json = cr.after.rules_json,
                .prerequisites_json = cr.after.prerequisites_json,
            }, actor, now_ms);
            _ = try hub.recordChangeLocked(io, cr.flag_key, false, cr.enabled, cr.rollout_percentage);
        },
        .delete => {
            _ = try hub.store.deleteFlag(cr.flag_key, actor);
            _ = try hub.recordChangeLocked(io, cr.flag_key, true, false, 0);
        },
        .segment => {
            try hub.store.putSegment(cr.flag_key, cr.expression orelse "", actor);
        },
    }

    cr.status = .applied;
    cr.applied_at = now_ms;
    try hub.store.recordAudit("CHANGE_REQUEST_APPLIED", "change_request", cr.id, actor);
}

/// Apply every approved change whose scheduled time has arrived. Callers bump
/// this from the request loop so a scheduled release lands without a poller.
pub fn resolveDue(hub: *sync.SyncHub, io: Io, now_ms: i64, actor: []const u8) !usize {
    hub.lock(io);
    defer hub.unlock(io);

    var applied: usize = 0;
    for (hub.change_requests.items.items) |*cr| {
        if (cr.status != .approved) continue;
        if (cr.scheduled_at > 0 and cr.scheduled_at > now_ms) continue;
        try applyLocked(hub, io, cr, actor, now_ms);
        applied += 1;
    }
    return applied;
}

/// Stage a rollback to the state a flag had before its most recent applied
/// change, giving the one-click revert described in the architecture doc.
pub fn stageRollback(
    hub: *sync.SyncHub,
    io: Io,
    flag_key: []const u8,
    actor: []const u8,
    required_approvals: u8,
    now_ms: i64,
) !?ChangeRequest {
    hub.lock(io);
    defer hub.unlock(io);

    const target = hub.change_requests.lastAppliedFor(flag_key) orelse return null;
    const restore = target.before orelse return null;
    const current = hub.store.getFlag(flag_key) orelse return null;

    return try hub.change_requests.submit(.{
        .kind = .update,
        .flag_key = flag_key,
        .enabled = restore.enabled,
        .rollout_percentage = restore.rollout_percentage,
        .actor = actor,
        .detail_override = "rollback to the state before the last applied change",
        .before = .{
            .enabled = current.enabled,
            .rollout_percentage = current.rollout_percentage,
            .rules_json = current.rules_json,
        },
        .after = .{
            .enabled = restore.enabled,
            .rollout_percentage = restore.rollout_percentage,
            .rules_json = restore.rules_json,
            .prerequisites_json = restore.prerequisites_json,
        },
        .required_approvals = required_approvals,
        .now_ms = now_ms,
    });
}

test "change request requires every configured approval before applying" {
    const io = std.testing.io;
    var hub = sync.SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    const spec = ChangeSpec{
        .kind = .create,
        .flag_key = "gated-flag",
        .enabled = true,
        .rollout_percentage = 40,
        .actor = "alice",
        .before = null,
        .after = .{ .enabled = true, .rollout_percentage = 40 },
        .required_approvals = 2,
        .now_ms = 1,
    };
    _ = try hub.change_requests.submit(spec);

    // One approval is not enough to leave pending, and nothing is applied.
    try std.testing.expectEqual(ApprovalOutcome.recorded, hub.change_requests.approve("cr-1", "alice"));
    try std.testing.expect(hub.store.getFlag("gated-flag") == null);
    try std.testing.expectEqual(@as(usize, 1), hub.change_requests.counts().pending);

    // The same subject twice does not count twice.
    try std.testing.expectEqual(ApprovalOutcome.duplicate, hub.change_requests.approve("cr-1", "alice"));

    // A second distinct approver satisfies the requirement.
    try std.testing.expectEqual(ApprovalOutcome.ready, hub.change_requests.approve("cr-1", "bob"));
    try std.testing.expectEqual(@as(usize, 1), hub.change_requests.counts().approved);

    // Applying happens through resolve, which records the apply.
    try std.testing.expect(try resolve(&hub, io, "cr-1", true, "carol", 2));
    const flag = hub.store.getFlag("gated-flag");
    try std.testing.expect(flag != null);
    try std.testing.expectEqual(@as(u8, 40), flag.?.rollout_percentage);
    try std.testing.expectEqual(ChangeStatus.applied, hub.change_requests.find("cr-1").?.status);

    // Approving an applied request changes nothing.
    try std.testing.expectEqual(ApprovalOutcome.closed, hub.change_requests.approve("cr-1", "dave"));
}

test "scheduled apply waits for its due time and then lands" {
    const io = std.testing.io;
    var hub = sync.SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    _ = try hub.change_requests.submit(.{
        .kind = .update,
        .flag_key = "scheduled-flag",
        .enabled = false,
        .rollout_percentage = 10,
        .actor = "alice",
        .required_approvals = 1,
        .scheduled_at = 5_000,
        .now_ms = 1,
    });

    // Approve far before the due time.
    _ = hub.change_requests.approve("cr-1", "alice");
    try std.testing.expectEqual(@as(usize, 0), try resolveDue(&hub, io, 1_000, "alice"));
    try std.testing.expect(hub.change_requests.find("cr-1").?.status == .approved);
    try std.testing.expectEqual(@as(usize, 1), hub.change_requests.counts().scheduled);

    // Once the due time passes the release applies.
    try std.testing.expectEqual(@as(usize, 1), try resolveDue(&hub, io, 10_000, "alice"));
    try std.testing.expect(hub.change_requests.find("cr-1").?.status == .applied);

    // A second run does not double-apply.
    try std.testing.expectEqual(@as(usize, 0), try resolveDue(&hub, io, 20_000, "alice"));
}

test "rollback restores the state before the last applied change" {
    const io = std.testing.io;
    var hub = sync.SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    // Create at 60 percent, then update to 5 percent, both applied.
    _ = try hub.change_requests.submit(.{
        .kind = .create,
        .flag_key = "revert-flag",
        .enabled = true,
        .rollout_percentage = 60,
        .actor = "alice",
        .before = null,
        .after = .{ .enabled = true, .rollout_percentage = 60 },
        .now_ms = 1,
    });
    try std.testing.expect(try resolve(&hub, io, "cr-1", true, "alice", 2));

    _ = try hub.change_requests.submit(.{
        .kind = .update,
        .flag_key = "revert-flag",
        .enabled = false,
        .rollout_percentage = 5,
        .actor = "alice",
        .before = .{ .enabled = true, .rollout_percentage = 60 },
        .after = .{ .enabled = false, .rollout_percentage = 5 },
        .now_ms = 3,
    });
    try std.testing.expect(try resolve(&hub, io, "cr-2", true, "alice", 4));
    const updated = hub.store.getFlag("revert-flag");
    try std.testing.expectEqual(@as(u8, 5), updated.?.rollout_percentage);
    try std.testing.expect(!updated.?.enabled);

    // Rollback stages a request aimed at the pre-update state.
    const rollback = try stageRollback(&hub, io, "revert-flag", "alice", 1, 5);
    try std.testing.expect(rollback != null);
    try std.testing.expectEqualStrings("revert-flag", rollback.?.flag_key);
    try std.testing.expectEqual(@as(u8, 60), rollback.?.rollout_percentage);
    try std.testing.expect(rollback.?.enabled);

    // The diff pair describes the rollback in both directions.
    try std.testing.expectEqual(@as(u8, 5), rollback.?.before.?.rollout_percentage);
    try std.testing.expect(!rollback.?.before.?.enabled);
    try std.testing.expectEqual(@as(u8, 60), rollback.?.after.rollout_percentage);
    try std.testing.expect(rollback.?.after.enabled);

    try std.testing.expect(try resolve(&hub, io, rollback.?.id, true, "alice", 6));
    const reverted = hub.store.getFlag("revert-flag");
    try std.testing.expectEqual(@as(u8, 60), reverted.?.rollout_percentage);
    try std.testing.expect(reverted.?.enabled);
}

test "rollback returns null when a flag has no applied change" {
    const io = std.testing.io;
    var hub = sync.SyncHub.init(std.testing.allocator);
    defer hub.deinit();

    try std.testing.expect((try stageRollback(&hub, io, "never-changed", "alice", 1, 1)) == null);
}

test "audit chain is intact and detects tampering" {
    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    try store.putFlag("chain-flag", .{ .key = "chain-flag", .enabled = true }, "alice");
    try store.recordAudit("FLAG_DELETE", "flag", "chain-flag", "bob");

    const before = store.verifyAuditChain();
    try std.testing.expect(before.ok);
    try std.testing.expectEqual(@as(usize, 2), before.checked);

    // Rewriting a past record breaks the link at that record.
    store.audit_events.items[0].action = "FLAG_CREATED";
    const after = store.verifyAuditChain();
    try std.testing.expect(!after.ok);
    try std.testing.expectEqualStrings("evt_1", after.first_broken_id.?);
}

test "audit search filters and CSV export quotes fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    try store.recordAudit("FLAG_UPDATE", "flag", "checkout, v2", "alice");
    try store.recordAudit("FLAG_DELETE", "flag", "old-flag", "bob");
    try store.recordAudit("SEGMENT_CREATE", "segment", "eu", "alice");

    // Newest first, filtered by actor.
    var mine: std.ArrayList(storage.AuditRecord) = .empty;
    defer mine.deinit(std.testing.allocator);
    try store.searchAudit(.{ .actor = "alice" }, &mine);
    try std.testing.expectEqual(@as(usize, 2), mine.items.len);
    try std.testing.expectEqualStrings("SEGMENT_CREATE", mine.items[0].action);

    // Substring query matches the target id too.
    var by_target: std.ArrayList(storage.AuditRecord) = .empty;
    defer by_target.deinit(std.testing.allocator);
    try store.searchAudit(.{ .query = "old-flag" }, &by_target);
    try std.testing.expectEqual(@as(usize, 1), by_target.items.len);

    // CSV quotes a target id containing a comma and emits the hash column.
    const csv = try store.exportAuditCsv(arena.allocator(), .{ .query = "checkout" });
    try std.testing.expect(std.mem.indexOf(u8, csv, "\"checkout, v2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv, "FLAG_UPDATE") != null);
    const second_line = std.mem.indexOf(u8, csv, "\n").? + 1;
    const fields = csv[second_line .. csv.len - 1];
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, fields, ","));
}

test "flag dependencies come from prerequisites and segment references" {
    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    // child-flag declares a prerequisite on parent-flag, so the edge points
    // from parent to child.
    try store.putFlag("parent-flag", .{ .key = "parent-flag", .enabled = true }, "alice");
    try store.putFlag("child-flag", .{
        .key = "child-flag",
        .enabled = true,
        .prerequisites_json = "[{\"flagKey\":\"parent-flag\",\"variationKey\":\"on\"}]",
    }, "alice");

    var edges: std.ArrayList(storage.DependencyEdge) = .empty;
    defer edges.deinit(store.allocator);
    defer store.freeDependencyEdges(edges.items);
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(store.allocator);
    try store.flagDependencies("child-flag", &edges, &segments);
    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    try std.testing.expectEqualStrings("parent-flag", edges.items[0].from_key);
    try std.testing.expectEqualStrings("child-flag", edges.items[0].to_key);
    try std.testing.expectEqualStrings("on", edges.items[0].variation_key);

    // A flag with no prerequisites yields no edges.
    var none_edges: std.ArrayList(storage.DependencyEdge) = .empty;
    defer none_edges.deinit(store.allocator);
    defer store.freeDependencyEdges(none_edges.items);
    var none_segs: std.ArrayList([]const u8) = .empty;
    defer none_segs.deinit(store.allocator);
    try store.flagDependencies("parent-flag", &none_edges, &none_segs);
    try std.testing.expectEqual(@as(usize, 0), none_edges.items.len);

    // A rule expression naming the segment creates the reverse link.
    try store.putSegment("enterprise-accounts", "account.plan == \"enterprise\"", "alice");
    try store.putFlag("ruled", .{
        .key = "ruled",
        .enabled = true,
        .rules_json = "[{\"expression\":\"segment(enterprise-accounts)\"}]",
    }, "alice");
    var edges2: std.ArrayList(storage.DependencyEdge) = .empty;
    defer edges2.deinit(store.allocator);
    defer store.freeDependencyEdges(edges2.items);
    var segments2: std.ArrayList([]const u8) = .empty;
    defer segments2.deinit(store.allocator);
    try store.flagDependencies("ruled", &edges2, &segments2);
    try std.testing.expectEqual(@as(usize, 1), segments2.items.len);
    try std.testing.expectEqualStrings("enterprise-accounts", segments2.items[0]);

    // child-flag is a dependent of parent-flag.
    const dependents = try store.dependentsOf("parent-flag");
    var dep_list = dependents;
    defer dep_list.deinit(store.allocator);
    try std.testing.expectEqual(@as(usize, 1), dep_list.items.len);
    try std.testing.expectEqualStrings("child-flag", dep_list.items[0]);
}
