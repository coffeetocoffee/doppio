const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core doppio library module
    const doppio = b.addModule("doppio", .{
        .root_source_file = b.path("libdoppio/src/root.zig"),
    });

    // doppio CLI executable
    const cli = b.addExecutable(.{
        .name = "doppio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("libdoppio/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
        }),
    });
    b.installArtifact(cli);

    // doppio-control-plane server executable
    const server_exe = b.addExecutable(.{
        .name = "doppio-control-plane",
        .root_module = b.createModule(.{
            .root_source_file = b.path("control-plane/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
        }),
    });
    server_exe.root_module.addCSourceFile(.{
        .file = b.path("control-plane/vendor/sqlite/sqlite3.c"),
    });
    server_exe.root_module.addIncludePath(b.path("control-plane/vendor/sqlite"));
    server_exe.root_module.addCMacro("SQLITE_THREADSAFE", "1");
    server_exe.root_module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    b.installArtifact(server_exe);

    // Run tests for both libdoppio and control-plane
    const doppio_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("libdoppio/src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_doppio_tests = b.addRunArtifact(doppio_tests);

    const cp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("control-plane/src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
        }),
    });
    cp_tests.root_module.addCSourceFile(.{
        .file = b.path("control-plane/vendor/sqlite/sqlite3.c"),
    });
    cp_tests.root_module.addIncludePath(b.path("control-plane/vendor/sqlite"));
    cp_tests.root_module.addCMacro("SQLITE_THREADSAFE", "1");
    cp_tests.root_module.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    const run_cp_tests = b.addRunArtifact(cp_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_doppio_tests.step);
    test_step.dependOn(&run_cp_tests.step);

    // WebAssembly target for libdoppio
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("libdoppio/src/wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "doppio", .module = doppio },
        },
    });
    wasm_module.export_symbol_names = &.{
        "doppio_abi_version",
        "doppio_bucket",
        "doppio_enabled",
        "doppio_eval_cel",
        "doppio_buffer_ptr",
        "doppio_buffer_size",
    };
    const wasm = b.addExecutable(.{
        .name = "doppio",
        .root_module = wasm_module,
    });
    wasm.entry = .disabled;
    wasm.export_memory = true;
    wasm.import_memory = false;

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_sub_path = "doppio.wasm",
    });
    const wasm_step = b.step("wasm", "Build WebAssembly module");
    wasm_step.dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(&install_wasm.step);
}
