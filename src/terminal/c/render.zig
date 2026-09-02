const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const colorpkg = @import("../color.zig");
const cursorpkg = @import("../cursor.zig");
const page = @import("../page.zig");
const size = @import("../size.zig");
const Style = @import("../style.zig").Style;
const terminal_c = @import("terminal.zig");
const ZigTerminal = @import("../Terminal.zig");
const renderpkg = @import("../render.zig");
const Result = @import("result.zig").Result;
const row = @import("row.zig");
const style_c = @import("style.zig");

const log = std.log.scoped(.render_state_c);

const RenderStateWrapper = struct {
    alloc: std.mem.Allocator,
    state: renderpkg.RenderState = .empty,
};

const RowIteratorWrapper = struct {
    alloc: std.mem.Allocator,

    /// The current index (also y value) into the row list.
    y: ?size.CellCountInt,

    /// These are the raw pointers into the render state data.
    raws: []const page.Row,
    cells: []const std.MultiArrayList(renderpkg.RenderState.Cell),
    selection: []const ?[2]size.CellCountInt,
    dirty: []bool,

    /// The color palette from the render state, needed to resolve
    /// palette-indexed background colors on cells.
    palette: *const colorpkg.Palette,
};

const RowCellsWrapper = struct {
    alloc: std.mem.Allocator,
    x: ?size.CellCountInt,
    raws: []const page.Cell,
    graphemes: []const []const u21,
    styles: []const Style,
    selection: ?[2]size.CellCountInt,

    /// The color palette, needed to resolve palette-indexed background colors.
    palette: *const colorpkg.Palette,
};

/// C: GhosttyRenderState
pub const RenderState = ?*RenderStateWrapper;

/// C: GhosttyRenderStateRowIterator
pub const RowIterator = ?*RowIteratorWrapper;

/// C: GhosttyRenderStateRowCells
pub const RowCells = ?*RowCellsWrapper;

/// C: GhosttyRenderStateDirty
pub const Dirty = renderpkg.RenderState.Dirty;

/// C: GhosttyRenderStateRowSelection
pub const RowSelection = extern struct {
    size: usize = @sizeOf(RowSelection),
    start_x: u16 = 0,
    end_x: u16 = 0,
};

/// C: GhosttyRenderStateCursorVisualStyle
pub const CursorVisualStyle = enum(c_int) {
    bar = 0,
    block = 1,
    underline = 2,
    block_hollow = 3,

    pub fn fromCursorStyle(s: cursorpkg.Style) CursorVisualStyle {
        return switch (s) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    }
};

/// C: GhosttyRenderStateData
pub const Data = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    dirty = 3,
    row_iterator = 4,
    color_background = 5,
    color_foreground = 6,
    color_cursor = 7,
    color_cursor_has_value = 8,
    color_palette = 9,
    cursor_visual_style = 10,
    cursor_visible = 11,
    cursor_blinking = 12,
    cursor_password_input = 13,
    cursor_viewport_has_value = 14,
    cursor_viewport_x = 15,
    cursor_viewport_y = 16,
    cursor_viewport_wide_tail = 17,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: Data) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows => size.CellCountInt,
            .dirty => Dirty,
            .row_iterator => RowIterator,
            .color_background, .color_foreground, .color_cursor => colorpkg.RGB.C,
            .color_cursor_has_value => bool,
            .color_palette => colorpkg.PaletteC,
            .cursor_visual_style => CursorVisualStyle,
            .cursor_visible, .cursor_blinking, .cursor_password_input => bool,
            .cursor_viewport_has_value, .cursor_viewport_wide_tail => bool,
            .cursor_viewport_x, .cursor_viewport_y => size.CellCountInt,
        };
    }
};

/// C: GhosttyRenderStateOption
pub const SetOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: SetOption) type {
        return switch (self) {
            .dirty => Dirty,
        };
    }
};

