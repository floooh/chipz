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
    const tests = .{
        "z80test",
        "z80zex",
        "z80int",
        "z80timing",
    };
    inline for (tests) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}/{s}.zig", .{ opts.src_dir, name })),
                .target = opts.target,
                .optimize = opts.optimize,
                .imports = &.{
                    .{ .name = "chipz", .module = opts.mod_chipz },
                },
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name})).dependOn(&run.step);
    }

    // unit tests
    const unit_tests = [_][]const u8{
        "memory",
        "ay3891",
        "z80ctc",
        "z80pio",
        "intel8255",
        "keybuf",
    };
    const test_step = b.step("test", "Run unit tests");
    inline for (unit_tests) |name| {
        const unit_test = b.addTest(.{
            .name = name ++ ".test",
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}/{s}.test.zig", .{ opts.src_dir, name })),
                .target = opts.target,
                .imports = &.{
                    .{ .name = "chipz", .module = opts.mod_chipz },
                },
            }),
        });
        b.installArtifact(unit_test); // install an exe for debugging
        const run_unit_test = b.addRunArtifact(unit_test);
        test_step.dependOn(&run_unit_test.step);
    }
}
