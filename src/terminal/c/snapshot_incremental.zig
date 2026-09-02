const std = @import("std");
const builtin = @import("builtin");
const lib = @import("../lib.zig");
const snapshot = @import("../snapshot/main.zig");
const terminal_c = @import("terminal.zig");
const CAllocator = lib.alloc.Allocator;

pub const abi_version: u32 = 1;
pub const token_len: usize = 32;

pub const Status = enum(c_int) {
    success = 0,
    unsupported_feature = -1,
    unknown_version = -2,
    corruption = -3,
    truncated = -4,
    limit_exceeded = -5,
    stale = -6,
    pruned = -7,
    wrong_generation = -8,
    wrong_terminal = -9,
    invalid_handle = -10,
    import_busy = -11,
    out_of_memory = -12,
    out_of_space = -13,
    invalid_state = -14,
    continuation_unavailable = -15,
    reset = -16,
    resize = -17,
};

pub const Token = extern struct {
    size: usize,
    bytes: [token_len]u8,
};

pub const Capabilities = extern struct {
    size: usize,
    version: u32,
    min_decode_version: u16,
    max_decode_version: u16,
    default_encode_version: u16,
    incremental: bool,
    ready: bool,
    history: bool,
    authenticated_tokens: bool,
    bounded_records: bool,
    bounded_pages: bool,
    bounded_units: bool,
    max_record_bytes: usize,
    max_pages: usize,
    max_unit_bytes: usize,
    max_rows: usize,
    codec_identity: lib.String,
    build_identity: lib.String,
};

pub const CaptureOptions = extern struct {
    size: usize,
    version: u32,
    max_record_bytes: usize,
    max_pages: usize,
};

pub const DetachOptions = extern struct {
    size: usize,
    version: u32,
    max_pages: usize,
    max_total_bytes: usize,
    max_rows: usize,
    /// Pin the retained history through a copy-on-write lease and encode each
    /// record on demand instead of owning every record up front.
    ///
    /// Leased detachment is constant-time however deep the scrollback is, and
    /// retains one page at a time rather than the whole encoded history, but
    /// the source terminal must then outlive the continuation. It may still be
    /// mutated freely.
    leased: bool,
};

pub const ContinuationOptions = extern struct {
    size: usize,
    version: u32,
    max_rows: usize,
};

pub const CaptureEventKind = enum(c_int) {
    record = 0,
    ready = 1,
    history_begin = 2,
    history_page = 3,
    finish = 4,
};

pub const CaptureEvent = extern struct {
    size: usize,
    version: u32,
    kind: CaptureEventKind,
    codec_version: u16,
    screen_key: u16,
    index: u32,
    count: u32,
    written: usize,
    required_bytes: usize,
    checkpoint: Token,
    rows: usize,
    required_rows: usize,
};

pub const DecoderOptions = extern struct {
    size: usize,
    version: u32,
    max_continuation_bytes: usize,
    max_record_bytes: usize,
    max_pages: usize,
};

pub const DecodeEventKind = enum(c_int) {
    need_input = 0,
    progress = 1,
    ready = 2,
    history_begin = 3,
    history_page = 4,
    finish = 5,
};

pub const DecodeEvent = extern struct {
    size: usize,
    version: u32,
    kind: DecodeEventKind,
    codec_version: u16,
    screen_key: u16,
    index: u32,
    count: u32,
    retained: bool,
    consumed: usize,
    needed: usize,
};

pub const TakeTerminalResult = extern struct {
    size: usize,
    version: u32,
    terminal: terminal_c.Terminal,
    codec_version: u16,
};

pub const HistoryOptions = extern struct {
    size: usize,
    version: u32,
    max_unit_bytes: usize,
    max_rows: usize,
    max_units: usize,
};

pub const HistoryLeaseResult = extern struct {
    size: usize,
    version: u32,
    lease: HistoryLease,
    checkpoint: Token,
};

pub const HistoryCursorResult = extern struct {
    size: usize,
    version: u32,
    cursor: HistoryCursor,
    capability: Token,
};

pub const HistoryEventKind = enum(c_int) {
    unit = 0,
    end = 1,
};

pub const HistoryEvent = extern struct {
    size: usize,
    version: u32,
    kind: HistoryEventKind,
    written: usize,
    required_bytes: usize,
    rows: usize,
    page_complete: bool,
};

