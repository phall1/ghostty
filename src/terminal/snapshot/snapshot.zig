//! Complete terminal snapshot encoding and restoration.

const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const checkpoint = @import("checkpoint.zig");
const continuation = @import("continuation.zig");
const envelope = @import("envelope.zig");
const test_fixture = @import("fixture.zig");
const history = @import("history.zig");
const record = @import("record.zig");
const screen = @import("screen.zig");
const terminal = @import("terminal.zig");
const Terminal = @import("../Terminal.zig");
const TerminalStream = @import("../stream_terminal.zig").Stream;
const terminal_kitty = @import("../kitty.zig");
const TerminalPageList = @import("../PageList.zig");
const TerminalScreen = @import("../Screen.zig");
const TerminalSelection = @import("../Selection.zig");
const TerminalScreenKey = @import("../ScreenSet.zig").Key;
const Blake3 = std.crypto.hash.Blake3;

const test_complete_v1_fixture = test_fixture.parse(
    @embedFile("testdata/complete-v1.hex"),
);
const test_complete_v2_fixture = test_fixture.parse(
    @embedFile("testdata/complete-v2.hex"),
);
const test_complete_kitty_placeholder_v2_fixture = test_fixture.parse(
    @embedFile("testdata/complete-kitty-placeholder-v2.hex"),
);

const test_encode_options: EncodeOptions = .{ .continuation = .ground };
const test_decode_options: DecodeOptions = .{ .max_continuation_bytes = 1024 };

fn testRecordOffset(
    bytes: []const u8,
    expected_tag: record.Tag,
    after_ready: bool,
    occurrence: usize,
) usize {
    var offset: usize = envelope.encoded_len;
    var seen_ready = false;
    var found: usize = 0;
    while (offset + record.Header.len <= bytes.len) {
        const tag_raw = std.mem.readInt(
            u16,
            bytes[offset..][0..2],
            .little,
        );
        const payload_len: usize = std.mem.readInt(
            u32,
            bytes[offset + 2 ..][0..4],
            .little,
        );
        const tag = std.enums.fromInt(record.Tag, tag_raw) orelse unreachable;
        if ((!after_ready or seen_ready) and tag == expected_tag) {
            if (found == occurrence) return offset;
            found += 1;
        }
        if (tag == .ready) seen_ready = true;
        offset += record.Header.len + payload_len;
    }
    unreachable;
}

fn framedRecordLen(payload_len: usize) error{RecordLimitExceeded}!usize {
    return std.math.add(
        usize,
        record.Header.len,
        payload_len,
    ) catch error.RecordLimitExceeded;
}

pub const Version = envelope.Version;

/// Re-export continuation to make it a bit more ergonomic to reference.
pub const Continuation = continuation.Value;

/// Immutable feature metadata for the complete snapshot codec. Feature booleans
/// describe the default encoded format; decoding support is version-dispatched.
pub const Capabilities = struct {
    /// Inclusive envelope-version decode bounds.
    min_decode_version: Version,
    max_decode_version: Version,

    /// Version emitted by `encode`.
    default_encode_version: Version,

    /// Features present in `default_encode_version`.
    continuation: bool,
    ready: bool,
    history: bool,
};

pub const capabilities: Capabilities = .{
    .min_decode_version = envelope.min_decode_version,
    .max_decode_version = envelope.max_decode_version,
    .default_encode_version = envelope.default_encode_version,
    .continuation = true,
    .ready = true,
    .history = true,
};

/// Exact native state that the immutable v1/v2 grammar cannot represent.
pub const UnsupportedStateError = error{
    UnsupportedKittyGraphics,
    UnsupportedGlyphGlossary,
};

/// Reject terminal-owned semantics that v1/v2 would otherwise silently omit.
///
/// This scan performs no allocation and must run while the terminal is held
/// immutable, before constructing a record writer or emitting the envelope.
pub fn validateSupportedState(t: *const Terminal) UnsupportedStateError!void {
    if (comptime build_options.kitty_graphics) {
        for ([_]TerminalScreenKey{ .primary, .alternate }) |key| {
            const value = t.screens.get(key) orelse continue;
            if (!value.kitty_images.isSemanticallyEmpty()) {
                return error.UnsupportedKittyGraphics;
            }
        }
    }

    if (!t.glyph_glossary.isEmpty()) {
        return error.UnsupportedGlyphGlossary;
    }
}

/// Errors possible while encoding one complete terminal snapshot.
pub const EncodeError = Allocator.Error ||
    UnsupportedStateError ||
    terminal.EncodeError ||
    screen.EncodeError ||
    history.EncodeError ||
    checkpoint.EncodeError ||
    continuation.EncodeError ||
    error{RecordLimitExceeded};

pub const EncodeOptions = struct {
    continuation: Continuation,
};

pub const EncodeEvent = enum {
    /// One envelope or ordinary data record was emitted.
    progress,

    /// The authenticated active state and continuation are now complete.
    ready,

    /// FINISH was emitted. No further call to `next` is valid.
    finish,
};

