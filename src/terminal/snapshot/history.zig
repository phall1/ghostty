//! HISTORY record payload encoding.
//!
//! One HISTORY record describes the complete history for a previously encoded
//! screen. It is followed immediately by the number of complete PAGE records
//! declared by `page_count`. Those pages contain the history older than the
//! first page in the corresponding SCREEN sequence and are ordered from newest
//! to oldest.
//!
//! Every encoded SCREEN has one corresponding HISTORY record. A screen with no
//! older pages uses a zero page count and has no following PAGE records.
//!
//! The first SCREEN page may begin above the active area. Those incidental
//! history rows are already present at READY and are not repeated after
//! HISTORY. The corresponding SCREEN header declares the complete logical
//! history extent, including both that resident overlap and the following PAGE
//! records.
//!
//! All integers are unsigned and little-endian.
//!
//! ## Binary Format
//!
//! A HISTORY record is followed immediately by its declared PAGE records:
//!
//! ```text
//! +----------------------+
//! | HISTORY record       |
//! +----------------------+
//! | PAGE record 0        | newest
//! +----------------------+
//! | ...                  |
//! +----------------------+
//! | PAGE record (n - 1)  | oldest
//! +----------------------+
//!
//! n = page_count
//! ```
//!
//! Newest-to-oldest order lets a reader start showing most-recent
//! history as soon as possible which is more useful to a user.
//!
//! The PAGE sequence may be empty when all history is already included in the
//! first SCREEN page or when the screen has no history.
//!
//! ### Header
//!
//! The HISTORY payload consists only of this fixed header:
//!
//! ```text
//!  0 +--------------------------------+
//!    | Screen key (u16)               |
//!  2 +--------------------------------+
//!    | Following page count (u32)     |
//!  6 +--------------------------------+
//! ```
//!
//! A decoder uses `page_count`, rather than another record tag, to find the end
//! of the page sequence.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");
const page = @import("page.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const TerminalPage = @import("../page.zig").Page;
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;
const Terminal = @import("../Terminal.zig");
const tripwire = @import("../../tripwire.zig");

const history_tw = tripwire.module(enum {
    current_pin,
    boundary_pin,
    encode_page,
}, Allocator.Error);

/// A caller-provided upper bound for one incremental history operation.
pub const Budget = struct {
    bytes: usize,
    rows: usize,
};

/// Result of requesting the next engine-owned history unit.
pub const NextResult = union(enum) {
    /// The checkpoint contains no more history.
    end,
    /// At least one budget dimension is zero. The cursor did not advance.
    zero_budget,
    /// One row cannot fit within the byte budget. The cursor did not advance.
    too_small: struct {
        minimum_bytes: usize,
    },
    /// One complete engine-owned history unit was emitted.
    chunk: struct {
        bytes: usize,
        rows: usize,
        page_complete: bool,
    },
};

pub const CursorError = Allocator.Error ||
    page.EncodeError ||
    TerminalPage.CloneFromError ||
    std.Io.Writer.Error ||
    error{
        Stale,
        Pruned,
        WrongTerminal,
        InvalidHandle,
        WrongGeneration,
        Reset,
        Resize,
        CursorAlreadyTaken,
    };

/// Authenticated identity for one captured history cut.
///
/// `bytes` are semantically opaque: callers may copy them, but construction or
/// mutation is rejected by the owning PageList's private authenticator.
pub const HistoryCheckpoint = struct {
    bytes: TerminalPageList.HistoryLeaseToken,

    pub fn eql(a: HistoryCheckpoint, b: HistoryCheckpoint) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }
};

const CheckpointData = struct {
    screen_generation: usize,
    history_generation: u64,
    newest_serial: u64,
    newest_y: u16,
    oldest_serial: u64,
};

const LeaseState = struct {
    alloc: Allocator,
    terminal: *Terminal,
    key: TerminalScreenKey,
    checkpoint: CheckpointData,
    secret: [32]u8,
    current: ?*TerminalPageList.Pin,
    boundary: ?*TerminalPageList.Pin,
    current_serial: u64,
    boundary_serial: u64,
    pages_inspected: usize = 0,
    inspected_serial: ?u64 = null,
    cursor_taken: bool = false,
    sequence: u64 = 0,
};

fn releaseLeaseState(raw: *anyopaque, pages: *TerminalPageList) void {
    const state: *LeaseState = @ptrCast(@alignCast(raw));
    if (state.current) |pin_| pages.untrackPin(pin_);
    if (state.boundary) |pin_| pages.untrackPin(pin_);
    state.alloc.destroy(state);
}

fn tokenScreenKey(
    token: TerminalPageList.HistoryLeaseToken,
) ?TerminalScreenKey {
    const Tag = @typeInfo(TerminalScreenKey).@"enum".tag_type;
    const value = std.math.cast(Tag, token[8]) orelse return null;
    return @enumFromInt(value);
}

fn resolveLease(
    token: TerminalPageList.HistoryLeaseToken,
    terminal_: *Terminal,
) CursorError!struct {
    screen: *TerminalScreen,
    state: *LeaseState,
} {
    const terminal_address = std.mem.readInt(u64, token[0..8], .little);
    if (terminal_address != @as(u64, @intCast(@intFromPtr(terminal_)))) {
        return error.WrongTerminal;
    }
    const key = tokenScreenKey(token) orelse return error.InvalidHandle;
    const terminal_screen = terminal_.screens.get(key) orelse
        return error.WrongGeneration;
    const token_screen_generation =
        std.mem.readInt(u32, token[18..22], .little);
    if (token_screen_generation !=
        @as(u32, @truncate(terminal_.screens.generation(key))))
    {
        return error.WrongGeneration;
    }
    const raw = switch (terminal_screen.pages.historyLease(token)) {
        .active => |ptr| ptr,
        .stale => return error.Stale,
        .invalid => return error.InvalidHandle,
    };
    const state: *LeaseState = @ptrCast(@alignCast(raw));
    if (terminal_.screens.generation(key) !=
        state.checkpoint.screen_generation)
    {
        return error.WrongGeneration;
    }
    if (terminal_screen.pages.historyGeneration() !=
        state.checkpoint.history_generation)
    {
        return switch (terminal_screen.pages.historyInvalidation()) {
            .reset => error.Reset,
            .resize => error.Resize,
            .none, .stale => error.Stale,
        };
    }
    if (state.boundary) |pin_| {
        if (pin_.garbage or pin_.node.serial != state.boundary_serial) {
            return error.Pruned;
        }
    }
    if (state.current) |pin_| {
        if (pin_.garbage) return error.Pruned;
        if (pin_.node.serial != state.current_serial) return error.Stale;
    }
    return .{ .screen = terminal_screen, .state = state };
}

fn resolveCheckpoint(
    terminal_: *Terminal,
    checkpoint: HistoryCheckpoint,
) error{InvalidCheckpoint}!*LeaseState {
    const resolved = resolveLease(checkpoint.bytes, terminal_) catch
        return error.InvalidCheckpoint;
    return resolved.state;
}

/// Engine-owned lease over one screen's complete historical prefix.
pub const HistoryLease = struct {
    bytes: TerminalPageList.HistoryLeaseToken,

    pub const InitError = Allocator.Error || error{
        ScreenUnavailable,
        LeaseLimitExceeded,
        LeaseGenerationExhausted,
    };

    pub fn init(
        terminal_: *Terminal,
        key: TerminalScreenKey,
    ) InitError!HistoryLease {
        const terminal_screen = terminal_.screens.get(key) orelse
            return error.ScreenUnavailable;
        const newest = terminal_screen.pages.getBottomRight(.history);
        const current_node = if (newest) |pin_| pin_.node else null;
        const current_serial = if (current_node) |node| node.serial else 0;
        const newest_y: u16 = if (newest) |pin_| pin_.y else 0;
        const oldest_node = if (current_node != null)
            terminal_screen.pages.getTopLeft(.screen).node
        else
            null;
        const oldest_serial = if (oldest_node) |node| node.serial else 0;

        var current: ?*TerminalPageList.Pin = null;
        errdefer if (current) |pin_| terminal_screen.pages.untrackPin(pin_);
        if (newest) |pin_| {
            try history_tw.check(.current_pin);
            current = try terminal_screen.pages.trackPin(pin_);
        }

        var boundary: ?*TerminalPageList.Pin = null;
        errdefer if (boundary) |pin_| terminal_screen.pages.untrackPin(pin_);
        if (oldest_node) |node| {
            if (node != current_node.?) {
                try history_tw.check(.boundary_pin);
                boundary = try terminal_screen.pages.trackPin(.{ .node = node });
            }
        }

        const state = try terminal_screen.alloc.create(LeaseState);
        errdefer terminal_screen.alloc.destroy(state);
        state.* = .{
            .alloc = terminal_screen.alloc,
            .terminal = terminal_,
            .key = key,
            .checkpoint = .{
                .screen_generation = terminal_.screens.generation(key),
                .history_generation = terminal_screen.pages.historyGeneration(),
                .newest_serial = current_serial,
                .newest_y = newest_y,
                .oldest_serial = oldest_serial,
            },
            .secret = undefined,
            .current = current,
            .boundary = boundary,
            .current_serial = current_serial,
            .boundary_serial = oldest_serial,
        };
        std.crypto.random.bytes(&state.secret);
        const token = try terminal_screen.pages.registerHistoryLease(
            @intCast(@intFromPtr(terminal_)),
            @intCast(@intFromEnum(key)),
            @truncate(terminal_.screens.generation(key)),
            .{
                .ptr = state,
                .release = releaseLeaseState,
                .generation = undefined,
            },
        );
        current = null;
        boundary = null;
        return .{ .bytes = token };
    }

    pub fn checkpoint(self: *const HistoryLease) HistoryCheckpoint {
        return .{ .bytes = self.bytes };
    }

    pub fn cursor(
        self: *const HistoryLease,
        terminal_: *Terminal,
    ) CursorError!HistoryCursor {
        const resolved = try resolveLease(self.bytes, terminal_);
        if (resolved.state.cursor_taken) return error.CursorAlreadyTaken;
        resolved.state.cursor_taken = true;
        return .{ .bytes = self.bytes };
    }

    pub fn inspectedPages(
        self: *const HistoryLease,
        terminal_: *Terminal,
    ) usize {
        const resolved = resolveLease(self.bytes, terminal_) catch return 0;
        return resolved.state.pages_inspected;
    }

    pub fn abort(self: *const HistoryLease, terminal_: *Terminal) void {
        self.deinit(terminal_);
    }

    pub fn deinit(self: *const HistoryLease, terminal_: *Terminal) void {
        const terminal_address = std.mem.readInt(u64, self.bytes[0..8], .little);
        if (terminal_address != @as(u64, @intCast(@intFromPtr(terminal_)))) {
            return;
        }
        const key = tokenScreenKey(self.bytes) orelse return;
        const terminal_screen = terminal_.screens.get(key) orelse return;
        terminal_screen.pages.releaseHistoryLease(self.bytes);
    }
};

