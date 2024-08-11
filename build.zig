const std = @import("std");
const tests = @import("tests/build.zig");
const tools = @import("tools/build.zig");
const emus = @import("emus/build.zig");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // internal module definitions
    const mod_common = b.addModule("common", .{
        .root_source_file = b.path("src/common/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod_chips = b.addModule("chips", .{
        .root_source_file = b.path("src/chips/chips.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = mod_common },
        },
    });
    const mod_systems = b.addModule("systems", .{
        .root_source_file = b.path("src/systems/systems.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = mod_common },
            .{ .name = "chips", .module = mod_chips },
        },
    });

    // top-level module
    const mod_chipz = b.addModule("chipz", .{
        .root_source_file = b.path("src/chipz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = mod_common },
            .{ .name = "chips", .module = mod_chips },
            .{ .name = "systems", .module = mod_systems },
        },
    });

    tools.build(b, .{
        .src_dir = "tools",
        .target = target,
        .optimize = optimize,
    });
    tests.build(b, .{
        .src_dir = "tests",
        .target = target,
        .optimize = optimize,
        .mod_chipz = mod_chipz,
    });
    emus.build(b, .{
        .src_dir = "emus",
        .target = target,
        .optimize = optimize,
        .mod_chipz = mod_chipz,
    });
    buildDocs(b, target);
}

fn buildDocs(b: *Build, target: Build.ResolvedTarget) void {
    const obj_autodocs = b.addObject(.{
        .name = "chipz",
        .root_source_file = b.path("src/chipz.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const install_autodocs = b.addInstallDirectory(.{
        .source_dir = obj_autodocs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.getInstallStep().dependOn(&install_autodocs.step);
}
