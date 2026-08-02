#include <ghostty/vt.h>

#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ABI GHOSTTY_TERMINAL_SNAPSHOT_ABI_VERSION
#define SUCCESS GHOSTTY_TERMINAL_SNAPSHOT_STATUS_SUCCESS

typedef struct { uint8_t* data; size_t len; size_t cap; } Bytes;
typedef struct { size_t calls; size_t fail_after; size_t active; } FailAlloc;

static void* tracked_alloc(void* raw, size_t len, uint8_t alignment, uintptr_t ra) {
    (void)alignment; (void)ra;
    FailAlloc* state = (FailAlloc*)raw;
    if (state->calls++ >= state->fail_after) return NULL;
    void* result = malloc(len);
    if (result != NULL) ++state->active;
    return result;
}
static bool tracked_resize(void* raw, void* ptr, size_t old_len,
    uint8_t alignment, size_t new_len, uintptr_t ra) {
    (void)raw; (void)ptr; (void)old_len; (void)alignment; (void)new_len; (void)ra;
    return false;
}
static void* tracked_remap(void* raw, void* ptr, size_t old_len,
    uint8_t alignment, size_t new_len, uintptr_t ra) {
    (void)raw; (void)ptr; (void)old_len; (void)alignment; (void)new_len; (void)ra;
    return NULL;
}
static void tracked_free(void* raw, void* ptr, size_t len,
    uint8_t alignment, uintptr_t ra) {
    (void)len; (void)alignment; (void)ra;
    FailAlloc* state = (FailAlloc*)raw;
    assert(state->active > 0);
    --state->active;
    free(ptr);
}
static const GhosttyAllocatorVtable tracked_vtable = {
    .alloc = tracked_alloc,
    .resize = tracked_resize,
    .remap = tracked_remap,
    .free = tracked_free,
};

static uint64_t rng = UINT64_C(0x534E41504350524F);
static uint32_t random_u32(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)rng;
}
static void append(Bytes* bytes, const uint8_t* data, size_t len) {
    if (bytes->len + len > bytes->cap) {
        size_t cap = bytes->cap == 0 ? 4096 : bytes->cap;
        while (cap < bytes->len + len) cap *= 2;
        uint8_t* next = (uint8_t*)realloc(bytes->data, cap);
        assert(next != NULL);
        bytes->data = next;
        bytes->cap = cap;
    }
    memcpy(bytes->data + bytes->len, data, len);
    bytes->len += len;
}

static GhosttyTerminalSnapshotCaptureOptions capture_options(void) {
    return (GhosttyTerminalSnapshotCaptureOptions){
        .size = sizeof(GhosttyTerminalSnapshotCaptureOptions), .version = ABI,
        .max_record_bytes = 1024 * 1024, .max_pages = 4096,
    };
}
static GhosttyTerminalSnapshotDecoderOptions decoder_options(void) {
    return (GhosttyTerminalSnapshotDecoderOptions){
        .size = sizeof(GhosttyTerminalSnapshotDecoderOptions), .version = ABI,
        .max_continuation_bytes = 4096, .max_record_bytes = 1024 * 1024,
        .max_pages = 4096,
    };
}
static GhosttyTerminalHistoryOptions history_options(void) {
    return (GhosttyTerminalHistoryOptions){
        .size = sizeof(GhosttyTerminalHistoryOptions), .version = ABI,
        .max_unit_bytes = 1024 * 1024, .max_rows = 64, .max_units = 4096,
    };
}

static Bytes capture_fixture(GhosttyTerminal terminal) {
    GhosttyTerminalSnapshotCapture capture = NULL;
    GhosttyTerminalSnapshotCaptureOptions options = capture_options();
    assert(ghostty_terminal_snapshot_capture_new(NULL, terminal, &options, &capture) == SUCCESS);
    Bytes result = {0};
    for (;;) {
        GhosttyTerminalSnapshotCaptureEvent probe = { .size = sizeof(probe), .version = ABI };
        assert(ghostty_terminal_snapshot_capture_next(capture, NULL, 0, &probe) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
        assert(probe.required_bytes > 0 && probe.written == 0);
        uint8_t* record = (uint8_t*)malloc(probe.required_bytes);
        assert(record != NULL);
        GhosttyTerminalSnapshotCaptureEvent event = { .size = sizeof(event), .version = ABI };
        assert(ghostty_terminal_snapshot_capture_next(capture, record,
            probe.required_bytes, &event) == SUCCESS);
        assert(event.written == probe.required_bytes);
        append(&result, record, event.written);
        free(record);
        if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_CAPTURE_FINISH) break;
    }
    ghostty_terminal_snapshot_capture_free(capture);
    return result;
}

