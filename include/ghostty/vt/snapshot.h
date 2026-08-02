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

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SNAPSHOT_H */
