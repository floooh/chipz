const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Module = Build.Module;

const emulators = .{
    "pacman",
    "pengo",
};

pub const Options = struct {
    src_dir: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    mod_chipz: *Module,
};

pub fn build(b: *Build, opts: Options) void {
    const dep_sokol = b.dependency("sokol", .{
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const mod_host = b.addModule("host", .{
        .root_source_file = b.path(b.fmt("{s}/host/host.zig", .{opts.src_dir})),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "sokol", .module = dep_sokol.module("sokol") },
            .{ .name = "chipz", .module = opts.mod_chipz },
        },
    });

    inline for (emulators) |name| {
        addEmulator(b, .{
            .name = name,
            .src = b.fmt("{s}/{s}/{s}.zig", .{ opts.src_dir, name, name }),
            .target = opts.target,
            .optimize = opts.optimize,
            .mod_chipz = opts.mod_chipz,
            .mod_sokol = dep_sokol.module("sokol"),
            .mod_host = mod_host,
        });
    }
}

const EmuOptions = struct {
    name: []const u8,
    src: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
    mod_chipz: *Module,
    mod_sokol: *Module,
    mod_host: *Module,
};

fn addEmulator(b: *Build, opts: EmuOptions) void {
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_source_file = b.path(opts.src),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    exe.root_module.addImport("chipz", opts.mod_chipz);
    exe.root_module.addImport("host", opts.mod_host);
    exe.root_module.addImport("sokol", opts.mod_sokol);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step(b.fmt("run-{s}", .{opts.name}), b.fmt("Run {s}", .{opts.name}));
    run_step.dependOn(&run_cmd.step);
}
