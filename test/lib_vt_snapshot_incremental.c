#include <ghostty/vt.h>

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
    size_t finish_offset;
} Bytes;

typedef struct {
    size_t calls;
    size_t fail_after;
    size_t active;
} FailAllocator;

static void* fail_alloc(
    void* raw, size_t len, uint8_t alignment, uintptr_t ret_addr)
{
    (void)alignment;
    (void)ret_addr;
    FailAllocator* state = (FailAllocator*)raw;
    if (state->calls++ >= state->fail_after) return NULL;
    void* memory = malloc(len);
    if (memory != NULL) ++state->active;
    return memory;
}

static bool fail_resize(
    void* raw, void* memory, size_t memory_len, uint8_t alignment,
    size_t new_len, uintptr_t ret_addr)
{
    (void)raw; (void)memory; (void)memory_len; (void)alignment;
    (void)new_len; (void)ret_addr;
    return false;
}

static void* fail_remap(
    void* raw, void* memory, size_t memory_len, uint8_t alignment,
    size_t new_len, uintptr_t ret_addr)
{
    (void)raw; (void)memory; (void)memory_len; (void)alignment;
    (void)new_len; (void)ret_addr;
    return NULL;
}

static void fail_free(
    void* raw, void* memory, size_t memory_len, uint8_t alignment,
    uintptr_t ret_addr)
{
    (void)memory_len; (void)alignment; (void)ret_addr;
    FailAllocator* state = (FailAllocator*)raw;
    assert(state->active > 0);
    --state->active;
    free(memory);
}

static const GhosttyAllocatorVtable fail_vtable = {
    .alloc = fail_alloc,
    .resize = fail_resize,
    .remap = fail_remap,
    .free = fail_free,
};

static void append(Bytes* b, const uint8_t* data, size_t len) {
    if (b->len + len > b->cap) {
        size_t cap = b->cap == 0 ? 4096 : b->cap;
        while (cap < b->len + len) cap *= 2;
        uint8_t* next = (uint8_t*)realloc(b->data, cap);
        assert(next != NULL);
        b->data = next;
        b->cap = cap;
    }
    memcpy(b->data + b->len, data, len);
    b->len += len;
}

static GhosttyTerminalSnapshotCaptureOptions capture_options(void) {
    GhosttyTerminalSnapshotCaptureOptions result = {
        .size = sizeof(result),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        .max_record_bytes = 4 * 1024 * 1024,
        .max_pages = 4096,
    };
    return result;
}

static GhosttyTerminalSnapshotDecoderOptions decoder_options(void) {
    GhosttyTerminalSnapshotDecoderOptions result = {
        .size = sizeof(result),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        .max_continuation_bytes = 1024 * 1024,
        .max_record_bytes = 4 * 1024 * 1024,
        .max_pages = 4096,
    };
    return result;
}

static GhosttyTerminalHistoryOptions history_options(void) {
    GhosttyTerminalHistoryOptions result = {
        .size = sizeof(result),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        .max_unit_bytes = 256 * 1024,
        .max_rows = 32,
        .max_units = 4096,
    };
    return result;
}

