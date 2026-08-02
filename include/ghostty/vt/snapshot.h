/**
 * @file snapshot.h
 *
 * Complete terminal state snapshot encoding and restoration.
 */

#ifndef GHOSTTY_VT_SNAPSHOT_H
#define GHOSTTY_VT_SNAPSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup snapshot Terminal Snapshots
 *
 * Bootstrap whole-blob access to Ghostty's complete terminal snapshot codec.
 * A snapshot includes terminal state, active and historical screen contents,
 * and the canonical continuation of the standard VT stream. This API does not
 * expose incremental READY/history delivery; callers receive or provide one
 * complete snapshot blob.
 *
 * Snapshot versions 1 and 2 are frozen compatibility boundaries. This codec
 * decodes both and emits version 2 by default. A decoder may reject a blob
 * produced with an unknown version using `GHOSTTY_INVALID_VALUE`.
 *
 * Snapshot calls are not thread safe with terminal mutation. The caller must
 * pause and serialize VT writes while encoding a terminal.
 *
 * @{ */

/**
 * Immutable compatibility and feature metadata for the complete snapshot
 * codec.
 *
 * Before calling ghostty_terminal_snapshot_capabilities(), set `size` to
 * `sizeof(GhosttyTerminalSnapshotCapabilities)`. The decode bounds are
 * inclusive. Feature booleans describe the format emitted by
 * `default_encode_version`; older decoded versions may omit a feature.
 */
typedef struct {
    size_t size;
    /** Lowest accepted envelope version, inclusive. */
    uint16_t min_decode_version;
    /** Highest accepted envelope version, inclusive. */
    uint16_t max_decode_version;
    /** Envelope version emitted by the whole-blob encoder. */
    uint16_t default_encode_version;
    /** Default encoding includes CONTINUATION before READY. */
    bool continuation;
    /** Default encoding exposes an authenticated READY boundary. */
    bool ready;
    /** Default encoding includes HISTORY/PAGE after READY. */
    bool history;
} GhosttyTerminalSnapshotCapabilities;

/**
 * Return immutable codec compatibility and feature metadata.
 *
 * `out_capabilities` must be non-NULL and its `size` must be at least
 * `sizeof(GhosttyTerminalSnapshotCapabilities)`.
 */
GHOSTTY_API GhosttyResult ghostty_terminal_snapshot_capabilities(
    GhosttyTerminalSnapshotCapabilities* out_capabilities);

/**
 * Allocator-owned bytes for one complete encoded terminal snapshot.
 *
 * Before calling ghostty_terminal_snapshot_encode(), set `size` to
 * `sizeof(GhosttyTerminalSnapshot)`. On success, `data` points to exactly `len`
 * bytes allocated with the allocator passed to the encode call. Release the
 * bytes with `ghostty_free(allocator, data, len)` using that same allocator.
 *
 * On failure, `data` is NULL and `len` is zero.
 */
typedef struct {
    size_t size;
    uint8_t* data;
    size_t len;
} GhosttyTerminalSnapshot;

/**
 * Result of restoring exactly one complete terminal snapshot.
 *
 * Before calling ghostty_terminal_snapshot_decode(), set `size` to
 * `sizeof(GhosttyTerminalSnapshotDecodeResult)`. On success, `terminal` is a
 * fully usable terminal with its standard VT stream continuation restored and
 * `consumed` is the number of input bytes through the snapshot FINISH record.
 * Any bytes in the input after `consumed` belong to the containing transport
 * and are not processed by the snapshot decoder.
 *
 * The returned terminal owns allocations made through the allocator passed to
 * decode and must be released with ghostty_terminal_free(). On failure,
 * `terminal` is NULL and `consumed` is zero.
 */
typedef struct {
    size_t size;
    GhosttyTerminal terminal;
    size_t consumed;
} GhosttyTerminalSnapshotDecodeResult;

/**
 * Encode a terminal and its live VT stream continuation as one complete
 * allocator-owned version 2 snapshot.
 *
 * `allocator` may be NULL to use the library default. `terminal` and
 * `out_snapshot` must be non-NULL, and `out_snapshot->size` must be at least
 * `sizeof(GhosttyTerminalSnapshot)`.
 *
 * Returns `GHOSTTY_SUCCESS` on success, `GHOSTTY_OUT_OF_MEMORY` if allocation
 * fails, `GHOSTTY_UNSUPPORTED_FEATURE` if version 2 cannot represent
 * terminal-owned semantic state (currently Kitty graphics or glyph glossary
 * entries), or `GHOSTTY_INVALID_VALUE` if the terminal cannot provide a
 * complete canonical continuation or an argument is invalid.
 */
GHOSTTY_API GhosttyResult ghostty_terminal_snapshot_encode(
    const GhosttyAllocator* allocator,
    GhosttyTerminal terminal,
    GhosttyTerminalSnapshot* out_snapshot);

/**
 * Decode exactly one complete snapshot from the start of `data`.
 *
 * `allocator` may be NULL to use the library default. `data` may be NULL only
 * when `len` is zero. `out_result` must be non-NULL, and `out_result->size`
 * must be at least `sizeof(GhosttyTerminalSnapshotDecodeResult)`.
 *
 * The operation is transactional: no terminal is published until every record
 * through FINISH has validated. Version 1 explicitly restores a ground stream;
 * version 2 replays its canonical continuation exactly once at the terminal's
 * final address. Trailing bytes are allowed and are reported via
 * `out_result->consumed`.
 *
 * Returns `GHOSTTY_SUCCESS` on success, `GHOSTTY_OUT_OF_MEMORY` if allocation
 * fails, or `GHOSTTY_INVALID_VALUE` for malformed, truncated, unsupported, or
 * otherwise invalid input.
 */
GHOSTTY_API GhosttyResult ghostty_terminal_snapshot_decode(
    const GhosttyAllocator* allocator,
    const uint8_t* data,
    size_t len,
    GhosttyTerminalSnapshotDecodeResult* out_result);

/** ABI version required in every incremental options, event, and result. */
#define GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION 1u
#define GHOSTTY_TERMINAL_HISTORY_TOKEN_BYTES 32u

/** Detailed incremental codec and history result. */
typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS = 0,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNSUPPORTED_FEATURE = -1,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNKNOWN_VERSION = -2,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION = -3,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED = -4,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_LIMIT_EXCEEDED = -5,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_STALE = -6,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_PRUNED = -7,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_GENERATION = -8,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_TERMINAL = -9,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_HANDLE = -10,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_IMPORT_BUSY = -11,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY = -12,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE = -13,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE = -14,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CONTINUATION_UNAVAILABLE = -15,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_RESET = -16,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_RESIZE = -17,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_ENTROPY_UNAVAILABLE = -18,
    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalSnapshotStatus;

/** Sized, semantically opaque 32-byte checkpoint or capability token. */
typedef struct {
    size_t size;
    uint8_t bytes[GHOSTTY_TERMINAL_HISTORY_TOKEN_BYTES];
} GhosttyTerminalHistoryToken;

/**
 * Incremental ABI feature and identity metadata.
 *
 * `codec_identity` and `build_identity` are immutable library-owned strings.
 * Standalone `wasm32-freestanding` builds require the wasm function import
 * `ghostty.host_entropy_fill(i32 buffer, i32 len) -> i32`. The host must fill
 * all `len` bytes in module linear memory with cryptographically secure random
 * data and return zero. Any nonzero return produces ENTROPY_UNAVAILABLE; there
 * is no deterministic fallback. Other freestanding targets continue to report
 * authenticated history as unsupported.
 */
typedef struct {
    size_t size;
    uint32_t version;
    uint16_t min_decode_version;
    uint16_t max_decode_version;
    uint16_t default_encode_version;
    bool incremental;
    bool ready;
    bool history;
    bool authenticated_tokens;
    bool bounded_records;
    bool bounded_pages;
    bool bounded_units;
    size_t max_record_bytes;
    size_t max_pages;
    size_t max_unit_bytes;
    size_t max_rows;
    GhosttyString codec_identity;
    GhosttyString build_identity;
} GhosttyTerminalSnapshotIncrementalCapabilities;

typedef struct {
    size_t size;
    uint32_t version;
    /** Inclusive limit for one envelope or framed record. Must be nonzero. */
    size_t max_record_bytes;
    /** Inclusive count of PAGE records. Must be nonzero. */
    size_t max_pages;
} GhosttyTerminalSnapshotCaptureOptions;

typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_RECORD = 0,
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_READY = 1,
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_HISTORY_BEGIN = 2,
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_HISTORY_PAGE = 3,
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_FINISH = 4,
    GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalSnapshotCaptureEventKind;

/**
 * Result of one capture step. Exactly one opaque envelope or record is written.
 *
 * On OUT_OF_SPACE, `written` is zero, `required_bytes` is exact, and the next
 * call observes the same event and bytes. `checkpoint` is nonzero only for
 * READY and is the authenticated READY prefix digest.
 */
typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalSnapshotCaptureEventKind kind;
    uint16_t codec_version;
    uint16_t screen_key;
    uint32_t index;
    uint32_t count;
    size_t written;
    size_t required_bytes;
    GhosttyTerminalHistoryToken checkpoint;
} GhosttyTerminalSnapshotCaptureEvent;