/// C: GhosttyRenderStateColors
pub const Colors = extern struct {
    size: usize = @sizeOf(Colors),
    background: colorpkg.RGB.C,
    foreground: colorpkg.RGB.C,
    cursor: colorpkg.RGB.C,
    cursor_has_value: bool,
    palette: colorpkg.PaletteC,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *RenderState,
) callconv(lib.calling_conv) Result {
    result.* = new_(alloc_) catch |err| {
        result.* = null;
        return switch (err) {
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(alloc_: ?*const CAllocator) error{OutOfMemory}!*RenderStateWrapper {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RenderStateWrapper) catch
        return error.OutOfMemory;
    ptr.* = .{ .alloc = alloc };
    return ptr;
}

pub fn free(state_: RenderState) callconv(lib.calling_conv) void {
    const state = state_ orelse return;
    const alloc = state.alloc;
    state.state.deinit(alloc);
    alloc.destroy(state);
}

pub fn update(
    state_: RenderState,
    terminal_: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;

    state.state.update(state.alloc, t) catch return .out_of_memory;
    return .success;
}

pub fn begin_update(
    state_: RenderState,
    terminal_: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;

    state.state.beginUpdate(state.alloc, t) catch return .out_of_memory;
    return .success;
}

pub fn end_update(
    state_: RenderState,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    state.state.endUpdate();
    return .success;
}

pub fn get(
    state_: RenderState,
    data: Data,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(Data, @intFromEnum(data)) orelse {
            log.warn("render_state_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            state_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn get_multi(
    state_: RenderState,
    count: usize,
    keys: ?[*]const Data,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = get(state_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn getTyped(
    state_: RenderState,
    comptime data: Data,
    out: *data.OutType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = state.state.cols,
        .rows => out.* = state.state.rows,
        .dirty => out.* = state.state.dirty,
        .row_iterator => {
            const it = out.* orelse return .invalid_value;
            const row_data = state.state.row_data.slice();
            it.* = .{
                .alloc = it.alloc,
                .y = null,
                .raws = row_data.items(.raw),
                .cells = row_data.items(.cells),
                .selection = row_data.items(.selection),
                .dirty = row_data.items(.dirty),
                .palette = &state.state.colors.palette,
            };
        },
        .color_background => out.* = state.state.colors.background.cval(),
        .color_foreground => out.* = state.state.colors.foreground.cval(),
        .color_cursor => {
            const cursor = state.state.colors.cursor orelse return .invalid_value;
            out.* = cursor.cval();
        },
        .color_cursor_has_value => out.* = state.state.colors.cursor != null,
        .color_palette => out.* = colorpkg.paletteCval(&state.state.colors.palette),
        .cursor_visual_style => out.* = CursorVisualStyle.fromCursorStyle(state.state.cursor.visual_style),
        .cursor_visible => out.* = state.state.cursor.visible,
        .cursor_blinking => out.* = state.state.cursor.blinking,
        .cursor_password_input => out.* = state.state.cursor.password_input,
        .cursor_viewport_has_value => out.* = state.state.cursor.viewport != null,
        .cursor_viewport_x => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.x;
        },
        .cursor_viewport_y => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.y;
        },
        .cursor_viewport_wide_tail => {
            const vp = state.state.cursor.viewport orelse return .invalid_value;
            out.* = vp.wide_tail;
        },
    }

    return .success;
}

pub fn set(
    state_: RenderState,
    option: SetOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(SetOption, @intFromEnum(option)) orelse {
            log.warn("render_state_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setTyped(
            state_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn setTyped(
    state_: RenderState,
    comptime option: SetOption,
    value: *const option.InType(),
) Result {
    const state = state_ orelse return .invalid_value;
    switch (option) {
        .dirty => state.state.dirty = value.*,
    }

    return .success;
}

pub fn colors_get(
    state_: RenderState,
    out_colors_: ?*Colors,
) callconv(lib.calling_conv) Result {
    const state = state_ orelse return .invalid_value;
    const out_colors = out_colors_ orelse return .invalid_value;
    const out_size = out_colors.size;
    if (out_size < @sizeOf(usize)) return .invalid_value;

    const colors = state.state.colors;
    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "background",
    )) {
        out_colors.background = colors.background.cval();
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "foreground",
    )) {
        out_colors.foreground = colors.foreground.cval();
    }

    if (colors.cursor) |cursor| {
        if (lib.structSizedFieldFits(
            Colors,
            out_size,
            "cursor",
        )) {
            out_colors.cursor = cursor.cval();
        }
    }

    if (lib.structSizedFieldFits(
        Colors,
        out_size,
        "cursor_has_value",
    )) {
        out_colors.cursor_has_value = colors.cursor != null;
    }

    {
        const palette_offset = @offsetOf(Colors, "palette");
        if (out_size > palette_offset) {
            const available = out_size - palette_offset;
            const max_entries = @min(colors.palette.len, available / @sizeOf(colorpkg.RGB.C));
            for (0..max_entries) |i| {
                out_colors.palette[i] = colors.palette[i].cval();
            }
        }
    }

    return .success;
}

pub fn row_iterator_new(
    alloc_: ?*const CAllocator,
    result: *RowIterator,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RowIteratorWrapper) catch {
        result.* = null;
        return .out_of_memory;
    };
    ptr.* = .{
        .alloc = alloc,
        .y = undefined,
        .raws = undefined,
        .cells = undefined,
        .selection = undefined,
        .dirty = undefined,
        .palette = undefined,
    };
    result.* = ptr;
    return .success;
}

pub fn row_iterator_free(iterator_: RowIterator) callconv(lib.calling_conv) void {
    const iterator = iterator_ orelse return;
    const alloc = iterator.alloc;
    alloc.destroy(iterator);
}

pub fn row_iterator_next(iterator_: RowIterator) callconv(lib.calling_conv) bool {
    const it = iterator_ orelse return false;
    const next_y: size.CellCountInt = if (it.y) |y| y + 1 else 0;
    if (next_y >= it.raws.len) return false;
    it.y = next_y;
    return true;
}

pub fn row_cells_new(
    alloc_: ?*const CAllocator,
    result: *RowCells,
) callconv(lib.calling_conv) Result {
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(RowCellsWrapper) catch {
        result.* = null;
        return .out_of_memory;
    };
    ptr.* = .{
        .alloc = alloc,
        .x = undefined,
        .raws = undefined,
        .graphemes = undefined,
        .styles = undefined,
        .selection = undefined,
        .palette = undefined,
    };
    result.* = ptr;
    return .success;
}

pub fn row_cells_next(cells_: RowCells) callconv(lib.calling_conv) bool {
    const cells = cells_ orelse return false;
    const next_x: size.CellCountInt = if (cells.x) |x| x + 1 else 0;
    if (next_x >= cells.raws.len) return false;
    cells.x = next_x;
    return true;
}

pub fn row_cells_select(cells_: RowCells, x: size.CellCountInt) callconv(lib.calling_conv) Result {
    const cells = cells_ orelse return .invalid_value;
    if (x >= cells.raws.len) return .invalid_value;
    cells.x = x;
    return .success;
}

pub fn row_cells_free(cells_: RowCells) callconv(lib.calling_conv) void {
    const cells = cells_ orelse return;
    const alloc = cells.alloc;
    alloc.destroy(cells);
}

/// C: GhosttyRenderStateRowCellsData
pub const RowCellsData = enum(c_int) {
    invalid = 0,
    raw = 1,
    style = 2,
    graphemes_len = 3,
    graphemes_buf = 4,
    bg_color = 5,
    fg_color = 6,
    selected = 7,
    has_styling = 8,
    graphemes_utf8 = 9,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowCellsData) type {
        return switch (self) {
            .invalid => void,
            .raw => page.Cell.C,
            .style => style_c.Style,
            .graphemes_len => u32,
            .graphemes_buf => u32,
            .bg_color, .fg_color => colorpkg.RGB.C,
            .selected, .has_styling => bool,
            .graphemes_utf8 => lib.Buffer,
        };
    }
};

pub fn row_cells_get(
    cells_: RowCells,
    data: RowCellsData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowCellsData, @intFromEnum(data)) orelse {
            log.warn("render_state_row_cells_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }
    if (out == null) return .invalid_value;

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| rowCellsGetTyped(
            cells_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

/// C: GhosttyRenderStateRowCellEntry
///
/// One cell's worth of render data, filled by row_cells_get_all. Text lives
/// out of line in the batch's text buffer so this record stays small enough
/// that a whole row of them fits in cache.
pub const RowCellEntry = extern struct {
    /// Byte offset of this cell's UTF-8 grapheme cluster within the batch's
    /// text buffer.
    text_offset: u32 = 0,

    /// Byte length of this cell's grapheme cluster. Zero when the cell has
    /// no text.
    text_len: u32 = 0,

    /// Index of this cell's style within the batch's styles array. Always
    /// zero when the caller passed a NULL styles array.
    style_index: u32 = 0,

    /// The resolved foreground color. Only meaningful when has_fg is true.
    fg: colorpkg.RGB.C = .{ .r = 0, .g = 0, .b = 0 },

    /// The resolved background color. Only meaningful when has_bg is true.
    bg: colorpkg.RGB.C = .{ .r = 0, .g = 0, .b = 0 },

    /// Whether fg holds a resolved foreground color. False means the cell
    /// has no explicit foreground and the caller should use its own default.
    has_fg: bool = false,

    /// Whether bg holds a resolved background color. False means the cell
    /// has no explicit background and the caller should use its own default.
    has_bg: bool = false,

    /// Whether the cell carries a non-default style entry.
    has_styling: bool = false,

    /// Whether the cell falls inside the row's selection range.
    selected: bool = false,

    /// The cell's wide property, a GhosttyCellWide value narrowed to a byte.
    wide: u8 = 0,

    _reserved: u8 = 0,
};

/// C: GhosttyRenderStateRowCellsBatch
///
/// In/out parameter block for row_cells_get_all. The caller owns every
/// buffer; the function only writes into them.
pub const RowCellsBatch = extern struct {
    /// Size of this struct in bytes. Must be set by the caller.
    size: usize = @sizeOf(RowCellsBatch),

    /// Array receiving one entry per cell in the row, in column order.
    entries: ?[*]RowCellEntry = null,

    /// Capacity of entries, in elements.
    entries_cap: usize = 0,

    /// Array receiving the row's styles, deduplicated by style id: a new
    /// entry is appended only where a cell's style differs from the
    /// preceding cell's. May be NULL to skip style materialization, in
    /// which case every entry's style_index is zero and styles_len is zero.
    styles: ?[*]style_c.Style = null,

    /// Capacity of styles, in elements.
    styles_cap: usize = 0,

    /// Buffer receiving every cell's UTF-8 grapheme cluster, laid out back
    /// to back in column order. Each entry's text_offset/text_len index
    /// into it.
    text: lib.Buffer = .{},

    /// Number of entries written, or the required entry capacity when the
    /// call returns GHOSTTY_OUT_OF_SPACE.
    entries_len: usize = 0,

    /// Number of styles written, or the required style capacity when the
    /// call returns GHOSTTY_OUT_OF_SPACE.
    styles_len: usize = 0,
};

/// Read an entire row's cells in one call.
///
/// This is the batched counterpart to row_cells_get: it fills a caller-owned
/// record per cell plus a shared text buffer, so a renderer pays one C API
/// call per ROW instead of several per cell.
///
/// The iterator position is neither read nor modified: the whole row is read
/// regardless of where row_cells_next/row_cells_select left it.
///
/// On GHOSTTY_OUT_OF_SPACE the required capacities are reported in
/// entries_len, styles_len and text.len, and the contents of the caller's
/// buffers are unspecified.
pub fn row_cells_get_all(
    cells_: RowCells,
    batch_: ?*RowCellsBatch,
) callconv(lib.calling_conv) Result {
    const cells = cells_ orelse return .invalid_value;
    const batch = batch_ orelse return .invalid_value;
    if (batch.size < @sizeOf(RowCellsBatch)) return .invalid_value;

    const len = cells.raws.len;
    const want_styles = batch.styles != null;

    // Space check up front so the write loop never has to branch on the
    // entry or style capacity. The text buffer is checked as it is filled,
    // because its requirement is only known once the clusters are encoded.
    var out_of_space = batch.entries == null or batch.entries_cap < len;
    if (want_styles and batch.styles_cap < 1) out_of_space = true;

    var text_len: usize = 0;
    var styles_len: usize = 0;

    // The last style id appended to the styles array, and its index. A style
    // id identifies a style exactly (0 is always the default), so a run of
    // cells sharing one costs a single styles entry. The resolved foreground
    // depends only on the style, so it is carried across the run too.
    var last_style_id: u32 = 0;
    var have_last_style = false;
    var last_fg: ?colorpkg.RGB.C = null;

    for (cells.raws, 0..) |cell, x| {
        const s: Style = if (cell.hasStyling()) cells.styles[x] else .{};

        if (!have_last_style or last_style_id != cell.style_id) {
            have_last_style = true;
            last_style_id = cell.style_id;
            last_fg = if (s.fg_color == .none)
                null
            else
                s.fg(.{ .default = .{}, .palette = cells.palette }).cval();

            if (want_styles) {
                if (styles_len < batch.styles_cap) {
                    batch.styles.?[styles_len] = style_c.Style.fromStyle(s);
                } else {
                    out_of_space = true;
                }
                styles_len += 1;
            }
        }

        const text_offset = text_len;
        text_len += rowCellsEncodeCluster(
            cell,
            if (cell.hasGrapheme()) cells.graphemes[x] else &.{},
            batch.text,
            text_len,
            &out_of_space,
        );

        if (out_of_space) continue;

        const bg = s.bg(&cell, cells.palette);
        batch.entries.?[x] = .{
            .text_offset = @intCast(text_offset),
            .text_len = @intCast(text_len - text_offset),
            .style_index = if (want_styles) @intCast(styles_len - 1) else 0,
            .fg = last_fg orelse .{ .r = 0, .g = 0, .b = 0 },
            .bg = if (bg) |c| c.cval() else .{ .r = 0, .g = 0, .b = 0 },
            .has_fg = last_fg != null,
            .has_bg = bg != null,
            .has_styling = cell.hasStyling(),
            .selected = if (cells.selection) |sel|
                x >= @as(usize, sel[0]) and x <= @as(usize, sel[1])
            else
                false,
            .wide = @intCast(@intFromEnum(cell.wide)),
        };
    }

    batch.entries_len = len;
    batch.styles_len = styles_len;
    batch.text.len = text_len;
    return if (out_of_space) .out_of_space else .success;
}

/// Encode one cell's grapheme cluster into `buf` at `offset`, returning the
/// byte length the cluster needs. Sets `out_of_space` and writes nothing
/// when the buffer cannot hold it, so the caller still learns the total
/// capacity the row requires.
fn rowCellsEncodeCluster(
    cell: page.Cell,
    extra: []const u21,
    buf: lib.Buffer,
    offset: usize,
    out_of_space: *bool,
) usize {
    if (!cell.hasText()) return 0;

    var needed: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch 0;
    for (extra) |cp| {
        needed += std.unicode.utf8CodepointSequenceLength(cp) catch 0;
    }

    const ptr = buf.ptr orelse {
        out_of_space.* = true;
        return needed;
    };
    if (out_of_space.* or offset + needed > buf.cap) {
        out_of_space.* = true;
        return needed;
    }

    const dst = ptr[offset..buf.cap];
    var i: usize = 0;
    i += std.unicode.utf8Encode(cell.codepoint(), dst[i..]) catch 0;
    for (extra) |cp| {
        i += std.unicode.utf8Encode(cp, dst[i..]) catch 0;
    }
    return i;
}

pub fn row_cells_get_multi(
    cells_: RowCells,
    count: usize,
    keys: ?[*]const RowCellsData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = row_cells_get(cells_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn rowCellsGetTyped(
    cells_: RowCells,
    comptime data: RowCellsData,
    out: *data.OutType(),
) Result {
    const cells = cells_ orelse return .invalid_value;
    const x = cells.x orelse return .invalid_value;
    const cell = cells.raws[x];
    switch (data) {
        .invalid => return .invalid_value,
        .raw => out.* = cell.cval(),
        .style => out.* = if (cell.hasStyling())
            style_c.Style.fromStyle(cells.styles[x])
        else
            style_c.Style.fromStyle(.{}),
        .graphemes_len => {
            if (!cell.hasText()) {
                out.* = 0;
                return .success;
            }
            const extra = if (cell.hasGrapheme()) cells.graphemes[x] else &[_]u21{};
            out.* = @intCast(1 + extra.len);
        },
        .graphemes_buf => {
            if (!cell.hasText()) return .success;
            const extra = if (cell.hasGrapheme()) cells.graphemes[x] else &[_]u21{};
            const buf: [*]u32 = @ptrCast(out);
            buf[0] = cell.codepoint();
            for (extra, 1..) |cp, i| {
                buf[i] = cp;
            }
        },
        .bg_color => {
            const s: Style = if (cell.hasStyling()) cells.styles[x] else .{};
            const bg = s.bg(&cell, cells.palette) orelse return .invalid_value;
            out.* = bg.cval();
        },
        .fg_color => {
            const s: Style = if (cell.hasStyling()) cells.styles[x] else .{};
            if (s.fg_color == .none) return .invalid_value;
            const fg = s.fg(.{ .default = .{}, .palette = cells.palette });
            out.* = fg.cval();
        },
        .selected => out.* = if (cells.selection) |sel|
            x >= sel[0] and x <= sel[1]
        else
            false,
        .has_styling => out.* = cell.hasStyling(),
        .graphemes_utf8 => return rowCellsGetGraphemesUtf8(cell, if (cell.hasGrapheme()) cells.graphemes[x] else &.{}, out),
    }

    return .success;
}

fn rowCellsGetGraphemesUtf8(
    cell: page.Cell,
    extra: []const u21,
    out: *lib.Buffer,
) Result {
    out.len = 0;

    if (!cell.hasText()) return .success;

    var needed: usize = std.unicode.utf8CodepointSequenceLength(cell.codepoint()) catch
        return .invalid_value;
    for (extra) |cp| {
        needed += std.unicode.utf8CodepointSequenceLength(cp) catch
            return .invalid_value;
    }
    out.len = needed;

    if (out.ptr == null or out.cap < needed) return .out_of_space;

    const buf = out.ptr.?[0..out.cap];
    var i: usize = 0;
    i += std.unicode.utf8Encode(cell.codepoint(), buf[i..]) catch
        return .invalid_value;
    for (extra) |cp| {
        i += std.unicode.utf8Encode(cp, buf[i..]) catch
            return .invalid_value;
    }

    out.len = i;
    return .success;
}

/// C: GhosttyRenderStateRowData
pub const RowData = enum(c_int) {
    invalid = 0,
    dirty = 1,
    raw = 2,
    cells = 3,
    selection = 4,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: RowData) type {
        return switch (self) {
            .invalid => void,
            .dirty => bool,
            .raw => row.CRow,
            .cells => RowCells,
            .selection => RowSelection,
        };
    }
};

/// C: GhosttyRenderStateRowOption
pub const RowOption = enum(c_int) {
    dirty = 0,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: RowOption) type {
        return switch (self) {
            .dirty => bool,
        };
    }
};

pub fn row_get(
    iterator_: RowIterator,
    data: RowData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowData, @intFromEnum(data)) orelse {
            log.warn("render_state_row_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| rowGetTyped(
            iterator_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

pub fn row_get_multi(
    iterator_: RowIterator,
    count: usize,
    keys: ?[*]const RowData,
    values: ?[*]?*anyopaque,
    out_written: ?*usize,
) callconv(lib.calling_conv) Result {
    const k = keys orelse return .invalid_value;
    const v = values orelse return .invalid_value;

    for (0..count) |i| {
        const result = row_get(iterator_, k[i], v[i]);
        if (result != .success) {
            if (out_written) |w| w.* = i;
            return result;
        }
    }
    if (out_written) |w| w.* = count;
    return .success;
}

fn rowGetTyped(
    iterator_: RowIterator,
    comptime data: RowData,
    out: *data.OutType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (data) {
        .invalid => return .invalid_value,
        .dirty => out.* = it.dirty[y],
        .raw => out.* = it.raws[y].cval(),
        .cells => {
            const cells = out.* orelse return .invalid_value;
            const cell_data = it.cells[y].slice();
            cells.* = .{
                .alloc = cells.alloc,
                .x = null,
                .raws = cell_data.items(.raw),
                .graphemes = cell_data.items(.grapheme),
                .styles = cell_data.items(.style),
                .selection = it.selection[y],
                .palette = it.palette,
            };
        },
        .selection => {
            const out_size = out.size;
            if (out_size < @sizeOf(RowSelection)) return .invalid_value;

            const sel = it.selection[y] orelse return .no_value;
            out.start_x = sel[0];
            out.end_x = sel[1];
        },
    }

    return .success;
}

pub fn row_set(
    iterator_: RowIterator,
    option: RowOption,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(RowOption, @intFromEnum(option)) orelse {
            log.warn("render_state_row_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    return switch (option) {
        inline else => |comptime_option| rowSetTyped(
            iterator_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return .invalid_value)),
        ),
    };
}

fn rowSetTyped(
    iterator_: RowIterator,
    comptime option: RowOption,
    value: *const option.InType(),
) Result {
    const it = iterator_ orelse return .invalid_value;
    const y = it.y orelse return .invalid_value;
    switch (option) {
        .dirty => it.dirty[y] = value.*,
    }

    return .success;
}

test "render: new/free" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    try testing.expect(state != null);
    free(state);
}

test "render: free null" {
    free(null);
}

test "render: update invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, update(null, null));
    try testing.expectEqual(Result.invalid_value, update(state, null));
}

test "render: begin/end update invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, begin_update(null, null));
    try testing.expectEqual(Result.invalid_value, begin_update(state, null));
    try testing.expectEqual(Result.invalid_value, end_update(null));

    // End without a begin is safe.
    try testing.expectEqual(Result.success, end_update(state));
}

test "render: begin/end update" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    defer terminal_c.free(terminal);

    // Write some styled text so that the update has deferred work.
    const t = terminal.?.terminal;
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[1mAB"); // Bold

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    // Begin should record pending work, end should complete it.
    try testing.expectEqual(Result.success, begin_update(state, terminal));
    try testing.expect(state.?.state.pending_styles.items.len > 0);
    try testing.expectEqual(Result.success, end_update(state));
    try testing.expectEqual(0, state.?.state.pending_styles.items.len);

    // The cell styles should be complete.
    const row_data = state.?.state.row_data.slice();
    const cells = row_data.items(.cells);
    try testing.expect(cells[0].get(0).style.flags.bold);
    try testing.expect(cells[0].get(1).style.flags.bold);
}

test "render: get invalid value" {
    var cols: size.CellCountInt = 0;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "render: get invalid data" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, get(state, .invalid, null));
}

test "render: colors get invalid value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);

    try testing.expectEqual(Result.invalid_value, colors_get(null, &colors));
    try testing.expectEqual(Result.invalid_value, colors_get(state, null));

    colors.size = @sizeOf(usize) - 1;
    try testing.expectEqual(Result.invalid_value, colors_get(state, &colors));
}