/// Bounded incremental complete-snapshot encoder.
///
/// Every call to `next` emits exactly one envelope or framed record. The
/// Terminal and continuation bytes are borrowed and must remain immutable until
/// FINISH or `deinit`.
pub const Encoder = struct {
    const State = enum {
        envelope,
        terminal,
        screens,
        continuation,
        ready,
        histories,
        finish,
        done,
    };
    const keys = [_]TerminalScreenKey{ .primary, .alternate };

    alloc: Allocator,
    terminal_: *const Terminal,
    options: EncodeOptions,
    version: Version,
    stream: record.Writer,
    state: State = .envelope,
    key_index: usize = 0,
    screen_encoder: ?screen.Encoder = null,
    history_encoder: ?history.Encoder = null,

    pub fn init(
        alloc: Allocator,
        destination: *std.Io.Writer,
        t: *const Terminal,
        options: EncodeOptions,
    ) EncodeError!Encoder {
        return initVersion(
            alloc,
            destination,
            t,
            options,
            capabilities.default_encode_version,
            null,
        );
    }

    /// Initialize an encoder whose destination and per-record payload scratch
    /// can never grow past `max_record_bytes`.
    pub fn initLimited(
        alloc: Allocator,
        destination: *std.Io.Writer,
        t: *const Terminal,
        options: EncodeOptions,
        max_record_bytes: usize,
    ) EncodeError!Encoder {
        if (max_record_bytes < record.Header.len)
            return error.RecordLimitExceeded;
        return initVersion(
            alloc,
            destination,
            t,
            options,
            capabilities.default_encode_version,
            max_record_bytes,
        );
    }

    fn initVersion(
        alloc: Allocator,
        destination: *std.Io.Writer,
        t: *const Terminal,
        options: EncodeOptions,
        version: Version,
        max_record_bytes: ?usize,
    ) EncodeError!Encoder {
        switch (version) {
            .v1 => switch (options.continuation) {
                .ground => {},
                .bytes => unreachable,
            },
            .v2 => try continuation.validate(options.continuation),
        }

        try validateSupportedState(t);

        const stream = if (max_record_bytes) |limit|
            try record.Writer.initLimited(
                alloc,
                destination,
                limit - record.Header.len,
            )
        else
            record.Writer.init(alloc, destination);
        return .{
            .alloc = alloc,
            .terminal_ = t,
            .options = options,
            .version = version,
            .stream = stream,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn finished(self: *const Encoder) bool {
        return self.state == .done;
    }

    /// Emit at most one unit of caller-controlled work.
    pub fn next(self: *Encoder) EncodeError!EncodeEvent {
        while (true) switch (self.state) {
            .envelope => {
                try envelope.encodeVersion(self.stream.writer(), self.version);
                self.state = .terminal;
                return .progress;
            },
            .terminal => {
                try terminal.encode(self.terminal_, &self.stream);
                self.state = .screens;
                return .progress;
            },
            .screens => {
                if (self.screen_encoder == null) {
                    while (self.key_index < keys.len) {
                        const key = keys[self.key_index];
                        const value = self.terminal_.screens.get(key) orelse {
                            self.key_index += 1;
                            continue;
                        };
                        self.screen_encoder = try .init(value, key);
                        break;
                    }
                    if (self.screen_encoder == null) {
                        self.key_index = 0;
                        self.state = .continuation;
                        continue;
                    }
                }

                var active = &self.screen_encoder.?;
                try active.next(&self.stream);
                if (active.finished()) {
                    self.screen_encoder = null;
                    self.key_index += 1;
                }
                return .progress;
            },
            .continuation => {
                if (self.version == .v1) {
                    self.state = .ready;
                    continue;
                }
                try continuation.encode(self.options.continuation, &self.stream);
                self.state = .ready;
                return .progress;
            },
            .ready => {
                try checkpoint.encode(.ready, &self.stream);
                self.state = .histories;
                return .ready;
            },
            .histories => {
                if (self.history_encoder == null) {
                    while (self.key_index < keys.len) {
                        const key = keys[self.key_index];
                        const value = self.terminal_.screens.get(key) orelse {
                            self.key_index += 1;
                            continue;
                        };
                        self.history_encoder = try .init(value, key);
                        break;
                    }
                    if (self.history_encoder == null) {
                        self.state = .finish;
                        continue;
                    }
                }

                var active = &self.history_encoder.?;
                try active.next(&self.stream);
                if (active.finished()) {
                    self.history_encoder = null;
                    self.key_index += 1;
                }
                return .progress;
            },
            .finish => {
                try checkpoint.encode(.finish, &self.stream);
                self.state = .done;
                return .finish;
            },
            .done => unreachable,
        };
    }
};

/// Encode one complete terminal snapshot using the incremental state machine.
pub fn encode(
    alloc: Allocator,
    destination: *std.Io.Writer,
    t: *const Terminal,
    options: EncodeOptions,
) EncodeError!void {
    return encodeVersion(
        alloc,
        destination,
        t,
        options,
        capabilities.default_encode_version,
    );
}

/// Version-selectable adapter kept private to freeze legacy v1 fixtures.
fn encodeVersion(
    alloc: Allocator,
    destination: *std.Io.Writer,
    t: *const Terminal,
    options: EncodeOptions,
    version: Version,
) EncodeError!void {
    var encoder = try Encoder.initVersion(
        alloc,
        destination,
        t,
        options,
        version,
        null,
    );
    defer encoder.deinit();
    while (!encoder.finished()) _ = try encoder.next();
}

/// Errors possible while restoring one complete terminal snapshot.
pub const DecodeError = envelope.DecodeError ||
    terminal.DecodeError ||
    screen.DecodeError ||
    history.DecodeError ||
    checkpoint.DecodeError ||
    continuation.DecodeError ||
    error{
        /// A SCREEN names a key not declared by TERMINAL.
        UnexpectedScreenKey,

        /// More than one SCREEN names the same key.
        DuplicateScreen,

        /// A HISTORY names a key not declared by TERMINAL.
        UnexpectedHistoryKey,

        /// More than one HISTORY names the same key.
        DuplicateHistory,

        /// A record payload exceeds caller policy.
        RecordLimitExceeded,

        /// A declared PAGE sequence exceeds caller policy.
        PageLimitExceeded,

        /// History bytes arrived before the caller transferred READY.
        ReadyNotTaken,

        /// This decoder is no longer able to consume input.
        DecoderTerminal,
    };

pub const DecodeOptions = struct {
    /// Largest non-ground continuation the decoder may allocate and return.
    /// Set this to zero when only ground-state snapshots are acceptable.
    max_continuation_bytes: usize,

    /// Largest payload accepted for any single framed record. The default
    /// preserves the complete frozen grammar; streaming callers should set a
    /// smaller transport policy.
    max_record_bytes: usize = std.math.maxInt(u32),

    /// Largest declared SCREEN or HISTORY page sequence. The default preserves
    /// the complete frozen grammar; streaming callers should set a work bound.
    max_pages: usize = std.math.maxInt(u32),
};

/// Ownership transferred exactly once at the authenticated READY boundary.
pub const Ready = struct {
    alloc: Allocator,
    version: Version,
    continuation: ?Continuation,

    /// Replay the authenticated continuation exactly once against the Stream
    /// already attached to the Terminal's final address.
    pub fn replay(
        self: *Ready,
        stream: *TerminalStream,
    ) !void {
        const value = self.continuation orelse
            return error.ContinuationAlreadyReplayed;

        switch (value) {
            .ground => self.continuation = null,
            .bytes => |bytes| {
                // Allocation failure is retry-safe: ownership and Stream state
                // remain untouched until verification storage exists.
                const verification = try self.alloc.alloc(u8, bytes.len);
                defer self.alloc.free(verification);

                self.continuation = null;
                defer self.alloc.free(bytes);
                stream.nextSlice(bytes);

                var writer: std.Io.Writer = .fixed(verification);
                try stream.writeContinuation(&writer);
                if (!std.mem.eql(u8, bytes, writer.buffered())) {
                    return error.ContinuationReplayMismatch;
                }
            },
        }
    }

    /// Release an unreplayed continuation.
    pub fn deinit(self: *Ready) void {
        if (self.continuation) |value| switch (value) {
            .ground => {},
            .bytes => |bytes| self.alloc.free(bytes),
        };
        self.* = undefined;
    }
};

pub const DecodeEvent = union(enum) {
    need_input,
    progress,
    ready: Version,
    history_begin: struct {
        key: TerminalScreenKey,
        page_count: u32,
    },
    history_page: struct {
        key: TerminalScreenKey,
        index: u32,
        count: u32,
        retained: bool,
    },
    finish,
};

pub const PushResult = struct {
    consumed: usize,
    event: DecodeEvent,
};

/// Bounded incremental decoder for one complete snapshot.
///
/// Input may be fragmented at any byte. Only the current record is retained,
/// and its payload length is checked against `DecodeOptions.max_record_bytes`
/// before payload bytes are copied.
pub const Decoder = struct {
    const State = enum {
        envelope,
        terminal,
        screen,
        screen_page,
        continuation,
        ready,
        history,
        history_page,
        finish,
        done,
        failed,
        aborted,
    };

    alloc: Allocator,
    io_: std.Io,
    options: DecodeOptions,
    state: State = .envelope,
    envelope_buffer: [envelope.encoded_len]u8 = undefined,
    envelope_len: usize = 0,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    expected_len: usize = envelope.encoded_len,
    hasher: Blake3 = Blake3.init(.{}),
    version: ?Version = null,
    terminal_: ?Terminal = null,
    live_terminal: ?*Terminal = null,
    decoded_continuation: ?Continuation = null,
    ready_available: bool = false,
    ready_taken: bool = false,
    screen_remaining: usize = 0,
    screen_decoder: ?screen.Decoder = null,
    screen_seen: [2]bool = .{ false, false },
    history_seen: [2]bool = .{ false, false },
    ready_screen_generation: [2]usize = .{ 0, 0 },
    ready_history_generation: [2]u64 = .{ 0, 0 },
    history_discarding: bool = false,
    history_remaining: usize = 0,
    history_decoder: ?history.Decoder = null,
    history_key: TerminalScreenKey = .primary,
    imports: [2]?TerminalPageList.HistoryImport = .{ null, null },
    imported_prompt: [2]bool = .{ false, false },
    last_consumed: usize = 0,

    pub fn init(
        alloc: Allocator,
        io_: std.Io,
        options: DecodeOptions,
    ) Decoder {
        return .{
            .alloc = alloc,
            .io_ = io_,
            .options = options,
        };
    }

    /// Number of bytes required before the next bounded state transition.
    pub fn bytesNeeded(self: *const Decoder) usize {
        if (self.state == .done or
            self.state == .failed or
            self.state == .aborted)
        {
            return 0;
        }
        if (self.state == .envelope) {
            return envelope.encoded_len - self.envelope_len;
        }
        return self.expected_len - self.buffer.items.len;
    }

    /// Bytes accepted from the most recent push when that push returned an
    /// error after completing a bounded transition.
    pub fn consumedOnError(self: *const Decoder) usize {
        return self.last_consumed;
    }

    /// Consume at most the bytes needed for one envelope or record.
    pub fn push(
        self: *Decoder,
        input: []const u8,
    ) DecodeError!PushResult {
        switch (self.state) {
            .done => return .{ .consumed = 0, .event = .finish },
            .failed, .aborted => return error.DecoderTerminal,
            .history, .history_page, .finish => {
                if (!self.ready_taken) return error.ReadyNotTaken;
            },
            else => {},
        }
        self.last_consumed = 0;

        // The fixed envelope validates version dispatch before the decoder
        // performs its first allocation. Record staging begins only afterward.
        if (self.state == .envelope) {
            const wanted = envelope.encoded_len - self.envelope_len;
            const consumed = @min(wanted, input.len);
            @memcpy(
                self.envelope_buffer[self.envelope_len..][0..consumed],
                input[0..consumed],
            );
            self.envelope_len += consumed;
            self.last_consumed = consumed;
            if (self.envelope_len < envelope.encoded_len) {
                return .{ .consumed = consumed, .event = .need_input };
            }

            const event = self.process(&self.envelope_buffer) catch |err| {
                self.fail();
                return err;
            };
            self.expected_len = record.Header.len;
            return .{ .consumed = consumed, .event = event };
        }

        const wanted = self.expected_len - self.buffer.items.len;
        const consumed = @min(wanted, input.len);
        if (consumed > 0) {
            self.buffer.appendSlice(
                self.alloc,
                input[0..consumed],
            ) catch |err| {
                self.fail();
                return err;
            };
        }
        self.last_consumed = consumed;

        if (self.buffer.items.len < self.expected_len) {
            return .{ .consumed = consumed, .event = .need_input };
        }

        if (self.state != .envelope and
            self.expected_len == record.Header.len)
        {
            var header_source: std.Io.Reader = .fixed(self.buffer.items);
            const header = record.Header.decode(&header_source) catch |err| {
                self.fail();
                return err;
            };
            const payload_len: usize = header.payload_len;
            if (payload_len > self.options.max_record_bytes) {
                self.fail();
                return error.RecordLimitExceeded;
            }
            self.expected_len = framedRecordLen(payload_len) catch {
                self.fail();
                return error.RecordLimitExceeded;
            };
            if (self.buffer.items.len < self.expected_len) {
                return .{ .consumed = consumed, .event = .need_input };
            }
        }

        const event = self.process(self.buffer.items) catch |err| {
            self.fail();
            return err;
        };
        self.buffer.clearRetainingCapacity();
        if (self.state != .done) self.expected_len = record.Header.len;
        return .{ .consumed = consumed, .event = event };
    }

    /// Move the READY Terminal exactly once into caller-owned final storage.
    pub fn takeReady(
        self: *Decoder,
        destination: *Terminal,
    ) error{ ReadyUnavailable, ReadyAlreadyTaken }!Ready {
        if (self.ready_taken) return error.ReadyAlreadyTaken;
        if (!self.ready_available or
            self.terminal_ == null or
            self.decoded_continuation == null)
        {
            return error.ReadyUnavailable;
        }

        destination.* = self.terminal_.?;
        self.terminal_ = null;
        self.live_terminal = destination;
        self.ready_taken = true;

        const value = self.decoded_continuation.?;
        self.decoded_continuation = null;
        return .{
            .alloc = self.alloc,
            .version = self.version.?,
            .continuation = value,
        };
    }

    /// Abort decoding, rolling back uncommitted history and releasing all
    /// decoder-owned state. A transferred READY Terminal remains caller-owned.
    pub fn abort(self: *Decoder) void {
        if (self.state == .aborted) return;
        self.rollbackHistory();
        if (self.screen_decoder) |*value| value.deinit();
        self.screen_decoder = null;
        if (self.terminal_) |*value| value.deinit(self.alloc);
        self.terminal_ = null;
        if (self.decoded_continuation) |value| switch (value) {
            .ground => {},
            .bytes => |bytes| self.alloc.free(bytes),
        };
        self.decoded_continuation = null;
        self.ready_available = false;
        self.buffer.clearRetainingCapacity();
        self.state = .aborted;
    }

    pub fn deinit(self: *Decoder) void {
        self.abort();
        for (&self.imports) |*entry| {
            if (entry.*) |*value| value.deinit();
            entry.* = null;
        }
        self.buffer.deinit(self.alloc);
        self.* = undefined;
    }

    fn process(
        self: *Decoder,
        bytes: []const u8,
    ) DecodeError!DecodeEvent {
        if (self.state == .envelope) {
            var source: std.Io.Reader = .fixed(bytes);
            self.version = try envelope.decode(&source);
            self.hasher.update(bytes);
            self.state = .terminal;
            return .progress;
        }

        const state = self.state;
        var source: std.Io.Reader = .fixed(bytes);
        const event = switch (state) {
            .terminal => try self.processTerminal(&source),
            .screen => try self.processScreen(&source),
            .screen_page => try self.processScreenPage(&source),
            .continuation => try self.processContinuation(&source),
            .ready => try self.processReady(&source),
            .history => try self.processHistory(&source),
            .history_page => try self.processHistoryPage(&source),
            .finish => try self.processFinish(&source),
            else => unreachable,
        };
        if (state != .finish) self.hasher.update(bytes);
        return event;
    }

    fn processTerminal(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        var value = try terminal.decode(source, self.io_, self.alloc);
        errdefer value.deinit(self.alloc);
        self.screen_remaining = value.screens.all.count();
        self.history_remaining = self.screen_remaining;
        self.terminal_ = value;
        self.state = .screen;
        return .progress;
    }

    fn screenOptions(self: *Decoder) TerminalScreen.Options {
        const value = &self.terminal_.?;
        const primary = value.screens.get(.primary).?;
        const explicit_bytes = primary.pages.limits.bytes.explicit;
        const explicit_lines = primary.pages.limits.lines.explicit;
        return .{
            .cols = value.cols,
            .rows = value.rows,
            .max_scrollback_bytes = if (explicit_bytes == std.math.maxInt(usize))
                null
            else
                explicit_bytes,
            .max_scrollback_lines = if (explicit_lines == std.math.maxInt(usize))
                null
            else
                explicit_lines,
        };
    }

    fn processScreen(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        std.debug.assert(self.screen_remaining > 0);
        var decoder = try screen.Decoder.init(
            source,
            self.io_,
            self.alloc,
            self.screenOptions(),
        );
        errdefer decoder.deinit();
        if (@as(usize, decoder.header.page_count) > self.options.max_pages) {
            return error.PageLimitExceeded;
        }

        const value = &self.terminal_.?;
        if (value.screens.get(decoder.header.key) == null) {
            return error.UnexpectedScreenKey;
        }
        const index = keyIndex(decoder.header.key);
        if (self.screen_seen[index]) return error.DuplicateScreen;
        self.screen_seen[index] = true;

        self.screen_decoder = decoder;
        self.state = .screen_page;
        return .progress;
    }

    fn processScreenPage(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        var active = &self.screen_decoder.?;
        try active.decodePage(source);
        if (active.needsPage()) return .progress;

        var decoded = try active.finish();
        errdefer decoded.deinit();
        active.deinit();
        self.screen_decoder = null;

        const value = &self.terminal_.?;
        const slot = value.screens.get(decoded.key) orelse
            return error.UnexpectedScreenKey;
        slot.deinit();
        slot.* = decoded.screen;
        decoded.screen = undefined;

        self.screen_remaining -= 1;
        self.state = if (self.screen_remaining == 0)
            if (self.version.? == .v2) .continuation else .ready
        else
            .screen;
        return .progress;
    }

    fn processContinuation(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        self.decoded_continuation = try continuation.decode(
            self.alloc,
            source,
            self.options.max_continuation_bytes,
        );
        self.state = .ready;
        return .progress;
    }

    fn prefixDigest(self: *const Decoder) record.PrefixDigest {
        var result: record.PrefixDigest = undefined;
        self.hasher.final(&result);
        return result;
    }

    fn processReady(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        if (self.version.? == .v1) self.decoded_continuation = .ground;
        try checkpoint.decodeExpected(.ready, source, self.prefixDigest());

        const value = &self.terminal_.?;
        for ([_]TerminalScreenKey{ .primary, .alternate }, 0..) |key, index| {
            self.ready_screen_generation[index] =
                value.screens.generation(key);
            if (value.screens.get(key)) |restored| {
                self.ready_history_generation[index] =
                    restored.pages.historyGeneration();
            }
        }

        self.ready_available = true;
        self.state = .history;
        return .{ .ready = self.version.? };
    }

    fn processHistory(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        std.debug.assert(self.history_remaining > 0);

        var decoder: history.Decoder = undefined;
        try decoder.init(source);
        if (@as(usize, decoder.header.page_count) > self.options.max_pages) {
            return error.PageLimitExceeded;
        }

        const index = keyIndex(decoder.header.key);
        if (!self.screen_seen[index]) return error.UnexpectedHistoryKey;
        if (self.history_seen[index]) return error.DuplicateHistory;
        self.history_seen[index] = true;
        self.history_discarding = !self.historySnapshotValid(index);

        if (!self.history_discarding) {
            const restored =
                self.live_terminal.?.screens.get(decoder.header.key).?;
            self.imports[index] = try .init(
                &restored.pages,
                self.alloc,
                @as(usize, decoder.header.page_count),
            );
        }
        self.history_decoder = decoder;
        self.history_key = decoder.header.key;

        if (decoder.needsPage()) {
            self.state = .history_page;
        } else {
            self.history_remaining -= 1;
            self.state = if (self.history_remaining == 0) .finish else .history;
        }

        return .{ .history_begin = .{
            .key = decoder.header.key,
            .page_count = decoder.header.page_count,
        } };
    }

    fn processHistoryPage(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        var decoder = &self.history_decoder.?;
        const index = keyIndex(self.history_key);
        self.refreshHistoryImport(index);
        const page_index = decoder.pages_decoded;
        var retained = false;

        if (self.history_discarding) {
            try decoder.discardPage(source, self.alloc);
        } else {
            const restored =
                self.live_terminal.?.screens.get(self.history_key).?;
            const result = try decoder.decodePage(
                source,
                self.alloc,
                restored,
                &self.imports[index].?,
            );
            retained = result.retained;
            self.imported_prompt[index] =
                self.imported_prompt[index] or result.contains_prompt;
        }

        const event: DecodeEvent = .{ .history_page = .{
            .key = self.history_key,
            .index = page_index,
            .count = decoder.header.page_count,
            .retained = retained,
        } };
        if (!decoder.needsPage()) {
            self.history_decoder = null;
            self.history_remaining -= 1;
            self.state = if (self.history_remaining == 0) .finish else .history;
        }
        return event;
    }

    fn processFinish(
        self: *Decoder,
        source: *std.Io.Reader,
    ) DecodeError!DecodeEvent {
        try checkpoint.decodeExpected(.finish, source, self.prefixDigest());
        const value = self.live_terminal.?;
        for (&self.imports, 0..) |*entry, index| {
            if (!self.historySnapshotValid(index)) {
                self.invalidateImport(index);
            }
            if (entry.*) |*import| {
                if (import.isActive()) import.commit();
            }
            if (self.imported_prompt[index]) {
                const key = keyForIndex(index);
                if (value.screens.get(key)) |restored| {
                    restored.semantic_prompt.seen = true;
                }
            }
        }
        self.state = .done;
        return .finish;
    }

    fn fail(self: *Decoder) void {
        self.rollbackHistory();
        self.state = .failed;
    }

    fn rollbackHistory(self: *Decoder) void {
        for (0..self.imports.len) |index| self.invalidateImport(index);
    }

    fn refreshHistoryImport(self: *Decoder, index: usize) void {
        if (self.history_discarding) return;
        if (self.historySnapshotValid(index)) return;
        self.invalidateImport(index);
        self.history_discarding = true;
    }

    fn invalidateImport(self: *Decoder, index: usize) void {
        const entry = &self.imports[index];
        if (entry.*) |*value| {
            if (value.isActive()) {
                if (self.screenStorageValid(index)) {
                    value.rollback();
                } else {
                    value.abandon();
                }
            }
        }
        self.imported_prompt[index] = false;
    }

    fn historySnapshotValid(self: *const Decoder, index: usize) bool {
        if (!self.screenStorageValid(index)) return false;
        const restored =
            self.live_terminal.?.screens.get(keyForIndex(index)).?;
        return restored.pages.historyGeneration() ==
            self.ready_history_generation[index];
    }

    fn screenStorageValid(self: *const Decoder, index: usize) bool {
        const value = self.live_terminal orelse return false;
        const key = keyForIndex(index);
        if (value.screens.generation(key) !=
            self.ready_screen_generation[index])
        {
            return false;
        }
        return value.screens.get(key) != null;
    }

    fn keyForIndex(index: usize) TerminalScreenKey {
        return if (index == 0) .primary else .alternate;
    }

    fn keyIndex(key: TerminalScreenKey) usize {
        return switch (key) {
            .primary => 0,
            .alternate => 1,
        };
    }
};

/// One complete decoded Terminal and the bytes needed to resume its Stream.
///
/// A successful decode owns both values. Keep this result alive until the
/// Terminal's Stream has been restored, and always finish by calling `deinit`.
/// The usual restoration sequence is:
///
///   1. Inspect `continuation` and use its length to size continuation tracking.
///   2. Call `toOwned` once and store the returned Terminal at its final address.
///   3. Create the persistent, read-only standard TerminalStream for that
///      address. If `continuation` contains bytes, feed them exactly once and
///      verify that re-exporting the continuation returns the same bytes.
///   4. Call `deinit` to release the decoded continuation. The transferred
///      Terminal and its Stream remain owned by the caller.
///   5. Process PTY bytes that came after the snapshot cut.
///
/// Do not create a Stream against the address of `terminal` in this struct.
/// `toOwned` moves the Terminal, which would leave such a Stream pointing at
/// its old address.
pub const Decoded = struct {
    /// Present until `toOwned` transfers the Terminal to the caller. Callers
    /// may inspect it, but must transfer it before attaching a persistent
    /// TerminalStream.
    terminal: ?Terminal,

    /// Format version selected by the decoded envelope.
    version: Version,

    /// For decoded results, nonempty bytes are allocator-owned and remain
    /// valid until `deinit`. Ground needs no replay. Bytes must be replayed
    /// exactly once after the Terminal has reached its final address.
    continuation: Continuation,

    /// Destroy an untransferred Terminal and always free continuation bytes.
    /// After `toOwned`, this leaves the caller-owned Terminal untouched.
    pub fn deinit(self: *Decoded, alloc: Allocator) void {
        if (self.terminal) |*value| value.deinit(alloc);
        switch (self.continuation) {
            .ground => {},
            .bytes => |bytes| alloc.free(bytes),
        }
        self.* = undefined;
    }

    /// Transfer the Terminal while retaining the continuation for replay.
    ///
    /// This may be called exactly once. Store the returned value directly at
    /// its final address before creating the TerminalStream that will replay
    /// `continuation`.
    pub fn toOwned(self: *Decoded) Terminal {
        const result = self.terminal.?;
        self.terminal = null;
        return result;
    }
};

/// Restore one complete snapshot through the bounded incremental decoder.
///
/// Reads are capped at the decoder's exact current need, so FINISH leaves
/// following transport bytes untouched.
pub fn decode(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeError!Decoded {
    var decoder: Decoder = .init(alloc, io_, options);

    var restored: Terminal = undefined;
    var restored_initialized = false;
    errdefer if (restored_initialized) restored.deinit(alloc);
    defer decoder.deinit();

    var ready: ?Ready = null;
    defer if (ready) |*value| value.deinit();

    var input: [4096]u8 = undefined;
    while (true) {
        const needed = decoder.bytesNeeded();
        std.debug.assert(needed > 0);
        const len = @min(input.len, needed);
        try source.readSliceAll(input[0..len]);
        const pushed = try decoder.push(input[0..len]);
        std.debug.assert(pushed.consumed == len);

        switch (pushed.event) {
            .ready => {
                ready = decoder.takeReady(&restored) catch
                    return error.DecoderTerminal;
                restored_initialized = true;
            },
            .finish => {
                const ready_value = &ready.?;
                const decoded_continuation = ready_value.continuation.?;
                ready_value.continuation = null;
                const version = ready_value.version;

                if (comptime build_options.slow_runtime_safety) {
                    for ([_]TerminalScreenKey{
                        .primary,
                        .alternate,
                    }) |key| {
                        const restored_screen =
                            restored.screens.get(key) orelse continue;
                        restored_screen.pages.assertIntegrity();
                        restored_screen.assertIntegrity();
                    }
                }

                restored_initialized = false;
                return .{
                    .terminal = restored,
                    .version = version,
                    .continuation = decoded_continuation,
                };
            },
            else => {},
        }
    }
}

/// Errors possible while restoring a snapshot that must end at end-of-file.
pub const DecodeExactError = DecodeError || std.Io.Reader.Error || error{
    /// FINISH was followed by additional bytes.
    TrailingData,
};

/// Restore one snapshot and require FINISH to be followed by end-of-file.
///
/// This is intended for bounded snapshot files and buffers. On a live stream,
/// checking for end-of-file may block; use `decode` to stop at FINISH instead.
pub fn decodeExact(
    alloc: Allocator,
    io_: std.Io,
    source: *std.Io.Reader,
    options: DecodeOptions,
) DecodeExactError!Decoded {
    var result = try decode(alloc, io_, source, options);
    errdefer result.deinit(alloc);

    _ = source.peekByte() catch |err| switch (err) {
        error.EndOfStream => return result,
        else => return err,
    };
    return error.TrailingData;
}

test "complete snapshot round trip with history and alternate screen" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 3,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = null,
    });
    defer t.deinit(testing.allocator);

    // Exercise terminal-wide state.
    t.width_px = 800;
    t.height_px = 600;
    t.colors.palette.set(7, .{ .r = 1, .g = 2, .b = 3 });
    t.modes.values.bracketed_paste = true;
    try t.setPwd("file:///tmp/snapshot");
    try t.setTitle("complete snapshot");

    const primary = t.screens.get(.primary).?;

    // Use small exact capacities so this compound golden remains practical to
    // review while still containing two complete history pages and one active
    // page. Replacing the Screen in place preserves ScreenSet routing.
    var replacement: TerminalScreen = replacement: {
        var builder = try TerminalPageList.Builder.init(
            testing.allocator,
            .{
                .cols = t.cols,
                .rows = t.rows,
                .max_size = null,
                .max_lines = null,
            },
        );
        defer builder.deinit();

        const oldest = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        oldest.size.rows = 2;
        oldest.getRowAndCell(0, 0).cell.* = .init('A');

        const recent = try builder.allocatePage(.{ .cols = 2, .rows = 2 });
        recent.size.rows = 2;
        recent.getRowAndCell(0, 0).cell.* = .init('B');

        const active = try builder.allocatePage(.{ .cols = 2, .rows = 3 });
        active.size.rows = 3;
        active.getRowAndCell(0, 0).cell.* = .init('C');
        active.getRowAndCell(0, 1).cell.* = .init('D');
        active.getRowAndCell(0, 2).cell.* = .init('E');

        var pages = try builder.finish();
        errdefer pages.deinit();

        const cursor_pin = try pages.trackPin(
            pages.pin(.{ .active = .{} }).?,
        );
        const cursor_rac = cursor_pin.rowAndCell();
        break :replacement .{
            .io = testing.io,
            .alloc = testing.allocator,
            .pages = pages,
            .cursor = .{
                .page_pin = cursor_pin,
                .page_row = cursor_rac.row,
                .page_cell = cursor_rac.cell,
            },
        };
    };
    primary.deinit();
    primary.* = replacement;
    replacement = undefined;

    try testing.expect(primary.pages.scrollbar().total > t.rows);

    // Compression is an internal source representation and must remain
    // unchanged while the complete history is inspected for encoding.
    _ = primary.pages.compress(.full);
    const source_memory = primary.pages.memoryStats();

    // The optional alternate screen participates in both phases and remains
    // the active screen after restoration.
    _ = try t.switchScreen(.alternate);
    try t.printString("alternate");

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try testing.expectEqualDeep(source_memory, primary.pages.memoryStats());
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v2.hex",
        "snapshot_fixture-complete-v2.hex",
        &test_complete_v2_fixture,
        encoded.written(),
    );

    // A complete snapshot can stream through a non-allocating destination.
    // Independently hash that output so both its length and complete byte
    // sequence are checked without retaining a second snapshot copy.
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var hashing = discard.writer.hashed(
        std.crypto.hash.Blake3.init(.{}),
        &.{},
    );
    try encode(testing.allocator, &hashing.writer, &t, test_encode_options);
    try testing.expectEqual(
        @as(u64, test_complete_v2_fixture.len),
        discard.fullCount(),
    );
    var expected_digest: checkpoint.Digest = undefined;
    std.crypto.hash.Blake3.hash(
        &test_complete_v2_fixture,
        &expected_digest,
        .{},
    );
    var actual_digest: checkpoint.Digest = undefined;
    hashing.hasher.final(&actual_digest);
    try testing.expectEqual(expected_digest, actual_digest);

    // Restore the checked-in reference rather than the just-generated bytes.
    var encoded_source: std.Io.Reader = .fixed(&test_complete_v2_fixture);
    var source_buffer: [1]u8 = undefined;
    var limited = encoded_source.limited(.unlimited, &source_buffer);
    var restored = try decode(
        testing.allocator,
        testing.io,
        &limited.interface,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    try testing.expectEqual(Version.v2, restored.version);
    const restored_terminal = &restored.terminal.?;

    try testing.expectEqual(
        TerminalScreenKey.alternate,
        restored_terminal.screens.active_key,
    );
    try testing.expectEqual(
        restored_terminal.screens.get(.alternate).?,
        restored_terminal.screens.active,
    );
    try testing.expectEqualStrings(
        "file:///tmp/snapshot",
        restored_terminal.getPwd().?,
    );
    try testing.expectEqualStrings(
        "complete snapshot",
        restored_terminal.getTitle().?,
    );
    try testing.expectEqual(
        primary.pages.scrollbar().total,
        restored_terminal.screens.get(.primary).?.pages.scrollbar().total,
    );

    // Re-encoding is a compact semantic equality check over all TERMINAL,
    // SCREEN, PAGE, and HISTORY fields and both checkpoint boundaries.
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        restored_terminal,
        test_encode_options,
    );
    try testing.expectEqualStrings(
        &test_complete_v2_fixture,
        reencoded.written(),
    );

    // SCREEN and HISTORY keys make both sequence groups order independent.
    var reversed: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reversed.deinit();
    var reversed_stream: record.Writer = .init(
        testing.allocator,
        &reversed.writer,
    );
    defer reversed_stream.deinit();
    try envelope.encode(reversed_stream.writer());
    try terminal.encode(&t, &reversed_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try screen.encode(primary, .primary, &reversed_stream);
    try continuation.encode(.ground, &reversed_stream);
    try checkpoint.encode(.ready, &reversed_stream);
    try history.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &reversed_stream,
    );
    try history.encode(primary, .primary, &reversed_stream);
    try checkpoint.encode(.finish, &reversed_stream);

    var reversed_source: std.Io.Reader = .fixed(reversed.written());
    var reversed_restored = try decode(
        testing.allocator,
        testing.io,
        &reversed_source,
        test_decode_options,
    );
    defer reversed_restored.deinit(testing.allocator);
    const reversed_terminal = &reversed_restored.terminal.?;
    try testing.expectEqual(
        TerminalScreenKey.alternate,
        reversed_terminal.screens.active_key,
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.primary),
    );
    try testing.expectEqual(
        @as(usize, 0),
        reversed_terminal.screens.generation(.alternate),
    );
}