static GhosttyTerminalSnapshotStatus decode_split(const uint8_t* data,
    size_t len, size_t split, const GhosttyAllocator* allocator) {
    GhosttyTerminalSnapshotDecoder decoder = NULL;
    GhosttyTerminalSnapshotDecoderOptions options = decoder_options();
    GhosttyTerminalSnapshotStatus status = ghostty_terminal_snapshot_decoder_new(
        allocator, &options, &decoder);
    if (status != SUCCESS) return status;
    GhosttyTerminal terminal = NULL;
    size_t offset = 0;
    bool finish = false;
    while (!finish) {
        size_t boundary = offset < split ? split : len;
        GhosttyTerminalSnapshotDecodeEvent event = { .size = sizeof(event), .version = ABI };
        status = ghostty_terminal_snapshot_decoder_push(decoder,
            data + offset, boundary - offset, &event);
        offset += event.consumed;
        if (status != SUCCESS) break;
        assert(event.consumed > 0 || event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH);
        if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
            GhosttyTerminalSnapshotDecodeEvent blocked = { .size = sizeof(blocked), .version = ABI };
            assert(ghostty_terminal_snapshot_decoder_push(decoder,
                data + offset, offset < len ? 1 : 0, &blocked) ==
                GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
            assert(blocked.consumed == 0);
            GhosttyTerminalSnapshotTakeTerminalResult take = { .size = sizeof(take), .version = ABI };
            status = ghostty_terminal_snapshot_decoder_take_terminal(decoder, &take);
            if (status != SUCCESS) break;
            terminal = take.terminal;
            status = ghostty_terminal_snapshot_decoder_replay_continuation(decoder, terminal);
            if (status != SUCCESS) break;
        } else if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_HISTORY_PAGE && terminal != NULL) {
            static const uint8_t live[] = "live-during-property-history";
            ghostty_terminal_vt_write(terminal, live, sizeof(live) - 1);
        } else if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_FINISH) {
            finish = true;
        }
    }
    if (status == SUCCESS) {
        assert(finish && offset == len && terminal != NULL);
        static const uint8_t usable[] = "terminal-remains-usable";
        ghostty_terminal_vt_write(terminal, usable, sizeof(usable) - 1);
    }
    ghostty_terminal_snapshot_decoder_free(decoder);
    if (terminal != NULL) ghostty_terminal_free(terminal);
    return status;
}

static void property_splits_and_truncations(const Bytes* bytes) {
    for (size_t split = 0; split <= bytes->len; ++split)
        assert(decode_split(bytes->data, bytes->len, split, NULL) == SUCCESS);
    for (size_t cut = 0; cut < bytes->len; ++cut) {
        GhosttyTerminalSnapshotDecoder decoder = NULL;
        GhosttyTerminalSnapshotDecoderOptions options = decoder_options();
        assert(ghostty_terminal_snapshot_decoder_new(NULL, &options, &decoder) == SUCCESS);
        GhosttyTerminal terminal = NULL;
        size_t offset = 0;
        while (offset < cut) {
            GhosttyTerminalSnapshotDecodeEvent event = { .size = sizeof(event), .version = ABI };
            size_t width = 1 + random_u32() % 31;
            if (width > cut - offset) width = cut - offset;
            GhosttyTerminalSnapshotStatus status = ghostty_terminal_snapshot_decoder_push(
                decoder, bytes->data + offset, width, &event);
            assert(status == SUCCESS);
            offset += event.consumed;
            if (event.kind == GHOSTTY_TERMINAL_SNAPSHOT_DECODE_READY) {
                GhosttyTerminalSnapshotTakeTerminalResult take = { .size = sizeof(take), .version = ABI };
                assert(ghostty_terminal_snapshot_decoder_take_terminal(decoder, &take) == SUCCESS);
                terminal = take.terminal;
                assert(ghostty_terminal_snapshot_decoder_replay_continuation(decoder, terminal) == SUCCESS);
            }
        }
        GhosttyTerminalSnapshotDecodeEvent eof = { .size = sizeof(eof), .version = ABI };
        assert(ghostty_terminal_snapshot_decoder_push(decoder, NULL, 0, &eof) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED);
        ghostty_terminal_snapshot_decoder_free(decoder);
        if (terminal != NULL) {
            static const uint8_t usable[] = "usable-after-truncation";
            ghostty_terminal_vt_write(terminal, usable, sizeof(usable) - 1);
            ghostty_terminal_free(terminal);
        }
    }
}