static Bytes capture_all(GhosttyTerminal terminal) {
    GhosttyTerminalSnapshotCapture capture = NULL;
    GhosttyTerminalSnapshotCaptureOptions options = capture_options();
    assert(ghostty_terminal_snapshot_capture_new(
        NULL, terminal, &options, &capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(capture != NULL);

    Bytes bytes = {0};
    for (;;) {
        GhosttyTerminalSnapshotCaptureEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        assert(ghostty_terminal_snapshot_capture_next(
            capture, NULL, 0, &event) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
        assert(event.written == 0);
        assert(event.required_bytes > 0);

        uint8_t* record = (uint8_t*)malloc(event.required_bytes);
        assert(record != NULL);
        if (event.required_bytes > 1) {
            GhosttyTerminalSnapshotCaptureEvent short_event = {
                .size = sizeof(short_event),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_capture_next(
                capture, record, event.required_bytes - 1, &short_event) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
            assert(short_event.written == 0);
            assert(short_event.required_bytes == event.required_bytes);
            assert(short_event.kind == event.kind);
        }

        GhosttyTerminalSnapshotCaptureEvent exact = {
            .size = sizeof(exact),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        assert(ghostty_terminal_snapshot_capture_next(
            capture, record, event.required_bytes, &exact) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        assert(exact.written == event.required_bytes);
        assert(exact.kind == event.kind);
        if (exact.kind == GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_FINISH)
            bytes.finish_offset = bytes.len;
        append(&bytes, record, exact.written);
        free(record);
        if (exact.kind == GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_FINISH) break;
    }

    assert(ghostty_terminal_snapshot_capture_abort(capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_snapshot_capture_free(capture);
    return bytes;
}

typedef struct {
    GhosttyTerminal terminal;
    size_t consumed;
    bool saw_ready;
    bool saw_history;
} Decoded;

static Decoded decode_fragmented(const uint8_t* data, size_t len) {
    GhosttyTerminalSnapshotDecoder decoder = NULL;
    GhosttyTerminalSnapshotDecoderOptions options = decoder_options();
    assert(ghostty_terminal_snapshot_decoder_new(NULL, &options, &decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);

    Decoded decoded = {0};
    size_t offset = 0;
    while (offset < len) {
        GhosttyTerminalSnapshotDecodeEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        GhosttyTerminalSnapshotStatus status =
            ghostty_terminal_snapshot_decoder_push(
                decoder, data + offset, 1, &event);
        assert(status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        assert(event.consumed <= 1);
        assert(event.consumed != 0 ||
            event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH);
        offset += event.consumed;

        if (!decoded.saw_ready) {
            GhosttyTerminalSnapshotTakeTerminalResult unavailable = {
                .size = sizeof(unavailable),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            if (event.kind != GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
                assert(ghostty_terminal_snapshot_decoder_take_terminal(
                    decoder, &unavailable) ==
                    GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
                assert(unavailable.terminal == NULL);
            }
        }

        if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
            GhosttyTerminalSnapshotTakeTerminalResult ready = {
                .size = sizeof(ready),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_decoder_take_terminal(
                decoder, &ready) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
            assert(ready.terminal != NULL);
            decoded.terminal = ready.terminal;
            decoded.saw_ready = true;

            GhosttyTerminal wrong = NULL;
            assert(ghostty_terminal_new(NULL, &wrong, 80, 24) == GHOSTTY_SUCCESS);
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                decoder, wrong) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_TERMINAL);
            ghostty_terminal_free(wrong);
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                decoder, decoded.terminal) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                decoder, decoded.terminal) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
        } else if (event.kind ==
            GHOSTTY_TERMINAL_SNAPSHOT_DECODE_HISTORY_PAGE) {
            decoded.saw_history = true;
            static const uint8_t live[] = "live-between-history-units";
            ghostty_terminal_vt_write(decoded.terminal, live, sizeof(live) - 1);
        } else if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH) {
            break;
        }
    }
    decoded.consumed = offset;
    ghostty_terminal_snapshot_decoder_free(decoder);
    return decoded;
}

static void expect_decode_error(
    const uint8_t* data,
    size_t len,
    GhosttyTerminalSnapshotDecoderOptions options,
    GhosttyTerminalSnapshotStatus expected)
{
    GhosttyTerminalSnapshotDecoder decoder = NULL;
    assert(ghostty_terminal_snapshot_decoder_new(NULL, &options, &decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    size_t offset = 0;
    GhosttyTerminalSnapshotStatus status =
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS;
    GhosttyTerminal transferred = NULL;
    while (offset < len && status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS) {
        GhosttyTerminalSnapshotDecodeEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        status = ghostty_terminal_snapshot_decoder_push(
            decoder, data + offset, len - offset, &event);
        offset += event.consumed;
        if (status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS &&
            event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
            GhosttyTerminalSnapshotTakeTerminalResult take = {
                .size = sizeof(take),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_decoder_take_terminal(
                decoder, &take) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
            transferred = take.terminal;
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                decoder, transferred) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        }
    }
    if (status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS &&
        expected == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED) {
        GhosttyTerminalSnapshotDecodeEvent eof = {
            .size = sizeof(eof),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        status = ghostty_terminal_snapshot_decoder_push(
            decoder, NULL, 0, &eof);
    }
    assert(status == expected);
    assert(ghostty_terminal_snapshot_decoder_abort(decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_snapshot_decoder_free(decoder);
    if (transferred != NULL) ghostty_terminal_free(transferred);
}

static void exercise_history_units(
    GhosttyTerminal source,
    GhosttyTerminal destination)
{
    GhosttyTerminalHistoryLeaseResult lease = {
        .size = sizeof(lease),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(NULL, source, 0, &lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);

    GhosttyTerminalHistoryCursorResult cursor = {
        .size = sizeof(cursor),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalHistoryCursorResult second = {
        .size = sizeof(second),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &second) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);

    GhosttyTerminalHistoryOptions options = history_options();
    GhosttyTerminalHistoryImporterResult importer = {
        .size = sizeof(importer),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    GhosttyTerminalHistoryToken forged = lease.checkpoint;
    forged.bytes[31] ^= 0x80;
    GhosttyTerminalHistoryImporterResult rejected = {
        .size = sizeof(rejected),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &forged, &options, &rejected) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_HANDLE);
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &lease.checkpoint, &options, &importer) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalHistoryImporterResult busy = {
        .size = sizeof(busy),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &lease.checkpoint, &options, &busy) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_IMPORT_BUSY);

    bool wrote_live = false;
    bool corrupted_once = false;
    for (;;) {
        GhosttyTerminalHistoryEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        GhosttyTerminalSnapshotStatus probe =
            ghostty_terminal_history_cursor_next(
                cursor.cursor, source, &options, NULL, 0, &event);
        if (probe == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS) {
            assert(event.kind == GHOSTTY_TERMINAL_HISTORY_END);
            break;
        }
        assert(probe == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
        assert(event.required_bytes > 0);
        uint8_t* unit = (uint8_t*)malloc(event.required_bytes);
        assert(unit != NULL);
        options.max_unit_bytes = event.required_bytes;
        if (event.required_bytes > 1) {
            GhosttyTerminalHistoryEvent short_event = {
                .size = sizeof(short_event),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_history_cursor_next(
                cursor.cursor, source, &options, unit,
                event.required_bytes - 1, &short_event) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
            assert(short_event.written == 0);
            assert(short_event.required_bytes == event.required_bytes);
        }
        assert(ghostty_terminal_history_cursor_next(
            cursor.cursor, source, &options, unit,
            event.required_bytes, &event) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        assert(event.kind == GHOSTTY_TERMINAL_HISTORY_UNIT);

        GhosttyTerminalHistoryImportEvent imported = {
            .size = sizeof(imported),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        if (!corrupted_once) {
            unit[event.written - 1] ^= 0x40;
            assert(ghostty_terminal_history_importer_push(
                importer.importer, destination, unit, event.written,
                &options, &imported) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
            unit[event.written - 1] ^= 0x40;
            corrupted_once = true;
        }
        assert(ghostty_terminal_history_importer_push(
            importer.importer, source, unit, event.written,
            &options, &imported) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_TERMINAL);
        assert(ghostty_terminal_history_importer_push(
            importer.importer, destination, unit, event.written,
            &options, &imported) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        assert(imported.consumed == event.written);
        free(unit);

        if (!wrote_live) {
            static const uint8_t live[] = "live while old history imports\r\n";
            ghostty_terminal_vt_write(destination, live, sizeof(live) - 1);
            wrote_live = true;
        }
        options = history_options();
    }

    assert(ghostty_terminal_history_importer_commit(
        importer.importer, destination) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_history_importer_free(importer.importer);
    ghostty_terminal_history_cursor_free(cursor.cursor);
    ghostty_terminal_history_lease_free(lease.lease);
}

int main(void) {
    GhosttyTerminalSnapshotIncrementalCapabilities capabilities = {
        .size = sizeof(capabilities),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_snapshot_incremental_capabilities(&capabilities) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(capabilities.incremental && capabilities.ready &&
        capabilities.history && capabilities.authenticated_tokens &&
        capabilities.bounded_records && capabilities.bounded_pages &&
        capabilities.bounded_units);
    assert(capabilities.default_encode_version == 2);

    GhosttyTerminal unsupported = NULL;
    assert(ghostty_terminal_new(NULL, &unsupported, 20, 4) == GHOSTTY_SUCCESS);
    static const uint8_t glyph_register[] =
        "\x1b_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1b\\";
    ghostty_terminal_vt_write(
        unsupported, glyph_register, sizeof(glyph_register) - 1);
    GhosttyTerminalSnapshotCaptureOptions unsupported_options =
        capture_options();
    GhosttyTerminalSnapshotCapture unsupported_capture = NULL;
    assert(ghostty_terminal_snapshot_capture_new(
        NULL, unsupported, &unsupported_options, &unsupported_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNSUPPORTED_FEATURE);
    assert(unsupported_capture == NULL);
    ghostty_terminal_free(unsupported);

    GhosttyTerminal allocation_terminal = NULL;
    assert(ghostty_terminal_new(
        NULL, &allocation_terminal, 20, 4) == GHOSTTY_SUCCESS);
    FailAllocator fail_state = { .fail_after = 0 };
    GhosttyAllocator fail_allocator = {
        .ctx = &fail_state,
        .vtable = &fail_vtable,
    };
    GhosttyTerminalSnapshotCapture allocation_capture = NULL;
    GhosttyTerminalSnapshotCaptureOptions allocation_options =
        capture_options();
    assert(ghostty_terminal_snapshot_capture_new(
        &fail_allocator, allocation_terminal, &allocation_options,
        &allocation_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(allocation_capture == NULL);
    assert(fail_state.active == 0);
    fail_state.calls = 0;
    fail_state.fail_after = SIZE_MAX;
    assert(ghostty_terminal_snapshot_capture_new(
        &fail_allocator, allocation_terminal, &allocation_options,
        &allocation_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_snapshot_capture_free(allocation_capture);
    assert(fail_state.active == 0);
    ghostty_terminal_free(allocation_terminal);

    GhosttyTerminal source = NULL;
    assert(ghostty_terminal_new(NULL, &source, 20, 4) == GHOSTTY_SUCCESS);
    for (unsigned i = 0; i < 200; ++i) {
        char line[32];
        int len = snprintf(line, sizeof(line), "row-%03u\r\n", i);
        assert(len > 0);
        ghostty_terminal_vt_write(source, (const uint8_t*)line, (size_t)len);
    }
    static const uint8_t split_csi[] = "\x1b[31";
    ghostty_terminal_vt_write(source, split_csi, sizeof(split_csi) - 1);

    Bytes bytes = capture_all(source);
    assert(bytes.len > bytes.finish_offset);
    Decoded decoded = decode_fragmented(bytes.data, bytes.len);
    assert(decoded.saw_ready);
    assert(decoded.consumed == bytes.len);

    /* FINISH consumes exactly its record and leaves live transport bytes. */
    GhosttyTerminalSnapshotDecoder decoder = NULL;
    GhosttyTerminalSnapshotDecoderOptions decode_options = decoder_options();
    assert(ghostty_terminal_snapshot_decoder_new(
        NULL, &decode_options, &decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    size_t offset = 0;
    GhosttyTerminal live_terminal = NULL;
    while (offset < bytes.finish_offset) {
        GhosttyTerminalSnapshotDecodeEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        assert(ghostty_terminal_snapshot_decoder_push(
            decoder, bytes.data + offset, bytes.finish_offset - offset,
            &event) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        offset += event.consumed;
        if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
            GhosttyTerminalSnapshotTakeTerminalResult take = {
                .size = sizeof(take),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_decoder_take_terminal(
                decoder, &take) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
            live_terminal = take.terminal;
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                decoder, live_terminal) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        }
    }
    static const uint8_t tail[] = "PTY-after-cut";
    Bytes finish_tail = {0};
    append(&finish_tail, bytes.data + bytes.finish_offset,
        bytes.len - bytes.finish_offset);
    append(&finish_tail, tail, sizeof(tail) - 1);
    GhosttyTerminalSnapshotDecodeEvent finish = {
        .size = sizeof(finish),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_snapshot_decoder_push(
        decoder, finish_tail.data, finish_tail.len, &finish) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(finish.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH);
    assert(finish.consumed == bytes.len - bytes.finish_offset);
    ghostty_terminal_vt_write(live_terminal,
        finish_tail.data + finish.consumed, finish_tail.len - finish.consumed);
    ghostty_terminal_snapshot_decoder_free(decoder);
    free(finish_tail.data);

    exercise_history_units(source, live_terminal);

    uint8_t* damaged = (uint8_t*)malloc(bytes.len);
    assert(damaged != NULL);
    memcpy(damaged, bytes.data, bytes.len);
    damaged[8] = 0xff;
    damaged[9] = 0x7f;
    expect_decode_error(damaged, bytes.len, decoder_options(),
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNKNOWN_VERSION);
    memcpy(damaged, bytes.data, bytes.len);
    damaged[bytes.finish_offset + 10] ^= 0x80;
    expect_decode_error(damaged, bytes.len, decoder_options(),
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
    GhosttyTerminalSnapshotDecoderOptions limited = decoder_options();
    limited.max_record_bytes = 1;
    expect_decode_error(bytes.data, bytes.len, limited,
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_LIMIT_EXCEEDED);
    expect_decode_error(bytes.data, bytes.len - 1, decoder_options(),
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED);
    free(damaged);

    GhosttyTerminalHistoryLeaseResult wrong_generation = {
        .size = sizeof(wrong_generation),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, UINT16_MAX, &wrong_generation) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_GENERATION);

    /* Generation invalidation is explicit and never aliases another terminal. */
    GhosttyTerminalHistoryLeaseResult reset_lease = {
        .size = sizeof(reset_lease),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, 0, &reset_lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalHistoryCursorResult reset_cursor = {
        .size = sizeof(reset_cursor),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_cursor(
        reset_lease.lease, source, &reset_cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_reset(source);
    GhosttyTerminalHistoryOptions hopt = history_options();
    uint8_t unit[4096];
    GhosttyTerminalHistoryEvent hevent = {
        .size = sizeof(hevent),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_cursor_next(
        reset_cursor.cursor, source, &hopt, unit, sizeof(unit), &hevent) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_RESET);
    ghostty_terminal_history_cursor_free(reset_cursor.cursor);
    ghostty_terminal_history_lease_free(reset_lease.lease);

    GhosttyTerminalHistoryLeaseResult resize_lease = {
        .size = sizeof(resize_lease),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, 0, &resize_lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalHistoryCursorResult resize_cursor = {
        .size = sizeof(resize_cursor),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_cursor(
        resize_lease.lease, source, &resize_cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(ghostty_terminal_resize(source, 21, 5, 0, 0) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_history_cursor_next(
        resize_cursor.cursor, source, &hopt, unit, sizeof(unit), &hevent) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_RESIZE);
    ghostty_terminal_history_cursor_free(resize_cursor.cursor);
    ghostty_terminal_history_lease_free(resize_lease.lease);

    GhosttyTerminalHistoryLeaseResult stale_lease = {
        .size = sizeof(stale_lease),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, 0, &stale_lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalHistoryCursorResult stale_cursor = {
        .size = sizeof(stale_cursor),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_cursor(
        stale_lease.lease, source, &stale_cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_history_lease_free(stale_lease.lease);
    assert(ghostty_terminal_history_cursor_next(
        stale_cursor.cursor, source, &hopt, unit, sizeof(unit), &hevent) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_STALE);
    ghostty_terminal_history_cursor_free(stale_cursor.cursor);

    ghostty_terminal_free(decoded.terminal);
    ghostty_terminal_free(live_terminal);
    ghostty_terminal_free(source);
    free(bytes.data);
    return 0;
}
