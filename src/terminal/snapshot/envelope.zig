//! Snapshot envelope.
//!
//! Every snapshot binary blob begins with exactly one envelope at byte zero.
//! It is followed by a set of records. Each record provides their own
//! tag, payload length, CRC, etc.
//!
//! The envelope identifies the bytes as a terminal snapshot and selects the
//! single version governing the entire blob. A decoder validates both fields
//! before reading any records.
//!
//! The envelope is exactly ten bytes. All integers are unsigned and
//! little-endian.
//!
//! | Offset | Size | Field                |
//! | -----: | ---: | :------------------- |
//! |      0 |    8 | Magic (`GHOSTSNP`)   |
//! |      8 |    2 | Version (`u16`)      |

const std = @import("std");
const test_fixture = @import("fixture.zig");
const io = @import("io.zig");

/// Identifies a Ghostty terminal snapshot and rejects unrelated input before
/// any record decoding begins. All eight bytes are part of the wire value.
pub const magic = "GHOSTSNP";

/// Supported snapshot format versions. Every layout or record-semantic change
/// requires a new value; decoders dispatch the complete record order by this.
pub const Version = enum(u16) {
    v1 = 1,
    v2 = 2,
};

pub const min_decode_version: Version = .v1;
pub const max_decode_version: Version = .v2;
pub const default_encode_version: Version = .v2;

/// Number of bytes in the fixed envelope: magic followed by version.
pub const encoded_len = computeLen();

comptime {
    // We expect this so if it changes we should think carefully.
    std.debug.assert(encoded_len == 10);
}

pub const DecodeError = std.Io.Reader.Error || error{
    InvalidMagic,
    UnsupportedVersion,
};

/// Encode the envelope using the default format version.
pub fn encode(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    return encodeVersion(writer, default_encode_version);
}

/// Encode the envelope for an explicitly selected supported format version.
pub fn encodeVersion(
    writer: *std.Io.Writer,
    version: Version,
) std.Io.Writer.Error!void {
    try writer.writeAll(magic);
    try io.writeInt(writer, u16, @intFromEnum(version));
}

/// Decode and validate the envelope, returning the version that governs every
/// following record. This completes before record or page allocation begins.
pub fn decode(reader: *std.Io.Reader) DecodeError!Version {
    var actual_magic: [magic.len]u8 = undefined;
    try reader.readSliceAll(&actual_magic);
    if (!std.mem.eql(u8, magic, &actual_magic)) return error.InvalidMagic;

    const actual_version = try io.readInt(reader, u16);
    return std.enums.fromInt(Version, actual_version) orelse
        error.UnsupportedVersion;
}

fn computeLen() usize {
    comptime {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        encode(&writer) catch unreachable;
        return writer.end;
    }
}

const test_v1_fixture = test_fixture.parse(@embedFile("testdata/envelope-v1.hex"));
const test_v2_fixture = test_fixture.parse(@embedFile("testdata/envelope-v2.hex"));

test "golden encodings and supported decoding" {
    var buf: [encoded_len]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer);

    try test_fixture.expectEqual(
        .bytes,
        "src/terminal/snapshot/testdata/envelope-v2.hex",
        "snapshot_fixture-envelope-v2.hex",
        &test_v2_fixture,
        writer.buffered(),
    );

    var v1_reader: std.Io.Reader = .fixed(&test_v1_fixture);
    try std.testing.expectEqual(Version.v1, try decode(&v1_reader));

    var v2_reader: std.Io.Reader = .fixed(&test_v2_fixture);
    try std.testing.expectEqual(Version.v2, try decode(&v2_reader));
}

test "reject invalid magic and unknown versions" {
    var invalid_magic: std.Io.Reader = .fixed("GHOSTSNX\x02\x00");
    try std.testing.expectError(error.InvalidMagic, decode(&invalid_magic));

    for ([_]u16{ 0, 3, std.math.maxInt(u16) }) |version| {
        var bytes: [encoded_len]u8 = undefined;
        @memcpy(bytes[0..magic.len], magic);
        std.mem.writeInt(u16, bytes[magic.len..][0..2], version, .little);
        var reader: std.Io.Reader = .fixed(&bytes);
        try std.testing.expectError(error.UnsupportedVersion, decode(&reader));
    }
}

test "reject every truncation" {
    for (0..encoded_len) |len| {
        var reader: std.Io.Reader = .fixed(test_v2_fixture[0..len]);
        try std.testing.expectError(error.EndOfStream, decode(&reader));
    }
}
