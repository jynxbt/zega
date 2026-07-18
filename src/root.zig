//! zega — Code Bubbles editor core (Zig).

pub const geom = @import("geom.zig");
pub const bubble = @import("bubble.zig");
pub const canvas = @import("canvas.zig");
pub const spacer = @import("spacer.zig");
pub const font = @import("font.zig");
pub const text = @import("text.zig");
pub const pills = @import("pills.zig");
pub const doc = @import("doc.zig");
pub const detect = @import("lang/detect.zig");
pub const outline = @import("lang/outline.zig");
pub const highlight = @import("lang/highlight.zig");
pub const brackets = @import("lang/brackets.zig");
pub const complete = @import("lang/complete.zig");
pub const edit = @import("edit.zig");
pub const layout = @import("layout.zig");
pub const connection = @import("connection.zig");
pub const diag = @import("diag.zig");
pub const term_screen = @import("term/screen.zig");
pub const term_vt = @import("term/vt.zig");
pub const project = @import("project.zig");
// session/pty need fork — tested via app; screen+vt are pure unit tests.

pub const Vec2 = geom.Vec2;
pub const BoundingBox = geom.BoundingBox;
pub const Bubble = bubble.Bubble;
pub const BubbleKind = bubble.BubbleKind;
pub const Canvas = canvas.Canvas;
pub const Viewport = canvas.Viewport;
pub const Connection = bubble.Connection;
pub const WorkingSet = bubble.WorkingSet;
pub const DocumentStore = doc.DocumentStore;
pub const Language = detect.Language;

test {
    _ = geom;
    _ = bubble;
    _ = canvas;
    _ = spacer;
    _ = font;
    _ = text;
    _ = pills;
    _ = doc;
    _ = detect;
    _ = outline;
    _ = highlight;
    _ = brackets;
    _ = complete;
    // edit/layout pull sokol? no — pure
    _ = edit;
    // layout embeds files and uses spacer — ok for tests
    _ = layout;
    _ = connection;
    _ = diag;
    _ = term_screen;
    _ = term_vt;
    _ = project;
}