static void property_mutations(const Bytes* bytes) {
    for (size_t iteration = 0; iteration < 256; ++iteration) {
        uint8_t* mutated = (uint8_t*)malloc(bytes->len);
        assert(mutated != NULL);
        memcpy(mutated, bytes->data, bytes->len);
        size_t index = random_u32() % bytes->len;
        mutated[index] ^= (uint8_t)(1u << (random_u32() & 7));
        GhosttyTerminalSnapshotStatus status = decode_split(mutated, bytes->len,
            random_u32() % (bytes->len + 1), NULL);
        assert(status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNSUPPORTED_FEATURE ||
            status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_UNKNOWN_VERSION ||
            status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION ||
            status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_TRUNCATED ||
            status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_LIMIT_EXCEEDED ||
            status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_STATE);
        free(mutated);
    }
}

static void property_allocator_failures(const Bytes* bytes, GhosttyTerminal source) {
    bool decode_success = false;
    for (size_t fail_after = 0; fail_after < 512; ++fail_after) {
        FailAlloc state = { .fail_after = fail_after };
        GhosttyAllocator allocator = { .ctx = &state, .vtable = &tracked_vtable };
        GhosttyTerminalSnapshotStatus status = decode_split(bytes->data, bytes->len,
            random_u32() % (bytes->len + 1), &allocator);
        assert(status == SUCCESS || status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
        assert(state.active == 0);
        if (status == SUCCESS) { decode_success = true; break; }
    }
    assert(decode_success);

    for (size_t fail_after = 0; fail_after < 8; ++fail_after) {
        FailAlloc state = { .fail_after = fail_after };
        GhosttyAllocator allocator = { .ctx = &state, .vtable = &tracked_vtable };
        GhosttyTerminalSnapshotCaptureOptions options = capture_options();
        GhosttyTerminalSnapshotCapture capture = NULL;
        GhosttyTerminalSnapshotStatus status = ghostty_terminal_snapshot_capture_new(
            &allocator, source, &options, &capture);
        assert(status == SUCCESS || status == GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
        if (capture != NULL) ghostty_terminal_snapshot_capture_free(capture);
        assert(state.active == 0);
        if (status == SUCCESS) break;
    }
}

static void property_history_tokens(GhosttyTerminal source) {
    GhosttyTerminal destination = NULL;
    GhosttyTerminal wrong = NULL;
    assert(ghostty_terminal_new(NULL, &destination, 8, 3) == GHOSTTY_SUCCESS);
    assert(ghostty_terminal_new(NULL, &wrong, 8, 3) == GHOSTTY_SUCCESS);
    FailAlloc lease_state = { .fail_after = 0 };
    GhosttyAllocator lease_allocator = {
        .ctx = &lease_state, .vtable = &tracked_vtable,
    };
    GhosttyTerminalHistoryLeaseResult lease = {
        .size = sizeof(lease), .version = ABI,
    };
    assert(ghostty_terminal_history_lease_new(
        &lease_allocator, source, 0, &lease) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(lease_state.active == 0);
    lease_state.calls = 0;
    lease_state.fail_after = SIZE_MAX;
    assert(ghostty_terminal_history_lease_new(
        &lease_allocator, source, 0, &lease) == SUCCESS);
    assert(lease_state.active == 1);
    GhosttyTerminalHistoryCursorResult cursor = {
        .size = sizeof(cursor), .version = ABI,
    };
    lease_state.fail_after = lease_state.calls;
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &cursor) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(lease_state.active == 1);
    lease_state.fail_after = SIZE_MAX;
    assert(ghostty_terminal_history_lease_cursor(
        lease.lease, source, &cursor) == SUCCESS);
    assert(lease_state.active == 2);
    GhosttyTerminalHistoryOptions options = history_options();
    GhosttyTerminalHistoryEvent event = {
        .size = sizeof(event), .version = ABI,
    };
    assert(ghostty_terminal_history_cursor_next(
        cursor.cursor, wrong, &options, NULL, 0, &event) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_WRONG_TERMINAL);

    GhosttyTerminalHistoryToken forged = lease.checkpoint;
    forged.bytes[random_u32() % sizeof(forged.bytes)] ^= 1;
    GhosttyTerminalHistoryImporterResult importer = {
        .size = sizeof(importer), .version = ABI,
    };
    assert(ghostty_terminal_history_importer_new(
        NULL, destination, 0, source, &forged, &options, &importer) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_INVALID_HANDLE);

    FailAlloc importer_state = { .fail_after = 0 };
    GhosttyAllocator importer_allocator = {
        .ctx = &importer_state, .vtable = &tracked_vtable,
    };
    assert(ghostty_terminal_history_importer_new(
        &importer_allocator, destination, 0, source, &lease.checkpoint,
        &options, &importer) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_MEMORY);
    assert(importer_state.active == 0);
    importer_state.calls = 0;
    importer_state.fail_after = SIZE_MAX;
    assert(ghostty_terminal_history_importer_new(
        &importer_allocator, destination, 0, source, &lease.checkpoint,
        &options, &importer) == SUCCESS);
    assert(importer_state.active == 1);
    options.max_rows = 1;
    uint8_t* units[2] = { NULL, NULL };
    size_t unit_lens[2] = { 0, 0 };
    for (size_t index = 0; index < 2; ++index) {
        GhosttyTerminalHistoryEvent probe = {
            .size = sizeof(probe), .version = ABI,
        };
        assert(ghostty_terminal_history_cursor_next(
            cursor.cursor, source, &options, NULL, 0, &probe) ==
            GHOSTTY_TERMINAL_SNAPSHOT_STATUS_OUT_OF_SPACE);
        units[index] = (uint8_t*)malloc(probe.required_bytes);
        assert(units[index] != NULL);
        GhosttyTerminalHistoryEvent unit_event = {
            .size = sizeof(unit_event), .version = ABI,
        };
        assert(ghostty_terminal_history_cursor_next(
            cursor.cursor, source, &options, units[index],
            probe.required_bytes, &unit_event) == SUCCESS);
        unit_lens[index] = unit_event.written;
    }
    GhosttyTerminalHistoryImportEvent imported = {
        .size = sizeof(imported), .version = ABI,
    };
    assert(ghostty_terminal_history_importer_push(
        importer.importer, destination, units[1], unit_lens[1],
        &options, &imported) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
    assert(ghostty_terminal_history_importer_push(
        importer.importer, destination, units[0], unit_lens[0],
        &options, &imported) == SUCCESS);
    assert(ghostty_terminal_history_importer_push(
        importer.importer, destination, units[0], unit_lens[0],
        &options, &imported) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_CORRUPTION);
    assert(ghostty_terminal_history_importer_push(
        importer.importer, destination, units[1], unit_lens[1],
        &options, &imported) == SUCCESS);
    free(units[0]);
    free(units[1]);
    assert(ghostty_terminal_history_importer_abort(
        importer.importer, destination) == SUCCESS);
    ghostty_terminal_history_importer_free(importer.importer);
    assert(importer_state.active == 0);
    ghostty_terminal_history_cursor_free(cursor.cursor);
    assert(lease_state.active == 1);
    ghostty_terminal_history_lease_free(lease.lease);
    assert(lease_state.active == 0);
    GhosttyTerminalHistoryLeaseResult reset_lease = {
        .size = sizeof(reset_lease), .version = ABI,
    };
    assert(ghostty_terminal_history_lease_new(
        NULL, source, 0, &reset_lease) == SUCCESS);
    GhosttyTerminalHistoryCursorResult reset_cursor = {
        .size = sizeof(reset_cursor), .version = ABI,
    };
    assert(ghostty_terminal_history_lease_cursor(
        reset_lease.lease, source, &reset_cursor) == SUCCESS);
    ghostty_terminal_reset(source);
    GhosttyTerminalHistoryEvent reset_event = {
        .size = sizeof(reset_event), .version = ABI,
    };
    assert(ghostty_terminal_history_cursor_next(
        reset_cursor.cursor, source, &options, NULL, 0, &reset_event) ==
        GHOSTTY_TERMINAL_SNAPSHOT_STATUS_RESET);
    ghostty_terminal_history_cursor_free(reset_cursor.cursor);
    ghostty_terminal_history_lease_free(reset_lease.lease);
    static const uint8_t usable[] = "usable-after-generation-reset";
    ghostty_terminal_vt_write(source, usable, sizeof(usable) - 1);
    ghostty_terminal_free(wrong);
    ghostty_terminal_free(destination);
}

int main(void) {
    GhosttyTerminal source = NULL;
    assert(ghostty_terminal_new(NULL, &source, 8, 3) == GHOSTTY_SUCCESS);
    for (unsigned index = 0; index < 32; ++index) {
        char line[24];
        int len = snprintf(line, sizeof(line), "property-%03u\r\n", index);
        assert(len > 0);
        ghostty_terminal_vt_write(source, (const uint8_t*)line, (size_t)len);
    }
    static const uint8_t continuation[] = "\x1b[38;2;1;2";
    ghostty_terminal_vt_write(source, continuation, sizeof(continuation) - 1);
    Bytes bytes = capture_fixture(source);
    property_splits_and_truncations(&bytes);
    property_mutations(&bytes);
    property_allocator_failures(&bytes, source);
    property_history_tokens(source);
    free(bytes.data);
    ghostty_terminal_free(source);
    return 0;
}