pub const HistoryImporterResult = extern struct {
    size: usize,
    version: u32,
    importer: HistoryImporter,
    capability: Token,
};

pub const HistoryImportEvent = extern struct {
    size: usize,
    version: u32,
    consumed: usize,
    required_bytes: usize,
    required_rows: usize,
    rows: usize,
    retained: bool,
};

const codec_identity = "ghostty.snapshot.v1-v2.incremental.v1";
const build_options = @import("terminal_options");
const authenticated_history = builtin.os.tag != .freestanding;

pub fn capabilities(out_: ?*Capabilities) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_handle;
    if (!validSized(out, Capabilities)) return .invalid_state;
    out.version = abi_version;
    out.min_decode_version = @intFromEnum(snapshot.capabilities.min_decode_version);
    out.max_decode_version = @intFromEnum(snapshot.capabilities.max_decode_version);
    out.default_encode_version = @intFromEnum(snapshot.capabilities.default_encode_version);
    out.incremental = true;
    out.ready = true;
    out.history = true;
    out.authenticated_tokens = authenticated_history;
    out.bounded_records = true;
    out.bounded_pages = true;
    out.bounded_units = authenticated_history;
    out.max_record_bytes = std.math.maxInt(u32);
    out.max_pages = std.math.maxInt(u32);
    out.max_unit_bytes = if (authenticated_history)
        std.math.maxInt(u32)
    else
        0;
    out.max_rows = std.math.maxInt(u32);
    out.codec_identity = .{ .ptr = codec_identity.ptr, .len = codec_identity.len };
    out.build_identity = .{
        .ptr = build_options.version_string.ptr,
        .len = build_options.version_string.len,
    };
    return .success;
}

fn validSized(ptr: anytype, comptime T: type) bool {
    return ptr.size >= @sizeOf(T);
}

fn validVersioned(ptr: anytype, comptime T: type) bool {
    return validSized(ptr, T) and ptr.version == abi_version;
}

const capture_event_v1_size = @offsetOf(CaptureEvent, "rows");

fn validCaptureEvent(ptr: *const CaptureEvent) bool {
    return ptr.size >= capture_event_v1_size and ptr.version == abi_version;
}

fn captureEventHasRows(ptr: *const CaptureEvent) bool {
    return ptr.size >= @sizeOf(CaptureEvent);
}

fn validBound(value: usize) bool {
    return value > 0 and value <= std.math.maxInt(u32);
}

fn mapError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.UnsupportedKittyGraphics,
        error.UnsupportedGlyphGlossary,
        => .unsupported_feature,
        error.UnsupportedVersion => .unknown_version,
        error.EndOfStream => .truncated,
        error.RecordLimitExceeded,
        error.PageLimitExceeded,
        error.ChunkLimitExceeded,
        error.LeaseLimitExceeded,
        error.LeaseGenerationExhausted,
        error.InvalidLimit,
        error.TotalBytesLimitExceeded,
        => .limit_exceeded,
        error.Stale => .stale,
        error.Pruned => .pruned,
        error.WrongGeneration, error.ScreenUnavailable => .wrong_generation,
        error.WrongTerminal => .wrong_terminal,
        error.InvalidHandle, error.InvalidCheckpoint => .invalid_handle,
        error.InvalidHistoryUnit => .corruption,
        error.ImportBusy => .import_busy,
        error.WriteFailed => .out_of_memory,
        error.ContinuationDisabled,
        error.ContinuationUnavailable,
        => .continuation_unavailable,
        error.Reset => .reset,
        error.Resize => .resize,
        error.ReadyUnavailable,
        error.ReadyAlreadyTaken,
        error.ReadyNotTaken,
        error.DecoderTerminal,
        error.ContinuationAlreadyReplayed,
        error.CursorAlreadyTaken,
        error.UnexpectedHistoryUnit,
        => .invalid_state,
        else => .corruption,
    };
}

fn emptyToken() Token {
    return .{ .size = @sizeOf(Token), .bytes = [_]u8{0} ** token_len };
}

