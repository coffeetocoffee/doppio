const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const doppio = b.addModule("doppio", .{
        .root_source_file = b.path("../libdoppio/src/root.zig"),
    });

    const exe = b.addExecutable(.{
        .name = "doppio-control-plane",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
    });
    exe.root_module.addIncludePath(b.path("vendor/sqlite"));
    exe.root_module.addCMacro("SQLITE_THREADSAFE", "1");
    exe.root_module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // b.args removed in zig 0.17; skip
    const run_step = b.step("run", "Run the doppio control plane server");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
            .link_libc = true,
        }),
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
    });
    tests.root_module.addIncludePath(b.path("vendor/sqlite"));
    tests.root_module.addCMacro("SQLITE_THREADSAFE", "1");
    tests.root_module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run control plane unit tests");
    test_step.dependOn(&run_tests.step);
}
