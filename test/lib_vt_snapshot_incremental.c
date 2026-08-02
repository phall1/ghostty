#include <ghostty/vt.h>

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
    size_t history_pages;
    size_t history_pages_declared;
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
        if (exact.kind == GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_HISTORY_PAGE)
            ++bytes.history_pages;
        if (exact.kind == GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_HISTORY_BEGIN &&
            exact.count > bytes.history_pages_declared)
            bytes.history_pages_declared = exact.count;
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
            GhosttyTerminalSnapshotDecodeEvent blocked = {
                .size = sizeof(blocked),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_decoder_push(
                decoder, data + offset, 1, &blocked) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
            assert(blocked.consumed == 0);
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
    FailAllocator cursor_alloc = { .fail_after = SIZE_MAX };
    GhosttyAllocator cursor_allocator = {
        .ctx = &cursor_alloc,
        .vtable = &fail_vtable,
    };
    GhosttyTerminalHistoryLeaseResult lease = {
        .size = sizeof(lease),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        &cursor_allocator, source, 0, &lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(cursor_alloc.active == 1);
    GhosttyTerminalHistoryLeaseResult unavailable = {
        .size = sizeof(unavailable),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, 1, &unavailable) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_GENERATION);

    GhosttyTerminalHistoryCursorResult cursor = {
        .size = sizeof(cursor),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    cursor_alloc.fail_after = cursor_alloc.calls;
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(cursor.cursor == NULL);
    assert(cursor_alloc.active == 1);
    cursor_alloc.fail_after = SIZE_MAX;
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(cursor_alloc.active == 2);
    GhosttyTerminalHistoryCursor cursor_handle = cursor.cursor;
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
    GhosttyTerminalHistoryImporterResult unavailable_importer = {
        .size = sizeof(unavailable_importer),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 1, source, &lease.checkpoint, &options,
        &unavailable_importer) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_GENERATION);
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
    GhosttyTerminalHistoryImporterResult abort_importer = {
        .size = sizeof(abort_importer),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &lease.checkpoint, &options,
        &abort_importer) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(ghostty_terminal_history_importer_abort(
        abort_importer.importer, source) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_TERMINAL);
    ghostty_terminal_history_importer_free(abort_importer.importer);

    abort_importer = (GhosttyTerminalHistoryImporterResult){
        .size = sizeof(abort_importer),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &lease.checkpoint, &options,
        &abort_importer) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(ghostty_terminal_history_importer_abort(
        abort_importer.importer, destination) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    ghostty_terminal_history_importer_free(abort_importer.importer);
    assert(cursor.cursor == cursor_handle);
    ghostty_terminal_history_cursor_free(cursor.cursor);
    assert(cursor_alloc.active == 1);
    ghostty_terminal_history_lease_free(lease.lease);
    assert(cursor_alloc.active == 0);
}

typedef struct {
    const char* name;
    const char* path;
    size_t length;
    uint64_t checksum;
} CorpusCase;

static const CorpusCase corpus_cases[] = {
    {
        .name = "shell-80x24",
        .path = "src/terminal/snapshot/testdata/corpus/shell-80x24-v2.hex",
        .length = 31920,
        .checksum = UINT64_C(0x794094e8f39f40d8),
    },
    {
        .name = "rich-200x60",
        .path = "src/terminal/snapshot/testdata/corpus/rich-200x60-v2.hex",
        .length = 385539,
        .checksum = UINT64_C(0x9b746bfb359a5eeb),
    },
    {
        .name = "history-multipage",
        .path =
            "src/terminal/snapshot/testdata/corpus/history-multipage-v2.hex",
        .length = 2469736,
        .checksum = UINT64_C(0x557529ed7661a40b),
    },
};

static uint64_t corpus_checksum(const uint8_t* data, size_t len) {
    uint64_t result = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < len; ++i) {
        result ^= data[i];
        result *= UINT64_C(1099511628211);
    }
    return result;
}

static void corpus_write(GhosttyTerminal terminal, const char* value) {
    ghostty_terminal_vt_write(
        terminal, (const uint8_t*)value, strlen(value));
}