const CaptureState = struct {
    alloc: std.mem.Allocator,
    terminal: terminal_c.Terminal,
    continuation: []u8,
    output_buffer: []u8,
    output: std.Io.Writer,
    encoder: snapshot.Encoder,
    max_pages: usize,
    pending: bool = false,
    pending_len: usize = 0,
    pending_kind: CaptureEventKind = .record,
    pending_codec_version: u16 = 0,
    pending_key: u16 = 0,
    pending_index: u32 = 0,
    pending_count: u32 = 0,
    pending_checkpoint: [token_len]u8 = [_]u8{0} ** token_len,
    pending_rows: usize = 0,
    history_key: u16 = 0,
    history_index: u32 = 0,
    history_count: u32 = 0,
    page_records: usize = 0,
    envelope_emitted: bool = false,
    terminal_state: bool = false,
    detached: bool = false,
};

pub const Capture = ?*CaptureState;

pub fn captureNew(
    alloc_: ?*const CAllocator,
    terminal: terminal_c.Terminal,
    options_: ?*const CaptureOptions,
    out_: ?*Capture,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_handle;
    out.* = null;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(options, CaptureOptions) or
        !validBound(options.max_record_bytes) or
        !validBound(options.max_pages))
    {
        return .invalid_state;
    }
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    snapshot.validateSupportedState(zig_terminal) catch |err| return mapError(err);

    const alloc = lib.alloc.default(alloc_);
    const state = alloc.create(CaptureState) catch return .out_of_memory;
    defer if (out.* == null) alloc.destroy(state);
    const output_buffer = alloc.alloc(u8, options.max_record_bytes) catch
        return .out_of_memory;
    defer if (out.* == null) alloc.free(output_buffer);

    var continuation_writer: std.Io.Writer = .fixed(output_buffer);
    terminal_c.writeSnapshotContinuation(
        terminal,
        &continuation_writer,
    ) catch |err| return if (err == error.WriteFailed)
        .limit_exceeded
    else
        mapError(err);
    if (continuation_writer.end >
        options.max_record_bytes -| snapshot.record.Header.len)
    {
        return .limit_exceeded;
    }
    const continuation = alloc.dupe(
        u8,
        continuation_writer.buffered(),
    ) catch return .out_of_memory;
    defer if (out.* == null) alloc.free(continuation);

    state.* = undefined;
    state.alloc = alloc;
    state.terminal = terminal;
    state.continuation = continuation;
    state.output_buffer = output_buffer;
    state.output = .fixed(output_buffer);
    state.max_pages = options.max_pages;
    state.pending = false;
    state.pending_len = 0;
    state.pending_kind = .record;
    state.pending_codec_version = 0;
    state.pending_key = 0;
    state.pending_index = 0;
    state.pending_count = 0;
    state.pending_checkpoint = [_]u8{0} ** token_len;
    state.pending_rows = 0;
    state.history_key = 0;
    state.history_index = 0;
    state.history_count = 0;
    state.envelope_emitted = false;
    state.page_records = 0;
    state.terminal_state = false;
    state.detached = false;
    const continuation_value: snapshot.Continuation = if (continuation.len == 0)
        .ground
    else
        .{ .bytes = continuation };
    state.encoder = snapshot.Encoder.initLimited(
        alloc,
        &state.output,
        zig_terminal,
        .{ .continuation = continuation_value },
        options.max_record_bytes,
    ) catch |err| return mapError(err);
    out.* = state;
    return .success;
}

fn classifyCapture(state: *CaptureState, event: snapshot.EncodeEvent, bytes: []const u8) Status {
    state.pending_kind = switch (event) {
        .ready => .ready,
        .finish => .finish,
        .progress => .record,
    };
    state.pending_codec_version = @intFromEnum(snapshot.capabilities.default_encode_version);
    state.pending_key = 0;
    state.pending_index = 0;
    state.pending_count = 0;
    state.pending_checkpoint = [_]u8{0} ** token_len;
    state.pending_rows = 0;

    if (!state.envelope_emitted) {
        state.envelope_emitted = true;
        return .success;
    }
    if (event == .ready) {
        if (bytes.len < snapshot.record.Header.len + token_len) return .corruption;
        @memcpy(state.pending_checkpoint[0..], bytes[snapshot.record.Header.len..][0..token_len]);
        return .success;
    }
    if (bytes.len < snapshot.record.Header.len) return .success;
    var reader: std.Io.Reader = .fixed(bytes);
    const header = snapshot.record.Header.decode(&reader) catch return .corruption;
    switch (header.tag) {
        .history => {
            if (bytes.len < snapshot.record.Header.len + 6) return .corruption;
            state.pending_kind = .history_begin;
            state.history_key = std.mem.readInt(u16, bytes[10..12], .little);
            state.history_count = std.mem.readInt(u32, bytes[12..16], .little);
            state.history_index = 0;
            state.pending_key = state.history_key;
            state.pending_count = state.history_count;
        },
        .page => {
            state.page_records += 1;
            if (state.page_records > state.max_pages) return .limit_exceeded;
            if (state.history_count > 0) {
                if (bytes.len < snapshot.record.Header.len + 4)
                    return .corruption;
                state.pending_rows = std.mem.readInt(
                    u16,
                    bytes[snapshot.record.Header.len + 2 ..][0..2],
                    .little,
                );
                state.pending_kind = .history_page;
                state.pending_key = state.history_key;
                state.pending_index = state.history_index;
                state.pending_count = state.history_count;
                state.history_index += 1;
                if (state.history_index == state.history_count)
                    state.history_count = 0;
            }
        },
        else => {},
    }
    return .success;
}

