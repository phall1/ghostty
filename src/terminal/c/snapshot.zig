const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const snapshot_codec = @import("../snapshot/main.zig");
const allocator_c = @import("allocator.zig");
const terminal_c = @import("terminal.zig");
const CAllocator = lib.alloc.Allocator;
const Result = @import("result.zig").Result;

/// Allocator-owned encoded snapshot bytes.
///
/// C: GhosttyTerminalSnapshot
pub const Encoded = extern struct {
    size: usize,
    data: ?[*]u8,
    len: usize,
};

/// A terminal restored from exactly one complete snapshot and the number of
/// source bytes consumed through its FINISH record.
///
/// C: GhosttyTerminalSnapshotDecodeResult
pub const DecodeResult = extern struct {
    size: usize,
    terminal: terminal_c.Terminal,
    consumed: usize,
};

fn mapError(err: anyerror) Result {
    return switch (err) {
        error.OutOfMemory, error.WriteFailed => .out_of_memory,
        else => .invalid_value,
    };
}

/// Encode the terminal and its live standard-stream continuation into one
/// complete allocator-owned snapshot.
pub fn encode(
    alloc_: ?*const CAllocator,
    terminal: terminal_c.Terminal,
    out_: ?*Encoded,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    if (out.size < @sizeOf(Encoded)) return .invalid_value;
    out.data = null;
    out.len = 0;

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);

    var continuation_writer: std.Io.Writer.Allocating = .init(alloc);
    defer continuation_writer.deinit();
    terminal_c.writeSnapshotContinuation(
        terminal,
        &continuation_writer.writer,
    ) catch |err| return mapError(err);

    const continuation: snapshot_codec.Continuation = if (continuation_writer.written().len == 0)
        .ground
    else
        .{ .bytes = continuation_writer.written() };

    var snapshot_writer: std.Io.Writer.Allocating = .init(alloc);
    defer snapshot_writer.deinit();
    snapshot_codec.encode(
        alloc,
        &snapshot_writer.writer,
        t,
        .{ .continuation = continuation },
    ) catch |err| return mapError(err);

    const bytes = snapshot_writer.toOwnedSlice() catch return .out_of_memory;
    out.data = bytes.ptr;
    out.len = bytes.len;
    return .success;
}

/// Decode exactly one complete snapshot and leave any trailing transport bytes
/// unconsumed. The returned terminal is published only after continuation
/// replay succeeds at its final address.
pub fn decode(
    alloc_: ?*const CAllocator,
    data_: ?[*]const u8,
    len: usize,
    out_: ?*DecodeResult,
) callconv(lib.calling_conv) Result {
    const out = out_ orelse return .invalid_value;
    if (out.size < @sizeOf(DecodeResult)) return .invalid_value;
    out.terminal = null;
    out.consumed = 0;

    const data = if (data_) |ptr|
        ptr[0..len]
    else if (len == 0)
        &.{}
    else
        return .invalid_value;

    const alloc = lib.alloc.default(alloc_);
    var context = terminal_c.SnapshotDecodeContext.init(alloc) catch |err|
        return mapError(err);
    defer context.deinit();

    var reader: std.Io.Reader = .fixed(data);
    var decoded = snapshot_codec.decode(
        alloc,
        context.io(),
        &reader,
        .{ .max_continuation_bytes = data.len },
    ) catch |err| return mapError(err);
    defer decoded.deinit(alloc);

    const restored = context.restore(&decoded) catch |err|
        return mapError(err);

    out.terminal = restored;
    out.consumed = reader.seek;
    return .success;
}

fn testTerminal() !terminal_c.Terminal {
    var terminal: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &terminal,
        80,
        24,
    ));
    return terminal;
}

fn testEncode(terminal: terminal_c.Terminal) !Encoded {
    var result: Encoded = .{
        .size = @sizeOf(Encoded),
        .data = null,
        .len = 0,
    };
    try testing.expectEqual(Result.success, encode(
        &lib.alloc.test_allocator,
        terminal,
        &result,
    ));
    try testing.expect(result.data != null);
    try testing.expect(result.len > 0);
    return result;
}

fn testFreeEncoded(encoded: Encoded) void {
    allocator_c.free(
        &lib.alloc.test_allocator,
        encoded.data,
        encoded.len,
    );
}

fn testDecode(data: []const u8) !DecodeResult {
    var result: DecodeResult = .{
        .size = @sizeOf(DecodeResult),
        .terminal = null,
        .consumed = 0,
    };
    try testing.expectEqual(Result.success, decode(
        &lib.alloc.test_allocator,
        data.ptr,
        data.len,
        &result,
    ));
    try testing.expect(result.terminal != null);
    return result;
}

fn expectEquivalent(a: terminal_c.Terminal, b: terminal_c.Terminal) !void {
    const a_encoded = try testEncode(a);
    defer testFreeEncoded(a_encoded);
    const b_encoded = try testEncode(b);
    defer testFreeEncoded(b_encoded);
    try testing.expectEqualSlices(
        u8,
        a_encoded.data.?[0..a_encoded.len],
        b_encoded.data.?[0..b_encoded.len],
    );
}