test "render: get/set dirty invalid value" {
    var dirty: Dirty = .false;
    try testing.expectEqual(Result.invalid_value, get(null, .dirty, @ptrCast(&dirty)));
    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.invalid_value, set(null, .dirty, @ptrCast(&dirty_full)));
}

test "render: get/set dirty" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    var dirty: Dirty = undefined;
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.false, dirty);

    const dirty_partial: Dirty = .partial;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_partial)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.partial, dirty);

    const dirty_full: Dirty = .full;
    try testing.expectEqual(Result.success, set(state, .dirty, @ptrCast(&dirty_full)));
    try testing.expectEqual(Result.success, get(state, .dirty, @ptrCast(&dirty)));
    try testing.expectEqual(Dirty.full, dirty);
}

test "render: set null value" {
    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.invalid_value, set(state, .dirty, null));
}

test "render: row iterator get invalid value" {
    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.invalid_value, get(null, .row_iterator, @ptrCast(&iterator)));
}

test "render: row iterator new/free" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expect(iterator != null);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));

    const iterator_ptr = iterator.?;
    const row_data = state.?.state.row_data.slice();

    try testing.expectEqual(@as(?size.CellCountInt, null), iterator_ptr.y);
    try testing.expectEqual(row_data.items(.raw).len, iterator_ptr.raws.len);
    try testing.expectEqual(row_data.items(.cells).len, iterator_ptr.cells.len);
    try testing.expectEqual(row_data.items(.selection).len, iterator_ptr.selection.len);
    try testing.expectEqual(row_data.items(.dirty).len, iterator_ptr.dirty.len);
}

