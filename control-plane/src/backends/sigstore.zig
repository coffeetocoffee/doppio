// Sigstore-style audit signing (pure Zig, no extern). Already wired in storage.zig.
const std = @import("std");

pub const SigstoreSigner = struct {
    pub fn sign(payload: []const u8) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update(payload);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }

    pub fn verify(payload: []const u8, signature: [32]u8) bool {
        return std.mem.eql(u8, &sign(payload), &signature);
    }
};

test "sigstore sign and verify round-trip" {
    const payload = "audit-event-payload";
    const sig = SigstoreSigner.sign(payload);
    try std.testing.expect(SigstoreSigner.verify(payload, sig));
    try std.testing.expect(!SigstoreSigner.verify("tampered", sig));
}