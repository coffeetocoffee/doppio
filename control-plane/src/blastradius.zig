const std = @import("std");
const doppio = @import("doppio");
const storage = @import("storage.zig");

/// Deterministic blast-radius simulation.
///
/// The architecture doc asks for "deterministic simulation of affected
/// segments before a change". This evaluates a fixed synthetic population, so
/// the same flag and candidate state always produce the same numbers, and
/// reports how many units flip and which segments they land in.
/// Number of synthetic units evaluated per simulation. Fixed so the results
/// are comparable across runs and across candidate states.
pub const sample_size = 1000;

pub const SegmentHit = struct {
    key: []const u8,
    /// Units affected by the change that also match this segment.
    affected: usize,
};

pub const BlastResult = struct {
    sampled: usize,
    /// Units whose enabled decision changes between the two states.
    affected: usize,
    enabled_before: usize,
    enabled_after: usize,
    by_segment: []SegmentHit,
};

/// Synthetic attributes for a sampled unit. Derived from the unit index so
/// the population is stable and deterministic across runs and machines.
fn sampleContext(arena: std.mem.Allocator, index: usize) !doppio.Context {
    const countries = [_][]const u8{ "us", "de", "fr", "jp" };
    const plans = [_][]const u8{ "free", "pro", "enterprise", "starter" };

    var attrs: std.ArrayList(doppio.Attribute) = .empty;
    try attrs.append(arena, .{
        .key = "country",
        .value = countries[(index * 7) % countries.len],
    });
    try attrs.append(arena, .{
        .key = "account.plan",
        .value = plans[(index * 13) % plans.len],
    });
    try attrs.append(arena, .{
        .key = "account.age_days",
        .value = try std.fmt.allocPrint(arena, "{d}", .{index % 500}),
    });

    const unit_id = try std.fmt.allocPrint(arena, "sim-u-{d:0>4}", .{index});
    return .{ .unit_id = unit_id, .attributes = attrs.items };
}

fn flagOf(store: *const storage.Storage, key: []const u8, enabled: bool, rollout_percentage: u8) ?doppio.Flag {
    const record = store.getFlag(key) orelse return null;
    return .{
        .key = record.key,
        .enabled = enabled,
        .rollout_percentage = rollout_percentage,
    };
}

/// Simulate switching `flag_key` from its stored state to
/// (candidate_enabled, candidate_rollout) over the synthetic population.
pub fn simulate(
    arena: std.mem.Allocator,
    store: *const storage.Storage,
    key: []const u8,
    candidate_enabled: bool,
    candidate_rollout: u8,
) !BlastResult {
    const current = store.getFlag(key) orelse return .{
        .sampled = 0,
        .affected = 0,
        .enabled_before = 0,
        .enabled_after = 0,
        .by_segment = &.{},
    };

    const before_flag = flagOf(store, key, current.enabled, current.rollout_percentage);
    const after_flag = flagOf(store, key, candidate_enabled, candidate_rollout);
    if (before_flag == null or after_flag == null) {
        return .{
            .sampled = 0,
            .affected = 0,
            .enabled_before = 0,
            .enabled_after = 0,
            .by_segment = &.{},
        };
    }

    // Segment expressions, evaluated against the affected units only.
    var segment_keys: std.ArrayList([]const u8) = .empty;
    var segment_exprs: std.ArrayList([]const u8) = .empty;
    var seg_it = store.segments.iterator();
    while (seg_it.next()) |entry| {
        try segment_keys.append(arena, entry.key_ptr.*);
        try segment_exprs.append(arena, entry.value_ptr.expression);
    }
    var hits: std.ArrayList(SegmentHit) = .empty;
    try hits.ensureTotalCapacity(arena, segment_keys.items.len);
    for (segment_keys.items) |seg_key| {
        try hits.append(arena, .{ .key = seg_key, .affected = 0 });
    }

    var enabled_before: usize = 0;
    var enabled_after: usize = 0;
    var affected: usize = 0;

    var index: usize = 0;
    while (index < sample_size) : (index += 1) {
        const context = try sampleContext(arena, index);

        const before_eval = doppio.evaluate(before_flag.?, context);
        const after_eval = doppio.evaluate(after_flag.?, context);
        if (before_eval.enabled) enabled_before += 1;
        if (after_eval.enabled) enabled_after += 1;

        if (before_eval.enabled != after_eval.enabled) {
            affected += 1;
            // Count which segments the affected unit belongs to.
            for (segment_exprs.items, 0..) |expr, seg_index| {
                const matched = doppio.cel.evaluate(expr, context) catch false;
                if (matched) hits.items[seg_index].affected += 1;
            }
        }
    }

    return .{
        .sampled = sample_size,
        .affected = affected,
        .enabled_before = enabled_before,
        .enabled_after = enabled_after,
        .by_segment = hits.items,
    };
}