static GhosttyTerminal corpus_terminal(size_t index) {
    GhosttyTerminal terminal = NULL;
    if (index == 0) {
        assert(ghostty_terminal_new(NULL, &terminal, 80, 24) == GHOSTTY_SUCCESS);
        corpus_write(terminal,
            "\x1b]7;file:///home/corpus\x1b\\"
            "\x1b]2;corpus-shell\x1b\\"
            "\x1b]133;A\x1b\\corpus@host$ "
            "\x1b]133;B\x1b\\printf checkpoint"
            "\x1b]133;C\x1b\\\r\ncheckpoint ready\r\n"
            "\x1b]133;D;0\x1b\\");
        return terminal;
    }

    if (index == 1) {
        assert(ghostty_terminal_new(NULL, &terminal, 200, 60) ==
            GHOSTTY_SUCCESS);
        corpus_write(terminal,
            "\x1b]7;file:///workspace/corpus\x1b\\"
            "\x1b]2;corpus-rich\x1b\\"
            "\x1b]133;A\x1b\\rich$ \x1b]133;B\x1b\\"
            "\x1b[1;4;38;2;12;34;56;48;2;78;90;123mstyled\x1b[0m "
            "\xe7\x95\x8c \xf0\x9f\x98\x80 e\xcc\x81\r\n"
            "\x1b]8;id=corpus;https://example.invalid/corpus\x1b\\link"
            "\x1b]8;;\x1b\\\r\n"
            "\x1b]133;C\x1b\\output\x1b]133;D;0\x1b\\"
            "\x1b[?1049h"
            "\x1b[3;38;5;201malt-screen\x1b[0m "
            "\xe7\x95\x8c e\xcc\x81\r\n"
            "\x1b]133;A\x1b\\alt$ \x1b]133;B\x1b\\");
        return terminal;
    }

    assert(index == 2);
    assert(ghostty_terminal_new(NULL, &terminal, 512, 4) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(
        terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, NULL) ==
        GHOSTTY_SUCCESS);
    assert(ghostty_terminal_set(
        terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, NULL) ==
        GHOSTTY_SUCCESS);
    corpus_write(terminal,
        "\x1b]7;file:///var/tmp/corpus-history\x1b\\"
        "\x1b]2;corpus-history\x1b\\");
    uint8_t grapheme_row[510 * 3];
    for (size_t column = 0; column < 510; ++column) {
        grapheme_row[column * 3] = 'x';
        grapheme_row[column * 3 + 1] = 0xcc;
        grapheme_row[column * 3 + 2] = 0x81;
    }
    for (unsigned row = 0; row < 240; ++row) {
        char style[64];
        int style_len = snprintf(style, sizeof(style),
            "\x1b[38;2;%u;%u;%um",
            row, (row * 17) % 256, (row * 29) % 256);
        assert(style_len > 0 && (size_t)style_len < sizeof(style));
        ghostty_terminal_vt_write(
            terminal, (const uint8_t*)style, (size_t)style_len);
        ghostty_terminal_vt_write(
            terminal, grapheme_row, sizeof(grapheme_row));
        corpus_write(terminal, "\x1b[0m\r\n");
    }
    return terminal;
}

static Bytes corpus_load(const char* path) {
    FILE* file = fopen(path, "rb");
    assert(file != NULL);
    Bytes result = {0};
    int high = -1;
    bool comment = false;
    for (;;) {
        int c = fgetc(file);
        if (c == EOF) break;
        if (comment) {
            if (c == '\n') comment = false;
            continue;
        }
        if (c == '#') {
            assert(high == -1);
            comment = true;
            continue;
        }
        int nibble = -1;
        if (c >= '0' && c <= '9') nibble = c - '0';
        else if (c >= 'a' && c <= 'f') nibble = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') nibble = c - 'A' + 10;
        else {
            assert(high == -1);
            continue;
        }
        if (high == -1) {
            high = nibble;
        } else {
            uint8_t byte = (uint8_t)((high << 4) | nibble);
            append(&result, &byte, 1);
            high = -1;
        }
    }
    assert(high == -1);
    assert(fclose(file) == 0);
    return result;
}