fn captureNextBounded(
    state: *CaptureState,
    max_rows: ?usize,
    buffer_: ?[*]u8,
    buffer_len: usize,
    out: *CaptureEvent,
) Status {
    if (!validCaptureEvent(out)) return .invalid_state;
    out.written = 0;
    out.required_bytes = 0;
    out.checkpoint = emptyToken();
    if (captureEventHasRows(out)) {
        out.rows = 0;
        out.required_rows = 0;
    }
    if (state.terminal_state) return .invalid_state;
    if (buffer_ == null and buffer_len != 0) return .invalid_state;

    if (!state.pending) {
        const detached_rows = state.encoder.detachedNextRows();
        state.output.end = 0;
        const encode_event = state.encoder.next() catch |err| {
            state.terminal_state = true;
            return if (err == error.WriteFailed)
                .limit_exceeded
            else
                mapError(err);
        };
        const bytes = state.output.buffered();
        const status = classifyCapture(state, encode_event, bytes);
        if (status != .success) {
            state.terminal_state = true;
            return status;
        }
        if (detached_rows) |rows| state.pending_rows = rows;
        state.pending = true;
        state.pending_len = bytes.len;
    }

    const pending = state.output_buffer[0..state.pending_len];
    out.kind = state.pending_kind;
    out.codec_version = state.pending_codec_version;
    out.screen_key = state.pending_key;
    out.index = state.pending_index;
    out.count = state.pending_count;
    out.required_bytes = pending.len;
    out.checkpoint.bytes = state.pending_checkpoint;
    if (captureEventHasRows(out)) out.rows = state.pending_rows;
    if (max_rows) |limit| {
        if (state.pending_rows > limit) {
            if (captureEventHasRows(out))
                out.required_rows = state.pending_rows;
            return .out_of_space;
        }
    }
    if (pending.len > buffer_len) return .out_of_space;
    if (pending.len > 0) @memcpy(buffer_.?[0..pending.len], pending);
    out.written = pending.len;
    state.pending = false;
    state.pending_len = 0;
    if (state.pending_kind == .finish) state.terminal_state = true;
    return .success;
}

pub fn captureNext(
    capture: Capture,
    buffer_: ?[*]u8,
    buffer_len: usize,
    out_: ?*CaptureEvent,
) callconv(lib.calling_conv) Status {
    const state = capture orelse return .invalid_handle;
    if (state.detached) return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    return captureNextBounded(state, null, buffer_, buffer_len, out);
}

pub const Continuation = ?*CaptureState;

pub fn captureDetachReady(
    capture_: ?*Capture,
    options_: ?*const DetachOptions,
    out_: ?*Continuation,
) callconv(lib.calling_conv) Status {
    const capture = capture_ orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    out.* = null;
    const state = capture.* orelse return .invalid_handle;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(options, DetachOptions) or
        !validBound(options.max_pages) or
        !validBound(options.max_total_bytes) or
        !validBound(options.max_rows))
    {
        return .invalid_state;
    }
    if (state.detached or
        state.terminal_state or
        state.pending or
        state.pending_kind != .ready)
    {
        return .invalid_state;
    }
    const terminal = terminal_c.zigTerminal(state.terminal) orelse
        return .wrong_terminal;
    if (state.page_records > state.max_pages) return .invalid_state;
    const remaining_pages = state.max_pages - state.page_records;
    const detached_page_limit = @min(options.max_pages, remaining_pages);
    const status = if (options.leased)
        attachLeased(state, state.terminal, terminal, detached_page_limit, options)
    else
        attachOwned(state, terminal, detached_page_limit, options);
    if (status != .success) return status;
    state.detached = true;
    capture.* = null;
    out.* = state;
    return .success;
}

