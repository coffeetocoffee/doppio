const std = @import("std");

pub const bucket_count: u32 = 100_000;

pub fn bucket(key: []const u8, salt: []const u8, buckets: u32) u32 {
    const num_buckets = if (buckets == 0) bucket_count else buckets;
    var hasher = std.hash.XxHash32.init(0);
    if (salt.len > 0) {
        hasher.update(salt);
        hasher.update(&[_]u8{0});
    }
    hasher.update(key);
    return hasher.final() % num_buckets;
}

pub fn bucketUnit(flag_key: []const u8, unit_id: []const u8) u32 {
    return bucket(unit_id, flag_key, bucket_count);
}

pub fn inRollout(flag_key: []const u8, unit_id: []const u8, percentage: u8) bool {
    if (percentage == 0) return false;
    if (percentage >= 100) return true;
    const threshold: u32 = @as(u32, percentage) * 1000;
    return bucketUnit(flag_key, unit_id) < threshold;
}

pub fn inRolloutWithSalt(key: []const u8, salt: []const u8, percentage: u8, buckets: u32) bool {
    if (percentage == 0) return false;
    if (percentage >= 100) return true;
    const num_buckets = if (buckets == 0) bucket_count else buckets;
    const threshold: u32 = @as(u32, percentage) * (num_buckets / 100);
    return bucket(key, salt, num_buckets) < threshold;
}

test "bucket is deterministic and bounded" {
    const first = bucket("user-123", "checkout-redesign", bucket_count);
    const second = bucket("user-123", "checkout-redesign", bucket_count);

    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u32, 20826), first);
    try std.testing.expect(first < bucket_count);
}

test "bucketUnit matches architecture specification" {
    try std.testing.expectEqual(@as(u32, 24261), bucketUnit("flag-a", "user-1"));
    try std.testing.expectEqual(@as(u32, 42637), bucketUnit("flag-b", "user-1"));
    try std.testing.expectEqual(@as(u32, 58649), bucketUnit("flag-a", "user-2"));
}

test "rollout boundaries are exact" {
    try std.testing.expect(!inRollout("demo", "user-1", 0));
    try std.testing.expect(inRollout("demo", "user-1", 100));
}