test "snapshot C API ground-state round trip restores usable terminal" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    terminal_c.vt_write(source, "hello\r\nworld", 12);

    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);
    const restored = try testDecode(encoded.data.?[0..encoded.len]);
    defer terminal_c.free(restored.terminal);

    try testing.expectEqual(encoded.len, restored.consumed);
    try expectEquivalent(source, restored.terminal);

    const S = struct {
        var bells: usize = 0;
        fn bell(_: terminal_c.Terminal, _: ?*anyopaque) callconv(lib.calling_conv) void {
            bells += 1;
        }
    };
    S.bells = 0;
    try testing.expectEqual(Result.success, terminal_c.set(
        restored.terminal,
        .bell,
        @ptrCast(&S.bell),
    ));
    terminal_c.vt_write(restored.terminal, "\x07", 1);
    try testing.expectEqual(@as(usize, 1), S.bells);
}

test "snapshot C API resumes split CSI" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    terminal_c.vt_write(source, "\x1b[31", 4);

    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);
    const restored = try testDecode(encoded.data.?[0..encoded.len]);
    defer terminal_c.free(restored.terminal);

    terminal_c.vt_write(source, "mred", 4);
    terminal_c.vt_write(restored.terminal, "mred", 4);
    try expectEquivalent(source, restored.terminal);
}

test "snapshot C API resumes split UTF-8" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    const prefix = "\xF0\x9F\x98";
    terminal_c.vt_write(source, prefix, prefix.len);

    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);
    const restored = try testDecode(encoded.data.?[0..encoded.len]);
    defer terminal_c.free(restored.terminal);

    terminal_c.vt_write(source, "\x80", 1);
    terminal_c.vt_write(restored.terminal, "\x80", 1);
    try expectEquivalent(source, restored.terminal);

    const plain = try terminal_c.zigTerminal(restored.terminal).?.plainString(testing.allocator);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("😀", plain);
}

test "snapshot C API reports one-snapshot consumption with trailing bytes" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    terminal_c.vt_write(source, "state", 5);

    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);
    const trailing = "trailing transport bytes";
    const input = try testing.allocator.alloc(u8, encoded.len + trailing.len);
    defer testing.allocator.free(input);
    @memcpy(input[0..encoded.len], encoded.data.?[0..encoded.len]);
    @memcpy(input[encoded.len..], trailing);

    const restored = try testDecode(input);
    defer terminal_c.free(restored.terminal);
    try testing.expectEqual(encoded.len, restored.consumed);
    try testing.expectEqualStrings(trailing, input[restored.consumed..]);
}

test "snapshot C API rejects malformed and truncated input transactionally" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);

    const malformed = try testing.allocator.dupe(u8, encoded.data.?[0..encoded.len]);
    defer testing.allocator.free(malformed);
    malformed[0] ^= 1;

    const cases = [_][]const u8{
        malformed,
        encoded.data.?[0 .. encoded.len - 1],
    };
    for (cases) |input| {
        var result: DecodeResult = .{
            .size = @sizeOf(DecodeResult),
            .terminal = @ptrFromInt(@alignOf(usize)),
            .consumed = std.math.maxInt(usize),
        };
        try testing.expectEqual(Result.invalid_value, decode(
            &lib.alloc.test_allocator,
            input.ptr,
            input.len,
            &result,
        ));
        try testing.expectEqual(@as(terminal_c.Terminal, null), result.terminal);
        try testing.expectEqual(@as(usize, 0), result.consumed);
    }
}

test "snapshot C API maps allocation failure and clears outputs" {
    const source = try testTerminal();
    defer terminal_c.free(source);
    const encoded = try testEncode(source);
    defer testFreeEncoded(encoded);

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    const failing_alloc = failing.allocator();
    const c_failing = CAllocator.fromZig(&failing_alloc);

    var encoded_result: Encoded = .{
        .size = @sizeOf(Encoded),
        .data = @ptrFromInt(@alignOf(usize)),
        .len = std.math.maxInt(usize),
    };
    const encode_status = encode(
        &c_failing,
        source,
        &encoded_result,
    );
    defer allocator_c.free(
        &c_failing,
        encoded_result.data,
        encoded_result.len,
    );
    try testing.expectEqual(Result.out_of_memory, encode_status);
    try testing.expectEqual(@as(?[*]u8, null), encoded_result.data);
    try testing.expectEqual(@as(usize, 0), encoded_result.len);

    var decode_failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 1,
    });
    const decode_failing_alloc = decode_failing.allocator();
    const c_decode_failing = CAllocator.fromZig(&decode_failing_alloc);
    var decoded_result: DecodeResult = .{
        .size = @sizeOf(DecodeResult),
        .terminal = @ptrFromInt(@alignOf(usize)),
        .consumed = std.math.maxInt(usize),
    };
    const decode_status = decode(
        &c_decode_failing,
        encoded.data,
        encoded.len,
        &decoded_result,
    );
    defer terminal_c.free(decoded_result.terminal);
    try testing.expectEqual(Result.out_of_memory, decode_status);
    try testing.expectEqual(@as(terminal_c.Terminal, null), decoded_result.terminal);
    try testing.expectEqual(@as(usize, 0), decoded_result.consumed);
}
