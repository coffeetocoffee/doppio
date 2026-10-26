const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const doppio = b.addModule("doppio", .{
        .root_source_file = b.path("src/root.zig"),
    });

    const cli = b.addExecutable(.{
        .name = "doppio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "doppio", .module = doppio },
            },
        }),
    });
    b.installArtifact(cli);

    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the doppio CLI");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
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
    const wasm_step = b.step("wasm", "Build the WebAssembly module");
    wasm_step.dependOn(&install_wasm.step);
    b.getInstallStep().dependOn(&install_wasm.step);
}