static void corpus_store(const CorpusCase* corpus, const Bytes* bytes) {
    FILE* file = fopen(corpus->path, "wb");
    assert(file != NULL);
    assert(fprintf(file,
        "# Ghostty snapshot fixture\n"
        "# Kaitai type: ghostty_snapshot\n"
        "# Kaitai params:\n"
        "# Kaitai offset: 0\n"
        "# Wire version: 2\n"
        "# Corpus case: %s\n"
        "# FNV-1a-64: %016" PRIx64 "\n\n",
        corpus->name, corpus_checksum(bytes->data, bytes->len)) > 0);
    for (size_t offset = 0; offset < bytes->len; offset += 16) {
        size_t count = bytes->len - offset;
        if (count > 16) count = 16;
        for (size_t i = 0; i < count; ++i) {
            assert(fprintf(file, "%02x%s", bytes->data[offset + i],
                i + 1 == count ? "" : " ") > 0);
        }
        assert(fprintf(file, " # 0x%08zx\n", offset) > 0);
    }
    assert(fclose(file) == 0);
}

static void exercise_snapshot_corpus(bool update) {
    for (size_t index = 0;
        index < sizeof(corpus_cases) / sizeof(corpus_cases[0]);
        ++index) {
        const CorpusCase* corpus = &corpus_cases[index];
        GhosttyTerminal terminal = corpus_terminal(index);
        Bytes captured = capture_all(terminal);
        assert(captured.len > captured.finish_offset);
        if (index == 2) {
            assert(captured.history_pages_declared > 1);
            assert(captured.history_pages ==
                captured.history_pages_declared);
        }

        if (update) {
            corpus_store(corpus, &captured);
        } else {
            Bytes fixture = corpus_load(corpus->path);
            assert(fixture.len == corpus->length);
            assert(corpus_checksum(fixture.data, fixture.len) ==
                corpus->checksum);
            assert(fixture.len == captured.len);
            assert(memcmp(fixture.data, captured.data, fixture.len) == 0);

            Decoded decoded = decode_fragmented(fixture.data, fixture.len);
            assert(decoded.saw_ready);
            assert(decoded.consumed == fixture.len);
            ghostty_terminal_free(decoded.terminal);

            uint8_t* future = (uint8_t*)malloc(fixture.len);
            assert(future != NULL);
            memcpy(future, fixture.data, fixture.len);
            future[8] = 3;
            future[9] = 0;
            expect_decode_error(future, fixture.len, decoder_options(),
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNKNOWN_VERSION);

            memcpy(future, fixture.data, fixture.len);
            future[fixture.len - 1] ^= 0x80;
            expect_decode_error(future, fixture.len, decoder_options(),
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
            expect_decode_error(fixture.data, fixture.len - 1,
                decoder_options(), GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED);
            free(future);
            free(fixture.data);
        }

        free(captured.data);
        ghostty_terminal_free(terminal);
    }

    if (!update) {
        Bytes v1 = corpus_load(
            "src/terminal/snapshot/testdata/complete-v1.hex");
        Decoded decoded = decode_fragmented(v1.data, v1.len);
        assert(decoded.saw_ready);
        assert(decoded.consumed == v1.len);
        ghostty_terminal_free(decoded.terminal);
        free(v1.data);
    }
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

    const bool update_corpus =
        getenv("GHOSTTY_UPDATE_SNAPSHOT_CORPUS") != NULL;
    exercise_snapshot_corpus(update_corpus);
    if (update_corpus) return 0;

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
    FailAllocator fail_state = { .fail_after = 1 };
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
    assert(ghostty_terminal_snapshot_capture_abort(allocation_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    GhosttyTerminalSnapshotCaptureEvent aborted_event = {
        .size = sizeof(aborted_event),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_snapshot_capture_next(
        allocation_capture, NULL, 0, &aborted_event) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
    ghostty_terminal_snapshot_capture_free(allocation_capture);
    assert(fail_state.active == 0);
    fail_state.calls = 0;
    fail_state.fail_after = 1;
    GhosttyTerminalSnapshotDecoder allocation_decoder = NULL;
    GhosttyTerminalSnapshotDecoderOptions allocation_decoder_options =
        decoder_options();
    assert(ghostty_terminal_snapshot_decoder_new(
        &fail_allocator, &allocation_decoder_options, &allocation_decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(allocation_decoder == NULL);
    assert(fail_state.active == 0);
    GhosttyTerminalSnapshotCaptureOptions bounded_options =
        capture_options();
    bounded_options.max_record_bytes = 10;
    GhosttyTerminalSnapshotCapture bounded_capture = NULL;
    assert(ghostty_terminal_snapshot_capture_new(
        NULL, allocation_terminal, &bounded_options, &bounded_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    uint8_t bounded_record[10];
    GhosttyTerminalSnapshotCaptureEvent bounded_event = {
        .size = sizeof(bounded_event),
        .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
    };
    assert(ghostty_terminal_snapshot_capture_next(
        bounded_capture, bounded_record, sizeof(bounded_record),
        &bounded_event) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    assert(bounded_event.written == sizeof(bounded_record));
    assert(ghostty_terminal_snapshot_capture_next(
        bounded_capture, bounded_record, sizeof(bounded_record),
        &bounded_event) == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_LIMIT_EXCEEDED);
    ghostty_terminal_snapshot_capture_free(bounded_capture);
    static const uint8_t bounded_continuation[] = "\x1b[31";
    ghostty_terminal_vt_write(
        allocation_terminal,
        bounded_continuation,
        sizeof(bounded_continuation) - 1);
    bounded_options.max_record_bytes = 12;
    bounded_capture = NULL;
    assert(ghostty_terminal_snapshot_capture_new(
        NULL, allocation_terminal, &bounded_options, &bounded_capture) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_LIMIT_EXCEEDED);
    assert(bounded_capture == NULL);
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
    size_t finish_consumed = 0;
    do {
        assert(ghostty_terminal_snapshot_decoder_push(
            decoder, finish_tail.data + finish_consumed,
            finish_tail.len - finish_consumed, &finish) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        assert(finish.consumed > 0);
        finish_consumed += finish.consumed;
    } while (finish.kind != GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH);
    assert(finish_consumed == bytes.len - bytes.finish_offset);
    ghostty_terminal_vt_write(live_terminal,
        finish_tail.data + finish_consumed,
        finish_tail.len - finish_consumed);
    ghostty_terminal_snapshot_decoder_free(decoder);
    free(finish_tail.data);

    GhosttyTerminalSnapshotDecoder corrupt_decoder = NULL;
    assert(ghostty_terminal_snapshot_decoder_new(
        NULL, &decode_options, &corrupt_decoder) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
    size_t corrupt_offset = 0;
    GhosttyTerminal corrupt_terminal = NULL;
    while (corrupt_offset < bytes.finish_offset) {
        GhosttyTerminalSnapshotDecodeEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        assert(ghostty_terminal_snapshot_decoder_push(
            corrupt_decoder, bytes.data + corrupt_offset,
            bytes.finish_offset - corrupt_offset, &event) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        corrupt_offset += event.consumed;
        if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
            GhosttyTerminalSnapshotTakeTerminalResult take = {
                .size = sizeof(take),
                .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
            };
            assert(ghostty_terminal_snapshot_decoder_take_terminal(
                corrupt_decoder, &take) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
            corrupt_terminal = take.terminal;
            assert(ghostty_terminal_snapshot_decoder_replay_continuation(
                corrupt_decoder, corrupt_terminal) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS);
        }
    }
    Bytes corrupt_finish_tail = {0};
    append(&corrupt_finish_tail, bytes.data + bytes.finish_offset,
        bytes.len - bytes.finish_offset);
    corrupt_finish_tail.data[10] ^= 0x80;
    append(&corrupt_finish_tail, tail, sizeof(tail) - 1);
    size_t corrupt_consumed = 0;
    GhosttyTerminalSnapshotStatus corrupt_status =
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS;
    while (corrupt_status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS) {
        GhosttyTerminalSnapshotDecodeEvent event = {
            .size = sizeof(event),
            .version = GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION,
        };
        corrupt_status = ghostty_terminal_snapshot_decoder_push(
            corrupt_decoder,
            corrupt_finish_tail.data + corrupt_consumed,
            corrupt_finish_tail.len - corrupt_consumed,
            &event);
        corrupt_consumed += event.consumed;
    }
    assert(corrupt_status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
    assert(corrupt_consumed == bytes.len - bytes.finish_offset);
    ghostty_terminal_vt_write(
        corrupt_terminal,
        corrupt_finish_tail.data + corrupt_consumed,
        corrupt_finish_tail.len - corrupt_consumed);
    ghostty_terminal_snapshot_decoder_free(corrupt_decoder);
    ghostty_terminal_free(corrupt_terminal);
    free(corrupt_finish_tail.data);

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