const UnitHeader = struct {
    const magic: u64 = 0x3254494E554847; // "GHUNIT2"
    const prefix_len = 58;
    const len = prefix_len + 32;

    checkpoint: CheckpointData,
    sequence: u64,
    rows: u32,
    payload_len: u32,
    authenticator: [32]u8,

    fn encodePrefix(
        self: UnitHeader,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try io.writeInt(writer, u64, magic);
        try io.writeInt(
            writer,
            u64,
            @intCast(self.checkpoint.screen_generation),
        );
        try io.writeInt(writer, u64, self.checkpoint.history_generation);
        try io.writeInt(writer, u64, self.checkpoint.newest_serial);
        try io.writeInt(writer, u16, self.checkpoint.newest_y);
        try io.writeInt(writer, u64, self.checkpoint.oldest_serial);
        try io.writeInt(writer, u64, self.sequence);
        try io.writeInt(writer, u32, self.rows);
        try io.writeInt(writer, u32, self.payload_len);
    }

    fn authenticate(
        self: UnitHeader,
        secret: [32]u8,
        payload: []const u8,
    ) [32]u8 {
        var prefix: [prefix_len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&prefix);
        self.encodePrefix(&writer) catch unreachable;
        var hasher = std.crypto.hash.Blake3.init(.{ .key = secret });
        hasher.update(&prefix);
        hasher.update(payload);
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }

    fn encode(self: UnitHeader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try self.encodePrefix(writer);
        try writer.writeAll(&self.authenticator);
    }

    const UnitDecodeError = std.Io.Reader.Error || error{
        InvalidHistoryUnit,
        WrongGeneration,
    };

    fn decode(reader: *std.Io.Reader) UnitDecodeError!UnitHeader {
        if (try io.readInt(reader, u64) != magic) {
            return error.InvalidHistoryUnit;
        }
        const screen_generation_u64 = try io.readInt(reader, u64);
        const screen_generation = std.math.cast(
            usize,
            screen_generation_u64,
        ) orelse return error.WrongGeneration;
        return .{
            .checkpoint = .{
                .screen_generation = screen_generation,
                .history_generation = try io.readInt(reader, u64),
                .newest_serial = try io.readInt(reader, u64),
                .newest_y = try io.readInt(reader, u16),
                .oldest_serial = try io.readInt(reader, u64),
            },
            .sequence = try io.readInt(reader, u64),
            .rows = try io.readInt(reader, u32),
            .payload_len = try io.readInt(reader, u32),
            .authenticator = (try reader.takeArray(32)).*,
        };
    }
};

pub const HistoryCursor = struct {
    bytes: TerminalPageList.HistoryLeaseToken,
    /// Emit one authenticated history unit without advancing on a budget
    /// outcome or allocation/encoding failure.
    pub fn next(
        self: *const HistoryCursor,
        terminal_: *Terminal,
        budget: Budget,
        destination: *std.Io.Writer,
    ) CursorError!NextResult {
        const resolved = try resolveLease(self.bytes, terminal_);
        const terminal_screen = resolved.screen;
        const state = resolved.state;
        const pin_ = state.current orelse return .end;
        if (budget.bytes == 0 or budget.rows == 0) return .zero_budget;

        const source_node = pin_.node;
        const row_end: usize = @as(usize, pin_.y) + 1;
        const max_rows = @min(row_end, budget.rows);
        var preserved = try source_node.pagePreservingState(terminal_screen.alloc);
        defer preserved.deinit();
        const source_page = preserved.page();

        try history_tw.check(.encode_page);
        var one = try encodePageSlice(
            terminal_screen.alloc,
            source_page,
            row_end - 1,
            row_end,
        );
        defer one.deinit();
        const one_len = UnitHeader.len + one.written().len;
        if (one_len > budget.bytes) {
            return .{ .too_small = .{ .minimum_bytes = one_len } };
        }

        var low: usize = 1;
        var high: usize = max_rows;
        while (low < high) {
            const candidate = low + (high - low + 1) / 2;
            const fits = fits: {
                var candidate_bytes = try encodePageSlice(
                    terminal_screen.alloc,
                    source_page,
                    row_end - candidate,
                    row_end,
                );
                defer candidate_bytes.deinit();
                break :fits UnitHeader.len + candidate_bytes.written().len <=
                    budget.bytes;
            };
            if (fits) {
                low = candidate;
            } else {
                high = candidate - 1;
            }
        }

        const rows = low;
        var encoded = try encodePageSlice(
            terminal_screen.alloc,
            source_page,
            row_end - rows,
            row_end,
        );
        defer encoded.deinit();
        const encoded_len = UnitHeader.len + encoded.written().len;
        var unit_header: UnitHeader = .{
            .checkpoint = state.checkpoint,
            .sequence = state.sequence,
            .rows = @intCast(rows),
            .payload_len = @intCast(encoded.written().len),
            .authenticator = undefined,
        };
        unit_header.authenticator = unit_header.authenticate(
            state.secret,
            encoded.written(),
        );
        try unit_header.encode(destination);
        try destination.writeAll(encoded.written());

        if (state.inspected_serial != source_node.serial) {
            state.inspected_serial = source_node.serial;
            state.pages_inspected += 1;
        }
        state.sequence += 1;
        const row_start = row_end - rows;
        const page_complete = row_start == 0;
        if (page_complete) {
            if (source_node.serial == state.boundary_serial) {
                terminal_screen.pages.untrackPin(pin_);
                if (state.boundary) |boundary| {
                    terminal_screen.pages.untrackPin(boundary);
                    state.boundary = null;
                }
                state.current = null;
            } else if (source_node.prev) |previous| {
                pin_.node = previous;
                pin_.y = previous.rows() - 1;
                pin_.x = 0;
                state.current_serial = previous.serial;
            } else {
                return error.Pruned;
            }
        } else {
            pin_.y = @intCast(row_start - 1);
        }

        return .{ .chunk = .{
            .bytes = encoded_len,
            .rows = rows,
            .page_complete = page_complete,
        } };
    }
};

const PageSliceEncodeError = Allocator.Error ||
    page.EncodeError ||
    TerminalPage.CloneFromError;

fn encodePageSlice(
    alloc: Allocator,
    source: *const TerminalPage,
    row_start: usize,
    row_end: usize,
) PageSliceEncodeError!std.Io.Writer.Allocating {
    std.debug.assert(row_start < row_end);
    std.debug.assert(row_end <= source.size.rows);

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var stream: record.Writer = .init(alloc, &output.writer);
    defer stream.deinit();

    if (row_start == 0 and row_end == source.size.rows) {
        try page.encode(source, &stream);
    } else {
        var sliced = TerminalPage.init(
            source.exactRowCapacity(row_start, row_end),
        ) catch return error.OutOfMemory;
        defer sliced.deinit();
        sliced.size.rows = @intCast(row_end - row_start);
        try sliced.cloneFrom(source, row_start, row_end);
        try page.encode(&sliced, &stream);
    }
    return output;
}

pub const ImportResult = union(enum) {
    zero_budget,
    too_small: struct {
        required_bytes: usize,
        required_rows: usize,
    },
    imported: struct {
        rows: usize,
        retained: bool,
    },
};