test "v1 decode is ground-compatible and default re-encoding upgrades to v2" {
    const testing = std.testing;

    var source: std.Io.Reader = .fixed(&test_complete_v1_fixture);
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        .{ .max_continuation_bytes = 0 },
    );
    defer decoded.deinit(testing.allocator);

    try testing.expectEqual(Version.v1, decoded.version);
    switch (decoded.continuation) {
        .ground => {},
        .bytes => return error.TestUnexpectedResult,
    }

    // The private version-selectable path freezes the original v1 grammar and
    // bytes. Public encoding deliberately has no legacy-version ambiguity.
    var frozen_v1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer frozen_v1.deinit();
    try encodeVersion(
        testing.allocator,
        &frozen_v1.writer,
        &decoded.terminal.?,
        test_encode_options,
        .v1,
    );
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v1.hex",
        "snapshot_fixture-complete-v1.hex",
        &test_complete_v1_fixture,
        frozen_v1.written(),
    );

    var upgraded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer upgraded.deinit();
    try encode(
        testing.allocator,
        &upgraded.writer,
        &decoded.terminal.?,
        test_encode_options,
    );
    try test_fixture.expectEqual(
        .snapshot,
        "src/terminal/snapshot/testdata/complete-v2.hex",
        "snapshot_fixture-complete-v2-upgrade.hex",
        &test_complete_v2_fixture,
        upgraded.written(),
    );
}

