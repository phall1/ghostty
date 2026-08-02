//! Terminal snapshot binary representation and codecs.
//!
//! This is NOT a full transport-ready format to implement generic replay
//! software such as multiplexers, recorders (e.g. asciinema), etc. The goal
//! of this package is to provide a documented, binary-compatible representation
//! for a terminal state.
//!
//! We call this a "snapshot." The snapshot is purposely laid out in a way
//! that prioritizes making a terminal functional as quickly as possible.
//! To do that, it sends the active terminal state followed by a READY record,
//! then complete history.
//!
//! READY denotes that enough authenticated state is present to render the
//! terminal. Version 1 restores the standard Stream at ground. Version 2 also
//! authenticates the Stream CONTINUATION before READY, so a caller can replay
//! it once after moving the Terminal into final storage and then immediately
//! apply PTY bytes belonging after the snapshot cut.
//!
//! After READY, we send history pages (scrollback).
//!
//! ## Snapshot Format
//!
//! Versions 1 and 2 are frozen compatibility boundaries. Public encoding emits
//! version 2. Decoding dispatches the complete record order from the envelope:
//! v1 remains the pre-continuation display/ground format, while v2 adds the
//! continuation required for immediate safe PTY resumption. Any future layout,
//! tag, or record-semantic change requires another version.
//!
//! A snapshot is one envelope followed by a sequence of records. The envelope
//! occurs once at byte zero. Every record is independently framed as a fixed
//! header followed by the number of payload bytes declared by that header.
//!
//! ```text
//! +------------------+
//! | Envelope         |
//! +------------------+
//! | Record 1 header  |
//! +------------------+
//! | Record 1 payload |
//! +------------------+
//! | Record 2 header  |
//! +------------------+
//! | Record 2 payload |
//! +------------------+
//! | ...              |
//! +------------------+
//! ```
//!
//! Record groups have a strict order:
//!
//! ```text
//! +----------------------------------------+
//! | TERMINAL                               |
//! +----------------------------------------+
//! | SCREEN * terminal.screen_count         |
//! | PAGE * each screen.page_count          |
//! +----------------------------------------+
//! | CONTINUATION (version 2 only)          |
//! +----------------------------------------+
//! | READY                                  |
//! +----------------------------------------+
//! | HISTORY * terminal.screen_count        |
//! | PAGE * each history.page_count         |
//! +----------------------------------------+
//! | FINISH                                 |
//! +----------------------------------------+
//! ```
//!
//! The SCREEN and HISTORY sequence groups may each appear in any key order.
//! Each key must occur exactly once in each group and must identify one of the
//! screens declared by TERMINAL. SCREEN contains the complete pages needed to
//! restore each active area. HISTORY contains the older complete pages for its
//! screen in newest-to-oldest order so they can be prepended as they arrive.
//! Every SCREEN has one corresponding HISTORY, even when its history page count
//! is zero. FINISH terminates the snapshot. Bytes after FINISH belong to the
//! containing transport and are not consumed by snapshot decoding.
//!
//! In version 2, CONTINUATION contains the bytes required to bring the
//! VT parser/stream up to the same state, or no bytes if it should be in the
//! ground state. Version 1 has no CONTINUATION record and restores ground.
//!
//! READY and FINISH contain BLAKE3-256 digests of all preceding snapshot bytes.
//! READY therefore validates through active SCREEN/PAGE in v1 and through
//! CONTINUATION in v2. FINISH covers READY, all history, and the complete
//! version-specific record order. Each SCREEN declares its complete logical
//! extent, allowing a client to size its scrollbar at READY even though older
//! PAGE records arrive afterward.
//!
//! ## Encoding
//!
//! Encode a complete snapshot into any writer:
//!
//! ```zig
//! var output: std.Io.Writer.Allocating = .init(alloc);
//! defer output.deinit();
//!
//! try snapshot.encode(alloc, &output.writer, &terminal, .{
//!     .continuation = .ground,
//! });
//!
//! const bytes = output.written();
//! ```
//!
//! `Encoder.next` emits at most one envelope or record per call and reports the
//! authenticated READY boundary before it begins history. `snapshot.encode` is
//! the blocking adapter over that same state machine. Encoding begins at the
//! writer's current position, so unrelated bytes may precede the snapshot.
//! Only the current record payload is buffered to calculate its length and
//! CRC32C; completed records stream immediately and BLAKE3 checkpoint coverage
//! is updated incrementally.
//!
//! Unsupported Kitty graphics or glyph glossary state is rejected before the
//! envelope and leaves the destination unchanged. A later failure may leave
//! prior complete records, or a partial record if the destination itself fails.
//! Such a prefix has no valid FINISH checkpoint and cannot be restored as a
//! complete snapshot.
//!
//! Each record type usually exposes an `encode` function that encodes
//! a complete record, such as `screen.encode`.
//!
//! ## Decoding
//!
//! `Decoder.push` accepts arbitrary fragments, buffers at most one
//! caller-bounded record, and publishes the authenticated Terminal exactly at
//! READY through `takeReady`. The caller may attach its persistent Stream and
//! serialize PTY writes between later history records. `snapshot.decode` is the
//! blocking adapter and still consumes exactly one snapshot through FINISH,
//! leaving following bytes unread.
//!
//! ```zig
//! var decoded = try snapshot.decode(alloc, io, &reader, .{
//!     .max_continuation_bytes = 1024 * 1024,
//! });
//! defer decoded.deinit(alloc);
//! var terminal = decoded.toOwned();
//! defer terminal.deinit(alloc);
//! ```
//!
//! Use `snapshot.decodeExact` for a bounded file or buffer that must contain
//! only one snapshot. It preserves the stricter end-of-file check, which may
//! block when used with a live stream.

