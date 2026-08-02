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
