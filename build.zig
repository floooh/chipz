const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Step = Build.Step;
const Module = Build.Module;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const chips = b.addModule("chips", .{
        .root_source_file = b.path("src/chips/chips.zig"),
        .target = target,
        .optimize = optimize,
    });
    buildZ80gen(b, target, optimize);
    buildZ80test(b, target, optimize, chips);
    buildZ80zex(b, target, optimize, chips);
    buildTests(b, target, optimize);
}

fn buildZ80gen(b: *Build, target: ResolvedTarget, optimize: OptimizeMode) void {
    const z80gen = b.addExecutable(.{
        .name = "z80gen",
        .root_source_file = b.path("src/gen/z80/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(z80gen);

    const run_z80gen = b.addRunArtifact(z80gen);
    run_z80gen.step.dependOn(b.getInstallStep());
    b.step("run-z80gen", "Run the Z80 code generator").dependOn(&run_z80gen.step);
}

fn buildZ80test(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, chips: *Module) void {
    const z80test = b.addExecutable(.{
        .name = "z80test",
        .root_source_file = b.path("src/test/z80test.zig"),
        .target = target,
        .optimize = optimize,
    });
    z80test.root_module.addImport("chips", chips);
    b.installArtifact(z80test);

    const run_z80test = b.addRunArtifact(z80test);
    run_z80test.step.dependOn(b.getInstallStep());
    b.step("run-z80test", "Run Z80 instruction test").dependOn(&run_z80test.step);
}

fn buildZ80zex(b: *Build, target: ResolvedTarget, optimize: OptimizeMode, chips: *Module) void {
    const z80zex = b.addExecutable(.{
        .name = "z80zex",
        .root_source_file = b.path("src/test/z80zex.zig"),
        .target = target,
        .optimize = optimize,
    });
    z80zex.root_module.addImport("chips", chips);
    b.installArtifact(z80zex);

    const run_z80zex = b.addRunArtifact(z80zex);
    run_z80zex.step.dependOn(b.getInstallStep());
    b.step("run-z80zex", "Run Z80 ZEX test").dependOn(&run_z80zex.step);
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
