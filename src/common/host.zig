//! host bindings

pub const AudioCallback = ?*const fn (samples: []f32) void;

/// configures and emulator's audio output
pub const AudioOptions = struct {
    /// host audio frequency in Hz
    sample_rate: i32,
    /// number of samples to generate before callback is called
    num_samples: u32 = 128,
    /// output volume modulator (0..1)
    volume: f32 = 1.0,
    /// called when new chunk of audio data is ready
    callback: AudioCallback,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

pub const Dim = struct {
    width: i32 = 0,
    height: i32 = 0,
};

/// emulator framebuffer pixel formats
pub const PixelFormat = enum {
    /// pixels are 8-bit palette indices
    Palette8,
    /// pixels are 32-bit true color
    Rgba8,
};

/// display orientation
pub const DisplayOrientation = enum {
    Landscape,
    Portrait,
};

/// describe emulator display info back to the host
pub const DisplayInfo = struct {
    /// framebuffer properties
    fb: struct {
        /// framebuffer dimensions in pixels
        dim: Dim,
        /// slice to the actual framebuffer pixels
        buffer: ?union(PixelFormat) {
            Palette8: []const u8,
            Rgba8: []const u32,
        },
    },
    /// the visible area of the framebuffer
    view: Rect,
    /// optional color palette (always in RGBA8 format)
    palette: ?[]const u32,
    /// display orientation
    orientation: DisplayOrientation,
};
