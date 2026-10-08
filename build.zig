const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zest = b.dependency("zest", .{});
    const test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = zest.path("src/root.zig"),
        .mode = .simple,
    };

    const mod = b.addModule("zblkpg", .{
        .root_source_file = b.path("src/blkpg.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zblkpg",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blkpg.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Unit tests (struct sizes, basic validation)
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/blkpg.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .test_runner = test_runner,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration tests (require root for loop devices)
    const zgpt_dep = b.dependency("zgpt", .{
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zblkpg", .module = mod },
                .{ .name = "zgpt", .module = zgpt_dep.module("zgpt") },
            },
        }),
        .test_runner = test_runner,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const integration_test_step = b.step(
        "test-integration",
        "Run integration tests (requires root)",
    );
    integration_test_step.dependOn(&run_integration_tests.step);

    const integration_compile_step = b.step(
        "test-integration-compile",
        "Compile integration tests without running them",
    );
    integration_compile_step.dependOn(&integration_tests.step);
}