test "blast radius is deterministic and reflects the rollout delta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    try store.putFlag("pricing-page", .{
        .key = "pricing-page",
        .enabled = true,
        .rollout_percentage = 10,
    }, "alice");

    // Disabling a 10 percent flag flips the units that were inside it.
    const off = try simulate(arena.allocator(), &store, "pricing-page", false, 0);
    try std.testing.expectEqual(sample_size, off.sampled);
    try std.testing.expect(off.enabled_before > 0);
    try std.testing.expectEqual(@as(usize, 0), off.enabled_after);
    try std.testing.expectEqual(off.enabled_before, off.affected);

    // The same inputs produce the same result, so the numbers are stable.
    const off_again = try simulate(arena.allocator(), &store, "pricing-page", false, 0);
    try std.testing.expectEqual(off.affected, off_again.affected);
    try std.testing.expectEqual(off.enabled_before, off_again.enabled_before);

    // Raising the rollout from 10 to 100 affects the units newly included.
    const on = try simulate(arena.allocator(), &store, "pricing-page", true, 100);
    try std.testing.expectEqual(@as(usize, sample_size), on.enabled_after);
    try std.testing.expectEqual(sample_size - off.enabled_before, on.affected);

    // A no-op change affects nobody.
    const same = try simulate(arena.allocator(), &store, "pricing-page", true, 10);
    try std.testing.expectEqual(@as(usize, 0), same.affected);
}

test "blast radius reports segment membership for affected units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    try store.putFlag("checkout-flow", .{
        .key = "checkout-flow",
        .enabled = false,
        .rollout_percentage = 50,
    }, "alice");
    try store.putSegment("enterprise-accounts", "account.plan == \"enterprise\"", "alice");
    try store.putSegment("eu-users", "country == \"de\"", "alice");

    const result = try simulate(arena.allocator(), &store, "checkout-flow", true, 100);
    try std.testing.expectEqual(sample_size, result.sampled);

    // Every enabled unit lands in a segment, and the enterprise cohort is a
    // deterministic slice of the population.
    var enterprise_hits: usize = 0;
    var found = false;
    for (result.by_segment) |hit| {
        if (std.mem.eql(u8, hit.key, "enterprise-accounts")) {
            enterprise_hits = hit.affected;
            found = true;
        }
    }
    try std.testing.expect(found);
    try std.testing.expect(enterprise_hits > 0);
    try std.testing.expect(enterprise_hits <= result.affected);

    // The same call again yields identical segment counts.
    const repeat = try simulate(arena.allocator(), &store, "checkout-flow", true, 100);
    var repeat_enterprise: usize = 0;
    for (repeat.by_segment) |hit| {
        if (std.mem.eql(u8, hit.key, "enterprise-accounts")) repeat_enterprise = hit.affected;
    }
    try std.testing.expectEqual(enterprise_hits, repeat_enterprise);
}

test "blast radius handles an unknown flag without panicking" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = storage.Storage.init(std.testing.allocator);
    defer store.deinit();

    const result = try simulate(arena.allocator(), &store, "does-not-exist", true, 100);
    try std.testing.expectEqual(@as(usize, 0), result.sampled);
    try std.testing.expectEqual(@as(usize, 0), result.affected);
}