typedef struct {
    size_t size;
    uint32_t version;
    size_t max_continuation_bytes;
    size_t max_record_bytes;
    size_t max_pages;
} GhosttyTerminalSnapshotDecoderOptions;

typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_NEED_INPUT = 0,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_PROGRESS = 1,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY = 2,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_HISTORY_BEGIN = 3,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_HISTORY_PAGE = 4,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH = 5,
    GHOSTTY_TERMINAL_SNAPSHOT_DECODE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalSnapshotDecodeEventKind;

/**
 * Decoder event for one bounded state transition.
 *
 * `consumed` never includes bytes after FINISH. The caller must submit the
 * unconsumed suffix to its live VT stream after taking and replaying READY.
 */
typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalSnapshotDecodeEventKind kind;
    uint16_t codec_version;
    uint16_t screen_key;
    uint32_t index;
    uint32_t count;
    bool retained;
    size_t consumed;
    size_t needed;
} GhosttyTerminalSnapshotDecodeEvent;

typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminal terminal;
    uint16_t codec_version;
} GhosttyTerminalSnapshotTakeTerminalResult;

/**
 * Shared strict budget for one history cursor/import operation.
 *
 * `max_units` is consumed only by importer construction; byte and row limits
 * are applied independently on every next/push.
 */