/// Own every post-READY record now, releasing the terminal entirely.
fn attachOwned(
    state: *CaptureState,
    terminal: *terminal_c.ZigTerminal,
    page_limit: usize,
    options: *const DetachOptions,
) Status {
    var detached = snapshot.history.DetachedHistories.init(
        state.alloc,
        terminal,
        page_limit,
        options.max_total_bytes,
        state.output_buffer.len,
        options.max_rows,
    ) catch |err| return mapError(err);
    state.encoder.attachDetachedHistories(detached) catch {
        detached.deinit();
        return .invalid_state;
    };
    return .success;
}

/// Pin every post-READY record through a lease, encoding none of them yet.
fn attachLeased(
    state: *CaptureState,
    handle: terminal_c.Terminal,
    terminal: *terminal_c.ZigTerminal,
    page_limit: usize,
    options: *const DetachOptions,
) Status {
    if (!authenticated_history) return .unsupported_feature;
    const io_ = terminal_c.terminalIo(handle) orelse return .wrong_terminal;
    var leased = snapshot.history.LeasedHistories.init(
        io_,
        state.alloc,
        terminal,
        page_limit,
        state.output_buffer.len,
        options.max_rows,
    ) catch |err| return mapError(err);
    state.encoder.attachLeasedHistories(leased) catch {
        leased.deinit();
        return .invalid_state;
    };
    return .success;
}

pub fn continuationNext(
    continuation: Continuation,
    options_: ?*const ContinuationOptions,
    buffer_: ?[*]u8,
    buffer_len: usize,
    out_: ?*CaptureEvent,
) callconv(lib.calling_conv) Status {
    const state = continuation orelse return .invalid_handle;
    if (!state.detached) return .invalid_handle;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(options, ContinuationOptions) or
        !validBound(options.max_rows))
    {
        return .invalid_state;
    }
    const out = out_ orelse return .invalid_handle;
    return captureNextBounded(
        state,
        options.max_rows,
        buffer_,
        buffer_len,
        out,
    );
}

pub fn continuationAbort(
    continuation: Continuation,
) callconv(lib.calling_conv) Status {
    const state = continuation orelse return .invalid_handle;
    if (!state.detached) return .invalid_handle;
    state.terminal_state = true;
    return .success;
}

pub fn continuationFree(
    continuation: Continuation,
) callconv(lib.calling_conv) void {
    captureFree(continuation);
}

pub fn captureAbort(capture: Capture) callconv(lib.calling_conv) Status {
    const state = capture orelse return .invalid_handle;
    state.terminal_state = true;
    return .success;
}

pub fn captureFree(capture: Capture) callconv(lib.calling_conv) void {
    const state = capture orelse return;
    state.encoder.deinit();
    state.alloc.free(state.output_buffer);
    state.alloc.free(state.continuation);
    const alloc = state.alloc;
    alloc.destroy(state);
}

const DecoderState = struct {
    alloc: std.mem.Allocator,
    context: terminal_c.SnapshotDecodeContext,
    decoder: snapshot.Decoder,
    ready: ?snapshot.Ready = null,
    terminal: terminal_c.Terminal = null,
    codec_version: u16 = 0,
    terminal_state: bool = false,
};

pub const Decoder = ?*DecoderState;

pub fn decoderNew(
    alloc_: ?*const CAllocator,
    options_: ?*const DecoderOptions,
    out_: ?*Decoder,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_handle;
    out.* = null;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(options, DecoderOptions) or
        options.max_continuation_bytes > std.math.maxInt(u32) or
        !validBound(options.max_record_bytes) or
        !validBound(options.max_pages))
    {
        return .invalid_state;
    }
    const alloc = lib.alloc.default(alloc_);
    const state = alloc.create(DecoderState) catch return .out_of_memory;
    state.alloc = alloc;
    state.context = terminal_c.SnapshotDecodeContext.init(alloc) catch {
        alloc.destroy(state);
        return .out_of_memory;
    };
    state.decoder = .init(alloc, state.context.io(), .{
        .max_continuation_bytes = options.max_continuation_bytes,
        .max_record_bytes = options.max_record_bytes,
        .max_pages = options.max_pages,
    });
    state.ready = null;
    state.terminal = null;
    state.codec_version = 0;
    state.terminal_state = false;
    out.* = state;
    return .success;
}

