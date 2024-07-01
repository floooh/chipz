const std = @import("std");
const assert = std.debug.assert;
const sokol = @import("sokol");
const sg = sokol.gfx;
const sglue = sokol.glue;
const slog = sokol.log;
const chipz = @import("chipz");
const shaders = @import("shaders.zig");

const DisplayInfo = chipz.common.host.DisplayInfo;
const DisplayOrientation = chipz.common.host.DisplayOrientation;
const Dim = chipz.common.host.Dim;
const Rect = chipz.common.host.Rect;

pub const Border = struct {
    top: u32 = 8,
    bottom: u32 = 8,
    left: u32 = 8,
    right: u32 = 16,
};

pub const Options = struct {
    border: Border = .{},
    display_info: DisplayInfo,
    pixel_aspect: Dim = .{ .width = 1, .height = 1 },
};

const state = struct {
    var valid = false;
    var border: Border = .{};
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
        var pipeline: sg.Pipeline = .{};
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
const gfx_verts = []f32{
    // vec2 pos, vec2 uv
    0.0, 0.0, 0.0, 0.0,
    1.0, 0.0, 1.0, 0.0,
    0.0, 1.0, 0.0, 1.0,
    1.0, 1.0, 1.0, 1.0,
};

const gfx_verts_rot = []f32 {
    0.0, 0.0, 1.0, 0.0,
    1.0, 0.0, 1.0, 1.0,
    0.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 0.0, 1.0,
};

const gfx_verts_flipped = []f32{
    0.0, 0.0, 0.0, 1.0,
    1.0, 0.0, 1.0, 1.0,
    0.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 1.0, 0.0,
};

const gfx_verts_flipped_rot = []f32{
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
                data[0][0] = sg.asRange(pal_buf);
                break :init data;
            },
        });
    }

    state.offscreen.pass_action.colors[0] = .{ .load_action = .DONTCARE };
    state.offscreen.vbuf = sg.makeBuffer(.{ .data = sg.asRange(gfx_verts) });
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
            .Portrait => gfx_verts_rot,
            .Landscape => gfx_verts,
        } else switch (state.display.orientation) {
            .Portrait => gfx_verts_flipped_rot,
            .Landscape => gfx_verts_flipped,
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

pub fn draw() void {
    sg.beginPass(.{
        .action = state.pass_action,
        .swapchain = sglue.swapchain(),
    });
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
        .wrap_y = .CLAMP_TO_EDGE,
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
    state.offscreen.attachments = sg.makeAttachments(.{
        .colors = .{
            .{ .image = state.offscreen.img }, .{}, .{}, .{},
        },
    });
}
