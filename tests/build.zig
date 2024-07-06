const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Module = Build.Module;

pub const Options = struct {
    src_dir: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    mod_chipz: *Module,
};

pub fn build(b: *Build, opts: Options) void {
    // regular test tools
    const tests = .{ "z80test", "z80zex", "z80int", "z80timing" };
    inline for (tests) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(b.fmt("{s}/{s}.zig", .{ opts.src_dir, name })),
            .target = opts.target,
            .optimize = opts.optimize,
        });
        exe.root_module.addImport("chipz", opts.mod_chipz);
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&run.step);
    }

    // unit tests
    const unit_tests = [_][]const u8{ "memory", "ay3891x" };
    const test_step = b.step("test", "Run unit tests");
    for (unit_tests) |name| {
        const unit_test = b.addTest(.{
            .name = name,
            .root_source_file = b.path(b.fmt("{s}/{s}.test.zig", .{ opts.src_dir, name })),
            .target = opts.target,
        });
        b.installArtifact(unit_test); // install an exe for debugging
        unit_test.root_module.addImport("chipz", opts.mod_chipz);
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