test "unknown version is rejected before record allocation" {
    const testing = std.testing;

    var unknown = test_complete_v2_fixture;
    std.mem.writeInt(u16, unknown[8..10], 3, .little);
    var source: std.Io.Reader = .fixed(&unknown);
    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.UnsupportedVersion,
        decode(
            failing.allocator(),
            testing.io,
            &source,
            test_decode_options,
        ),
    );
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(usize, envelope.encoded_len), source.seek);
}

test "v2 restores a split continuation before immediate PTY bytes" {
    const testing = std.testing;

    var source_terminal = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 8, .rows = 2 },
    );
    defer source_terminal.deinit(testing.allocator);
    var source_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&source_terminal),
        .continuation_max_bytes = 1024,
    });
    defer source_stream.deinit();

    source_stream.nextSlice("A\x1b[31");
    var exported_bytes: [1024]u8 = undefined;
    var exported: std.Io.Writer = .fixed(&exported_bytes);
    try source_stream.writeContinuation(&exported);
    try testing.expectEqualStrings("\x1b[31", exported.buffered());

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &source_terminal, .{
        .continuation = .{ .bytes = exported.buffered() },
    });

    var encoded_source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &encoded_source,
        .{ .max_continuation_bytes = 1024 },
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(Version.v2, decoded.version);
    try testing.expectEqualStrings(
        exported.buffered(),
        decoded.continuation.bytes,
    );

    var restored_terminal = decoded.toOwned();
    defer restored_terminal.deinit(testing.allocator);
    try testing.expect(decoded.terminal == null);
    var restored_stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&restored_terminal),
        .continuation_max_bytes = 1024,
    });
    defer restored_stream.deinit();

    restored_stream.nextSlice(decoded.continuation.bytes);
    var reexported_bytes: [1024]u8 = undefined;
    var reexported: std.Io.Writer = .fixed(&reexported_bytes);
    try restored_stream.writeContinuation(&reexported);
    try testing.expectEqualStrings(exported.buffered(), reexported.buffered());

    // The identical post-cut bytes may use different feed chunking without
    // changing terminal semantics.
    source_stream.nextSlice("mB");
    restored_stream.next('m');
    restored_stream.next('B');
    const source_text = try source_terminal.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    try testing.expectEqual(
        source_terminal.screens.active.cursor.style_id,
        restored_terminal.screens.active.cursor.style_id,
    );
}

