const std = @import("std");
const assert = std.debug.assert;
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sdtx = sokol.debugtext;
const sglue = sokol.glue;
const slog = sokol.log;
const common = @import("common");
const prof = @import("prof.zig");
const shaders = @import("shaders");

const DisplayInfo = common.glue.DisplayInfo;
const DisplayOrientation = common.glue.DisplayOrientation;
const Dim = common.glue.Dim;
const Rect = common.glue.Rect;
const BoundedArray = common.BoundedArray;

pub const Border = struct {
    top: u32,
    bottom: u32,
    left: u32,
    right: u32,
};

pub const DEFAULT_BORDER = Border{
    .top = 16,
    .bottom = 24,
    .left = 16,
    .right = 16,
};

pub const Options = struct {
    border: Border = DEFAULT_BORDER,
    display: DisplayInfo,
    pixel_aspect: Dim = .{ .width = 1, .height = 1 },
};

pub const Status = struct {
    name: []const u8,
    num_ticks: u32,
    frame_stats: prof.Stats,
    emu_stats: prof.Stats,
};

const DrawOptions = struct {
    display: DisplayInfo,
    status: ?Status = null,
};

const DrawFunc = *const fn () void;
const DrawFuncs = BoundedArray(DrawFunc, 32);

const state = struct {
    var valid = false;
    var border: Border = DEFAULT_BORDER;
    var draw_funcs: DrawFuncs = .{};
    const fb = struct {
        const vidmem = struct {
            var img: sg.Image = .{};
            var tex_view: sg.View = .{};
        };
        const pal = struct {
            var img: sg.Image = .{};
            var tex_view: sg.View = .{};
        };
        var smp: sg.Sampler = .{};
        var dim: Dim = .{};
        var paletted: bool = false;
    };
    const offscreen = struct {
        var viewport: Rect = .{};
        var pixel_aspect: Dim = .{};
        var img: sg.Image = .{};
        var tex_view: sg.View = .{};
        var smp: sg.Sampler = .{};
        var vbuf: sg.Buffer = .{};
        var pip: sg.Pipeline = .{};
        var pass: sg.Pass = .{};
    };
    const display = struct {
        var vbuf: sg.Buffer = .{};
        var pip: sg.Pipeline = .{};
        var pass_action: sg.PassAction = .{};
        var orientation: DisplayOrientation = .Landscape;
    };
};

// zig fmt: off
const gfx_verts = [_]f32{
    // vec2 pos, vec2 uv
    0.0, 0.0, 0.0, 0.0,
    1.0, 0.0, 1.0, 0.0,
    0.0, 1.0, 0.0, 1.0,
    1.0, 1.0, 1.0, 1.0,
};

const gfx_verts_rot = [_]f32 {
    0.0, 0.0, 1.0, 0.0,
    1.0, 0.0, 1.0, 1.0,
    0.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 0.0, 1.0,
};

const gfx_verts_flipped = [_]f32{
    0.0, 0.0, 0.0, 1.0,
    1.0, 0.0, 1.0, 1.0,
    0.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 1.0, 0.0,
};

const gfx_verts_flipped_rot = [_]f32{
    0.0, 0.0, 1.0, 1.0,
    1.0, 0.0, 1.0, 0.0,
    0.0, 1.0, 0.0, 1.0,
    1.0, 1.0, 0.0, 0.0,
};
// zig fmt: on

