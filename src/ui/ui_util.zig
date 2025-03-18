//! UI helper functions
const ig = @import("cimgui");

pub fn color(imgui_color: usize) ig.ImU32 {
    const style = ig.igGetStyle();
    return ig.igGetColorU32Ex(@intCast(imgui_color), style.*.Alpha);
}