pub const ImportError = Allocator.Error ||
    UnitHeader.UnitDecodeError ||
    page.DecodeError ||
    TerminalPageList.PageAllocation.FinalizeError ||
    error{
        ChunkLimitExceeded,
        InvalidHistoryUnit,
        UnexpectedHistoryUnit,
        Stale,
        WrongTerminal,
        WrongGeneration,
        Reset,
        Resize,
    };

/// Transactional, independently bounded importer for authenticated
/// engine-owned history units. The private unit envelope is not part of the
/// immutable v1/v2 snapshot grammar; its payload is one unchanged PAGE record.
/// Imported pages are prepended while live writes continue at the active end.
pub const HistoryImporter = struct {
    terminal: *Terminal,
    key: TerminalScreenKey,
    screen_generation: usize,
    history_generation: u64,
    import: TerminalPageList.HistoryImport,
    expected_checkpoint: CheckpointData,
    secret: [32]u8,
    deinitialized: bool = false,
    chunks: usize = 0,
    max_chunks: usize,
    imported_prompt: bool = false,
    active: bool = true,

    pub const InitError = Allocator.Error || error{
        ScreenUnavailable,
        InvalidCheckpoint,
    };

    pub fn init(
        terminal_: *Terminal,
        key: TerminalScreenKey,
        max_chunks: usize,
        source_terminal: *Terminal,
        expected_checkpoint: HistoryCheckpoint,
    ) InitError!HistoryImporter {
        const source_state = try resolveCheckpoint(
            source_terminal,
            expected_checkpoint,
        );
        const terminal_screen = terminal_.screens.get(key) orelse
            return error.ScreenUnavailable;
        return .{
            .terminal = terminal_,
            .key = key,
            .screen_generation = terminal_.screens.generation(key),
            .history_generation = terminal_screen.pages.historyGeneration(),
            .expected_checkpoint = source_state.checkpoint,
            .secret = source_state.secret,
            .import = try .init(
                &terminal_screen.pages,
                terminal_screen.alloc,
                max_chunks,
            ),
            .max_chunks = max_chunks,
        };
    }

    /// Decode and prepend exactly one PAGE record.
    ///
    /// Budget failures and malformed units publish nothing. A retained result
    /// is visible immediately, but remains rollback-owned until commit.
    pub fn prepend(
        self: *HistoryImporter,
        terminal_: *Terminal,
        unit: []const u8,
        budget: Budget,
    ) ImportError!ImportResult {
        const terminal_screen = try self.validate(terminal_);
        if (budget.bytes == 0 or budget.rows == 0) return .zero_budget;
        if (self.chunks == self.max_chunks) return error.ChunkLimitExceeded;

        if (unit.len < UnitHeader.len) return error.InvalidHistoryUnit;
        var header_source: std.Io.Reader = .fixed(unit[0..UnitHeader.len]);
        const unit_header = try UnitHeader.decode(&header_source);
        if (!std.meta.eql(
            unit_header.checkpoint,
            self.expected_checkpoint,
        ) or unit_header.sequence != self.expected_sequence) {
            return error.UnexpectedHistoryUnit;
        }
        const payload_len: usize = @intCast(unit_header.payload_len);
        const expected_len = std.math.add(
            usize,
            UnitHeader.len,
            payload_len,
        ) catch return error.InvalidHistoryUnit;
        if (expected_len != unit.len) return error.InvalidHistoryUnit;
        const payload = unit[UnitHeader.len..];
        const expected_authenticator = unit_header.authenticate(
            self.secret,
            payload,
        );
        if (!std.crypto.timing_safe.eql(
            [32]u8,
            expected_authenticator,
            unit_header.authenticator,
        )) return error.InvalidHistoryUnit;
        const rows: usize = @intCast(unit_header.rows);
        if (unit.len > budget.bytes or rows > budget.rows) {
            return .{ .too_small = .{
                .required_bytes = unit.len,
                .required_rows = rows,
            } };
        }

        var source: std.Io.Reader = .fixed(unit[UnitHeader.len..]);
        var decoder: page.Decoder = undefined;
        try decoder.init(&source);
        if (decoder.header.rows != unit_header.rows) {
            return error.InvalidHistoryUnit;
        }

        var allocation = try terminal_screen.pages.allocatePage(
            decoder.capacity(),
        );
        defer allocation.deinit();
        try decoder.decode(allocation.page(), terminal_screen.alloc);
        const contains_prompt = hasSemanticPrompt(allocation.page());
        const retained = try self.import.prepend(&allocation);
        self.imported_prompt = self.imported_prompt or
            (retained and contains_prompt);
        self.chunks += 1;
        self.expected_sequence += 1;
        return .{ .imported = .{
            .rows = rows,
            .retained = retained,
        } };
    }

    pub fn inspectedPrefixNodes(self: *const HistoryImporter) usize {
        return self.import.inspectedPrefixNodes();
    }

    pub fn commit(
        self: *HistoryImporter,
        terminal_: *Terminal,
    ) ImportError!void {
        const terminal_screen = try self.validate(terminal_);
        self.import.commit();
        if (self.imported_prompt) terminal_screen.semantic_prompt.seen = true;
        self.active = false;
    }

    pub fn abort(self: *HistoryImporter) void {
        self.deinit();
    }

    pub fn deinit(self: *HistoryImporter) void {
        if (self.deinitialized) return;
        self.deinitialized = true;
        if (self.active) {
            self.active = false;
            if (self.terminal.screens.generation(self.key) !=
                self.screen_generation or
                self.terminal.screens.get(self.key) == null)
            {
                self.import.abandon();
            }
        }
        self.import.deinit();
    }

    fn validate(
        self: *HistoryImporter,
        terminal_: *Terminal,
    ) ImportError!*TerminalScreen {
        if (!self.active) return error.Stale;
        if (terminal_ != self.terminal) return error.WrongTerminal;
        if (terminal_.screens.generation(self.key) != self.screen_generation) {
            return error.WrongGeneration;
        }
        const terminal_screen = terminal_.screens.get(self.key) orelse
            return error.WrongGeneration;
        if (terminal_screen.pages.historyGeneration() !=
            self.history_generation)
        {
            return switch (terminal_screen.pages.historyInvalidation()) {
                .reset => error.Reset,
                .resize => error.Resize,
                .none, .stale => error.Stale,
            };
        }
        return terminal_screen;
    }
};

/// The complete fixed payload of one HISTORY record.
pub const Header = struct {
    /// Number of encoded bytes in the fixed payload, calculated by its encoder.
    pub const len = computeLen();

    comptime {
        // This size is part of the wire format. If it changes, the snapshot
        // version must also change.
        std.debug.assert(len == 6);
    }

    /// Identifies the previously encoded screen that owns this history.
    key: TerminalScreenKey,

    /// Number of complete PAGE records immediately following this record.
    page_count: u32,

    /// Encode the fixed HISTORY payload.
    pub fn encode(
        self: Header,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try io.writeInt(writer, u16, @intCast(@intFromEnum(self.key)));
        try io.writeInt(writer, u32, self.page_count);
    }

    pub const DecodeError = std.Io.Reader.Error || error{InvalidKey};

    /// Decode and validate the fixed HISTORY payload.
    pub fn decode(reader: *std.Io.Reader) Header.DecodeError!Header {
        const raw = try io.readInt(reader, u16);
        const Tag = @typeInfo(TerminalScreenKey).@"enum".tag_type;
        const value = std.math.cast(Tag, raw) orelse
            return error.InvalidKey;
        const key = std.enums.fromInt(
            TerminalScreenKey,
            value,
        ) orelse return error.InvalidKey;
        return .{
            .key = key,
            .page_count = try io.readInt(reader, u32),
        };
    }

    fn computeLen() usize {
        comptime {
            var buf: [128]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const value: Header = .{
                .key = .primary,
                .page_count = 0,
            };
            value.encode(&writer) catch unreachable;
            return writer.end;
        }
    }
};

/// Errors possible while encoding one HISTORY and its complete PAGE sequence.
pub const EncodeError = Allocator.Error ||
    page.EncodeError ||
    record.Writer.FinishError ||
    error{
        /// The complete historical prefix has more pages than the header fits.
        PageCountOverflow,
    };

