const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // z80 code generator
    const z80gen = b.addExecutable(.{
        .name = "z80gen",
        .root_source_file = b.path("src/gen/z80/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(z80gen);

    const run_z80gen = b.addRunArtifact(z80gen);
    run_z80gen.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_z80gen.addArgs(args);
    }
    b.step("run-z80gen", "Run the Z80 code generator").dependOn(&run_z80gen.step);

    //const exe_unit_tests = b.addTest(.{
    //    .root_source_file = b.path("src/main.zig"),
    //    .target = target,
    //    .optimize = optimize,
    //});
    //const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    //
    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    //const test_step = b.step("test", "Run unit tests");
    //test_step.dependOn(&run_lib_unit_tests.step);
    //test_step.dependOn(&run_exe_unit_tests.step);
}