test "render: row iterator free null" {
    row_iterator_free(null);
}

test "render: row iterator next null" {
    try testing.expect(!row_iterator_next(null));
}

test "render: row get null" {
    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(null, .dirty, @ptrCast(&dirty)));
}

test "render: row get invalid data" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .invalid, null));
}

test "render: row set null" {
    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(null, .dirty, @ptrCast(&dirty)));
}

test "render: row set before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    const dirty = false;
    try testing.expectEqual(Result.invalid_value, row_set(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get before iteration" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));
    var dirty: bool = undefined;
    try testing.expectEqual(Result.invalid_value, row_get(iterator, .dirty, @ptrCast(&dirty)));
}

test "render: row get/set dirty" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    // Dirty the first row so the iterator has at least one dirty row to observe.
    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    // Create an iterator and verify it is dirty.
    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));
    var dirty: bool = undefined;
    try testing.expectEqual(Result.success, row_get(it, .dirty, @ptrCast(&dirty)));
    try testing.expect(dirty);

    // Clear dirty on this row.
    const dirty_false = false;
    try testing.expectEqual(Result.success, row_set(it, .dirty, @ptrCast(&dirty_false)));

    // It should not be dirty anymore.
    var it2: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it2,
    ));
    defer row_iterator_free(it2);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it2)));
    try testing.expect(row_iterator_next(it2));
    try testing.expectEqual(Result.success, row_get(it2, .dirty, @ptrCast(&dirty)));
    try testing.expect(!dirty);
}