test "complete snapshot validates continuation before writing" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);

    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.ContinuationEndsAtGround,
        encode(testing.allocator, &destination.writer, &t, .{
            .continuation = .{ .bytes = "\x1b[31m" },
        }),
    );
    try testing.expectEqualStrings("prefix", destination.written());

    var tail = [_]u8{ 0x1b, '[', '3', '1' };
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = &tail },
    });
    tail[2] = '4';

    var source: std.Io.Reader = .fixed(encoded.written());
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings("\x1b[31", decoded.continuation.bytes);
}

test "complete snapshot waits for continuation tracking recovery" {
    const testing = std.testing;
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&t),
        .continuation_max_bytes = 4,
    });
    defer stream.deinit();

    stream.nextSlice("\x1b[123");
    var unavailable_bytes: [4]u8 = undefined;
    var unavailable: std.Io.Writer = .fixed(&unavailable_bytes);
    try testing.expectError(
        error.ContinuationUnavailable,
        stream.writeContinuation(&unavailable),
    );

    // A new replay start replaces the lost suffix and makes a later cut
    // publishable without affecting normal terminal parsing.
    stream.nextSlice("\x1b[");
    var recovered_bytes: [4]u8 = undefined;
    var recovered: std.Io.Writer = .fixed(&recovered_bytes);
    try stream.writeContinuation(&recovered);
    try testing.expectEqualStrings("\x1b[", recovered.buffered());

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = recovered.buffered() },
    });
}

test "complete snapshot preserves every supported continuation cut" {
    const testing = std.testing;
    const corpora = [_][]const u8{
        "plain \xF0\x9F\x98\x84 utf8",
        "bad \xE0\xA0\xF0\x9F\x98\x84 utf8",
        "\x1b[1\x07;2mstyled\x1b[0m",
        "\x1b]2;window title\x1b\\text",
        "\x1bP$qm\x1b\\text",
        "\x1b_Ga=q;payload\x1b\\text",
        "\x1b_25a1;s\x1b\\text",
        "\x1b]2;first\x1b\\\x1b_Gsecond",
        "\x1b[12\x9D2;title\x1b\\text",
        "\x1b[12\x18text\x1b[1\x1Atext",
    };

    for (corpora) |corpus| for (0..corpus.len + 1) |cut| {
        var source_terminal = try Terminal.init(
            testing.io,
            testing.allocator,
            .{ .cols = 20, .rows = 4 },
        );
        defer source_terminal.deinit(testing.allocator);
        var source_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&source_terminal),
            .continuation_max_bytes = 4096,
        });
        defer source_stream.deinit();
        source_stream.nextSlice(corpus[0..cut]);

        var cut_bytes: [4096]u8 = undefined;
        var cut_writer: std.Io.Writer = .fixed(&cut_bytes);
        try source_stream.writeContinuation(&cut_writer);
        const cut_continuation: Continuation = if (cut_writer.end == 0)
            .ground
        else
            .{ .bytes = cut_writer.buffered() };

        var snapshot_bytes: std.Io.Writer.Allocating = .init(testing.allocator);
        defer snapshot_bytes.deinit();
        try encode(
            testing.allocator,
            &snapshot_bytes.writer,
            &source_terminal,
            .{ .continuation = cut_continuation },
        );

        var snapshot_source: std.Io.Reader = .fixed(snapshot_bytes.written());
        var decoded = try decode(
            testing.allocator,
            testing.io,
            &snapshot_source,
            .{ .max_continuation_bytes = 4096 },
        );
        defer decoded.deinit(testing.allocator);
        var restored_terminal = decoded.toOwned();
        defer restored_terminal.deinit(testing.allocator);
        var restored_stream = TerminalStream.init(.{
            .allocator = testing.allocator,
            .handler = .init(&restored_terminal),
            .continuation_max_bytes = 4096,
        });
        defer restored_stream.deinit();
        switch (decoded.continuation) {
            .ground => {},
            .bytes => |bytes| restored_stream.nextSlice(bytes),
        }

        var reexport_bytes: [4096]u8 = undefined;
        var reexport_writer: std.Io.Writer = .fixed(&reexport_bytes);
        try restored_stream.writeContinuation(&reexport_writer);
        try testing.expectEqualStrings(
            cut_writer.buffered(),
            reexport_writer.buffered(),
        );

        source_stream.nextSlice(corpus[cut..]);
        var offset = cut;
        var partition = cut +% corpus.len +% 1;
        while (offset < corpus.len) {
            partition = partition *% 1664525 +% 1013904223;
            const len = @min(1 + partition % 7, corpus.len - offset);
            restored_stream.nextSlice(corpus[offset..][0..len]);
            offset += len;
        }

        var source_final_bytes: [4096]u8 = undefined;
        var source_final_writer: std.Io.Writer = .fixed(&source_final_bytes);
        try source_stream.writeContinuation(&source_final_writer);
        var restored_final_bytes: [4096]u8 = undefined;
        var restored_final_writer: std.Io.Writer = .fixed(&restored_final_bytes);
        try restored_stream.writeContinuation(&restored_final_writer);
        try testing.expectEqualStrings(
            source_final_writer.buffered(),
            restored_final_writer.buffered(),
        );

        const final_continuation: Continuation = if (source_final_writer.end == 0)
            .ground
        else
            .{ .bytes = source_final_writer.buffered() };
        var source_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer source_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &source_final_snapshot.writer,
            &source_terminal,
            .{ .continuation = final_continuation },
        );
        var restored_final_snapshot: std.Io.Writer.Allocating = .init(
            testing.allocator,
        );
        defer restored_final_snapshot.deinit();
        try encode(
            testing.allocator,
            &restored_final_snapshot.writer,
            &restored_terminal,
            .{ .continuation = final_continuation },
        );
        try testing.expectEqualStrings(
            source_final_snapshot.written(),
            restored_final_snapshot.written(),
        );
    };
}

fn testExpectUnsupportedCapture(
    t: *const Terminal,
    expected: UnsupportedStateError,
) !void {
    var destination: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try std.testing.expectError(
        expected,
        encode(
            std.testing.allocator,
            &destination.writer,
            t,
            test_encode_options,
        ),
    );
    try std.testing.expectEqualStrings("prefix", destination.written());
}

test "complete snapshot rejects every primary and alternate Kitty storage state" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const Case = enum {
        completed_image,
        placement,
        loading,
        implicit_image_counter,
        implicit_placement_counter,
    };
    const cases = [_]Case{
        .completed_image,
        .placement,
        .loading,
        .implicit_image_counter,
        .implicit_placement_counter,
    };

    for ([_]TerminalScreenKey{ .primary, .alternate }) |key| {
        for (cases) |case| {
            var t = try Terminal.init(testing.io, testing.allocator, .{
                .cols = 2,
                .rows = 1,
            });
            defer t.deinit(testing.allocator);
            if (key == .alternate) _ = try t.switchScreen(.alternate);
            const storage = &t.screens.active.kitty_images;

            switch (case) {
                .completed_image => try storage.addImage(
                    testing.io,
                    testing.allocator,
                    .{ .id = 1 },
                ),
                .placement => {
                    try storage.addImage(
                        testing.io,
                        testing.allocator,
                        .{ .id = 1 },
                    );
                    try storage.addPlacement(
                        testing.io,
                        testing.allocator,
                        1,
                        1,
                        .{ .location = .{ .virtual = {} } },
                    );
                },
                .loading => {
                    const cmd = try terminal_kitty.graphics.CommandParser.parseString(
                        testing.allocator,
                        "a=t,f=24,t=d,s=1,v=2,m=1,i=1;////",
                    );
                    defer cmd.deinit(testing.allocator);
                    _ = terminal_kitty.graphics.execute(
                        testing.io,
                        testing.allocator,
                        &t,
                        &cmd,
                    );
                },
                .implicit_image_counter => {
                    const cmd = try terminal_kitty.graphics.CommandParser.parseString(
                        testing.allocator,
                        "a=t,f=24,t=d,s=1,v=2,i=0,I=0;////////",
                    );
                    defer cmd.deinit(testing.allocator);
                    _ = terminal_kitty.graphics.execute(
                        testing.io,
                        testing.allocator,
                        &t,
                        &cmd,
                    );
                    storage.delete(
                        testing.io,
                        testing.allocator,
                        &t,
                        .{ .all = true },
                    );
                },
                .implicit_placement_counter => {
                    try storage.addImage(
                        testing.io,
                        testing.allocator,
                        .{ .id = 1 },
                    );
                    try storage.addPlacement(
                        testing.io,
                        testing.allocator,
                        1,
                        0,
                        .{ .location = .{ .virtual = {} } },
                    );
                    storage.delete(
                        testing.io,
                        testing.allocator,
                        &t,
                        .{ .id = .{
                            .delete = true,
                            .image_id = 1,
                            .placement_id = 0,
                        } },
                    );
                },
            }

            try testing.expect(!storage.isSemanticallyEmpty());
            try testExpectUnsupportedCapture(
                &t,
                error.UnsupportedKittyGraphics,
            );
        }
    }
}