pub const checkpoint = @import("checkpoint.zig");
pub const continuation = @import("continuation.zig");
pub const envelope = @import("envelope.zig");
pub const grid = @import("grid.zig");
pub const history = @import("history.zig");
pub const hyperlink = @import("hyperlink.zig");
pub const page = @import("page.zig");
pub const record = @import("record.zig");
pub const screen = @import("screen.zig");
pub const style = @import("style.zig");
pub const terminal = @import("terminal.zig");

const codec = @import("snapshot.zig");
pub const EncodeError = codec.EncodeError;
pub const UnsupportedStateError = codec.UnsupportedStateError;
pub const validateSupportedState = codec.validateSupportedState;
pub const DecodeError = codec.DecodeError;
pub const DecodeExactError = codec.DecodeExactError;
pub const Version = codec.Version;
pub const Capabilities = codec.Capabilities;
pub const capabilities = codec.capabilities;
pub const Continuation = codec.Continuation;
pub const EncodeOptions = codec.EncodeOptions;
pub const EncodeEvent = codec.EncodeEvent;
pub const Encoder = codec.Encoder;
pub const DecodeOptions = codec.DecodeOptions;
pub const Decoded = codec.Decoded;
pub const Ready = codec.Ready;
pub const DecodeEvent = codec.DecodeEvent;
pub const PushResult = codec.PushResult;
pub const Decoder = codec.Decoder;
pub const HistoryCheckpoint = history.HistoryCheckpoint;
pub const HistoryLease = history.HistoryLease;
pub const HistoryCursor = history.HistoryCursor;
pub const HistoryBudget = history.Budget;
pub const HistoryNextResult = history.NextResult;
pub const HistoryCursorError = history.CursorError;
pub const HistoryImporter = history.HistoryImporter;
pub const HistoryImportResult = history.ImportResult;
pub const HistoryImportError = history.ImportError;
pub const encode = codec.encode;
pub const decode = codec.decode;
pub const decodeExact = codec.decodeExact;

test {
    _ = @import("fuzz.zig");
    @import("std").testing.refAllDecls(@This());
}