pub fn init(opts: Options) void {
    state.valid = true;
    sg.setup(.{
        .buffer_pool_size = 32,
        .image_pool_size = 128,
        .shader_pool_size = 16,
        .pipeline_pool_size = 16,
        .view_pool_size = 128,
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });
    var desc = sdtx.Desc{};
    desc.fonts[0] = sdtx.fontOric();
    sdtx.setup(desc);

    state.border = opts.border;
    state.display.orientation = opts.display.orientation;
    state.fb.dim = opts.display.fb.dim;
    if (opts.display.fb.buffer) |buf| {
        state.fb.paletted = buf == .Palette8;
    }
    state.offscreen.pixel_aspect = opts.pixel_aspect;
    state.offscreen.viewport = opts.display.viewport;

    // create optional palette image and texture view
    if (state.fb.paletted) {
        var pal_buf = [_]u32{0} ** 256;
        std.mem.copyForwards(u32, &pal_buf, opts.display.palette.?);
        state.fb.pal.img = sg.makeImage(.{
            .width = 256,
            .height = 1,
            .pixel_format = .RGBA8,
            .data = init: {
                var data: sg.ImageData = .{};
                data.mip_levels[0] = sg.asRange(&pal_buf);
                break :init data;
            },
        });
        state.fb.pal.tex_view = sg.makeView(.{
            .texture = .{ .image = state.fb.pal.img },
        });
    }

    state.offscreen.pass.action.colors[0] = .{ .load_action = .DONTCARE };
    state.offscreen.vbuf = sg.makeBuffer(.{ .data = sg.asRange(&gfx_verts) });
    const pal8_shd_desc = shaders.offscreenPalShaderDesc(sg.queryBackend());
    const rgba8_shd_desc = shaders.offscreenShaderDesc(sg.queryBackend());
    state.offscreen.pip = sg.makePipeline(.{
        .shader = sg.makeShader(if (state.fb.paletted) pal8_shd_desc else rgba8_shd_desc),
        .layout = init: {
            var layout = sg.VertexLayoutState{};
            layout.attrs[0].format = .FLOAT2;
            layout.attrs[1].format = .FLOAT2;
            break :init layout;
        },
        .primitive_type = .TRIANGLE_STRIP,
        .depth = .{ .pixel_format = .NONE },
    });

    state.display.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.05, .g = 0.05, .b = 0.05, .a = 1 },
    };
    state.display.vbuf = sg.makeBuffer(.{
        .data = if (sg.queryFeatures().origin_top_left) switch (state.display.orientation) {
            .Portrait => sg.asRange(&gfx_verts_rot),
            .Landscape => sg.asRange(&gfx_verts),
        } else switch (state.display.orientation) {
            .Portrait => sg.asRange(&gfx_verts_flipped_rot),
            .Landscape => sg.asRange(&gfx_verts_flipped),
        },
    });
    state.display.pip = sg.makePipeline(.{
        .shader = sg.makeShader(shaders.displayShaderDesc(sg.queryBackend())),
        .layout = init: {
            var layout = sg.VertexLayoutState{};
            layout.attrs[0].format = .FLOAT2;
            layout.attrs[1].format = .FLOAT2;
            break :init layout;
        },
        .primitive_type = .TRIANGLE_STRIP,
    });

    initImagesAndPass();
}

pub fn shutdown() void {
    sdtx.shutdown();
    sg.shutdown();
}

pub fn addDrawFunc(func: DrawFunc) void {
    state.draw_funcs.appendAssumeCapacity(func);
}

fn asF32(val: anytype) f32 {
    return @floatFromInt(val);
}

fn applyViewport(canvas: Dim, view: Rect, aspect: Dim, border: Border) void {
    const b_left = asF32(border.left);
    const b_right = asF32(border.right);
    const b_top = asF32(border.top);
    const b_bottom = asF32(border.bottom);
    var cw: f32 = asF32(canvas.width) - b_left - b_right;
    if (cw < 1.0) {
        cw = 1.0;
    }
    var ch: f32 = asF32(canvas.height) - b_top - b_bottom;
    if (ch < 1.0) {
        ch = 1.0;
    }
    const canvas_aspect = cw / ch;
    const emu_aspect = asF32(view.width * aspect.width) / asF32(view.height * aspect.height);
    var vp_x: f32 = undefined;
    var vp_y: f32 = undefined;
    var vp_w: f32 = undefined;
    var vp_h: f32 = undefined;
    if (emu_aspect < canvas_aspect) {
        vp_y = b_top;
        vp_h = ch;
        vp_w = ch * emu_aspect;
        vp_x = b_left + (cw - vp_w) * 0.5;
    } else {
        vp_x = b_left;
        vp_w = cw;
        vp_h = cw / emu_aspect;
        vp_y = b_top + (ch - vp_h) * 0.5;
    }
    sg.applyViewportf(vp_x, vp_y, vp_w, vp_h, true);
}

fn dimEqual(d0: Dim, d1: Dim) bool {
    return (d0.width == d1.width) and (d0.height == d1.height);
}