test "render: row get selection" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    defer terminal_c.free(terminal);

    const t = terminal.?.terminal;
    const screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ));

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));

    var sel: RowSelection = .{};
    try testing.expect(row_iterator_next(it));
    try testing.expectEqual(Result.no_value, row_get(it, .selection, @ptrCast(&sel)));

    try testing.expect(row_iterator_next(it));
    sel = .{};
    try testing.expectEqual(Result.success, row_get(it, .selection, @ptrCast(&sel)));
    try testing.expectEqual(@as(u16, 2), sel.start_x);
    try testing.expectEqual(@as(u16, 4), sel.end_x);

    try testing.expect(row_iterator_next(it));
    sel = .{};
    try testing.expectEqual(Result.no_value, row_get(it, .selection, @ptrCast(&sel)));
}

test "render: row cells get selected" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    defer terminal_c.free(terminal);

    const t = terminal.?.terminal;
    const screen = t.screens.active;
    try screen.select(.init(
        screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?,
        screen.pages.pin(.{ .active = .{ .x = 4, .y = 1 } }).?,
        false,
    ));

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));

    try testing.expect(row_iterator_next(it));
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    var selected: bool = true;
    try testing.expectEqual(Result.success, row_cells_select(cells, 0));
    try testing.expectEqual(Result.success, row_cells_get(cells, .selected, @ptrCast(&selected)));
    try testing.expect(!selected);

    try testing.expect(row_iterator_next(it));
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    try testing.expectEqual(Result.success, row_cells_select(cells, 1));
    try testing.expectEqual(Result.success, row_cells_get(cells, .selected, @ptrCast(&selected)));
    try testing.expect(!selected);

    try testing.expectEqual(Result.success, row_cells_select(cells, 2));
    try testing.expectEqual(Result.success, row_cells_get(cells, .selected, @ptrCast(&selected)));
    try testing.expect(selected);

    try testing.expectEqual(Result.success, row_cells_select(cells, 4));
    try testing.expectEqual(Result.success, row_cells_get(cells, .selected, @ptrCast(&selected)));
    try testing.expect(selected);

    try testing.expectEqual(Result.success, row_cells_select(cells, 5));
    try testing.expectEqual(Result.success, row_cells_get(cells, .selected, @ptrCast(&selected)));
    try testing.expect(!selected);

    try testing.expectEqual(Result.success, row_cells_select(cells, 3));
    selected = false;
    var written: usize = 0;
    const keys = [_]RowCellsData{.selected};
    var values = [_]?*anyopaque{@ptrCast(&selected)};
    try testing.expectEqual(Result.success, row_cells_get_multi(cells, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expect(selected);
}

test "render: row cells get has_styling" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    defer terminal_c.free(terminal);

    const input = "A\x1b[31mB";
    terminal_c.vt_write(terminal, input, input.len);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    var has_styling = true;
    try testing.expectEqual(Result.success, row_cells_select(cells, 0));
    try testing.expectEqual(Result.success, row_cells_get(cells, .has_styling, @ptrCast(&has_styling)));
    try testing.expect(!has_styling);

    try testing.expectEqual(Result.success, row_cells_select(cells, 1));
    try testing.expectEqual(Result.success, row_cells_get(cells, .has_styling, @ptrCast(&has_styling)));
    try testing.expect(has_styling);

    has_styling = false;
    var written: usize = 0;
    const keys = [_]RowCellsData{.has_styling};
    var values = [_]?*anyopaque{@ptrCast(&has_styling)};
    try testing.expectEqual(Result.success, row_cells_get_multi(cells, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expect(has_styling);
}

test "render: row cells get graphemes utf8" {
    const cases = [_]struct {
        terminal_input: []const u8,
        expected: []const u8,
    }{
        .{
            .terminal_input = "e\u{301}",
            .expected = "e\u{301}",
        },
        .{
            .terminal_input = "\x1b[?2027h\u{1F1FA}\u{1F1F8}",
            .expected = "\u{1F1FA}\u{1F1F8}",
        },
        .{
            .terminal_input = "\x1b[?2027h\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            .expected = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
        },
    };

    for (cases) |case| {
        var terminal: terminal_c.Terminal = null;
        try testing.expectEqual(Result.success, terminal_c.new(
            &lib.alloc.test_allocator,
            &terminal,
            10,
            3,
        ));
        defer terminal_c.free(terminal);

        terminal_c.vt_write(terminal, case.terminal_input.ptr, case.terminal_input.len);

        var state: RenderState = null;
        try testing.expectEqual(Result.success, new(
            &lib.alloc.test_allocator,
            &state,
        ));
        defer free(state);

        try testing.expectEqual(Result.success, update(state, terminal));

        var it: RowIterator = null;
        try testing.expectEqual(Result.success, row_iterator_new(
            &lib.alloc.test_allocator,
            &it,
        ));
        defer row_iterator_free(it);

        var cells: RowCells = null;
        try testing.expectEqual(Result.success, row_cells_new(
            &lib.alloc.test_allocator,
            &cells,
        ));
        defer row_cells_free(cells);

        try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
        try testing.expect(row_iterator_next(it));
        try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

        try testing.expectEqual(Result.success, row_cells_select(cells, 0));

        var text: lib.Buffer = .{};
        try testing.expectEqual(Result.out_of_space, row_cells_get(cells, .graphemes_utf8, @ptrCast(&text)));
        try testing.expectEqual(case.expected.len, text.len);

        var small = [_]u8{'x'} ** 32;
        const small_cap = case.expected.len - 1;
        text = .{ .ptr = small[0..small_cap].ptr, .cap = small_cap };
        try testing.expectEqual(Result.out_of_space, row_cells_get(cells, .graphemes_utf8, @ptrCast(&text)));
        try testing.expectEqual(case.expected.len, text.len);
        try testing.expectEqualSlices(u8, &([_]u8{'x'} ** 32), &small);

        var buf: [32]u8 = undefined;
        text = .{ .ptr = &buf, .cap = case.expected.len };
        try testing.expectEqual(Result.success, row_cells_get(cells, .graphemes_utf8, @ptrCast(&text)));
        try testing.expectEqual(case.expected.len, text.len);
        try testing.expectEqualStrings(case.expected, buf[0..text.len]);
    }

    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        10,
        3,
    ));
    defer terminal_c.free(terminal);

    const input = "e\u{301}";
    terminal_c.vt_write(terminal, input, input.len);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    try testing.expectEqual(Result.success, row_cells_select(cells, 1));
    var buf: [8]u8 = undefined;
    var text: lib.Buffer = .{ .ptr = &buf, .cap = buf.len };
    try testing.expectEqual(Result.success, row_cells_get(cells, .graphemes_utf8, @ptrCast(&text)));
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "render: row iterator next" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var iterator: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &iterator,
    ));
    defer row_iterator_free(iterator);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&iterator)));

    const rows = state.?.state.rows;
    if (rows == 0) {
        try testing.expect(!row_iterator_next(iterator));
        return;
    }

    try testing.expect(row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, 0), iterator.?.y);

    var i: size.CellCountInt = 1;
    while (i < rows) : (i += 1) {
        try testing.expect(row_iterator_next(iterator));
        try testing.expectEqual(@as(?size.CellCountInt, i), iterator.?.y);
    }

    try testing.expect(!row_iterator_next(iterator));
    try testing.expectEqual(@as(?size.CellCountInt, rows - 1), iterator.?.y);
}

