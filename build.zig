const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Step = Build.Step;
const Module = Build.Module;

const Options = struct {
    name: []const u8,
    run_desc: []const u8,
    src: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    chipz: ?*Module = null,
};

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

    // top-level public module
    const mod_chipz = b.addModule("chipz", .{
        .root_source_file = b.path("src/chipz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = mod_common },
            .{ .name = "chips", .module = mod_chips },
        },
    });

    buildTool(b, .{
        .name = "z80gen",
        .run_desc = "Run the Z80 code generator",
        .src = "gen/z80/main.zig",
        .target = target,
        .optimize = optimize,
    });
    buildTool(b, .{
        .name = "z80test",
        .run_desc = "Run Z80 instruction test",
        .src = "test/z80test.zig",
        .target = target,
        .optimize = optimize,
        .chipz = mod_chipz,
    });
    buildTool(b, .{
        .name = "z80zex",
        .run_desc = "Run Z80 ZEXALL test",
        .src = "test/z80zex.zig",
        .target = target,
        .optimize = optimize,
        .chipz = mod_chipz,
    });
    buildTool(b, .{
        .name = "z80int",
        .run_desc = "Run Z80 interrupt timing test",
        .src = "test/z80int.zig",
        .target = target,
        .optimize = optimize,
        .chipz = mod_chipz,
    });
    buildTool(b, .{
        .name = "z80timing",
        .run_desc = "Run Z80 instruction timing test",
        .src = "test/z80timing.zig",
        .target = target,
        .optimize = optimize,
        .chipz = mod_chipz,
    });
}

fn buildTool(b: *Build, options: Options) void {
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_source_file = b.path(options.src),
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.chipz) |chipz| {
        exe.root_module.addImport("chipz", chipz);
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step(b.fmt("run-{s}", .{options.name}), options.run_desc).dependOn(&run.step);
}