/// Incremental encoder for one HISTORY record and its PAGE sequence.
///
/// Each call to `next` emits one complete record. Pages are emitted
/// newest-to-oldest so a decoder can prepend each page immediately.
pub const Encoder = struct {
    terminal_screen: *const TerminalScreen,
    key: TerminalScreenKey,
    next_node: ?*TerminalPageList.List.Node,
    page_count: u32,
    header_pending: bool = true,

    pub fn init(
        terminal_screen: *const TerminalScreen,
        key: TerminalScreenKey,
    ) EncodeError!Encoder {
        const first = terminal_screen.pages.getTopLeft(.active).node.prev;
        var page_count: usize = 0;
        var node = first;
        while (node) |current| : (node = current.prev) page_count += 1;

        return .{
            .terminal_screen = terminal_screen,
            .key = key,
            .next_node = first,
            .page_count = std.math.cast(
                u32,
                page_count,
            ) orelse return error.PageCountOverflow,
        };
    }

    pub fn finished(self: *const Encoder) bool {
        return !self.header_pending and self.next_node == null;
    }

    /// Emit the next complete record in the sequence.
    pub fn next(
        self: *Encoder,
        destination: *record.Writer,
    ) EncodeError!void {
        std.debug.assert(!self.finished());

        if (self.header_pending) {
            const payload = destination.begin(.history);
            errdefer destination.cancel();
            const header: Header = .{
                .key = self.key,
                .page_count = self.page_count,
            };
            try header.encode(payload);
            try destination.finish();
            self.header_pending = false;
            return;
        }

        const current = self.next_node.?;
        var preserved = try current.pagePreservingState(
            self.terminal_screen.alloc,
        );
        defer preserved.deinit();
        try page.encode(preserved.page(), destination);
        self.next_node = current.prev;
    }
};

/// Encode one screen's HISTORY and its complete historical pages.
pub fn encode(
    terminal_screen: *const TerminalScreen,
    key: TerminalScreenKey,
    destination: *record.Writer,
) EncodeError!void {
    var encoder = try Encoder.init(terminal_screen, key);
    while (!encoder.finished()) try encoder.next(destination);
}

/// Errors possible while restoring one HISTORY and its PAGE sequence.
pub const DecodeError = Decoder.InitError ||
    Decoder.RestoreError ||
    error{
        /// The HISTORY key does not match the caller-selected screen.
        UnexpectedScreenKey,
    };

/// A decoded HISTORY manifest ready to restore its following PAGE records.
pub const Decoder = struct {
    header: Header,
    pages_decoded: u32 = 0,

    pub const InitError = Header.DecodeError ||
        record.Reader.InitError ||
        record.Reader.FinishError ||
        error{
            /// The next record is valid but is not a HISTORY.
            UnexpectedRecordTag,
        };

    pub const RestoreError = Allocator.Error ||
        page.DecodeError ||
        TerminalPageList.PageAllocation.FinalizeError ||
        error{
            /// The Screen already contains complete pages before its active page.
            ExistingHistory,
        };

    /// Decode and finish the self-contained HISTORY manifest.
    pub fn init(self: *Decoder, source: *std.Io.Reader) InitError!void {
        var record_reader: record.Reader = undefined;
        try record_reader.init(source);
        if (record_reader.header.tag != .history) {
            return error.UnexpectedRecordTag;
        }
        const header = try Header.decode(record_reader.payloadReader());
        try record_reader.finish();
        self.* = .{ .header = header };
    }

    pub fn needsPage(self: *const Decoder) bool {
        return self.pages_decoded < self.header.page_count;
    }

    pub const PageResult = struct {
        retained: bool,
        contains_prompt: bool,
    };

    /// Restore one validated PAGE into a live transactional history import.
    ///
    /// The returned boolean reports whether the receiving PageList retained
    /// the page under its configured byte and line limits.
    pub fn decodePage(
        self: *Decoder,
        source: *std.Io.Reader,
        alloc: Allocator,
        terminal_screen: *TerminalScreen,
        import: *TerminalPageList.HistoryImport,
    ) RestoreError!PageResult {
        std.debug.assert(self.needsPage());

        var decoder: page.Decoder = undefined;
        try decoder.init(source);
        var allocation = try terminal_screen.pages.allocatePage(
            decoder.capacity(),
        );
        defer allocation.deinit();
        try decoder.decode(allocation.page(), alloc);
        const contains_prompt = hasSemanticPrompt(allocation.page());

        const retained = try import.prepend(&allocation);
        self.pages_decoded += 1;
        return .{
            .retained = retained,
            .contains_prompt = retained and contains_prompt,
        };
    }

    /// Decode and authenticate one PAGE without publishing it.
    pub fn discardPage(
        self: *Decoder,
        source: *std.Io.Reader,
        alloc: Allocator,
    ) RestoreError!void {
        std.debug.assert(self.needsPage());
        var discarded = try page.decode(source, alloc);
        defer discarded.deinit();
        self.pages_decoded += 1;
    }
};

/// Restore one HISTORY and its declared PAGE records into a native Screen.
pub fn decode(
    source: *std.Io.Reader,
    alloc: Allocator,
    expected_key: TerminalScreenKey,
    terminal_screen: *TerminalScreen,
) DecodeError!void {
    var decoder: Decoder = undefined;
    try decoder.init(source);
    if (decoder.header.key != expected_key) return error.UnexpectedScreenKey;

    const active_top = terminal_screen.pages.getTopLeft(.active);
    if (terminal_screen.pages.getTopLeft(.screen).node != active_top.node) {
        return error.ExistingHistory;
    }

    var import = try TerminalPageList.HistoryImport.init(
        &terminal_screen.pages,
        alloc,
        @as(usize, decoder.header.page_count),
    );
    defer import.deinit();
    var contains_prompt = false;
    while (decoder.needsPage()) {
        const result = try decoder.decodePage(
            source,
            alloc,
            terminal_screen,
            &import,
        );
        contains_prompt = contains_prompt or result.contains_prompt;
    }
    if (contains_prompt) terminal_screen.semantic_prompt.seen = true;
    import.commit();
}

fn hasSemanticPrompt(terminal_page: *const TerminalPage) bool {
    const rows = terminal_page.rows.ptr(terminal_page.memory)[0..terminal_page.size.rows];
    for (rows) |row| {
        if (row.semantic_prompt != .none) return true;

        const cells = row.cells.ptr(
            terminal_page.memory,
        )[0..terminal_page.size.cols];
        for (cells) |cell| {
            if (cell.semantic_content == .prompt) return true;
        }
    }
    return false;
}

const test_header_fixture = test_fixture.parse(@embedFile("testdata/history-header-v1.hex"));

test "HISTORY header golden encoding and decoding" {
    const expected: Header = .{
        .key = .alternate,
        .page_count = 0x01020304,
    };
    var encoded: [Header.len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try expected.encode(&writer);
    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/history-header-v1.hex",
        "snapshot_fixture-history-header-v1.hex",
        &test_header_fixture,
        writer.buffered(),
    );
    try std.testing.expectEqual(Header.len, test_header_fixture.len);

    var reader: std.Io.Reader = .fixed(&test_header_fixture);
    try std.testing.expectEqualDeep(expected, try Header.decode(&reader));
    for (0..Header.len) |fixture_len| {
        var truncated: std.Io.Reader = .fixed(
            test_header_fixture[0..fixture_len],
        );
        try std.testing.expectError(
            error.EndOfStream,
            Header.decode(&truncated),
        );
    }

    var invalid_key = test_header_fixture;
    invalid_key[0] = 2;
    var invalid_key_reader: std.Io.Reader = .fixed(&invalid_key);
    try std.testing.expectError(
        error.InvalidKey,
        Header.decode(&invalid_key_reader),
    );
}

