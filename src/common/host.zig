//! host bindings

/// configures and emulator's audio output
pub const AudioOptions = struct {
    /// host audio frequency in Hz
    sample_rate: u32,
    /// number of samples to generate before callback is called
    num_samples: u32 = 128,
    /// output volume modulator (0..1)
    volume: f32 = 1.0,
    /// called when new chunk of audio data is ready
    callback: *const fn (samples: []f32) void,
};

pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Dim = struct {
    width: u32 = 0,
    height: u32 = 0,
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
        /// framebuffer pixel format
        format: PixelFormat,
        /// slice to the actual framebuffer pixels
        buffer: ?[]const u8,
    },
    /// the visible area of the framebuffer
    view: Rect,
    /// optional color palette (always in RGBA8 format)
    palette: ?[]const u32,
    /// display orientation
    orientation: DisplayOrientation,
};