pub fn draw(opts: DrawOptions) void {
    assert(state.valid);
    assert((opts.display.fb.dim.width > 0) and (opts.display.fb.dim.height > 0));
    assert(opts.display.fb.buffer != null);
    assert((opts.display.viewport.width > 0) and (opts.display.viewport.height > 0));

    state.offscreen.viewport = opts.display.viewport;

    if (opts.status) |status| {
        drawStatusBar(status);
    }

    // check if emulator framebuffer size has changed, if yes recreate backing resources
    if (!dimEqual(opts.display.fb.dim, state.fb.dim)) {
        state.fb.dim = opts.display.fb.dim;
        initImagesAndPass();
    }

    // copy emulator pixels into framebuffer texture
    var img_data = sg.ImageData{};
    img_data.mip_levels[0] = switch (opts.display.fb.buffer.?) {
        .Palette8 => |pal_buf| sg.asRange(pal_buf),
        .Rgba8 => |rgba8_buf| sg.asRange(rgba8_buf),
    };
    sg.updateImage(state.fb.vidmem.img, img_data);

    // upscale emulator framebuffer with 2x nearest filtering
    sg.beginPass(state.offscreen.pass);
    sg.applyPipeline(state.offscreen.pip);
    sg.applyBindings(init: {
        var bind: sg.Bindings = .{};
        bind.vertex_buffers[0] = state.offscreen.vbuf;
        bind.views[shaders.VIEW_fb_tex] = state.fb.vidmem.tex_view;
        bind.views[shaders.VIEW_pal_tex] = state.fb.pal.tex_view;
        bind.samplers[shaders.SMP_smp] = state.fb.smp;
        break :init bind;
    });
    const vs_params = shaders.OffscreenVsParams{ .uv_offset = .{
        asF32(state.offscreen.viewport.x) / asF32(state.fb.dim.width),
        asF32(state.offscreen.viewport.y) / asF32(state.fb.dim.height),
    }, .uv_scale = .{
        asF32(state.offscreen.viewport.width) / asF32(state.fb.dim.width),
        asF32(state.offscreen.viewport.height) / asF32(state.fb.dim.height),
    } };
    sg.applyUniforms(shaders.UB_offscreen_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 4, 1);
    sg.endPass();

    // draw display pass with linear filtering
    const displayDim = Dim{ .width = sapp.width(), .height = sapp.height() };
    sg.beginPass(.{ .action = state.display.pass_action, .swapchain = sglue.swapchain() });
    applyViewport(
        displayDim,
        opts.display.viewport,
        state.offscreen.pixel_aspect,
        state.border,
    );
    sg.applyPipeline(state.display.pip);
    sg.applyBindings(init: {
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = state.display.vbuf;
        bind.views[shaders.VIEW_tex] = state.offscreen.tex_view;
        bind.samplers[shaders.SMP_smp] = state.offscreen.smp;
        break :init bind;
    });
    sg.draw(0, 4, 1);
    sg.applyViewport(0, 0, displayDim.width, displayDim.height, true);
    sdtx.draw();
    for (state.draw_funcs.slice()) |drawFunc| {
        drawFunc();
    }
    sg.endPass();
    sg.commit();
}

// called at init time and when the emulator framebuffer size changes
fn initImagesAndPass() void {
    // destroy previous resources (fine to be called with invalid handles)
    sg.destroyImage(state.fb.vidmem.img);
    sg.destroyView(state.fb.vidmem.tex_view);
    sg.destroySampler(state.fb.smp);
    sg.destroyImage(state.offscreen.img);
    sg.destroyView(state.offscreen.tex_view);
    sg.destroyView(state.offscreen.pass.attachments.colors[0]);
    sg.destroySampler(state.offscreen.smp);

    // an image abd texture-view with the emulator's raw pixel data
    assert((state.fb.dim.width > 0) and (state.fb.dim.height > 0));
    state.fb.vidmem.img = sg.makeImage(.{
        .width = state.fb.dim.width,
        .height = state.fb.dim.height,
        .pixel_format = if (state.fb.paletted) .R8 else .RGBA8,
        .usage = .{ .stream_update = true },
    });
    state.fb.vidmem.tex_view = sg.makeView(.{
        .texture = .{ .image = state.fb.vidmem.img },
    });

    // a sampler for sampling the emulator's raw pixel data
    state.fb.smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // 2x upscaling render target image, views and sampler
    assert((state.offscreen.viewport.width > 0) and (state.offscreen.viewport.height > 0));
    state.offscreen.img = sg.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 2 * state.offscreen.viewport.width,
        .height = 2 * state.offscreen.viewport.height,
        .sample_count = 1,
    });
    state.offscreen.tex_view = sg.makeView(.{
        .texture = .{ .image = state.offscreen.img },
    });
    state.offscreen.pass.attachments.colors[0] = sg.makeView(.{
        .color_attachment = .{ .image = state.offscreen.img },
    });
    state.offscreen.smp = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
}

fn drawStatusBar(status: Status) void {
    const w = sapp.widthf();
    const h = sapp.heightf();
    sdtx.canvas(w, h);
    sdtx.color3b(255, 255, 255);
    sdtx.pos(1.0, (h / 8.0) - 1.5);
    sdtx.print("sys:{s} frame:{d:.2}ms emu:{d:.2}ms (min:{d:.2}ms max:{d:.2}ms) ticks:{}", .{
        status.name,
        status.frame_stats.avg_val,
        status.emu_stats.avg_val,
        status.emu_stats.min_val,
        status.emu_stats.max_val,
        status.num_ticks,
    });
}