test "HISTORY encodes newest first and restores complete history" {
    // Choose an active height which spans two native pages, then grow until
    // exactly two additional complete pages precede the active boundary.
    var probe = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{ .cols = 80, .rows = 1, .max_scrollback_bytes = 0 },
    );
    const page_rows = probe.pages.getTopLeft(.screen).node.capacity().rows;
    probe.deinit();
    const screen_rows = page_rows + 1;

    var source_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer source_screen.deinit();
    source_screen.cursorAbsolute(0, screen_rows - 1);
    while (source_screen.pages.totalPages() < 4) {
        try source_screen.testWriteString("\n");
    }

    const active_top = source_screen.pages.getTopLeft(.active);
    const newest_history = active_top.node.prev.?;
    const oldest_history = newest_history.prev.?;
    try std.testing.expectEqual(
        source_screen.pages.getTopLeft(.screen).node,
        oldest_history,
    );
    try std.testing.expectEqual(null, oldest_history.prev);

    // Mark the two complete historical pages so the wire sequence and final
    // native order are visible. The oldest prompt also verifies derived state
    // is updated only when that page is restored.
    oldest_history.page().getRowAndCell(0, 0).cell.* = .init('A');
    oldest_history.page().getRowAndCell(
        0,
        0,
    ).cell.semantic_content = .prompt;
    newest_history.page().getRowAndCell(0, 0).cell.* = .init('B');

    // Encode SCREEN before history compression, then compress eligible history
    // and require HISTORY encoding to preserve each source storage state.
    var destination: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer destination.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try screen.encode(&source_screen, .primary, &stream);
    const history_offset = destination.written().len;

    _ = source_screen.pages.compress(.full);
    const oldest_storage = oldest_history.storage();
    const newest_storage = newest_history.storage();
    try encode(&source_screen, .primary, &stream);
    try std.testing.expectEqual(oldest_storage, oldest_history.storage());
    try std.testing.expectEqual(newest_storage, newest_history.storage());

    // Inspect the manifest and PAGE records independently. Newest history is
    // sent first even though native PageList order is oldest-to-newest.
    var history_source: std.Io.Reader = .fixed(
        destination.written()[history_offset..],
    );
    var history_record: record.Reader = undefined;
    try history_record.init(&history_source);
    try std.testing.expectEqual(record.Tag.history, history_record.header.tag);
    const header = try Header.decode(history_record.payloadReader());
    try history_record.finish();
    try std.testing.expectEqual(TerminalScreenKey.primary, header.key);
    try std.testing.expectEqual(@as(u32, 2), header.page_count);

    var decoded_newest = try page.decode(
        &history_source,
        std.testing.allocator,
    );
    defer decoded_newest.deinit();
    try std.testing.expectEqual(
        @as(u21, 'B'),
        decoded_newest.getRowAndCell(0, 0).cell.codepoint(),
    );
    var decoded_oldest = try page.decode(
        &history_source,
        std.testing.allocator,
    );
    defer decoded_oldest.deinit();
    try std.testing.expectEqual(
        @as(u21, 'A'),
        decoded_oldest.getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expectError(error.EndOfStream, history_source.takeByte());

    // Restore SCREEN first, then prepend HISTORY directly into that PageList.
    var restore_source: std.Io.Reader = .fixed(destination.written());
    var decoded_screen = try screen.decode(
        &restore_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_screen.deinit();
    try std.testing.expectEqual(
        TerminalScreenKey.primary,
        decoded_screen.key,
    );
    try std.testing.expectEqual(
        @as(u64, @intCast(source_screen.pages.total_rows - screen_rows)),
        decoded_screen.history_rows,
    );
    const restored = &decoded_screen.screen;
    try std.testing.expect(!restored.semantic_prompt.seen);
    try decode(
        &restore_source,
        std.testing.allocator,
        .primary,
        restored,
    );

    try std.testing.expectEqual(
        source_screen.pages.totalPages(),
        restored.pages.totalPages(),
    );
    const restored_oldest = restored.pages.getTopLeft(.screen).node;
    try std.testing.expectEqual(
        @as(u21, 'A'),
        restored_oldest.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expectEqual(
        @as(u21, 'B'),
        restored_oldest.next.?
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expect(restored.semantic_prompt.seen);
    try std.testing.expectError(error.EndOfStream, restore_source.takeByte());

    // Reuse a writable copy of the sequence for failure-path fixtures.
    const encoded = try std.testing.allocator.dupe(
        u8,
        destination.written(),
    );
    defer std.testing.allocator.free(encoded);
    const first_page_offset = history_offset + record.Header.len + Header.len;
    const first_payload_len = std.mem.readInt(
        u32,
        encoded[first_page_offset + 2 ..][0..4],
        .little,
    );
    const second_page_offset =
        first_page_offset + record.Header.len + first_payload_len;

    // Truncate the first PAGE only after its header has exposed a capacity.
    // Its detached allocation is discarded and the live SCREEN list remains
    // completely unchanged.
    var truncated_source: std.Io.Reader = .fixed(
        encoded[0 .. second_page_offset - 1],
    );
    var decoded_truncated = try screen.decode(
        &truncated_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_truncated.deinit();
    const truncated = &decoded_truncated.screen;
    const truncated_screen_first = truncated.pages.getTopLeft(.screen).node;
    const truncated_screen_page_count = truncated.pages.totalPages();
    try std.testing.expectError(
        error.EndOfStream,
        decode(
            &truncated_source,
            std.testing.allocator,
            .primary,
            truncated,
        ),
    );
    try std.testing.expectEqual(
        truncated_screen_page_count,
        truncated.pages.totalPages(),
    );
    try std.testing.expectEqual(
        truncated_screen_first,
        truncated.pages.getTopLeft(.screen).node,
    );
    truncated.pages.assertIntegrity();
    truncated.assertIntegrity();

    // Corrupt only the older PAGE tag. The transactional import rolls back
    // the successfully decoded newer page when the later record fails.
    std.mem.writeInt(
        u16,
        encoded[second_page_offset..][0..2],
        @intFromEnum(record.Tag.screen),
        .little,
    );

    var partial_source: std.Io.Reader = .fixed(encoded);
    var decoded_partial = try screen.decode(
        &partial_source,
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 80,
            .rows = screen_rows,
            .max_scrollback_bytes = null,
        },
    );
    defer decoded_partial.deinit();
    const partial = &decoded_partial.screen;
    const screen_page_count = partial.pages.totalPages();
    const screen_first = partial.pages.getTopLeft(.screen).node;
    const screen_first_codepoint =
        screen_first.page().getRowAndCell(0, 0).cell.codepoint();
    try std.testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            &partial_source,
            std.testing.allocator,
            .primary,
            partial,
        ),
    );
    try std.testing.expectEqual(
        screen_page_count,
        partial.pages.totalPages(),
    );
    try std.testing.expectEqual(
        screen_first,
        partial.pages.getTopLeft(.screen).node,
    );
    try std.testing.expectEqual(
        screen_first_codepoint,
        partial.pages.getTopLeft(.screen).node
            .page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try std.testing.expect(!partial.semantic_prompt.seen);
    partial.pages.assertIntegrity();
    partial.assertIntegrity();
}

test "HISTORY encodes and restores an empty sequence" {
    var terminal_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 2,
            .rows = 2,
            .max_scrollback_bytes = null,
        },
    );
    defer terminal_screen.deinit();

    var destination: std.Io.Writer.Allocating = .init(
        std.testing.allocator,
    );
    defer destination.deinit();
    var stream: record.Writer = .init(
        std.testing.allocator,
        &destination.writer,
    );
    defer stream.deinit();
    try encode(&terminal_screen, .primary, &stream);

    var inspect_source: std.Io.Reader = .fixed(destination.written());
    var history_record: record.Reader = undefined;
    try history_record.init(&inspect_source);
    const header = try Header.decode(history_record.payloadReader());
    try history_record.finish();
    try std.testing.expectEqual(@as(u32, 0), header.page_count);
    try std.testing.expectError(error.EndOfStream, inspect_source.takeByte());

    var decode_source: std.Io.Reader = .fixed(destination.written());
    const initial_first = terminal_screen.pages.getTopLeft(.screen).node;
    try decode(
        &decode_source,
        std.testing.allocator,
        .primary,
        &terminal_screen,
    );
    try std.testing.expectEqual(
        initial_first,
        terminal_screen.pages.getTopLeft(.screen).node,
    );
    try std.testing.expectError(error.EndOfStream, decode_source.takeByte());
}

test "HISTORY rejects invalid routing and incomplete sequences" {
    var terminal_screen = try TerminalScreen.init(
        std.testing.io,
        std.testing.allocator,
        .{
            .cols = 2,
            .rows = 2,
            .max_scrollback_bytes = null,
        },
    );
    defer terminal_screen.deinit();

    // Routing and sequence length still determine which native screen is
    // mutated and where the following record begins, so they remain strict.
    const Case = struct {
        header: Header,
        expected: anyerror,
    };
    const cases = [_]Case{
        .{
            .header = .{
                .key = .alternate,
                .page_count = 0,
            },
            .expected = error.UnexpectedScreenKey,
        },
        .{
            .header = .{
                .key = .primary,
                .page_count = 1,
            },
            .expected = error.EndOfStream,
        },
    };
    for (cases) |case| {
        var destination: std.Io.Writer.Allocating = .init(
            std.testing.allocator,
        );
        defer destination.deinit();
        var stream: record.Writer = .init(
            std.testing.allocator,
            &destination.writer,
        );
        defer stream.deinit();
        const payload = stream.begin(.history);
        errdefer stream.cancel();
        try case.header.encode(payload);
        try stream.finish();

        var source: std.Io.Reader = .fixed(destination.written());
        try std.testing.expectError(
            case.expected,
            decode(
                &source,
                std.testing.allocator,
                .primary,
                &terminal_screen,
            ),
        );
        terminal_screen.pages.assertIntegrity();
        terminal_screen.assertIntegrity();
    }
}

