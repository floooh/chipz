const std = @import("std");
const Build = std.Build;
const ResolvedTarget = Build.ResolvedTarget;
const OptimizeMode = std.builtin.OptimizeMode;

pub const Options = struct {
    src_dir: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
};

pub fn build(b: *Build, opts: Options) void {
    // Z80 code generator
    buildTool(b, .{
        .name = "z80gen",
        .run_desc = "Run the Z80 code generator",
        .src = b.fmt("{s}/z80gen/main.zig", .{opts.src_dir}),
        .target = opts.target,
        .optimize = opts.optimize,
    });
}

const ToolOptions = struct {
    name: []const u8,
    run_desc: []const u8,
    src: []const u8,
    target: ResolvedTarget,
    optimize: OptimizeMode,
};

fn buildTool(b: *Build, options: ToolOptions) void {
    const exe = b.addExecutable(.{
        .name = options.name,
        .root_source_file = b.path(options.src),
        .target = options.target,
        .optimize = options.optimize,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step(b.fmt("run-{s}", .{options.name}), options.run_desc).dependOn(&run.step);
}