test "complete snapshot rejects a nonempty glyph glossary before envelope" {
    const testing = std.testing;
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&t),
    });
    defer stream.deinit();

    stream.nextSlice(
        "\x1b_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1b\\",
    );
    try testing.expect(!t.glyph_glossary.isEmpty());
    try testExpectUnsupportedCapture(
        &t,
        error.UnsupportedGlyphGlossary,
    );
}

test "asset-free Kitty placeholder fixture round trips U+10EEEE" {
    const testing = std.testing;
    var source: std.Io.Reader = .fixed(
        &test_complete_kitty_placeholder_v2_fixture,
    );
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    const restored = &decoded.terminal.?;
    const restored_screen = restored.screens.get(.alternate).?;
    const restored_cell = restored_screen.pages.getCell(.{
        .screen = .{},
    }).?;

    try testing.expectEqual(
        terminal_kitty.graphics.unicode.placeholder,
        restored_cell.cell.codepoint(),
    );
    try testing.expectEqualSlices(
        u21,
        &.{ terminal_kitty.graphics.unicode.placeholder, 0x0305 },
        restored_cell.node.page().lookupGrapheme(restored_cell.cell).?,
    );
    try testing.expect(restored_cell.row.kitty_virtual_placeholder);
    if (comptime build_options.kitty_graphics) {
        try testing.expect(restored_screen.kitty_images.isSemanticallyEmpty());
    }

    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    try encode(
        testing.allocator,
        &reencoded.writer,
        restored,
        test_encode_options,
    );
    try testing.expectEqualStrings(
        &test_complete_kitty_placeholder_v2_fixture,
        reencoded.written(),
    );
}

test "complete snapshot omits and resets view-local state" {
    const testing = std.testing;
    var source: std.Io.Reader = .fixed(&test_complete_v2_fixture);
    var decoded = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer decoded.deinit(testing.allocator);
    const t = &decoded.terminal.?;
    const primary = t.screens.get(.primary).?;

    try primary.select(TerminalSelection.init(
        primary.pages.pin(.{ .active = .{} }).?,
        primary.pages.pin(.{ .active = .{ .x = 1 } }).?,
        false,
    ));
    primary.scroll(.top);
    t.flags.focused = false;
    t.flags.visible = false;
    t.flags.selection_scroll = true;
    t.flags.search_viewport_dirty = true;
    primary.dirty.selection = true;
    primary.dirty.hyperlink_hover = true;

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(
        testing.allocator,
        &encoded.writer,
        t,
        test_encode_options,
    );
    try testing.expectEqualStrings(
        &test_complete_v2_fixture,
        encoded.written(),
    );

    var restored_source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &restored_source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);
    const restored_terminal = &restored.terminal.?;
    const restored_primary = restored_terminal.screens.get(.primary).?;
    const scrollbar = restored_primary.pages.scrollbar();
    try testing.expect(restored_terminal.flags.focused);
    try testing.expect(restored_terminal.flags.visible);
    try testing.expect(!restored_terminal.flags.selection_scroll);
    try testing.expect(!restored_terminal.flags.search_viewport_dirty);
    try testing.expect(restored_primary.selection == null);
    try testing.expect(!restored_primary.dirty.selection);
    try testing.expect(!restored_primary.dirty.hyperlink_hover);
    try testing.expectEqual(scrollbar.total - scrollbar.len, scrollbar.offset);
}

test "complete snapshot encoding streams from the current writer position" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    // Prefix hashing begins with this call's envelope, independent of bytes
    // that were already present in the destination.
    var nonempty: std.Io.Writer.Allocating = .init(testing.allocator);
    defer nonempty.deinit();
    try nonempty.writer.writeAll("prefix");
    const snapshot_offset = nonempty.written().len;
    try encode(testing.allocator, &nonempty.writer, &t, test_encode_options);
    try testing.expectEqualStrings(
        "prefix",
        nonempty.written()[0..snapshot_offset],
    );
    var appended_source: std.Io.Reader = .fixed(
        nonempty.written()[snapshot_offset..],
    );
    var appended = try decode(
        testing.allocator,
        testing.io,
        &appended_source,
        test_decode_options,
    );
    appended.deinit(testing.allocator);

    // Payload validation happens in the record-local scratch allocation. The
    // already-streamed envelope remains, but no partial TERMINAL is emitted.
    t.colors.palette.current[7] = .{ .r = 1, .g = 2, .b = 3 };
    var destination: std.Io.Writer.Allocating = .init(testing.allocator);
    defer destination.deinit();
    try destination.writer.writeAll("prefix");
    try testing.expectError(
        error.InvalidPalette,
        encode(
            testing.allocator,
            &destination.writer,
            &t,
            test_encode_options,
        ),
    );
    var expected_envelope: [envelope.encoded_len]u8 = undefined;
    var envelope_writer: std.Io.Writer = .fixed(&expected_envelope);
    try envelope.encode(&envelope_writer);
    try testing.expectEqualStrings(
        &expected_envelope,
        destination.written()["prefix".len..],
    );
}

test "complete snapshot rejects ordering and invalid checkpoints" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);
    const primary = t.screens.get(.primary).?;

    // A v2 envelope cannot reinterpret v1's direct SCREEN-to-READY order.
    // READY is individually valid here, but v2 requires CONTINUATION first.
    var old_order: std.Io.Writer.Allocating = .init(testing.allocator);
    defer old_order.deinit();
    var old_order_stream: record.Writer = .init(
        testing.allocator,
        &old_order.writer,
    );
    defer old_order_stream.deinit();
    try envelope.encode(old_order_stream.writer());
    try terminal.encode(&t, &old_order_stream);
    try screen.encode(primary, .primary, &old_order_stream);
    try checkpoint.encode(.ready, &old_order_stream);
    var old_order_source: std.Io.Reader = .fixed(old_order.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &old_order_source,
            test_decode_options,
        ),
    );

    // A second CONTINUATION is rejected where READY is required.
    var duplicate_continuation: std.Io.Writer.Allocating = .init(
        testing.allocator,
    );
    defer duplicate_continuation.deinit();
    var duplicate_continuation_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_continuation.writer,
    );
    defer duplicate_continuation_stream.deinit();
    try envelope.encode(duplicate_continuation_stream.writer());
    try terminal.encode(&t, &duplicate_continuation_stream);
    try screen.encode(primary, .primary, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    try continuation.encode(.ground, &duplicate_continuation_stream);
    var duplicate_continuation_source: std.Io.Reader = .fixed(
        duplicate_continuation.written(),
    );
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_continuation_source,
            test_decode_options,
        ),
    );

    // HISTORY is individually valid here, but the full decoder requires the
    // primary SCREEN before READY.
    var reordered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reordered.deinit();
    var reordered_stream: record.Writer = .init(
        testing.allocator,
        &reordered.writer,
    );
    defer reordered_stream.deinit();
    try envelope.encode(reordered_stream.writer());
    try terminal.encode(&t, &reordered_stream);
    try history.encode(primary, .primary, &reordered_stream);
    var reordered_source: std.Io.Reader = .fixed(reordered.written());
    try testing.expectError(
        error.UnexpectedRecordTag,
        decode(
            testing.allocator,
            testing.io,
            &reordered_source,
            test_decode_options,
        ),
    );

    // Construct a correctly framed READY with an intentionally unrelated
    // digest so the full driver, rather than record CRC validation, rejects it.
    var invalid_ready: std.Io.Writer.Allocating = .init(testing.allocator);
    defer invalid_ready.deinit();
    var invalid_ready_stream: record.Writer = .init(
        testing.allocator,
        &invalid_ready.writer,
    );
    defer invalid_ready_stream.deinit();
    try envelope.encode(invalid_ready_stream.writer());
    try terminal.encode(&t, &invalid_ready_stream);
    try screen.encode(primary, .primary, &invalid_ready_stream);
    try continuation.encode(.ground, &invalid_ready_stream);
    const ready_payload = invalid_ready_stream.begin(.ready);
    errdefer invalid_ready_stream.cancel();
    try ready_payload.splatByteAll(
        0,
        @sizeOf(checkpoint.Digest),
    );
    try invalid_ready_stream.finish();
    var invalid_ready_source: std.Io.Reader = .fixed(
        invalid_ready.written(),
    );
    try testing.expectError(
        error.InvalidDigest,
        decode(
            testing.allocator,
            testing.io,
            &invalid_ready_source,
            test_decode_options,
        ),
    );

    // A SCREEN key must name one of the slots declared by TERMINAL.
    var undeclared: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared.deinit();
    var undeclared_stream: record.Writer = .init(
        testing.allocator,
        &undeclared.writer,
    );
    defer undeclared_stream.deinit();
    try envelope.encode(undeclared_stream.writer());
    try terminal.encode(&t, &undeclared_stream);
    try screen.encode(primary, .alternate, &undeclared_stream);
    var undeclared_source: std.Io.Reader = .fixed(undeclared.written());
    try testing.expectError(
        error.UnexpectedScreenKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_source,
            test_decode_options,
        ),
    );

    // HISTORY sequences are also routed by key, which must name a declared
    // screen even when the sequence contains no PAGE records.
    var undeclared_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer undeclared_history.deinit();
    var undeclared_history_stream: record.Writer = .init(
        testing.allocator,
        &undeclared_history.writer,
    );
    defer undeclared_history_stream.deinit();
    try envelope.encode(undeclared_history_stream.writer());
    try terminal.encode(&t, &undeclared_history_stream);
    try screen.encode(primary, .primary, &undeclared_history_stream);
    try continuation.encode(.ground, &undeclared_history_stream);
    try checkpoint.encode(.ready, &undeclared_history_stream);
    try history.encode(primary, .alternate, &undeclared_history_stream);
    var undeclared_history_source: std.Io.Reader = .fixed(
        undeclared_history.written(),
    );
    try testing.expectError(
        error.UnexpectedHistoryKey,
        decode(
            testing.allocator,
            testing.io,
            &undeclared_history_source,
            test_decode_options,
        ),
    );

    // The declared count cannot be satisfied by repeating the same key.
    _ = try t.switchScreen(.alternate);
    var duplicate: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate.deinit();
    var duplicate_stream: record.Writer = .init(
        testing.allocator,
        &duplicate.writer,
    );
    defer duplicate_stream.deinit();
    try envelope.encode(duplicate_stream.writer());
    try terminal.encode(&t, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    try screen.encode(primary, .primary, &duplicate_stream);
    var duplicate_source: std.Io.Reader = .fixed(duplicate.written());
    try testing.expectError(
        error.DuplicateScreen,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_source,
            test_decode_options,
        ),
    );

    // The declared count cannot be satisfied by repeating one HISTORY key.
    var duplicate_history: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicate_history.deinit();
    var duplicate_history_stream: record.Writer = .init(
        testing.allocator,
        &duplicate_history.writer,
    );
    defer duplicate_history_stream.deinit();
    try envelope.encode(duplicate_history_stream.writer());
    try terminal.encode(&t, &duplicate_history_stream);
    try screen.encode(primary, .primary, &duplicate_history_stream);
    try screen.encode(
        t.screens.get(.alternate).?,
        .alternate,
        &duplicate_history_stream,
    );
    try continuation.encode(.ground, &duplicate_history_stream);
    try checkpoint.encode(.ready, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    try history.encode(primary, .primary, &duplicate_history_stream);
    var duplicate_history_source: std.Io.Reader = .fixed(
        duplicate_history.written(),
    );
    try testing.expectError(
        error.DuplicateHistory,
        decode(
            testing.allocator,
            testing.io,
            &duplicate_history_source,
            test_decode_options,
        ),
    );
}