pub fn decoderPush(
    decoder: Decoder,
    data_: ?[*]const u8,
    len: usize,
    out_: ?*DecodeEvent,
) callconv(lib.calling_conv) Status {
    const state = decoder orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    if (!validVersioned(out, DecodeEvent)) return .invalid_state;
    out.consumed = 0;
    out.needed = state.decoder.bytesNeeded();
    out.codec_version = state.codec_version;
    out.screen_key = 0;
    out.index = 0;
    out.count = 0;
    out.retained = false;
    if (state.terminal_state) return .invalid_state;
    if (data_ == null and len != 0) return .invalid_state;
    // A null/empty push is the callback-free EOF marker. Ordinary fragmented
    // input never needs an empty progress call because push processes a
    // completed envelope/record in the same call that supplies its final byte.
    if (len == 0) {
        state.decoder.abort();
        state.terminal_state = true;
        return .truncated;
    }
    const data = data_.?[0..len];
    const result = state.decoder.push(data) catch |err| {
        out.consumed = state.decoder.consumedOnError();
        if (err != error.ReadyNotTaken) state.terminal_state = true;
        return mapError(err);
    };
    out.consumed = result.consumed;
    out.needed = state.decoder.bytesNeeded();
    out.kind = switch (result.event) {
        .need_input => .need_input,
        .progress => .progress,
        .ready => |version| ready: {
            out.codec_version = @intFromEnum(version);
            state.codec_version = @intFromEnum(version);
            break :ready .ready;
        },
        .history_begin => |value| history: {
            out.screen_key = @intCast(@intFromEnum(value.key));
            out.count = value.page_count;
            break :history .history_begin;
        },
        .history_page => |value| page: {
            out.screen_key = @intCast(@intFromEnum(value.key));
            out.index = value.index;
            out.count = value.count;
            out.retained = value.retained;
            break :page .history_page;
        },
        .finish => finish: {
            state.terminal_state = true;
            break :finish .finish;
        },
    };
    return .success;
}

pub fn decoderTakeTerminal(
    decoder: Decoder,
    out_: ?*TakeTerminalResult,
) callconv(lib.calling_conv) Status {
    const state = decoder orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    if (!validVersioned(out, TakeTerminalResult)) return .invalid_state;
    out.terminal = null;
    out.codec_version = 0;
    if (state.terminal != null) return .invalid_state;
    const transfer = state.context.restoreReady(&state.decoder) catch |err|
        return mapError(err);
    state.terminal = transfer.terminal;
    state.ready = transfer.ready;
    out.terminal = transfer.terminal;
    out.codec_version = state.codec_version;
    return .success;
}

pub fn decoderReplayContinuation(
    decoder: Decoder,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) Status {
    const state = decoder orelse return .invalid_handle;
    if (terminal == null or terminal != state.terminal) return .wrong_terminal;
    const ready = if (state.ready) |*value| value else return .invalid_state;
    terminal_c.replaySnapshotContinuation(terminal, ready) catch |err|
        return mapError(err);
    ready.deinit();
    state.ready = null;
    return .success;
}

pub fn decoderAbort(decoder: Decoder) callconv(lib.calling_conv) Status {
    const state = decoder orelse return .invalid_handle;
    if (state.ready) |*ready| ready.deinit();
    state.ready = null;
    state.decoder.abort();
    state.terminal_state = true;
    return .success;
}

pub fn decoderFree(decoder: Decoder) callconv(lib.calling_conv) void {
    const state = decoder orelse return;
    if (state.ready) |*ready| ready.deinit();
    state.ready = null;
    state.decoder.deinit();
    state.context.deinit();
    const alloc = state.alloc;
    alloc.destroy(state);
}

const HistoryLeaseState = struct {
    alloc: std.mem.Allocator,
    terminal: terminal_c.Terminal,
    lease: snapshot.HistoryLease,
    released: bool = false,
};
pub const HistoryLease = ?*HistoryLeaseState;

const HistoryCursorState = struct {
    alloc: std.mem.Allocator,
    terminal: terminal_c.Terminal,
    cursor: snapshot.HistoryCursor,
};
pub const HistoryCursor = ?*HistoryCursorState;

