const std = @import("std");
const lint = @import("lint.zig");
test "dbg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cp = lint.ControlPlane{ .flag_keys = &.{ "known-flag", "other-flag" } };
    const src =
        \\import { Doppio } from "@doppio/js";
        \\const on1 = doppio.get("known-flag", { unitId: "u1" });
        \\const on2 = doppio.isEnabled("orphan-flag");
        \\const on3 = doppio.get('single-quoted-flag');
        \\const on4 = doppio.get("known-flag", { unitId: "u2" });
        \\
    ;
    const r = try lint.lintSource(arena.allocator(), "app.ts", src, cp);
    for (r.findings) |f| std.debug.print("line={d} msg={s}\n", .{ f.line, f.message });
    std.debug.print("referenced={d}\n", .{r.referenced.len});
}
