const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;
const Module = Build.Module;

const Model = enum {
    NONE,

    // Namco arcade machine models
    Pacman,
    Pengo,

    // KC85 submodels
    KC852,
    KC853,
    KC854,
};

const emulators = .{
    .{ .name = "pacman", .path = "namco/namco.zig", .model = .Pacman },
    .{ .name = "pengo", .path = "namco/namco.zig", .model = .Pengo },
    .{ .name = "bombjack", .path = "bombjack/bombjack.zig", .model = .NONE },
    .{ .name = "kc852", .path = "kc85/kc85.zig", .model = .KC852 },
    .{ .name = "kc853", .path = "kc85/kc85.zig", .model = .KC853 },
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

    inline for (emulators) |emu| {
        addEmulator(b, .{
            .name = emu.name,
            .model = emu.model,
            .src = b.fmt("{s}/{s}", .{ opts.src_dir, emu.path }),
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
    model: Model,
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
    if (opts.model != .NONE) {
        const options = b.addOptions();
        options.addOption(Model, "model", opts.model);
        exe.root_module.addOptions("build_options", options);
    }
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