test "complete snapshot leaves continuation bytes unread" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    const snapshot_len = encoded.written().len;
    try encoded.writer.writeAll("pty");

    var source: std.Io.Reader = .fixed(encoded.written());
    var restored = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer restored.deinit(testing.allocator);

    var trailing: [3]u8 = undefined;
    try source.readSliceAll(&trailing);
    try testing.expectEqualStrings("pty", &trailing);

    var exact_source: std.Io.Reader = .fixed(encoded.written());
    try testing.expectError(
        error.TrailingData,
        decodeExact(
            testing.allocator,
            testing.io,
            &exact_source,
            test_decode_options,
        ),
    );

    var bounded_source: std.Io.Reader = .fixed(
        encoded.written()[0..snapshot_len],
    );
    var bounded = try decodeExact(
        testing.allocator,
        testing.io,
        &bounded_source,
        test_decode_options,
    );
    defer bounded.deinit(testing.allocator);
}

test "complete snapshots decode sequentially from one reader" {
    const testing = std.testing;

    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = 2,
        .rows = 1,
    });
    defer t.deinit(testing.allocator);

    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);
    try encode(testing.allocator, &encoded.writer, &t, test_encode_options);

    var source: std.Io.Reader = .fixed(encoded.written());
    var first = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer first.deinit(testing.allocator);
    var second = try decode(
        testing.allocator,
        testing.io,
        &source,
        test_decode_options,
    );
    defer second.deinit(testing.allocator);
    try testing.expectError(error.EndOfStream, source.takeByte());
}

test "incremental decoder authenticates READY with every-byte fragmentation" {
    const testing = std.testing;
    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();

    var restored: Terminal = undefined;
    var restored_owned = false;
    defer if (restored_owned) restored.deinit(testing.allocator);
    var ready: ?Ready = null;
    defer if (ready) |*value| value.deinit();
    var saw_finish = false;

    for (test_complete_v2_fixture) |byte| {
        const pushed = try decoder.push(&.{byte});
        try testing.expectEqual(@as(usize, 1), pushed.consumed);
        switch (pushed.event) {
            .ready => |version| {
                try testing.expectEqual(Version.v2, version);
                ready = try decoder.takeReady(&restored);
                restored_owned = true;

                var duplicate: Terminal = undefined;
                try testing.expectError(
                    error.ReadyAlreadyTaken,
                    decoder.takeReady(&duplicate),
                );
            },
            .finish => saw_finish = true,
            else => {},
        }
    }
    try testing.expect(saw_finish);

    // The incremental result re-encodes to the frozen public v2 grammar.
    var reencoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reencoded.deinit();
    var incremental_encoder = try Encoder.init(
        testing.allocator,
        &reencoded.writer,
        &restored,
        .{ .continuation = ready.?.continuation.? },
    );
    defer incremental_encoder.deinit();
    const ready_offset = testRecordOffset(
        &test_complete_v2_fixture,
        .ready,
        false,
        0,
    );
    const ready_payload_len: usize = std.mem.readInt(
        u32,
        test_complete_v2_fixture[ready_offset + 2 ..][0..4],
        .little,
    );
    var encoder_saw_ready = false;
    while (!incremental_encoder.finished()) {
        const event = try incremental_encoder.next();
        if (event == .ready) {
            encoder_saw_ready = true;
            try testing.expectEqual(
                ready_offset + record.Header.len + ready_payload_len,
                reencoded.written().len,
            );
        }
    }
    try testing.expect(encoder_saw_ready);
    try testing.expectEqualSlices(
        u8,
        &test_complete_v2_fixture,
        reencoded.written(),
    );

    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&restored),
        .continuation_max_bytes = 1024,
    });
    defer stream.deinit();
    try ready.?.replay(&stream);
    try testing.expectError(
        error.ContinuationAlreadyReplayed,
        ready.?.replay(&stream),
    );

    // FINISH is terminal and leaves every following transport byte untouched.
    const after_finish = try decoder.push("pty");
    try testing.expectEqual(@as(usize, 0), after_finish.consumed);
    try testing.expect(std.meta.activeTag(after_finish.event) == .finish);
}

test "incremental decoder reports bytes consumed by a failed transition" {
    const testing = std.testing;
    var invalid = test_complete_v2_fixture;
    invalid[8] = 0xFF;
    invalid[9] = 0x7F;

    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();
    try testing.expectError(
        error.UnsupportedVersion,
        decoder.push(&invalid),
    );
    try testing.expectEqual(
        envelope.encoded_len,
        decoder.consumedOnError(),
    );
}

test "incremental decoder rejects a forged READY digest" {
    const testing = std.testing;
    var invalid = test_complete_v2_fixture;
    const offset = testRecordOffset(&invalid, .ready, false, 0);
    const payload_len: usize = std.mem.readInt(
        u32,
        invalid[offset + 2 ..][0..4],
        .little,
    );
    invalid[offset + record.Header.len] ^= 0x80;

    var checksum: record.Checksum = .init(.ready, @intCast(payload_len));
    try checksum.writer().writeAll(
        invalid[offset + record.Header.len ..][0..payload_len],
    );
    std.mem.writeInt(
        u32,
        invalid[offset + 6 ..][0..4],
        checksum.final(),
        .little,
    );

    var source: std.Io.Reader = .fixed(&invalid);
    try testing.expectError(
        error.InvalidDigest,
        decode(
            testing.allocator,
            testing.io,
            &source,
            test_decode_options,
        ),
    );
}

test "incremental history accepts serialized VT writes between pages" {
    const testing = std.testing;
    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();

    var restored: Terminal = undefined;
    var restored_owned = false;
    defer if (restored_owned) restored.deinit(testing.allocator);
    var ready: ?Ready = null;
    defer if (ready) |*value| value.deinit();
    var stream: ?TerminalStream = null;
    defer if (stream) |*value| value.deinit();

    var offset: usize = 0;
    var history_pages: usize = 0;
    var saw_finish = false;
    while (offset < test_complete_v2_fixture.len) {
        const pushed = try decoder.push(test_complete_v2_fixture[offset..]);
        try testing.expect(pushed.consumed > 0);
        offset += pushed.consumed;

        switch (pushed.event) {
            .ready => {
                ready = try decoder.takeReady(&restored);
                restored_owned = true;
                stream = TerminalStream.init(.{
                    .allocator = testing.allocator,
                    .handler = .init(&restored),
                    .continuation_max_bytes = 1024,
                });
                try ready.?.replay(&stream.?);
            },
            .history_page => {
                history_pages += 1;
                if (history_pages == 1) {
                    stream.?.nextSlice("\x1b]2;LIVE\x07");
                }
            },
            .finish => saw_finish = true,
            else => {},
        }
    }

    try testing.expect(history_pages >= 2);
    try testing.expect(saw_finish);
    try testing.expectEqualStrings("LIVE", restored.getTitle().?);
}