fn testCursorTerminal(
    alloc: Allocator,
    history_pages: usize,
    base: u21,
) !Terminal {
    var terminal_value = try Terminal.init(std.testing.io, alloc, .{
        .cols = 2,
        .rows = 2,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    errdefer terminal_value.deinit(alloc);
    const primary = terminal_value.screens.get(.primary).?;

    var builder = try TerminalPageList.Builder.init(alloc, .{
        .cols = 2,
        .rows = 2,
        .max_size = null,
        .max_lines = null,
    });
    defer builder.deinit();

    for (0..history_pages) |page_index| {
        const terminal_page = try builder.allocatePage(.{
            .cols = 2,
            .rows = 2,
        });
        terminal_page.size.rows = 2;
        for (0..2) |row| {
            const offset: u21 = @intCast(page_index * 2 + row);
            terminal_page.getRowAndCell(0, row).cell.* = .init(base + offset);
        }
    }
    const active = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
    active.size.rows = 2;
    active.getRowAndCell(0, 0).cell.* = .init('x');
    active.getRowAndCell(0, 1).cell.* = .init('y');

    var pages = try builder.finish();
    errdefer pages.deinit();
    const cursor_pin = try pages.trackPin(pages.pin(.{ .active = .{} }).?);
    const cursor_rac = cursor_pin.rowAndCell();
    var replacement: TerminalScreen = .{
        .io = std.testing.io,
        .alloc = alloc,
        .pages = pages,
        .cursor = .{
            .page_pin = cursor_pin,
            .page_row = cursor_rac.row,
            .page_cell = cursor_rac.cell,
        },
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;
    return terminal_value;
}

fn testDecodedFirstCodepoint(unit: []const u8) !u21 {
    var header_source: std.Io.Reader = .fixed(unit[0..UnitHeader.len]);
    const unit_header = try UnitHeader.decode(&header_source);
    var source: std.Io.Reader = .fixed(unit[UnitHeader.len..]);
    var decoded = try page.decode(&source, std.testing.allocator);
    defer decoded.deinit();
    try std.testing.expectEqual(
        unit_header.rows,
        @as(u32, decoded.size.rows),
    );
    try std.testing.expectError(error.EndOfStream, source.takeByte());
    return decoded.getRowAndCell(0, 0).cell.codepoint();
}

fn testLeaseState(
    terminal_: *Terminal,
    lease: HistoryLease,
) *LeaseState {
    return (resolveLease(lease.bytes, terminal_) catch unreachable).state;
}
test "history cursor captures rows sharing the active page" {
    const testing = std.testing;
    var terminal_value = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 2,
        .max_scrollback_bytes = null,
    });
    defer terminal_value.deinit(testing.allocator);
    const terminal_screen = terminal_value.screens.get(.primary).?;
    try terminal_screen.testWriteString("A");
    terminal_screen.cursorAbsolute(0, 1);
    try terminal_screen.testWriteString("\n");
    try testing.expectEqual(@as(usize, 1), terminal_screen.pages.totalPages());
    try testing.expectEqual(
        terminal_screen.pages.getTopLeft(.active).node,
        terminal_screen.pages.getBottomRight(.history).?.node,
    );

    const first_lease = try HistoryLease.init(&terminal_value, .primary);
    defer first_lease.deinit(&terminal_value);
    const first_cut = testLeaseState(&terminal_value, first_lease).checkpoint;
    const first_cursor = try first_lease.cursor(&terminal_value);

    terminal_screen.cursorAbsolute(0, 1);
    try terminal_screen.testWriteString("\n");
    try testing.expectEqual(@as(usize, 1), terminal_screen.pages.totalPages());
    const second_lease = try HistoryLease.init(&terminal_value, .primary);
    defer second_lease.deinit(&terminal_value);
    const second_cut = testLeaseState(&terminal_value, second_lease).checkpoint;
    try testing.expectEqual(first_cut.newest_serial, second_cut.newest_serial);
    try testing.expect(first_cut.newest_y != second_cut.newest_y);

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    const result = try first_cursor.next(
        &terminal_value,
        .{ .bytes = 4096, .rows = 8 },
        &output.writer,
    );
    const chunk = switch (result) {
        .chunk => |value| value,
        else => return error.TestExpectedChunk,
    };
    try testing.expectEqual(@as(usize, 1), chunk.rows);
    try testing.expectEqual(
        @as(u21, 'A'),
        try testDecodedFirstCodepoint(output.written()),
    );
    var end_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer end_output.deinit();
    try testing.expectEqual(
        @as(std.meta.Tag(NextResult), .end),
        std.meta.activeTag(try first_cursor.next(
            &terminal_value,
            .{ .bytes = 4096, .rows = 1 },
            &end_output.writer,
        )),
    );
}

test "history cursor pages newest first within strict budgets" {
    const testing = std.testing;
    var source = try testCursorTerminal(testing.allocator, 3, 'A');
    defer source.deinit(testing.allocator);
    const source_screen = source.screens.get(.primary).?;
    const newest = source_screen.pages.getTopLeft(.active).node.prev.?;
    const middle = newest.prev.?;
    const oldest = middle.prev.?;

    _ = source_screen.pages.compress(.full);
    const storage = [_]TerminalPageList.List.Node.Storage{
        newest.storage(),
        middle.storage(),
        oldest.storage(),
    };

    const pins_before = source_screen.pages.countTrackedPins();
    const lease = try HistoryLease.init(&source, .primary);
    defer lease.deinit(&source);
    const checkpoint_value = lease.checkpoint();
    try testing.expect(checkpoint_value.eql(lease.checkpoint()));
    const cursor_value = try lease.cursor(&source);
    try testing.expectError(error.CursorAlreadyTaken, lease.cursor(&source));

    var no_output: [1]u8 = undefined;
    var no_output_writer: std.Io.Writer = .fixed(&no_output);
    try testing.expectEqual(
        @as(std.meta.Tag(NextResult), .zero_budget),
        std.meta.activeTag(try cursor_value.next(
            &source,
            .{ .bytes = 0, .rows = 1 },
            &no_output_writer,
        )),
    );
    try testing.expectEqual(@as(usize, 0), no_output_writer.end);

    const too_small = try cursor_value.next(
        &source,
        .{ .bytes = 1, .rows = 1 },
        &no_output_writer,
    );
    const minimum_bytes = switch (too_small) {
        .too_small => |value| value.minimum_bytes,
        else => return error.TestExpectedTooSmall,
    };
    try testing.expect(minimum_bytes > 1);
    try testing.expectEqual(@as(usize, 0), no_output_writer.end);

    var units: [6][]u8 = undefined;
    var unit_count: usize = 0;
    defer for (units[0..unit_count]) |unit| testing.allocator.free(unit);
    const expected = [_]u21{ 'F', 'E', 'D', 'C', 'B', 'A' };
    while (unit_count < units.len) : (unit_count += 1) {
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        const result = try cursor_value.next(
            &source,
            .{ .bytes = minimum_bytes + 4096, .rows = 1 },
            &output.writer,
        );
        const chunk = switch (result) {
            .chunk => |value| value,
            else => return error.TestExpectedChunk,
        };
        try testing.expectEqual(@as(usize, 1), chunk.rows);
        try testing.expectEqual(unit_count % 2 == 1, chunk.page_complete);
        try testing.expect(chunk.bytes <= minimum_bytes + 4096);
        try testing.expectEqual(chunk.bytes, output.written().len);
        try testing.expectEqual(
            expected[unit_count],
            try testDecodedFirstCodepoint(output.written()),
        );
        units[unit_count] = try testing.allocator.dupe(u8, output.written());

        if (unit_count == 0) {
            source_screen.cursorAbsolute(0, 1);
            try source_screen.testWriteString("\n");
        }
    }
    var end_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer end_output.deinit();
    try testing.expectEqual(
        @as(std.meta.Tag(NextResult), .end),
        std.meta.activeTag(try cursor_value.next(
            &source,
            .{ .bytes = 4096, .rows = 1 },
            &end_output.writer,
        )),
    );
    try testing.expectEqual(@as(usize, 3), lease.inspectedPages(&source));
    try testing.expectEqual(pins_before, source_screen.pages.countTrackedPins());
    try testing.expectEqual(storage[0], newest.storage());
    try testing.expectEqual(storage[1], middle.storage());
    try testing.expectEqual(storage[2], oldest.storage());

    const cross_lease = try HistoryLease.init(&source, .primary);
    defer cross_lease.deinit(&source);
    const cross_cursor = try cross_lease.cursor(&source);
    var cross_unit: std.Io.Writer.Allocating = .init(testing.allocator);
    defer cross_unit.deinit();
    _ = try cross_cursor.next(
        &source,
        .{ .bytes = 4096, .rows = 1 },
        &cross_unit.writer,
    );

    var destination = try testCursorTerminal(testing.allocator, 1, 'm');
    defer destination.deinit(testing.allocator);
    const destination_screen = destination.screens.get(.primary).?;
    try destination.printString("L");
    try destination.setTitle("live destination");
    destination.modes.values.bracketed_paste = true;
    const active_node = destination_screen.pages.getTopLeft(.active).node;
    const active_first = active_node.page().getRowAndCell(0, 0).cell.codepoint();
    const pages_before_import = destination_screen.pages.totalPages();
    destination_screen.pages.scroll(.top);
    const viewport_codepoint = destination_screen.pages
        .getTopLeft(.viewport).rowAndCell().cell.codepoint();

    var forged_checkpoint = checkpoint_value;
    forged_checkpoint.bytes[31] ^= 0x5A;
    try testing.expectError(
        error.InvalidCheckpoint,
        HistoryImporter.init(
            &destination,
            .primary,
            units.len,
            &source,
            forged_checkpoint,
        ),
    );
    try testing.expectEqual(
        pages_before_import,
        destination_screen.pages.totalPages(),
    );

    var importer = try HistoryImporter.init(
        &destination,
        .primary,
        units.len,
        &source,
        checkpoint_value,
    );
    defer importer.deinit();
    try testing.expectEqual(
        @as(std.meta.Tag(ImportResult), .zero_budget),
        std.meta.activeTag(try importer.prepend(
            &destination,
            units[0],
            .{ .bytes = 0, .rows = 1 },
        )),
    );
    const import_too_small = try importer.prepend(
        &destination,
        units[0],
        .{ .bytes = units[0].len - 1, .rows = 1 },
    );
    try testing.expectEqual(
        @as(std.meta.Tag(ImportResult), .too_small),
        std.meta.activeTag(import_too_small),
    );

    const rejected_pages = destination_screen.pages.totalPages();
    var tampered_header_unit = try testing.allocator.dupe(u8, units[0]);
    defer testing.allocator.free(tampered_header_unit);
    var tampered_source: std.Io.Reader =
        .fixed(tampered_header_unit[0..UnitHeader.len]);
    var tampered_header = try UnitHeader.decode(&tampered_source);
    tampered_header.rows +%= 1;
    var tampered_writer: std.Io.Writer =
        .fixed(tampered_header_unit[0..UnitHeader.len]);
    try tampered_header.encode(&tampered_writer);
    try testing.expectError(
        error.InvalidHistoryUnit,
        importer.prepend(
            &destination,
            tampered_header_unit,
            .{ .bytes = tampered_header_unit.len, .rows = 2 },
        ),
    );

    var oversized_header_unit: [UnitHeader.len]u8 = undefined;
    var oversized_source: std.Io.Reader =
        .fixed(units[0][0..UnitHeader.len]);
    var oversized_header = try UnitHeader.decode(&oversized_source);
    oversized_header.payload_len = std.math.maxInt(u32);
    var oversized_writer: std.Io.Writer = .fixed(&oversized_header_unit);
    try oversized_header.encode(&oversized_writer);
    try testing.expectError(
        error.InvalidHistoryUnit,
        importer.prepend(
            &destination,
            &oversized_header_unit,
            .{ .bytes = std.math.maxInt(usize), .rows = 1 },
        ),
    );
    var spliced_successor = try testing.allocator.dupe(u8, units[1]);
    defer testing.allocator.free(spliced_successor);
    var spliced_source: std.Io.Reader =
        .fixed(spliced_successor[0..UnitHeader.len]);
    var spliced_header = try UnitHeader.decode(&spliced_source);
    spliced_header.sequence = 0;
    var spliced_writer: std.Io.Writer =
        .fixed(spliced_successor[0..UnitHeader.len]);
    try spliced_header.encode(&spliced_writer);
    try testing.expectError(
        error.InvalidHistoryUnit,
        importer.prepend(
            &destination,
            spliced_successor,
            .{ .bytes = spliced_successor.len, .rows = 1 },
        ),
    );
    try testing.expectError(
        error.UnexpectedHistoryUnit,
        importer.prepend(
            &destination,
            units[1],
            .{ .bytes = units[1].len, .rows = 1 },
        ),
    );
    try testing.expectError(
        error.UnexpectedHistoryUnit,
        importer.prepend(
            &destination,
            cross_unit.written(),
            .{ .bytes = cross_unit.written().len, .rows = 1 },
        ),
    );
    var corrupt = try testing.allocator.dupe(u8, units[0]);
    defer testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try testing.expectError(
        error.InvalidHistoryUnit,
        importer.prepend(
            &destination,
            corrupt,
            .{ .bytes = corrupt.len, .rows = 1 },
        ),
    );
    try testing.expectEqual(rejected_pages, destination_screen.pages.totalPages());

    const first_import = try importer.prepend(
        &destination,
        units[0],
        .{ .bytes = units[0].len, .rows = 1 },
    );
    try testing.expect(std.meta.activeTag(first_import) == .imported);
    try testing.expectError(
        error.UnexpectedHistoryUnit,
        importer.prepend(
            &destination,
            units[0],
            .{ .bytes = units[0].len, .rows = 1 },
        ),
    );

    for (units[1..]) |unit| {
        const result = try importer.prepend(
            &destination,
            unit,
            .{ .bytes = unit.len, .rows = 1 },
        );
        const imported = switch (result) {
            .imported => |value| value,
            else => return error.TestExpectedImport,
        };
        try testing.expect(imported.retained);
        try testing.expectEqual(@as(usize, 1), imported.rows);
    }
    try testing.expectEqual(units.len - 1, importer.inspectedPrefixNodes());
    try importer.commit(&destination);

    try testing.expectEqualStrings("live destination", destination.getTitle().?);
    try testing.expect(destination.modes.values.bracketed_paste);
    try testing.expectEqual(
        active_node,
        destination_screen.pages.getTopLeft(.active).node,
    );
    try testing.expectEqual(
        active_first,
        active_node.page().getRowAndCell(0, 0).cell.codepoint(),
    );
    try testing.expectEqual(
        viewport_codepoint,
        destination_screen.pages.getTopLeft(.viewport).rowAndCell().cell.codepoint(),
    );
    try testing.expectEqual(
        pages_before_import + units.len,
        destination_screen.pages.totalPages(),
    );

    const exact_order = [_]u21{ 'A', 'B', 'C', 'D', 'E', 'F', 'm', 'n' };
    var order_index: usize = 0;
    var node = destination_screen.pages.getTopLeft(.screen).node;
    while (node != active_node) : (node = node.next.?) {
        for (0..node.rows()) |row| {
            try testing.expectEqual(
                exact_order[order_index],
                node.page().getRowAndCell(0, row).cell.codepoint(),
            );
            order_index += 1;
        }
    }
    try testing.expectEqual(exact_order.len, order_index);
}

test "history cursor invalidation and transactional abort outcomes" {
    const testing = std.testing;
    var source = try testCursorTerminal(testing.allocator, 3, 'A');
    defer source.deinit(testing.allocator);
    var other = try testCursorTerminal(testing.allocator, 1, 'Q');
    defer other.deinit(testing.allocator);

    {
        const lease = try HistoryLease.init(&source, .primary);
        defer lease.deinit(&source);
        const cursor_value = try lease.cursor(&source);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try testing.expectError(
            error.WrongTerminal,
            cursor_value.next(
                &other,
                .{ .bytes = 4096, .rows = 2 },
                &output.writer,
            ),
        );
        const source_pins =
            source.screens.get(.primary).?.pages.countTrackedPins();
        lease.deinit(&other);
        try testing.expectEqual(
            source_pins,
            source.screens.get(.primary).?.pages.countTrackedPins(),
        );
        var forged_lease = lease;
        forged_lease.bytes[31] ^= 0x5A;
        forged_lease.deinit(&source);
        try testing.expectEqual(
            source_pins,
            source.screens.get(.primary).?.pages.countTrackedPins(),
        );
        var forged_cursor = cursor_value;
        forged_cursor.bytes[31] ^= 0xA5;
        try testing.expectError(
            error.InvalidHandle,
            forged_cursor.next(
                &source,
                .{ .bytes = 4096, .rows = 1 },
                &output.writer,
            ),
        );
        try testing.expectEqual(
            source_pins,
            source.screens.get(.primary).?.pages.countTrackedPins(),
        );
    }
    var prune_source = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 1,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer prune_source.deinit(testing.allocator);
    const prune_screen = prune_source.screens.get(.primary).?;
    const page_rows: usize =
        prune_screen.pages.getTopLeft(.screen).node.capacity().rows;
    prune_screen.cursorAbsolute(0, 0);
    while (prune_screen.pages.totalPages() < 5) {
        try prune_screen.testWriteString("\n");
    }

    const prune_lease = try HistoryLease.init(&prune_source, .primary);
    defer prune_lease.deinit(&prune_source);
    const prune_cursor = try prune_lease.cursor(&prune_source);
    const prune_state = testLeaseState(&prune_source, prune_lease);
    const captured_boundary = prune_state.boundary.?.node;

    // Prepend an older page after capture. Pruning that page applies real
    // pressure but leaves the checkpoint boundary intact, so the cursor must
    // continue rather than silently including or skipping captured history.
    var older = try prune_screen.pages.allocatePage(
        captured_boundary.capacity(),
    );
    defer older.deinit();
    older.page().size.rows = @intCast(page_rows);
    try older.finalize(.prepend);
    prune_screen.pages.setMaxLines(4 * page_rows);
    try testing.expect(!prune_state.boundary.?.garbage);
    try testing.expectEqual(
        captured_boundary,
        prune_screen.pages.getTopLeft(.screen).node,
    );

    var prune_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer prune_output.deinit();
    try testing.expectEqual(
        @as(std.meta.Tag(NextResult), .chunk),
        std.meta.activeTag(try prune_cursor.next(
            &prune_source,
            .{ .bytes = std.math.maxInt(usize), .rows = page_rows },
            &prune_output.writer,
        )),
    );

    // Lowering below the remaining checkpoint prefix now recycles the oldest
    // captured boundary and must produce the explicit Pruned outcome.
    prune_screen.pages.setMaxLines(page_rows + page_rows / 2);
    try testing.expect(prune_state.boundary.?.garbage);
    try testing.expectError(
        error.Pruned,
        prune_cursor.next(
            &prune_source,
            .{ .bytes = std.math.maxInt(usize), .rows = page_rows },
            &prune_output.writer,
        ),
    );

    var reset_source = try testCursorTerminal(testing.allocator, 1, 'A');
    defer reset_source.deinit(testing.allocator);
    {
        const lease = try HistoryLease.init(&reset_source, .primary);
        defer lease.deinit(&reset_source);
        const cursor_value = try lease.cursor(&reset_source);
        reset_source.screens.get(.primary).?.pages.reset();
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try testing.expectError(
            error.Reset,
            cursor_value.next(
                &reset_source,
                .{ .bytes = 4096, .rows = 2 },
                &output.writer,
            ),
        );
    }

    var resize_source = try testCursorTerminal(testing.allocator, 1, 'A');
    defer resize_source.deinit(testing.allocator);
    {
        const lease = try HistoryLease.init(&resize_source, .primary);
        defer lease.deinit(&resize_source);
        const cursor_value = try lease.cursor(&resize_source);
        try resize_source.screens.get(.primary).?.pages.resize(.{ .cols = 3 });
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try testing.expectError(
            error.Resize,
            cursor_value.next(
                &resize_source,
                .{ .bytes = 4096, .rows = 2 },
                &output.writer,
            ),
        );
    }

    var stale_source = try testCursorTerminal(testing.allocator, 1, 'A');
    defer stale_source.deinit(testing.allocator);
    {
        const lease = try HistoryLease.init(&stale_source, .primary);
        defer lease.deinit(&stale_source);
        const cursor_value = try lease.cursor(&stale_source);
        stale_source.screens.get(.primary).?.pages.eraseHistory(null);
        var output: std.Io.Writer.Allocating = .init(testing.allocator);
        defer output.deinit();
        try testing.expectError(
            error.Stale,
            cursor_value.next(
                &stale_source,
                .{ .bytes = 4096, .rows = 2 },
                &output.writer,
            ),
        );
    }

    var generation_source = try testCursorTerminal(testing.allocator, 1, 'A');
    defer generation_source.deinit(testing.allocator);
    _ = try generation_source.switchScreen(.alternate);
    const generation_lease = try HistoryLease.init(&generation_source, .alternate);
    defer generation_lease.deinit(&generation_source);
    const generation_cursor = try generation_lease.cursor(&generation_source);
    _ = try generation_source.switchScreen(.primary);
    generation_source.screens.remove(testing.allocator, .alternate);
    _ = try generation_source.switchScreen(.alternate);
    var generation_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer generation_output.deinit();
    try testing.expectError(
        error.WrongGeneration,
        generation_cursor.next(
            &generation_source,
            .{ .bytes = 4096, .rows = 2 },
            &generation_output.writer,
        ),
    );

    var abort_source = try testCursorTerminal(testing.allocator, 1, 'A');
    defer abort_source.deinit(testing.allocator);
    const abort_lease = try HistoryLease.init(&abort_source, .primary);
    defer abort_lease.deinit(&abort_source);
    const abort_cursor = try abort_lease.cursor(&abort_source);
    var unit: std.Io.Writer.Allocating = .init(testing.allocator);
    defer unit.deinit();
    _ = try abort_cursor.next(
        &abort_source,
        .{ .bytes = 4096, .rows = 2 },
        &unit.writer,
    );

    var abort_destination = try testCursorTerminal(testing.allocator, 1, 'm');
    defer abort_destination.deinit(testing.allocator);
    const abort_screen = abort_destination.screens.get(.primary).?;
    const abort_pages = abort_screen.pages.totalPages();
    const abort_active = abort_screen.pages.getTopLeft(.active).node;
    abort_screen.pages.scroll(.top);
    const abort_viewport_codepoint = abort_screen.pages
        .getTopLeft(.viewport).rowAndCell().cell.codepoint();
    var abort_import = try HistoryImporter.init(
        &abort_destination,
        .primary,
        1,
        &abort_source,
        abort_lease.checkpoint(),
    );
    defer abort_import.deinit();
    _ = try abort_import.prepend(
        &abort_destination,
        unit.written(),
        .{ .bytes = unit.written().len, .rows = 2 },
    );
    abort_import.abort();
    try testing.expectEqual(abort_pages, abort_screen.pages.totalPages());
    try testing.expectEqual(
        abort_active,
        abort_screen.pages.getTopLeft(.active).node,
    );
    try testing.expectEqual(
        abort_viewport_codepoint,
        abort_screen.pages.getTopLeft(.viewport).rowAndCell().cell.codepoint(),
    );

    var ownership_source = try testCursorTerminal(testing.allocator, 1, 'R');
    defer ownership_source.deinit(testing.allocator);
    const ownership_screen = ownership_source.screens.get(.primary).?;
    const ownership_pins = ownership_screen.pages.countTrackedPins();
    const ownership_lease = try HistoryLease.init(&ownership_source, .primary);
    const ownership_alias = ownership_lease;
    const ownership_cursor = try ownership_alias.cursor(&ownership_source);
    const moved_cursor = ownership_cursor;
    ownership_lease.abort(&ownership_source);
    try testing.expectEqual(
        ownership_pins,
        ownership_screen.pages.countTrackedPins(),
    );
    var stale_output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stale_output.deinit();
    try testing.expectError(
        error.Stale,
        moved_cursor.next(
            &ownership_source,
            .{ .bytes = 4096, .rows = 1 },
            &stale_output.writer,
        ),
    );
    ownership_alias.deinit(&ownership_source);
}

test "history lease and cursor OOM release bounded state without advancing" {
    const testing = std.testing;
    const tw = history_tw;
    defer tw.end(.reset) catch unreachable;

    var source = try testCursorTerminal(testing.allocator, 3, 'A');
    defer source.deinit(testing.allocator);
    const source_screen = source.screens.get(.primary).?;
    const initial_pins = source_screen.pages.countTrackedPins();

    // Fail after the current pin was installed but before the boundary pin.
    // HistoryLease.init must release the first pin on this exact seam.
    tw.errorAlways(.boundary_pin, error.OutOfMemory);
    try testing.expectError(
        error.OutOfMemory,
        HistoryLease.init(&source, .primary),
    );
    try testing.expectEqual(initial_pins, source_screen.pages.countTrackedPins());
    try tw.end(.reset);

    const lease = try HistoryLease.init(&source, .primary);
    defer lease.deinit(&source);
    const cursor_value = try lease.cursor(&source);
    const lease_state = testLeaseState(&source, lease);
    const y_before = lease_state.current.?.y;
    const serial_before = lease_state.current_serial;
    const codepoint_before = lease_state.current.?.node.page()
        .getRowAndCell(0, y_before).cell.codepoint();
    const storage_before = lease_state.current.?.node.storage();
    const pins_with_lease = source_screen.pages.countTrackedPins();

    // Fail before any PAGE scratch encoding. No bytes, page state, pin, or
    // continuation coordinate may change, and the same call must be retryable.
    tw.errorAlways(.encode_page, error.OutOfMemory);
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    try testing.expectError(
        error.OutOfMemory,
        cursor_value.next(
            &source,
            .{ .bytes = 4096, .rows = 1 },
            &output.writer,
        ),
    );
    try testing.expectEqual(y_before, lease_state.current.?.y);
    try testing.expectEqual(serial_before, lease_state.current_serial);
    try testing.expectEqual(storage_before, lease_state.current.?.node.storage());
    try testing.expectEqual(
        codepoint_before,
        lease_state.current.?.node.page()
            .getRowAndCell(0, y_before).cell.codepoint(),
    );
    try testing.expectEqual(
        pins_with_lease,
        source_screen.pages.countTrackedPins(),
    );
    try testing.expectEqual(@as(usize, 0), output.written().len);
    try tw.end(.reset);

    const result = try cursor_value.next(
        &source,
        .{ .bytes = 4096, .rows = 1 },
        &output.writer,
    );
    try testing.expectEqual(
        @as(std.meta.Tag(NextResult), .chunk),
        std.meta.activeTag(result),
    );
    lease.abort(&source);
    try testing.expectEqual(initial_pins, source_screen.pages.countTrackedPins());
}

test "history lease slots recycle while stale aliases remain invalid" {
    const testing = std.testing;
    var terminal_value = try testCursorTerminal(testing.allocator, 1, 'A');
    defer terminal_value.deinit(testing.allocator);
    const screen = terminal_value.screens.get(.primary).?;
    const initial_pins = screen.pages.countTrackedPins();

    var stale: ?HistoryLease = null;
    for (0..1024) |index| {
        const lease = try HistoryLease.init(&terminal_value, .primary);
        if (index == 0) stale = lease;
        lease.deinit(&terminal_value);
    }
    try testing.expectEqual(initial_pins, screen.pages.countTrackedPins());
    try testing.expectError(
        error.Stale,
        stale.?.cursor(&terminal_value),
    );

    var active: [TerminalPageList.max_history_leases]HistoryLease = undefined;
    for (&active) |*lease| {
        lease.* = try HistoryLease.init(&terminal_value, .primary);
    }
    try testing.expectError(
        error.LeaseLimitExceeded,
        HistoryLease.init(&terminal_value, .primary),
    );
    for (&active) |*lease| lease.deinit(&terminal_value);
    try testing.expectEqual(initial_pins, screen.pages.countTrackedPins());
}