pub fn historyLeaseNew(
    alloc_: ?*const CAllocator,
    terminal: terminal_c.Terminal,
    screen_key: u16,
    out_: ?*HistoryLeaseResult,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_handle;
    if (!validVersioned(out, HistoryLeaseResult)) return .invalid_state;
    out.lease = null;
    out.checkpoint = emptyToken();
    if (!authenticated_history) return .unsupported_feature;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    const io_ = terminal_c.terminalIo(terminal) orelse return .wrong_terminal;
    const key = std.enums.fromInt(@import("../ScreenSet.zig").Key, screen_key) orelse
        return .wrong_generation;
    const lease = snapshot.HistoryLease.init(io_, zig_terminal, key) catch |err|
        return mapError(err);
    const alloc = lib.alloc.default(alloc_);
    const state = alloc.create(HistoryLeaseState) catch {
        lease.deinit(zig_terminal);
        return .out_of_memory;
    };
    state.* = .{ .alloc = alloc, .terminal = terminal, .lease = lease };
    out.lease = state;
    out.checkpoint.bytes = lease.checkpoint().bytes;
    return .success;
}

pub fn historyLeaseCursor(
    lease_: HistoryLease,
    terminal: terminal_c.Terminal,
    out_: ?*HistoryCursorResult,
) callconv(lib.calling_conv) Status {
    const state = lease_ orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    if (!validVersioned(out, HistoryCursorResult)) return .invalid_state;
    out.cursor = null;
    out.capability = emptyToken();
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    const cursor_state = state.alloc.create(HistoryCursorState) catch
        return .out_of_memory;
    const cursor = state.lease.cursor(zig_terminal) catch |err| {
        state.alloc.destroy(cursor_state);
        return mapError(err);
    };
    cursor_state.* = .{
        .alloc = state.alloc,
        .terminal = state.terminal,
        .cursor = cursor,
    };
    out.cursor = cursor_state;
    out.capability.bytes = cursor.bytes;
    return .success;
}

pub fn historyLeaseFree(lease_: HistoryLease) callconv(lib.calling_conv) void {
    const state = lease_ orelse return;
    if (!state.released) {
        if (terminal_c.zigTerminal(state.terminal)) |terminal| {
            state.lease.deinit(terminal);
        }
        state.released = true;
    }
    const alloc = state.alloc;
    alloc.destroy(state);
}

pub fn historyCursorNext(
    cursor_: HistoryCursor,
    terminal: terminal_c.Terminal,
    options_: ?*const HistoryOptions,
    buffer_: ?[*]u8,
    buffer_len: usize,
    out_: ?*HistoryEvent,
) callconv(lib.calling_conv) Status {
    const state = cursor_ orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(out, HistoryEvent) or
        !validVersioned(options, HistoryOptions) or
        !validBound(options.max_unit_bytes) or
        !validBound(options.max_rows)) return .invalid_state;
    out.written = 0;
    out.required_bytes = 0;
    out.rows = 0;
    out.page_complete = false;
    if (buffer_ == null and buffer_len != 0) return .invalid_state;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    const byte_budget = if (buffer_len == 0)
        1
    else
        @min(buffer_len, options.max_unit_bytes);
    var empty: [0]u8 = .{};
    var writer: std.Io.Writer = if (buffer_) |ptr|
        .fixed(ptr[0..buffer_len])
    else
        .fixed(&empty);
    const result = state.cursor.next(zig_terminal, .{
        .bytes = byte_budget,
        .rows = options.max_rows,
    }, &writer) catch |err| return mapError(err);
    switch (result) {
        .end => out.kind = .end,
        .zero_budget => return .out_of_space,
        .too_small => |value| {
            out.required_bytes = value.minimum_bytes;
            return .out_of_space;
        },
        .chunk => |value| {
            out.kind = .unit;
            out.written = value.bytes;
            out.required_bytes = value.bytes;
            out.rows = value.rows;
            out.page_complete = value.page_complete;
        },
    }
    return .success;
}

pub fn historyCursorFree(cursor_: HistoryCursor) callconv(lib.calling_conv) void {
    const state = cursor_ orelse return;
    const alloc = state.alloc;
    alloc.destroy(state);
}

const HistoryImporterState = struct {
    alloc: std.mem.Allocator,
    terminal: terminal_c.Terminal,
    importer: snapshot.HistoryImporter,
    released: bool = false,
};
pub const HistoryImporter = ?*HistoryImporterState;