typedef struct {
    size_t size;
    uint32_t version;
    size_t max_unit_bytes;
    size_t max_rows;
    size_t max_units;
} GhosttyTerminalHistoryOptions;

typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalHistoryLease lease;
    GhosttyTerminalHistoryToken checkpoint;
} GhosttyTerminalHistoryLeaseResult;

typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalHistoryCursor cursor;
    GhosttyTerminalHistoryToken capability;
} GhosttyTerminalHistoryCursorResult;

typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_TERMINAL_HISTORY_UNIT = 0,
    GHOSTTY_TERMINAL_HISTORY_END = 1,
    GHOSTTY_TERMINAL_HISTORY_EVENT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalHistoryEventKind;

typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalHistoryEventKind kind;
    size_t written;
    size_t required_bytes;
    size_t rows;
    bool page_complete;
} GhosttyTerminalHistoryEvent;

typedef struct {
    size_t size;
    uint32_t version;
    GhosttyTerminalHistoryImporter importer;
    GhosttyTerminalHistoryToken capability;
} GhosttyTerminalHistoryImporterResult;

typedef struct {
    size_t size;
    uint32_t version;
    size_t consumed;
    size_t required_bytes;
    size_t required_rows;
    size_t rows;
    bool retained;
} GhosttyTerminalHistoryImportEvent;

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_incremental_capabilities(
    GhosttyTerminalSnapshotIncrementalCapabilities* out_capabilities);