test "malformed and truncated post-READY history are isolated" {
    const testing = std.testing;
    const second_page = testRecordOffset(
        &test_complete_v2_fixture,
        .page,
        true,
        1,
    );

    // A later malformed PAGE rolls back an earlier validated import while
    // preserving PTY writes serialized between the two page arrivals.
    {
        var invalid = test_complete_v2_fixture;
        std.mem.writeInt(
            u16,
            invalid[second_page..][0..2],
            @intFromEnum(record.Tag.screen),
            .little,
        );

        var decoder: Decoder = .init(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoder.deinit();
        var restored: Terminal = undefined;
        var restored_owned = false;
        defer if (restored_owned) restored.deinit(testing.allocator);
        var ready: ?Ready = null;
        defer if (ready) |*value| value.deinit();
        var stream: ?TerminalStream = null;
        defer if (stream) |*value| value.deinit();
        var ready_page_count: usize = 0;
        var offset: usize = 0;
        var saw_first_history = false;
        var saw_error = false;

        while (offset < invalid.len) {
            const pushed = decoder.push(invalid[offset..]) catch |err| {
                try testing.expectEqual(error.UnexpectedRecordTag, err);
                saw_error = true;
                break;
            };
            offset += pushed.consumed;
            switch (pushed.event) {
                .ready => {
                    ready = try decoder.takeReady(&restored);
                    restored_owned = true;
                    ready_page_count =
                        restored.screens.get(.primary).?.pages.totalPages();
                    stream = TerminalStream.init(.{
                        .allocator = testing.allocator,
                        .handler = .init(&restored),
                        .continuation_max_bytes = 1024,
                    });
                    try ready.?.replay(&stream.?);
                    stream.?.nextSlice("\x1b]2;pre\x07");
                },
                .history_page => {
                    saw_first_history = true;
                    stream.?.nextSlice("\x1b]2;mid\x07");
                },
                else => {},
            }
        }

        try testing.expect(saw_error);
        try testing.expect(saw_first_history);
        try testing.expectEqual(
            ready_page_count,
            restored.screens.get(.primary).?.pages.totalPages(),
        );
        try testing.expectEqualStrings("mid", restored.getTitle().?);
    }

    // A forged FINISH rolls back every page published after READY.
    {
        var invalid = test_complete_v2_fixture;
        const finish_offset = testRecordOffset(&invalid, .finish, false, 0);
        const payload_len: usize = std.mem.readInt(
            u32,
            invalid[finish_offset + 2 ..][0..4],
            .little,
        );
        invalid[finish_offset + record.Header.len] ^= 0x40;
        var checksum: record.Checksum = .init(.finish, @intCast(payload_len));
        try checksum.writer().writeAll(
            invalid[finish_offset + record.Header.len ..][0..payload_len],
        );
        std.mem.writeInt(
            u32,
            invalid[finish_offset + 6 ..][0..4],
            checksum.final(),
            .little,
        );

        var decoder: Decoder = .init(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoder.deinit();
        var restored: Terminal = undefined;
        var restored_owned = false;
        defer if (restored_owned) restored.deinit(testing.allocator);
        var ready: ?Ready = null;
        defer if (ready) |*value| value.deinit();
        var resized_page_count: usize = 0;
        var resized = false;
        var offset: usize = 0;
        var saw_error = false;
        while (offset < invalid.len) {
            const pushed = decoder.push(invalid[offset..]) catch |err| {
                try testing.expectEqual(error.InvalidDigest, err);
                saw_error = true;
                break;
            };
            offset += pushed.consumed;
            switch (pushed.event) {
                .ready => {
                    ready = try decoder.takeReady(&restored);
                    restored_owned = true;
                },
                .history_page => |event| {
                    if (event.key == .primary and !resized) {
                        try testing.expect(event.retained);
                        try restored.resize(
                            testing.allocator,
                            .{ .cols = restored.cols, .rows = 5 },
                        );
                        resized_page_count =
                            restored.screens.get(.primary).?.pages.totalPages();
                        resized = true;
                    }
                },
                else => {},
            }
        }
        try testing.expect(saw_error);
        try testing.expect(resized);
        try testing.expectEqual(@as(@TypeOf(restored.rows), 5), restored.rows);
        const resized_primary = restored.screens.get(.primary).?;
        try testing.expect(resized_primary.pages.total_rows >= restored.rows);
        try testing.expectEqual(
            resized_primary.cursor.page_pin.rowAndCell().cell,
            resized_primary.cursor.page_cell,
        );
        resized_primary.pages.assertIntegrity();
        resized_primary.assertIntegrity();
        try testing.expectEqual(
            resized_page_count,
            resized_primary.pages.totalPages(),
        );
    }

    // Aborting with a later PAGE fragment buffered performs the same rollback.
    {
        const cutoff = second_page + record.Header.len + 1;
        var decoder: Decoder = .init(
            testing.allocator,
            testing.io,
            test_decode_options,
        );
        defer decoder.deinit();
        var restored: Terminal = undefined;
        var restored_owned = false;
        defer if (restored_owned) restored.deinit(testing.allocator);
        var ready: ?Ready = null;
        defer if (ready) |*value| value.deinit();
        var ready_page_count: usize = 0;
        var offset: usize = 0;
        while (offset < cutoff) {
            const pushed = try decoder.push(
                test_complete_v2_fixture[offset..cutoff],
            );
            try testing.expect(pushed.consumed > 0);
            offset += pushed.consumed;
            if (std.meta.activeTag(pushed.event) == .ready) {
                ready = try decoder.takeReady(&restored);
                restored_owned = true;
                ready_page_count =
                    restored.screens.get(.primary).?.pages.totalPages();
            }
        }
        decoder.abort();
        try testing.expectEqual(
            ready_page_count,
            restored.screens.get(.primary).?.pages.totalPages(),
        );
    }
}

test "READY abort invalidates pending transfer" {
    const testing = std.testing;
    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();

    var offset: usize = 0;
    while (offset < test_complete_v2_fixture.len) {
        const pushed = try decoder.push(test_complete_v2_fixture[offset..]);
        offset += pushed.consumed;
        if (std.meta.activeTag(pushed.event) != .ready) continue;

        decoder.abort();
        var destination: Terminal = undefined;
        try testing.expectError(
            error.ReadyUnavailable,
            decoder.takeReady(&destination),
        );
        return;
    }
    return error.TestExpectedEqual;
}

test "continuation replay OOM is retry-safe" {
    const testing = std.testing;
    var terminal_value = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer terminal_value.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&terminal_value),
        .continuation_max_bytes = 1024,
    });
    defer stream.deinit();

    var failing = testing.FailingAllocator.init(
        testing.allocator,
        .{ .fail_index = std.math.maxInt(usize) },
    );
    const bytes = try failing.allocator().dupe(u8, "\x1b[");
    var ready: Ready = .{
        .alloc = failing.allocator(),
        .version = .v2,
        .continuation = .{ .bytes = bytes },
    };
    defer ready.deinit();

    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, ready.replay(&stream));
    try testing.expect(ready.continuation != null);
    var ground_buf: [1]u8 = undefined;
    var ground_writer: std.Io.Writer = .fixed(&ground_buf);
    try stream.writeContinuation(&ground_writer);
    try testing.expectEqual(@as(usize, 0), ground_writer.end);

    failing.fail_index = std.math.maxInt(usize);
    try ready.replay(&stream);
}

test "live history clear and reset discard authenticated snapshot history" {
    const testing = std.testing;
    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();
    var restored: Terminal = undefined;
    var restored_owned = false;
    defer if (restored_owned) restored.deinit(testing.allocator);
    var ready: ?Ready = null;
    defer if (ready) |*value| value.deinit();
    var stream: ?TerminalStream = null;
    defer if (stream) |*value| value.deinit();

    var offset: usize = 0;
    var pages_after_clear: usize = 0;
    var discarded_pages: usize = 0;
    var saw_finish = false;
    while (offset < test_complete_v2_fixture.len) {
        const pushed = try decoder.push(test_complete_v2_fixture[offset..]);
        offset += pushed.consumed;
        switch (pushed.event) {
            .ready => {
                ready = try decoder.takeReady(&restored);
                restored_owned = true;
                stream = TerminalStream.init(.{
                    .allocator = testing.allocator,
                    .handler = .init(&restored),
                    .continuation_max_bytes = 1024,
                });
                try ready.?.replay(&stream.?);
                stream.?.nextSlice("\x1b[3J\x1bc");
                pages_after_clear =
                    restored.screens.get(.primary).?.pages.totalPages();
            },
            .history_page => |event| {
                if (event.key == .primary) {
                    try testing.expect(!event.retained);
                    discarded_pages += 1;
                }
            },
            .finish => saw_finish = true,
            else => {},
        }
    }

    try testing.expect(discarded_pages >= 2);
    try testing.expect(saw_finish);
    try testing.expectEqual(
        pages_after_clear,
        restored.screens.get(.primary).?.pages.totalPages(),
    );
}

test "alternate screen replacement abandons stale history import" {
    const testing = std.testing;
    var terminal_value = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer terminal_value.deinit(testing.allocator);
    var stream = TerminalStream.init(.{
        .allocator = testing.allocator,
        .handler = .init(&terminal_value),
        .continuation_max_bytes = 1024,
    });
    defer stream.deinit();
    stream.nextSlice("\x1b[?1049h");

    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();
    decoder.live_terminal = &terminal_value;
    decoder.ready_screen_generation[1] =
        terminal_value.screens.generation(.alternate);
    const alternate = terminal_value.screens.get(.alternate).?;
    decoder.ready_history_generation[1] =
        alternate.pages.historyGeneration();
    decoder.imports[1] = try .init(
        &alternate.pages,
        testing.allocator,
        0,
    );

    terminal_value.fullReset();
    decoder.abort();
    try testing.expect(!decoder.imports[1].?.isActive());
}

test "incremental decoder enforces caller bounds and one-record work" {
    const testing = std.testing;

    var decoder: Decoder = .init(
        testing.allocator,
        testing.io,
        test_decode_options,
    );
    defer decoder.deinit();
    const first = try decoder.push(&test_complete_v2_fixture);
    try testing.expectEqual(envelope.encoded_len, first.consumed);
    try testing.expect(std.meta.activeTag(first.event) == .progress);
    try testing.expectEqual(@as(usize, 0), decoder.buffer.items.len);
    try testing.expectError(
        error.RecordLimitExceeded,
        framedRecordLen(std.math.maxInt(usize)),
    );

    var record_limited: std.Io.Reader = .fixed(&test_complete_v2_fixture);
    try testing.expectError(
        error.RecordLimitExceeded,
        decode(
            testing.allocator,
            testing.io,
            &record_limited,
            .{
                .max_continuation_bytes = 1024,
                .max_record_bytes = 1,
            },
        ),
    );

    var page_limited: std.Io.Reader = .fixed(&test_complete_v2_fixture);
    try testing.expectError(
        error.PageLimitExceeded,
        decode(
            testing.allocator,
            testing.io,
            &page_limited,
            .{
                .max_continuation_bytes = 1024,
                .max_pages = 1,
            },
        ),
    );
}

test "incremental complete decode allocation failures are transactional" {
    const testing = std.testing;
    const S = struct {
        fn exercise(bytes: []const u8) !void {
            var baseline = testing.FailingAllocator.init(testing.allocator, .{
                .fail_index = std.math.maxInt(usize),
            });
            var baseline_source: std.Io.Reader = .fixed(bytes);
            var baseline_decoded = try decode(
                baseline.allocator(),
                testing.io,
                &baseline_source,
                test_decode_options,
            );
            baseline_decoded.deinit(baseline.allocator());
            const allocation_count = baseline.alloc_index;
            try testing.expect(allocation_count > 0);

            var saw_out_of_memory = false;
            for (0..allocation_count) |fail_index| {
                var failing = testing.FailingAllocator.init(
                    testing.allocator,
                    .{ .fail_index = fail_index },
                );
                var source: std.Io.Reader = .fixed(bytes);
                var decoded = decode(
                    failing.allocator(),
                    testing.io,
                    &source,
                    test_decode_options,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        saw_out_of_memory = true;
                        continue;
                    },
                    else => return err,
                };
                decoded.deinit(failing.allocator());
            }
            try testing.expect(saw_out_of_memory);
        }
    };

    // Both complete goldens exercise Terminal, both screens, and history.
    try S.exercise(&test_complete_v1_fixture);
    try S.exercise(&test_complete_v2_fixture);

    // A non-ground component additionally exercises owned continuation bytes.
    var t = try Terminal.init(
        testing.io,
        testing.allocator,
        .{ .cols = 2, .rows = 1 },
    );
    defer t.deinit(testing.allocator);
    var encoded: std.Io.Writer.Allocating = .init(testing.allocator);
    defer encoded.deinit();
    try encode(testing.allocator, &encoded.writer, &t, .{
        .continuation = .{ .bytes = "\x1b[31" },
    });
    try S.exercise(encoded.written());
}