test "render: update" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    terminal_c.vt_write(terminal, "hello", 5);
    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: size.CellCountInt = 0;
    var rows_val: size.CellCountInt = 0;
    try testing.expectEqual(Result.success, get(state, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(state, .rows, @ptrCast(&rows_val)));
    try testing.expectEqual(@as(size.CellCountInt, 80), cols);
    try testing.expectEqual(@as(size.CellCountInt, 24), rows_val);
}

test "render: colors get" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    colors.size = @sizeOf(Colors);
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.background.cval(), colors.background);
    try testing.expectEqual(state_colors.foreground.cval(), colors.foreground);

    if (state_colors.cursor) |cursor| {
        try testing.expect(colors.cursor_has_value);
        try testing.expectEqual(cursor.cval(), colors.cursor);
    } else {
        try testing.expect(!colors.cursor_has_value);
    }

    for (state_colors.palette, colors.palette) |expected, actual| {
        try testing.expectEqual(expected.cval(), actual);
    }
}

test "render: row cells bg_color no background" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Write plain text (no background color set).
    terminal_c.vt_write(terminal, "hello", 5);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    // No background set, should return invalid_value.
    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.invalid_value, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
}

test "render: row cells bg_color from style" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Set an RGB background via SGR 48;2;R;G;B and write text.
    terminal_c.vt_write(terminal, "\x1b[48;2;10;20;30mA", 18);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
    try testing.expectEqual(@as(u8, 10), bg.r);
    try testing.expectEqual(@as(u8, 20), bg.g);
    try testing.expectEqual(@as(u8, 30), bg.b);
}

