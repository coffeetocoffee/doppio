const std = @import("std");
const doppio = @import("doppio");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var buffer: [1 << 20]u8 = undefined;
    const outcome = doppio.cli.runOutcome(args, &buffer, init.io) catch |err| {
        std.debug.print("doppio: {s}\n\n{s}", .{ @errorName(err), doppio.cli.usage });
        std.process.exit(2);
    };

    try std.Io.File.stdout().writeStreamingAll(init.io, outcome.output);
    if (outcome.exit_code != 0) {
        // A lint failure is a finding, not a crash: the report is already on
        // stdout, so exit with the CI-visible code.
        std.process.exit(outcome.exit_code);
    }
}
