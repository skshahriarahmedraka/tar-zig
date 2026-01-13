const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "tar-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run tar-zig");
    run_step.dependOn(&run_cmd.step);

    // Unit tests for main module
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Create shared module for tar_header
    const tar_module = b.createModule(.{
        .root_source_file = b.path("src/tar_header.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Hard link tests
    const hardlink_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_hardlinks.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tar_header", .module = tar_module },
            },
        }),
    });

    const run_hardlink_tests = b.addRunArtifact(hardlink_tests);

    // Special files tests
    const special_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_special_files.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tar_header", .module = tar_module },
            },
        }),
    });

    const run_special_tests = b.addRunArtifact(special_tests);

    // Sparse files tests
    const sparse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_sparse_files.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tar_header", .module = tar_module },
            },
        }),
    });

    const run_sparse_tests = b.addRunArtifact(sparse_tests);

    // Large files tests
    const large_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_large_files.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tar_header", .module = tar_module },
            },
        }),
    });

    const run_large_tests = b.addRunArtifact(large_tests);

    // Checksum tests
    const checksum_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_checksum.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tar_header", .module = tar_module },
            },
        }),
    });

    const run_checksum_tests = b.addRunArtifact(checksum_tests);

    // PAX module for pax tests
    const pax_module = b.createModule(.{
        .root_source_file = b.path("src/pax.zig"),
        .target = target,
        .optimize = optimize,
    });

    // PAX header tests
    const pax_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/test_pax_headers.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pax", .module = pax_module },
            },
        }),
    });

    const run_pax_tests = b.addRunArtifact(pax_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_hardlink_tests.step);
    test_step.dependOn(&run_special_tests.step);
    test_step.dependOn(&run_sparse_tests.step);
    test_step.dependOn(&run_large_tests.step);
    test_step.dependOn(&run_checksum_tests.step);
    test_step.dependOn(&run_pax_tests.step);
}
