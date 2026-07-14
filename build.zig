//! Notes for myself as I always forget how zig building works.
//!
//! = CONCEPTS
//!
//! Module:
//! Unit of compilation; contains "root" source file (like index.js in ESM)
//!
//! Step:
//! Seems to be a node in the DAG of "tasks" that the compiler runs
//! Assume it's a DAG and not sequence because simplings can run in parallel
//!
//! = FUNCTIONS
//!
//! `addModule`:
//! CREATES a module and adds it to a "module set" so it can be used in src
//!
//! `createModule`:
//! Creates a PRIVATE module; can be used in this file but not in src
//!
//! `installArtifact`:
//! Creates an "install step"

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_mod = b.addModule("viguana-core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "viguana", .module = core_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "viguana",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "viguana",
        .root_module = exe_mod,
    });

    const check_step = b.step("check", "Check if viguana compiles");
    check_step.dependOn(&exe_check.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = core_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