/**
 * Begin record-compatible v2 capture. The source terminal and continuation
 * must remain serialized against mutation until READY; continuing through
 * snapshot HISTORY/FINISH requires serialization until capture is freed.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_capture_new(
    const GhosttyAllocator* allocator,
    GhosttyTerminal terminal,
    const GhosttyTerminalSnapshotCaptureOptions* options,
    GhosttyTerminalSnapshotCapture* out_capture);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_capture_next(
    GhosttyTerminalSnapshotCapture capture,
    uint8_t* buffer,
    size_t buffer_len,
    GhosttyTerminalSnapshotCaptureEvent* out_event);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_capture_abort(
    GhosttyTerminalSnapshotCapture capture);

GHOSTTY_API void ghostty_terminal_snapshot_capture_free(
    GhosttyTerminalSnapshotCapture capture);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_decoder_new(
    const GhosttyAllocator* allocator,
    const GhosttyTerminalSnapshotDecoderOptions* options,
    GhosttyTerminalSnapshotDecoder* out_decoder);

/** Push an arbitrary fragment and perform at most one bounded transition.
 * A zero-length push is an EOF marker and returns TRUNCATED unless FINISH was
 * already reported.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_decoder_push(
    GhosttyTerminalSnapshotDecoder decoder,
    const uint8_t* data,
    size_t len,
    GhosttyTerminalSnapshotDecodeEvent* out_event);

/** Transfer the authenticated READY terminal exactly once. */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_decoder_take_terminal(
    GhosttyTerminalSnapshotDecoder decoder,
    GhosttyTerminalSnapshotTakeTerminalResult* out_result);

/**
 * Replay the authenticated standard-stream continuation exactly once.
 * `terminal` must be the terminal returned by this decoder.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_decoder_replay_continuation(
    GhosttyTerminalSnapshotDecoder decoder,
    GhosttyTerminal terminal);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_snapshot_decoder_abort(
    GhosttyTerminalSnapshotDecoder decoder);

GHOSTTY_API void ghostty_terminal_snapshot_decoder_free(
    GhosttyTerminalSnapshotDecoder decoder);

/** Acquire one engine-owned, generation-bound history cut.
 * Returns UNSUPPORTED_FEATURE when authenticated history is not compiled for
 * the target, or ENTROPY_UNAVAILABLE when its secure entropy provider fails.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_lease_new(
    const GhosttyAllocator* allocator,
    GhosttyTerminal terminal,
    uint16_t screen_key,
    GhosttyTerminalHistoryLeaseResult* out_result);

/** Transfer the lease's newest-to-oldest cursor exactly once. */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_lease_cursor(
    GhosttyTerminalHistoryLease lease,
    GhosttyTerminal terminal,
    GhosttyTerminalHistoryCursorResult* out_result);

GHOSTTY_API void ghostty_terminal_history_lease_free(
    GhosttyTerminalHistoryLease lease);

/**
 * Emit one authenticated opaque history unit under strict byte/row bounds.
 * A short buffer returns OUT_OF_SPACE without advancing the cursor.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_cursor_next(
    GhosttyTerminalHistoryCursor cursor,
    GhosttyTerminal terminal,
    const GhosttyTerminalHistoryOptions* options,
    uint8_t* buffer,
    size_t buffer_len,
    GhosttyTerminalHistoryEvent* out_event);

GHOSTTY_API void ghostty_terminal_history_cursor_free(
    GhosttyTerminalHistoryCursor cursor);

/**
 * Create a transactional importer for units authenticated by `checkpoint`.
 * The source terminal and its lease must still be live; the destination owns
 * imported pages and may receive serialized live VT writes between pushes.
 * Returns UNSUPPORTED_FEATURE when authenticated history is not compiled for
 * the target, or ENTROPY_UNAVAILABLE when its secure entropy provider fails.
 */
GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_importer_new(
    const GhosttyAllocator* allocator,
    GhosttyTerminal terminal,
    uint16_t screen_key,
    GhosttyTerminal source_terminal,
    const GhosttyTerminalHistoryToken* checkpoint,
    const GhosttyTerminalHistoryOptions* options,
    GhosttyTerminalHistoryImporterResult* out_result);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_importer_push(
    GhosttyTerminalHistoryImporter importer,
    GhosttyTerminal terminal,
    const uint8_t* unit,
    size_t unit_len,
    const GhosttyTerminalHistoryOptions* options,
    GhosttyTerminalHistoryImportEvent* out_event);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_importer_commit(
    GhosttyTerminalHistoryImporter importer,
    GhosttyTerminal terminal);

GHOSTTY_API GhosttyTerminalSnapshotStatus
ghostty_terminal_history_importer_abort(
    GhosttyTerminalHistoryImporter importer,
    GhosttyTerminal terminal);

GHOSTTY_API void ghostty_terminal_history_importer_free(
    GhosttyTerminalHistoryImporter importer);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SNAPSHOT_H */