pub fn historyImporterNew(
    alloc_: ?*const CAllocator,
    terminal: terminal_c.Terminal,
    screen_key: u16,
    source_terminal: terminal_c.Terminal,
    checkpoint_: ?*const Token,
    options_: ?*const HistoryOptions,
    out_: ?*HistoryImporterResult,
) callconv(lib.calling_conv) Status {
    const out = out_ orelse return .invalid_handle;
    const checkpoint = checkpoint_ orelse return .invalid_handle;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(out, HistoryImporterResult) or
        !validSized(checkpoint, Token) or
        !validVersioned(options, HistoryOptions)) return .invalid_state;
    if (!validBound(options.max_unit_bytes) or
        !validBound(options.max_rows) or
        !validBound(options.max_units)) return .invalid_state;
    out.importer = null;
    out.capability = emptyToken();
    if (!authenticated_history) return .unsupported_feature;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    const zig_source = terminal_c.zigTerminal(source_terminal) orelse
        return .wrong_terminal;
    const io_ = terminal_c.terminalIo(terminal) orelse return .wrong_terminal;
    const key = std.enums.fromInt(@import("../ScreenSet.zig").Key, screen_key) orelse
        return .wrong_generation;
    const importer = snapshot.HistoryImporter.init(
        io_,
        zig_terminal,
        key,
        options.max_units,
        zig_source,
        .{ .bytes = checkpoint.bytes },
    ) catch |err| return mapError(err);
    const alloc = lib.alloc.default(alloc_);
    const state = alloc.create(HistoryImporterState) catch {
        importer.deinit(zig_terminal);
        return .out_of_memory;
    };
    state.* = .{ .alloc = alloc, .terminal = terminal, .importer = importer };
    out.importer = state;
    out.capability.bytes = importer.bytes;
    return .success;
}

pub fn historyImporterPush(
    importer_: HistoryImporter,
    terminal: terminal_c.Terminal,
    unit_: ?[*]const u8,
    unit_len: usize,
    options_: ?*const HistoryOptions,
    out_: ?*HistoryImportEvent,
) callconv(lib.calling_conv) Status {
    const state = importer_ orelse return .invalid_handle;
    const out = out_ orelse return .invalid_handle;
    const options = options_ orelse return .invalid_state;
    if (!validVersioned(out, HistoryImportEvent) or
        !validVersioned(options, HistoryOptions)) return .invalid_state;
    out.consumed = 0;
    if (!validBound(options.max_unit_bytes) or
        !validBound(options.max_rows)) return .invalid_state;
    out.required_bytes = 0;
    out.required_rows = 0;
    out.rows = 0;
    out.retained = false;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    const unit = if (unit_) |ptr| ptr[0..unit_len] else if (unit_len == 0) &.{} else return .invalid_state;
    const result = state.importer.prepend(zig_terminal, unit, .{
        .bytes = options.max_unit_bytes,
        .rows = options.max_rows,
    }) catch |err| return mapError(err);
    switch (result) {
        .zero_budget => return .out_of_space,
        .too_small => |value| {
            out.required_bytes = value.required_bytes;
            out.required_rows = value.required_rows;
            return .out_of_space;
        },
        .imported => |value| {
            out.consumed = unit.len;
            out.rows = value.rows;
            out.retained = value.retained;
        },
    }
    return .success;
}

pub fn historyImporterCommit(
    importer_: HistoryImporter,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) Status {
    const state = importer_ orelse return .invalid_handle;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    state.importer.commit(zig_terminal) catch |err| return mapError(err);
    state.released = true;
    return .success;
}

pub fn historyImporterAbort(
    importer_: HistoryImporter,
    terminal: terminal_c.Terminal,
) callconv(lib.calling_conv) Status {
    const state = importer_ orelse return .invalid_handle;
    if (terminal == null or terminal != state.terminal)
        return .wrong_terminal;
    const zig_terminal = terminal_c.zigTerminal(terminal) orelse
        return .wrong_terminal;
    state.importer.abort(zig_terminal);
    state.released = true;
    return .success;
}

pub fn historyImporterFree(importer_: HistoryImporter) callconv(lib.calling_conv) void {
    const state = importer_ orelse return;
    if (!state.released) {
        if (terminal_c.zigTerminal(state.terminal)) |terminal| {
            state.importer.deinit(terminal);
        }
    }
    const alloc = state.alloc;
    alloc.destroy(state);
}
