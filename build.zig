//! Chronicle Build Configuration
//!
//! A changelog generator with Zig CLI core.
//!
//! ## Build Commands
//! - `zig build` - Build the chronicle executable
//! - `zig build run` - Build and run chronicle
//! - `zig build test` - Run all tests
//!
//! ## Build Options
//! - `-Doptimize=<mode>` - Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
//! - `-Dtarget=<triple>` - Cross-compilation target
//! - `-Dlog=<bool>` - Enable debug logging

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ===== Standard Options =====
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ===== Custom Options =====
    const enable_logging = b.option(
        bool,
        "log",
        "Enable debug logging",
    ) orelse (optimize == .Debug);

    // Create options module for compile-time configuration
    const options = b.addOptions();
    options.addOption(bool, "enable_logging", enable_logging);

    // ===== Executable =====
    const exe = b.addExecutable(.{
        .name = "chronicle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "config", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    // ===== Run Step =====
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run chronicle");
    run_step.dependOn(&run_cmd.step);

    // ===== Tests =====
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
