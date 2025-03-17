//! UI helper functions
const ig = @import("cimgui");

pub fn color(imgui_color: c_int) ig.ImColor {
    const style = ig.igGetStyle();
    var c = style.Colors[imgui_color];
    c.w *= style.Alpha;
    return ig.ImColor{c};
}