test "render: row cells bg_color from content tag" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Set an RGB background and then erase the line. The erased cells
    // should carry the background color via the content tag (bg_color_rgb)
    // rather than through the style.
    terminal_c.vt_write(terminal, "\x1b[48;2;10;20;30m\x1b[2K", 21);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var bg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .bg_color, @ptrCast(&bg)));
    try testing.expectEqual(@as(u8, 10), bg.r);
    try testing.expectEqual(@as(u8, 20), bg.g);
    try testing.expectEqual(@as(u8, 30), bg.b);
}

test "render: row cells fg_color no foreground" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Write plain text (no foreground color set).
    terminal_c.vt_write(terminal, "hello", 5);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    // No foreground set, should return invalid_value.
    var fg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.invalid_value, row_cells_get(cells, .fg_color, @ptrCast(&fg)));
}

test "render: row cells fg_color from style" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    // Set an RGB foreground via SGR 38;2;R;G;B and write text.
    terminal_c.vt_write(terminal, "\x1b[38;2;10;20;30mA", 18);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var fg: colorpkg.RGB.C = undefined;
    try testing.expectEqual(Result.success, row_cells_get(cells, .fg_color, @ptrCast(&fg)));
    try testing.expectEqual(@as(u8, 10), fg.r);
    try testing.expectEqual(@as(u8, 20), fg.g);
    try testing.expectEqual(@as(u8, 30), fg.b);
}

test "render: colors get supports truncated sized struct" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var colors: Colors = std.mem.zeroes(Colors);
    const sentinel: colorpkg.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    for (&colors.palette) |*entry| entry.* = sentinel;

    colors.size = @offsetOf(Colors, "palette") + @sizeOf(colorpkg.RGB.C) * 2;
    try testing.expectEqual(Result.success, colors_get(state, &colors));

    const state_colors = &state.?.state.colors;
    try testing.expectEqual(state_colors.palette[0].cval(), colors.palette[0]);
    try testing.expectEqual(state_colors.palette[1].cval(), colors.palette[1]);
    try testing.expectEqual(sentinel, colors.palette[2]);
}

test "render: get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var cols: u16 = 0;
    var rows: u16 = 0;
    var written: usize = 0;

    const keys = [_]Data{ .cols, .rows };
    var values = [_]?*anyopaque{ @ptrCast(&cols), @ptrCast(&rows) };
    try testing.expectEqual(Result.success, get_multi(state, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "render: get_multi null returns invalid_value" {
    var cols: u16 = 0;
    var values = [_]?*anyopaque{@ptrCast(&cols)};
    try testing.expectEqual(Result.invalid_value, get_multi(null, 1, null, &values, null));
}

test "render: row_get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var dirty: bool = true;
    var written: usize = 0;

    const keys = [_]RowData{.dirty};
    var values = [_]?*anyopaque{@ptrCast(&dirty)};
    try testing.expectEqual(Result.success, row_get_multi(it, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
}

test "render: row_get_multi null returns invalid_value" {
    var dirty: bool = false;
    var values = [_]?*anyopaque{@ptrCast(&dirty)};
    try testing.expectEqual(Result.invalid_value, row_get_multi(null, 1, null, &values, null));
}

test "render: row_cells_get_multi success" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    defer terminal_c.free(terminal);

    terminal_c.vt_write(terminal, "A", 1);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &state,
    ));
    defer free(state);

    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(
        &lib.alloc.test_allocator,
        &it,
    ));
    defer row_iterator_free(it);

    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(
        &lib.alloc.test_allocator,
        &cells,
    ));
    defer row_cells_free(cells);

    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));
    try testing.expect(row_cells_next(cells));

    var raw: row.CRow = undefined;
    var written: usize = 0;

    const keys = [_]RowCellsData{.raw};
    var values = [_]?*anyopaque{@ptrCast(&raw)};
    try testing.expectEqual(Result.success, row_cells_get_multi(cells, keys.len, &keys, &values, &written));
    try testing.expectEqual(keys.len, written);
}

