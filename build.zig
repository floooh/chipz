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
    chips: ?*Module = null,
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const chips = b.addModule("chips", .{
        .root_source_file = b.path("src/chips/chips.zig"),
        .target = target,
        .optimize = optimize,
    });
    buildTests(b, target, optimize);
    buildTool(b, .{
        .name = "z80gen",
        .run_desc = "Run the Z80 code generator",
        .src = "src/gen/z80/main.zig",
        .target = target,
        .optimize = optimize,
    });
    buildTool(b, .{
        .name = "z80test",
        .run_desc = "Run Z80 instruction test",
        .src = "src/test/z80test.zig",
        .target = target,
        .optimize = optimize,
        .chips = chips,
    });
    buildTool(b, .{
        .name = "z80zex",
        .run_desc = "Run Z80 ZEXALL test",
        .src = "src/test/z80zex.zig",
        .target = target,
        .optimize = optimize,
        .chips = chips,
    });
    buildTool(b, .{
        .name = "z80int",
        .run_desc = "Run Z80 interrupt timing test",
        .src = "src/test/z80int.zig",
        .target = target,
        .optimize = optimize,
        .chips = chips,
    });
    buildTool(b, .{
        .name = "z80timing",
        .run_desc = "Run Z80 instruction timing test",
        .src = "src/test/z80timing.zig",
        .target = target,
        .optimize = optimize,
        .chips = chips,
    });
}

fn buildTool(b: *Build, options: Options) void {
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_source_file = b.path(options.src),
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.chips) |chips| {
        exe.root_module.addImport("chips", chips);
    }
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step(b.fmt("run-{s}", .{options.name}), options.run_desc).dependOn(&run.step);
}

fn buildTests(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
