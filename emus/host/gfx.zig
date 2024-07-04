const std = @import("std");
const assert = std.debug.assert;
const sokol = @import("sokol");
const sg = sokol.gfx;
const sapp = sokol.app;
const sglue = sokol.glue;
const slog = sokol.log;
const chipz = @import("chipz");
const shaders = @import("shaders.zig");

const DisplayInfo = chipz.common.host.DisplayInfo;
const DisplayOrientation = chipz.common.host.DisplayOrientation;
const Dim = chipz.common.host.Dim;
const Rect = chipz.common.host.Rect;

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
    display_info: DisplayInfo,
    pixel_aspect: Dim = .{ .width = 1, .height = 1 },
};

const state = struct {
    var valid = false;
    var border: Border = DEFAULT_BORDER;
    const fb = struct {
        var img: sg.Image = .{};
        var pal_img: sg.Image = .{};
        var smp: sg.Sampler = .{};
        var dim: Dim = .{};
        var paletted: bool = false;
    };
    const offscreen = struct {
        var view: Rect = .{};
        var pixel_aspect: Dim = .{};
        var img: sg.Image = .{};
        var smp: sg.Sampler = .{};
        var vbuf: sg.Buffer = .{};
        var pip: sg.Pipeline = .{};
        var attachments: sg.Attachments = .{};
        var pass_action: sg.PassAction = .{};
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
    sg.setup(.{
        .buffer_pool_size = 32,
        .image_pool_size = 128,
        .shader_pool_size = 16,
        .pipeline_pool_size = 16,
        .attachments_pool_size = 2,
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    state.valid = true;
    state.border = opts.border;
    state.display.orientation = opts.display_info.orientation;
    state.fb.dim = opts.display_info.fb.dim;
    state.fb.paletted = opts.display_info.palette != null;
    state.offscreen.pixel_aspect = opts.pixel_aspect;
    state.offscreen.view = opts.display_info.view;

    // create optional palette texture
    if (opts.display_info.palette) |palette| {
        var pal_buf = [_]u32{0} ** 256;
        std.mem.copyForwards(u32, &pal_buf, palette);
        state.fb.pal_img = sg.makeImage(.{
            .width = 256,
            .height = 1,
            .pixel_format = .RGBA8,
            .data = init: {
                var data: sg.ImageData = .{};
                data.subimage[0][0] = sg.asRange(&pal_buf);
                break :init data;
            },
        });
    }

    state.offscreen.pass_action.colors[0] = .{ .load_action = .DONTCARE };
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

pub fn draw(display_info: DisplayInfo) void {
    assert(state.valid);
    assert((display_info.fb.dim.width > 0) and (display_info.fb.dim.height > 0));
    assert(display_info.fb.buffer != null);
    assert((display_info.view.width > 0) and (display_info.view.height > 0));

    state.offscreen.view = display_info.view;

    // check if emulator framebuffer size has changed, if yes recreate backing resources
    if (!dimEqual(display_info.fb.dim, state.fb.dim)) {
        state.fb.dim = display_info.fb.dim;
        initImagesAndPass();
    }

    // copy emulator pixels into framebuffer texture
    var img_data = sg.ImageData{};
    img_data.subimage[0][0] = sg.asRange(display_info.fb.buffer.?);
    sg.updateImage(state.fb.img, img_data);

    // upscale emulator framebuffer with 2x nearest filtering
    sg.beginPass(.{ .action = state.offscreen.pass_action, .attachments = state.offscreen.attachments });
    sg.applyPipeline(state.offscreen.pip);
    sg.applyBindings(init: {
        var bind: sg.Bindings = .{};
        bind.vertex_buffers[0] = state.offscreen.vbuf;
        bind.fs.images[shaders.SLOT_fb_tex] = state.fb.img;
        bind.fs.images[shaders.SLOT_pal_tex] = state.fb.pal_img;
        bind.fs.samplers[shaders.SLOT_smp] = state.fb.smp;
        break :init bind;
    });
    const vs_params = shaders.OffscreenVsParams{ .uv_offset = .{
        asF32(state.offscreen.view.x) / asF32(state.fb.dim.width),
        asF32(state.offscreen.view.y) / asF32(state.fb.dim.height),
    }, .uv_scale = .{
        asF32(state.offscreen.view.width) / asF32(state.fb.dim.width),
        asF32(state.offscreen.view.height) / asF32(state.fb.dim.height),
    } };
    sg.applyUniforms(.VS, shaders.SLOT_offscreen_vs_params, sg.asRange(&vs_params));
    sg.draw(0, 4, 1);
    sg.endPass();

    // draw display pass with linear filtering
    const displayDim = Dim{ .width = sapp.width(), .height = sapp.height() };
    sg.beginPass(.{ .action = state.display.pass_action, .swapchain = sglue.swapchain() });
    applyViewport(
        displayDim,
        display_info.view,
        state.offscreen.pixel_aspect,
        state.border,
    );
    sg.applyPipeline(state.display.pip);
    sg.applyBindings(init: {
        var bind = sg.Bindings{};
        bind.vertex_buffers[0] = state.display.vbuf;
        bind.fs.images[shaders.SLOT_tex] = state.offscreen.img;
        bind.fs.samplers[shaders.SLOT_smp] = state.offscreen.smp;
        break :init bind;
    });
    sg.draw(0, 4, 1);
    sg.applyViewport(0, 0, displayDim.width, displayDim.height, true);
    sg.endPass();
    sg.commit();
}

pub fn shutdown() void {
    sg.shutdown();
}

// called at init time and when the emulator framebuffer size changes
fn initImagesAndPass() void {
    // destroy previous resources (fine to be called with invalid handles)
    sg.destroyImage(state.fb.img);
    sg.destroySampler(state.fb.smp);
    sg.destroyImage(state.offscreen.img);
    sg.destroySampler(state.offscreen.smp);
    sg.destroyAttachments(state.offscreen.attachments);

    // a texture with the emulator's raw pixel data
    assert((state.fb.dim.width > 0) and (state.fb.dim.height > 0));
    state.fb.img = sg.makeImage(.{
        .width = state.fb.dim.width,
        .height = state.fb.dim.height,
        .pixel_format = if (state.fb.paletted) .R8 else .RGBA8,
        .usage = .STREAM,
    });

    // a sampler for sampling the emulator's raw pixel data
    state.fb.smp = sg.makeSampler(.{
        .min_filter = .NEAREST,
        .mag_filter = .NEAREST,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });

    // 2x upscaling render target texture, sampler and pass
    assert((state.offscreen.view.width > 0) and (state.offscreen.view.height > 0));
    state.offscreen.img = sg.makeImage(.{
        .render_target = true,
        .width = 2 * state.offscreen.view.width,
        .height = 2 * state.offscreen.view.height,
        .sample_count = 1,
    });
    state.offscreen.smp = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .LINEAR,
        .wrap_u = .CLAMP_TO_EDGE,
        .wrap_v = .CLAMP_TO_EDGE,
    });
    var atts_desc: sg.AttachmentsDesc = .{};
    atts_desc.colors[0].image = state.offscreen.img;
    state.offscreen.attachments = sg.makeAttachments(atts_desc);
}
