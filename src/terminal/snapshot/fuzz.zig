const std = @import("std");
const snapshot = @import("snapshot.zig");
const envelope = @import("envelope.zig");
const record = @import("record.zig");
const Terminal = @import("../Terminal.zig");

const testing = std.testing;
const seed = 0x534E_4150_4655_5A5A;

const Span = struct { start: usize, end: usize, tag: record.Tag };

fn fixture(alloc: std.mem.Allocator) ![]u8 {
    var terminal = try Terminal.init(testing.io, alloc, .{ .cols = 7, .rows = 3 });
    defer terminal.deinit(alloc);
    for (0..40) |index| {
        var text: [16]u8 = undefined;
        const value = try std.fmt.bufPrint(&text, "row-{d:0>3}\r\n", .{index});
        try terminal.printString(value);
    }
    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    var encoder = try snapshot.Encoder.init(alloc, &output.writer, &terminal, .{ .continuation = .ground });
    defer encoder.deinit();
    while (!encoder.finished()) _ = try encoder.next();
    return output.toOwnedSlice();
}

fn recordSpans(bytes: []const u8, out: []Span) !usize {
    var offset = envelope.encoded_len;
    var count: usize = 0;
    while (offset < bytes.len) {
        if (count == out.len or bytes.len - offset < record.Header.len) return error.InvalidFixture;
        var source: std.Io.Reader = .fixed(bytes[offset..][0..record.Header.len]);
        const header = try record.Header.decode(&source);
        const end = offset + record.Header.len + header.payload_len;
        if (end > bytes.len) return error.InvalidFixture;
        out[count] = .{ .start = offset, .end = end, .tag = header.tag };
        count += 1;
        offset = end;
    }
    return count;
}

fn decodeFragments(bytes: []const u8, split: usize) !void {
    var decoder: snapshot.Decoder = .init(testing.allocator, testing.io, .{
        .max_continuation_bytes = 4096,
        .max_record_bytes = 1024 * 1024,
        .max_pages = 4096,
    });
    defer decoder.deinit();
    var restored: Terminal = undefined;
    var restored_owned = false;
    defer if (restored_owned) restored.deinit(testing.allocator);
    var ready: ?snapshot.Ready = null;
    defer if (ready) |*value| value.deinit();
    var offset: usize = 0;
    var finished = false;
    while (!finished) {
        const boundary = if (offset < split) split else bytes.len;
        const pushed = try decoder.push(bytes[offset..boundary]);
        try testing.expect(pushed.consumed <= boundary - offset);
        offset += pushed.consumed;
        switch (pushed.event) {
            .ready => {
                try testing.expect(!restored_owned);
                ready = try decoder.takeReady(&restored);
                restored_owned = true;
            },
            .finish => finished = true,
            else => {},
        }
        if (!finished and pushed.consumed == 0) return error.NoProgress;
    }
    try testing.expectEqual(bytes.len, offset);
    try testing.expect(restored_owned);
    try restored.printString("terminal-still-usable");
}

fn expectDecodeError(bytes: []const u8, expected: anyerror) !void {
    var source: std.Io.Reader = .fixed(bytes);
    const decoded = snapshot.decode(testing.allocator, testing.io, &source, .{
        .max_continuation_bytes = 4096,
        .max_record_bytes = 1024 * 1024,
        .max_pages = 4096,
    });
    try testing.expectError(expected, decoded);
}

test "snapshot property every split and truncation is bounded" {
    const bytes = try fixture(testing.allocator);
    defer testing.allocator.free(bytes);
    for (0..bytes.len + 1) |split| try decodeFragments(bytes, split);
    for (0..bytes.len) |cut| {
        var source: std.Io.Reader = .fixed(bytes[0..cut]);
        try testing.expectError(error.EndOfStream, snapshot.decode(
            testing.allocator,
            testing.io,
            &source,
            .{ .max_continuation_bytes = 4096, .max_record_bytes = 1024 * 1024, .max_pages = 4096 },
        ));
    }
}