test "render: row_cells_get_multi null returns invalid_value" {
    var raw: row.CRow = undefined;
    var values = [_]?*anyopaque{@ptrCast(&raw)};
    try testing.expectEqual(Result.invalid_value, row_cells_get_multi(null, 1, null, &values, null));
}

test "render: row_cells_get_all reads a whole row" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        8,
        2,
    ));
    defer terminal_c.free(terminal);

    // "AB" in bold red, then a wide glyph so the spacer tail is covered.
    const seq = "\x1b[1;31mAB\x1b[0m\u{6771}";
    terminal_c.vt_write(terminal, seq, seq.len);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &state));
    defer free(state);
    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(&lib.alloc.test_allocator, &it));
    defer row_iterator_free(it);
    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(&lib.alloc.test_allocator, &cells));
    defer row_cells_free(cells);
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    var entries: [8]RowCellEntry = undefined;
    var styles: [8]style_c.Style = undefined;
    var text: [64]u8 = undefined;
    var batch: RowCellsBatch = .{
        .entries = &entries,
        .entries_cap = entries.len,
        .styles = &styles,
        .styles_cap = styles.len,
        .text = .{ .ptr = &text, .cap = text.len, .len = 0 },
    };

    try testing.expectEqual(Result.success, row_cells_get_all(cells, &batch));
    try testing.expectEqual(@as(usize, 8), batch.entries_len);

    // The batch must agree cell-for-cell with the per-cell reads it replaces.
    for (0..batch.entries_len) |x| {
        try testing.expectEqual(Result.success, row_cells_select(cells, @intCast(x)));

        const entry = entries[x];

        var utf8: [16]u8 = undefined;
        var buf: lib.Buffer = .{ .ptr = &utf8, .cap = utf8.len, .len = 0 };
        try testing.expectEqual(Result.success, row_cells_get(cells, .graphemes_utf8, @ptrCast(&buf)));
        try testing.expectEqual(buf.len, @as(usize, entry.text_len));
        try testing.expectEqualSlices(
            u8,
            utf8[0..buf.len],
            text[entry.text_offset..][0..entry.text_len],
        );

        var raw: page.Cell.C = undefined;
        try testing.expectEqual(Result.success, row_cells_get(cells, .raw, @ptrCast(&raw)));
        const cell: page.Cell = @bitCast(raw);
        try testing.expectEqual(@intFromEnum(cell.wide), entry.wide);
        try testing.expectEqual(cell.hasStyling(), entry.has_styling);

        var fg: colorpkg.RGB.C = undefined;
        const fg_result = row_cells_get(cells, .fg_color, @ptrCast(&fg));
        try testing.expectEqual(fg_result == .success, entry.has_fg);
        if (entry.has_fg) try testing.expectEqual(fg, entry.fg);

        var bg: colorpkg.RGB.C = undefined;
        const bg_result = row_cells_get(cells, .bg_color, @ptrCast(&bg));
        try testing.expectEqual(bg_result == .success, entry.has_bg);
        if (entry.has_bg) try testing.expectEqual(bg, entry.bg);

        var style: style_c.Style = undefined;
        style.size = @sizeOf(style_c.Style);
        try testing.expectEqual(Result.success, row_cells_get(cells, .style, @ptrCast(&style)));
        try testing.expect(entry.style_index < batch.styles_len);
        try testing.expectEqual(style.bold, styles[entry.style_index].bold);
        try testing.expectEqual(style.fg_color.tag, styles[entry.style_index].fg_color.tag);
    }

    // The styled prefix and the unstyled remainder are distinct runs, so the
    // dedup must have produced more than one style but far fewer than 8.
    try testing.expect(batch.styles_len >= 2);
    try testing.expect(batch.styles_len < batch.entries_len);
}

test "render: row_cells_get_all reports required capacity" {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        8,
        2,
    ));
    defer terminal_c.free(terminal);
    terminal_c.vt_write(terminal, "hello", 5);

    var state: RenderState = null;
    try testing.expectEqual(Result.success, new(&lib.alloc.test_allocator, &state));
    defer free(state);
    try testing.expectEqual(Result.success, update(state, terminal));

    var it: RowIterator = null;
    try testing.expectEqual(Result.success, row_iterator_new(&lib.alloc.test_allocator, &it));
    defer row_iterator_free(it);
    try testing.expectEqual(Result.success, get(state, .row_iterator, @ptrCast(&it)));
    try testing.expect(row_iterator_next(it));

    var cells: RowCells = null;
    try testing.expectEqual(Result.success, row_cells_new(&lib.alloc.test_allocator, &cells));
    defer row_cells_free(cells);
    try testing.expectEqual(Result.success, row_get(it, .cells, @ptrCast(&cells)));

    // No buffers at all: the call still reports what the row needs.
    var batch: RowCellsBatch = .{};
    try testing.expectEqual(Result.out_of_space, row_cells_get_all(cells, &batch));
    try testing.expectEqual(@as(usize, 8), batch.entries_len);
    try testing.expectEqual(@as(usize, 5), batch.text.len);

    // A styles array is optional; omitting it leaves every index at zero.
    var entries: [8]RowCellEntry = undefined;
    var text: [8]u8 = undefined;
    batch = .{
        .entries = &entries,
        .entries_cap = entries.len,
        .text = .{ .ptr = &text, .cap = text.len, .len = 0 },
    };
    try testing.expectEqual(Result.success, row_cells_get_all(cells, &batch));
    try testing.expectEqual(@as(usize, 0), batch.styles_len);
    for (entries[0..batch.entries_len]) |entry| {
        try testing.expectEqual(@as(u32, 0), entry.style_index);
    }
    try testing.expectEqualSlices(u8, "hello", text[0..batch.text.len]);
}

test "render: row_cells_get_all null returns invalid_value" {
    var batch: RowCellsBatch = .{};
    try testing.expectEqual(Result.invalid_value, row_cells_get_all(null, &batch));

    var undersized: RowCellsBatch = .{ .size = 1 };
    try testing.expectEqual(Result.invalid_value, row_cells_get_all(null, &undersized));
}
