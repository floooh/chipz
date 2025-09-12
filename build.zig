const std = @import("std");
const tests = @import("tests/build.zig");
const tools = @import("tools/build.zig");
const emus = @import("emus/build.zig");
const Build = std.Build;
const sokol = @import("sokol");

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_sokol = b.dependency("sokol", .{
        .target = target,
        .optimize = optimize,
        .with_sokol_imgui = true,
    });
    const dep_cimgui = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });

    // inject the cimgui header search path into the sokol C library compile step
    dep_sokol.artifact("sokol_clib").addIncludePath(dep_cimgui.path("src"));
    const dep_shdc = dep_sokol.builder.dependency("shdc", .{});
    const mod_sokol = dep_sokol.module("sokol");

    // shader module
    const mod_shaders = try sokol.shdc.createModule(b, "shaders", mod_sokol, .{
        .shdc_dep = dep_shdc,
        .input = "src/host/shaders.glsl",
        .output = "shaders.zig",
        .slang = .{
            .glsl410 = true,
            .hlsl4 = true,
            .metal_macos = true,
            .glsl300es = true,
        },
    });

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
    const mod_host = b.addModule("host", .{
        .root_source_file = b.path("src/host/host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            .{ .name = "common", .module = mod_common },
            .{ .name = "shaders", .module = mod_shaders },
        },
    });
    const mod_ui = b.addModule("ui", .{
        .root_source_file = b.path("src/ui/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "cimgui", .module = dep_cimgui.module("cimgui") },
            .{ .name = "common", .module = mod_common },
            .{ .name = "chips", .module = mod_chips },
        },
    });

    // top-level modules
    const mod_chipz = b.addModule("chipz", .{
        .root_source_file = b.path("src/chipz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = mod_common },
            .{ .name = "chips", .module = mod_chips },
            .{ .name = "systems", .module = mod_systems },
            .{ .name = "host", .module = mod_host },
            .{ .name = "ui", .module = mod_ui },
        },
    });

    tools.build(b, .{
        .src_dir = "tools",
        .target = target,
        .optimize = optimize,
        .mod_common = mod_common,
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
        .mod_sokol = mod_sokol,
    });
}