test "snapshot property rejects reordered duplicated and forged records" {
    const bytes = try fixture(testing.allocator);
    defer testing.allocator.free(bytes);
    var spans: [128]Span = undefined;
    const count = try recordSpans(bytes, &spans);
    try testing.expect(count > 3);
    try testing.expectEqual(record.Tag.terminal, spans[0].tag);

    var reordered: std.Io.Writer.Allocating = .init(testing.allocator);
    defer reordered.deinit();
    try reordered.writer.writeAll(bytes[0..envelope.encoded_len]);
    try reordered.writer.writeAll(bytes[spans[1].start..spans[1].end]);
    try reordered.writer.writeAll(bytes[spans[0].start..spans[0].end]);
    try reordered.writer.writeAll(bytes[spans[1].end..]);
    try expectDecodeError(reordered.written(), error.UnexpectedRecordTag);

    var duplicated: std.Io.Writer.Allocating = .init(testing.allocator);
    defer duplicated.deinit();
    try duplicated.writer.writeAll(bytes[0..spans[0].end]);
    try duplicated.writer.writeAll(bytes[spans[0].start..spans[0].end]);
    try duplicated.writer.writeAll(bytes[spans[0].end..]);
    try expectDecodeError(duplicated.written(), error.UnexpectedRecordTag);

    var forged = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(forged);
    for (spans[0..count]) |span| {
        if (span.tag != .ready) continue;
        forged[span.end - 1] ^= 0x80;
        break;
    }
    try expectDecodeError(forged, error.InvalidChecksum);
    @memcpy(forged, bytes);
    forged[8] = 0xFF;
    try expectDecodeError(forged, error.UnsupportedVersion);
}

test "snapshot property malformed arbitrary bytes return typed errors without panic" {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var bytes: [257]u8 = undefined;
    var rejected: usize = 0;
    for (0..256) |_| {
        const len = random.uintLessThan(usize, bytes.len);
        random.bytes(bytes[0..len]);
        var decoder: snapshot.Decoder = .init(testing.allocator, testing.io, .{
            .max_continuation_bytes = 256,
            .max_record_bytes = 512,
            .max_pages = 8,
        });
        defer decoder.deinit();
        var offset: usize = 0;
        while (offset < len) {
            const width = @min(len - offset, 1 + random.uintLessThan(usize, 17));
            const pushed = decoder.push(bytes[offset..][0..width]) catch {
                rejected += 1;
                break;
            };
            offset += pushed.consumed;
            if (std.meta.activeTag(pushed.event) == .finish or
                pushed.consumed == 0) break;
        }
    }
    try testing.expect(rejected > 0);
}

test "snapshot property enforces record bound before payload allocation" {
    const bytes = try fixture(testing.allocator);
    defer testing.allocator.free(bytes);
    var malicious = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(malicious);
    std.mem.writeInt(u32, malicious[envelope.encoded_len + 2 ..][0..4], 4096, .little);
    var decoder: snapshot.Decoder = .init(testing.allocator, testing.io, .{
        .max_continuation_bytes = 64,
        .max_record_bytes = 64,
        .max_pages = 1,
    });
    defer decoder.deinit();
    const envelope_result = try decoder.push(malicious[0..envelope.encoded_len]);
    try testing.expectEqual(envelope.encoded_len, envelope_result.consumed);
    try testing.expectError(error.RecordLimitExceeded, decoder.push(
        malicious[envelope.encoded_len..][0..record.Header.len],
    ));
}

test "snapshot property allocator fail after every decode allocation" {
    const bytes = try fixture(testing.allocator);
    defer testing.allocator.free(bytes);
    var reached_success = false;
    for (0..256) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var source: std.Io.Reader = .fixed(bytes);
        if (snapshot.decode(failing.allocator(), testing.io, &source, .{
            .max_continuation_bytes = 4096,
            .max_record_bytes = 1024 * 1024,
            .max_pages = 4096,
        })) |value| {
            var decoded = value;
            decoded.deinit(failing.allocator());
            reached_success = true;
            break;
        } else |err| try testing.expectEqual(error.OutOfMemory, err);
    }
    try testing.expect(reached_success);
}
