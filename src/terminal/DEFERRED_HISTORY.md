# Deferred History Reflow and Paging

Status: proposed engine design. This document does not implement reflow or disk
I/O.

## Purpose and scope

A column resize currently reflows the complete `PageList`. The work grows with
scrollback, forces compressed pages to be restored, and invalidates coordinates
that callers may still need. The long-term design gives the terminal engine two
representations:

1. immutable logical history independent of display width; and
2. replaceable width projections, computed eagerly for the active area and on
   demand for cold history.

The same ownership model permits cold history to move from memory to durable
storage without exposing Zig `Page` memory. The engine owns representation,
validation, scheduling, caching, pruning, and recovery. A host supplies limits
and, where needed, a mechanical I/O transport. It does not decide which terminal
pages to cache.

This document fixes identity, ordering, compatibility, and failure contracts
before implementation. It is scoped to libghostty's terminal engine. UI
scrollbars, rendering caches, network transport, and application-specific
prefetch heuristics are outside its scope.

The design must:

- make active resize proportional to the viewport and a bounded hot margin;
- preserve logical positions across any number of width generations;
- bound every cold decode, reflow, compression, index, and persistence step;
- allow live VT writes after a snapshot decoder reaches `READY` while older
  authenticated history is imported;
- separate immutable backing from evictable projections;
- survive crashes without publishing partial segments; and
- expose native C and standalone WebAssembly using opaque handles, sized
  structures, caller buffers, and explicit ownership.

It does not preserve unsupported Kitty image pixels or glyph glossary state by
silently dropping it, add encryption, expose a native `Page`, or put cache policy
in a frontend.

## Invariants

1. **One canonical owner.** Content, styles, semantic marks, explicit line
   endings, and supported placeholder metadata have one immutable logical
   representation. A projection is never source data.
2. **Identity is not an address.** IDs contain no pointers, allocation
   generations, list positions, file offsets, or projected row numbers.
3. **Published generations are immutable.** Readers see a complete projection
   or `pending`, never an in-place partial rewrite.
4. **No lossy success.** Unsupported fidelity, malformed cell state, missing
   resources, and corrupt storage fail explicitly before output or publication.
5. **Budgets are strict.** Zero budget performs zero work. A step never starts an
   indivisible unit whose declared charge exceeds the remaining budget.
6. **Cancellation is monotonic.** Canceled, superseded, pruned, and failed work
   can never become runnable or publish a result.
7. **Transfer remains engine-owned.** Capabilities, cursor tokens, and history
   units are opaque engine bytes, newest-to-oldest, authenticated, and bound to a
   logical generation.
8. **Persistence is transactional.** Recovery chooses the last fully committed
   manifest. Bytes after it are unreachable garbage.
9. **Snapshot bytes do not change.** Snapshot envelope versions 1 and 2 and
   their existing records retain their exact grammar and golden bytes.
10. **Limits precede allocation.** External lengths, counts, offsets, and
    compression ratios are checked before allocation.

## Terms and ownership

| Term           | Meaning                                                    |
| -------------- | ---------------------------------------------------------- |
| logical stream | one screen's ordered history within a reset epoch          |
| logical row    | stable hard-line fragment independent of display width     |
| logical page   | bounded immutable group of consecutive logical rows        |
| anchor         | stable position between grapheme atoms in a logical row    |
| projection     | physical rows and anchor mappings for one width profile    |
| hot set        | active area plus bounded engine-owned overscan             |
| cold history   | logical pages not required by the hot set                  |
| backing        | canonical encoded logical pages, compressed or raw         |
| pin            | engine lease preventing eviction or pruning of a range     |
| segment        | independently checksummed immutable group of logical pages |
| manifest       | committed segment set and pruning boundary                 |

A logical row is not today's physical `Page.Row`. It ends at a terminal hard
line. Soft wraps are projection information. Every hard line has a stable
`LogicalLineId` equal to its first `LogicalRowId`; each bounded fragment stores
that ID, an absolute `fragment_ordinal`, and continuation flags.

A reflow span contains at most 4096 grapheme atoms, 256 KiB of canonical bytes,
or eight fragments, whichever limit is reached first. Crossing a limit inserts
an explicit canonical `layout_gap` record. It preserves the original no-newline
text continuation for copy/search only, but it is a semantic projection break:
the preceding projected row ends, the next span starts at column zero, render
rows expose `layout_gap_before`, and a request for physically contiguous mapping
across it returns `layout_gap` rather than silently claiming exact wrapping.
Anchors on either side remain exact; no anchor denotes an interpolated position
inside the gap.

Thus bounded projection deliberately reports the fidelity boundary instead of
changing wrapping invisibly. Demand expands backward to the current span start
and forward through the requested fragment. Pruning aligns to a span boundary
or persists the same explicit gap; anchors before it return `pruned`. The engine
computes the complete expanded charge before work starts and returns `too_small`
without work when it exceeds the budget.

```text
Terminal / ScreenSet mutation owner
  |
  +-- LogicalHistory (authoritative)
  |     +-- hot mutable tail
  |     +-- immutable logical pages
  |     |     +-- resident encoded bytes
  |     |     `-- durable segment reference
  |     `-- pins, prune frontier, append sequence
  +-- ProjectionSet (derived and evictable)
  |     +-- active width generation and hot projection
  |     `-- cold projections by range and generation
  +-- WorkQueue (budgeting, priority, cancellation)
  `-- Store (format, indexes, quarantine, host I/O requests)
```

The mutation owner alone appends, seals, prunes, publishes resize generations,
and installs projections. Workers read immutable backing and build private
candidates. Installation rechecks the stream, logical, prune, and projection
generations.

The engine owns bytes retained after a call. Input is borrowed for that call
unless ownership is explicitly transferred. Output uses caller buffers or an
allocator-owned result paired with the allocator and exact free length. No host
receives an internal page pointer.

## Stable logical identity

### Streams, pages, and rows

Each screen history has a random 128-bit `stream_id`, generated from engine
entropy and persisted. A reset that discards history creates a new stream. A
screen switch never reuses another screen's stream.

Within a stream the engine has:

- `logical_generation: u64`, advanced on a tail rewrite, import commit, repair,
  prune, or reset;
- `prune_generation: u64`, advanced when the oldest retained identity changes;
  and
- `next_page_sequence: u64`, monotonically allocated and never reused.

Overflow ends the stream: a new stream is created and old anchors become stale.
Wrapping is forbidden.

`LogicalPageId` is `(stream_id, page_sequence)`. `LogicalRowId` is
`(LogicalPageId, row_ordinal)`, where the ordinal is a checked `u32` absolute
index in the immutable page directory. A row slice never gets another page ID
or renumbers an ordinal. Identity survives compression, movement, compaction,
index rebuild, process restart, and every width. Re-encoding during migration
keeps identity. Editing content allocates new identity.

The mutable tail has an ephemeral identity. Sealing atomically publishes a map
from tail positions to new logical IDs. An API requiring durable identity forces
a bounded seal or returns `pending`; it never exposes a future sequence. Each
sealed page also persists its grapheme-boundary directory and segmentation
version. Those boundaries are canonical content and are never recomputed by a
later Unicode release.

### Anchors and mapping

```text
Anchor {
    stream_id: 128 bits
    page_sequence: u64
    row_ordinal: u32
    grapheme_boundary: u32
    affinity: before | after
}
```

Boundaries count grapheme atoms, not bytes, code points, or cells. Zero is before
the first atom and `atom_count` is after the last. Affinity resolves insertion
and hard-line ambiguity. Cursor restoration, selection, search, semantic zones,
viewport top, and durable bookmarks use anchors.

Each projected row stores boundary anchors and a compact grapheme-to-cell run
index. A generation sparse index maps a logical page to its first projected row.
Mapping validates the stream and retained range, selects an immutable generation,
locates or schedules the page projection, finds the row boundary range, then
maps the grapheme boundary using affinity. Reverse mapping returns an anchor.
Synthetic padding and an unplaceable-wide marker map to a neighboring source
boundary and are marked synthetic; they are not logical content.

| Outcome            | Meaning                                         |
| ------------------ | ----------------------------------------------- |
| `mapped`           | exact result is available                       |
| `pending`          | backing or projection was queued                |
| `stale_generation` | requested projection is no longer retained      |
| `wrong_stream`     | anchor belongs to another reset epoch or screen |
| `pruned`           | identity is older than the committed frontier   |
| `corrupt`          | its segment failed validation                   |
| `quarantined`      | policy isolated the failed segment              |
| `canceled`         | request was canceled before publication         |
| `budget_exhausted` | next unit cannot start under the hard budget    |

A stale projection does not stale the anchor; map it in the current generation.
`pruned`, `wrong_stream`, and reset are permanent for that identity.

## Reflow generations and active resize

A width profile includes columns, cell-width policy version, Unicode width-table
version, tab policy, and projection format version. Grapheme segmentation is not
a projection input: every logical page uses its persisted canonical boundaries.
Any field that changes physical row boundaries is part of the profile key. A
monotonic `projection_generation` distinguishes publications with identical
profiles. Changing segmentation for an existing page is forbidden. A future
segmentation migration must allocate new logical IDs and return an explicit
old-anchor-to-new-anchor map with `unmappable`; container v1 performs no such
migration.

A column resize is one mutation-owner transaction:

1. begin a rollback journal containing old dimensions, tail allocation state,
   parser/screen coordinates, and the current `next_page_sequence`;
2. record required positions only as transaction-local ephemeral tail
   coordinates, not public anchors;
3. build a provisional seal for every mutable tail fragment those coordinates
   can reference, reserving page sequences without publishing pages;
4. translate the ephemeral coordinates through the provisional seal map into
   stable logical anchors;
5. reflow active rows plus bounded hot overscan into a candidate generation and
   expand continued fragments only to their span start;
6. map the stable anchors, then validate screen invariants and memory limits;
7. atomically publish the sealed pages, stable-anchor state, dimensions, hot
   projection, and generation as one owner sequence.

Any failure before step 7 discards the candidate and provisional sealed pages,
restores the mutable tail and all ephemeral coordinates from the journal, and
leaves old dimensions/generation published. Reserved page sequences are burned
and never reused, so rollback cannot alias a previously observed identity.
Cursor/snapshot creation cannot interleave on the owner; it observes either the
complete state before this transaction or the complete publication after it.

Default overscan is two viewport heights, capped at 256 projected rows and
2 MiB of canonical input. Configuration may reduce it to zero but may not exceed
512 projected rows or 16 MiB, including predecessor-span expansion. The active
area is included in the byte cap. A required span is itself capped at 256 KiB by
the reflow-fence rule. If the active area plus one required span exceeds the hard
cap, resize returns `hot_set_too_large` and retains the old dimensions; it never
falls through to whole-history reflow.

Failure leaves old dimensions and projection live. The fast path never walks
cold pages, restores every compressed page, changes a disk index, or waits for
host I/O. Row-only resize reuses a compatible projection and changes the active
window; newly exposed cold rows become demand work.

The previous hot projection remains until its readers leave or the generation
retention budget is reached. If a pin prevents retirement, resize may return
`pinned_budget_exceeded` rather than overcommit.

### Cold work state machine

A cold request is an opaque ticket. Requests for the same stream, profile, and
page interval coalesce.

```text
queued -> loading -> decoding -> reflowing -> ready -> published
   |          |           |           |
   +----------+-----------+-----------+-> canceled
   +----------+-----------+-----------+-> stale
   +----------+-----------+-----------+-> pruned
   +----------+-----------+-----------+-> failed
```

`ready` is a complete private candidate. Only the owner can publish it. Live VT
mutation continues in all pre-publication states.

Priority classes describe engine urgency, not cache policy:

1. `interactive_active`: required by an active terminal operation;
2. `interactive_visible`: visible range or hit testing;
3. `explicit`: requested search, selection, or export;
4. `speculative`: optional adjacent work; and
5. `maintenance`: verification, compaction, and checkpoints.

FIFO applies within a class after coalescing. Aging may promote explicit and
maintenance work, but not above unfinished active work. Speculative work is
canceled first under pressure. Callers may request a class, not residency or an
eviction victim.

### Cooperative budgets and cancellation

Deterministic units make native and wasm behavior independent of clocks:

```text
WorkBudget {
    input_bytes: u64
    output_bytes: u64
    logical_rows: u32
    grapheme_atoms: u64
    allocation_bytes: u64
}
```

A too-small result reports the minimum charge for the next indivisible unit.
Units are a validated frame header, one row directory entry, one grapheme atom,
or one independently decodable compression quantum. Actual charges include
scratch allocation and are returned.

Every compression frame is a sequence of independent blocks, each at most
64 KiB compressed and 64 KiB produced. A block has its own compressed and
uncompressed lengths and checksum and resets codec state. The work state machine
checks and charges `input_bytes`, `output_bytes`, and `allocation_bytes` before
invoking the block decoder; an incremental codec is acceptable only if it
provides equivalent checks within both 64 KiB quanta. A 4 MiB segment frame is
therefore never one decoder call.

A host deadline is only a cancellation signal. Work checks cancellation before
and after every compression block, before each logical-row unit, at least every
256 rows, and every 64 KiB of both consumed and produced bytes, whichever comes
first. Cancel, superseding resize, crossed prune frontier, and destruction are
terminal. Scratch is released at the next check; no partial cache entry is
published.

## Text and terminal fidelity

Canonical rows preserve cell semantics, not merely UTF-8: grapheme atoms and
runs for style, hyperlink, protection, semantic prompt zones, and supported
placeholder metadata. Rows record hard break versus continuation. Significant
blank cells are explicit; incidental right padding is not.

### Unicode, width, and graphemes

- Input code-point order is retained after existing parser validation; no
  normalization occurs.
- A grapheme atom is indivisible in projection, selection, and mapping.
- Each logical page persists its canonical grapheme-boundary directory and
  segmentation version. Old pages are never silently resegmented, so anchor
  ordinals remain stable when Unicode data changes.
- Width-table changes create new projections without changing logical identity.
  New pages may use a newer segmentation version because each page carries its
  own immutable boundaries.
- Invalid scalars, orphan continuation cells, or a wide trail without its lead
  are corruption or unsupported fidelity, never decoder replacement.
- Zero-width atoms remain attached to their canonical base. State that cannot
  represent this exactly is rejected before persistence or history output.

A width-two atom in the last cell wraps as a whole. At a one-column width the
projection emits a one-cell `wide_unplaceable` render marker referencing the
original atom. Copy, search, and anchors use the original sequence. At a wider
projection the original renders again; the marker never enters backing.

Semantic marks are anchor intervals. Reflow cannot duplicate or drop them. A
hard-boundary mark follows affinity. Style and hyperlink runs split only in the
projection and coalesce on output. A new semantic feature without canonical
representation causes `unsupported_fidelity`.

### Kitty placeholders and glyph state

A valid Kitty Unicode placeholder base plus placement combining marks is one
grapheme atom. Textual placeholders flow atomically and retain image/placement
metadata. An over-wide placeholder follows `wide_unplaceable` while retaining
its source anchor.

Terminal-owned Kitty image payloads, live image-store-dependent placements, and
glyph glossary entries require dedicated canonical resource records and lifetime
rules. Until implemented, the fidelity gate rejects persistence, compaction, or
history output that would lose them. Unsupported Kitty or glyph state is found
before checkpoint bytes are emitted, matching current snapshot behavior. A
missing resource on decode is `unsupported_fidelity` or `corrupt`, not blank.

## Immutable backing and projection cache

A sealed logical page has a stable engine encoding and is immutable. Its
resident representation is raw canonical bytes or an independently compressed
frame. A recompression is validated and atomically swapped while readers of old
immutable bytes finish.

Frames have explicit codec ID and uncompressed length. The first implementation
may use `none` and a specified LZ4 block format, but never writes a native Zig
compression object. Unknown codecs fail. Frame-size and expansion-ratio limits
bound decompression before allocation.

A projection cache key is `(stream_id, logical page range, width profile,
projection format version)`. Its value contains projected rows, bidirectional
anchor indexes, byte charge, access sequence, pin count, and source digests. It
is derivable and discardable. A candidate with mismatched source digest or
generation is freed instead of installed.

There is no caller-owned `Page` cache. APIs request ranges and release pins; the
engine chooses grouping, compression, overscan, and eviction.

## Durable container

Persistence is optional. The engine owns format and state machine even when a
host executes reads and writes. Integers are fixed-width little-endian. Every
structure starts with type, version, and header length. Reserved bytes are zero
when written and handled only by explicit compatibility rules.

```text
+-----------------------------+ offset 0
| superblock A (4096 bytes)   |
+-----------------------------+
| superblock B (4096 bytes)   |
+-----------------------------+
| immutable segments          |
| immutable index checkpoints |
| immutable quarantine records |
| manifest commit records     |
| unreachable crash tail      |
+-----------------------------+
```

### Normative container v1 grammar

This subsection, not an in-memory declaration, defines v1. All integers are
unsigned little-endian, all offsets are absolute from the beginning of the
containing object or record as stated, and all records begin at an 8-byte object
offset. There are no varints, implicit padding, native enums, or byte-order
marks. A `[N]byte` field is exactly N uninterpreted bytes. Every reserved byte
must be zero. V1 readers reject a wrong fixed header length, nonzero reserved
field, unknown required flag, misalignment, overflow, overlap, hole in a
canonical section sequence, or nonzero trailing alignment byte.

Superblocks A and B begin at object offsets 0 and 4096 and are exactly 4096
bytes:

| Offset | Width | Field                               |
| -----: | ----: | ----------------------------------- |
|      0 |     8 | ASCII magic `GHHSB001`              |
|      8 |     2 | major = 1                           |
|     10 |     2 | minor = 0                           |
|     12 |     2 | header length = 144                 |
|     14 |     2 | checksum algorithm = 1 (BLAKE3-256) |
|     16 |     8 | required feature bits               |
|     24 |    16 | stream ID                           |
|     40 |     8 | superblock sequence                 |
|     48 |     8 | manifest object offset              |
|     56 |     8 | manifest byte length                |
|     64 |    32 | manifest digest                     |
|     96 |     8 | prune page sequence                 |
|    104 |     4 | prune row ordinal                   |
|    108 |     4 | flags                               |
|    112 |    32 | superblock checksum                 |
|    144 |  3952 | zero reserved bytes                 |

The five record magics are `GHSEG001`, `GHIDX001`, `GHCKP001`, `GHQUA001`, and
`GHMAN001`. Each starts with this 96-byte common header:

| Offset | Width | Field                                                            |
| -----: | ----: | ---------------------------------------------------------------- |
|      0 |     8 | type-specific magic                                              |
|      8 |     2 | major = 1                                                        |
|     10 |     2 | minor = 0                                                        |
|     12 |     2 | type: segment=1, index=2, checkpoint=3, quarantine=4, manifest=5 |
|     14 |     2 | flags; v1 writes zero                                            |
|     16 |     4 | header length                                                    |
|     20 |     4 | zero reserved                                                    |
|     24 |     8 | total record length, including final zero alignment              |
|     32 |     8 | record sequence                                                  |
|     40 |    32 | record digest                                                    |
|     72 |     8 | body length excluding header and final alignment                 |
|     80 |     8 | required feature bits                                            |
|     88 |     8 | zero reserved                                                    |

Except for a segment, `header_length` is 96, the body begins at offset 96, and
`total_record_length = align8(96 + body_length)`. The bytes between the body end
and total length are zero. Record sequence is strictly increasing in append
order. An optional future record is skippable only when its type and every
required feature are known to be optional; unknown v1 types are rejected.

A segment has `header_length = 256`. Its extension is:

| Offset | Width | Field                                                  |
| -----: | ----: | ------------------------------------------------------ |
|     96 |     8 | segment ID                                             |
|    104 |     8 | previous committed segment ID, or zero                 |
|    112 |     8 | first page sequence                                    |
|    120 |     8 | last page sequence, inclusive                          |
|    128 |     4 | page count                                             |
|    132 |     4 | logical row count                                      |
|    136 |     2 | codec: none=0, independent LZ4 block=1                 |
|    138 |     2 | block digest algorithm = 1 (BLAKE3-256)                |
|    140 |     4 | block count                                            |
|    144 |     8 | page directory offset, exactly 256                     |
|    152 |     8 | page directory byte length, exactly page_count \* 64   |
|    160 |     8 | block directory offset                                 |
|    168 |     8 | block directory byte length, exactly block_count \* 48 |
|    176 |     8 | compressed payload offset                              |
|    184 |     8 | compressed payload length                              |
|    192 |     8 | canonical uncompressed payload length                  |
|    200 |    32 | canonical payload digest                               |
|    232 |    24 | zero reserved                                          |

For a segment, `block_directory_offset = 256 + page_directory_byte_length`,
`compressed_payload_offset = align8(block_directory_offset +
block_directory_byte_length)`, and `body_length` is the bytes from offset 256
through the last compressed payload byte, including the intervening zero
alignment. `total_record_length = align8(compressed_payload_offset +
compressed_payload_length)`. Its final alignment is zero and is excluded from
`body_length`.

The page directory immediately follows the segment header. Each 64-byte entry is
ordered by increasing page sequence:

| Entry offset | Width | Field                                    |
| -----------: | ----: | ---------------------------------------- |
|            0 |     8 | page sequence                            |
|            8 |     4 | row count                                |
|           12 |     2 | canonical segmentation version           |
|           14 |     2 | page flags                               |
|           16 |     8 | offset in uncompressed canonical payload |
|           24 |     8 | canonical page byte length               |
|           32 |    32 | canonical page digest                    |

The block directory follows immediately, then zero padding to the next 8-byte
boundary, then the compressed payload. Each 48-byte block entry is:

| Entry offset | Width | Field                                      |
| -----------: | ----: | ------------------------------------------ |
|            0 |     8 | offset relative to compressed payload      |
|            8 |     4 | compressed length, 1..65536                |
|           12 |     4 | produced length, 1..65536                  |
|           16 |    32 | digest of the exact compressed block bytes |

Block offsets start at zero, are contiguous with no padding, and end exactly at
compressed payload length. Codec 0 requires compressed length equal produced
length for every block. Codec 1 is raw LZ4 Block Format 1.0: independent blocks,
no dictionary, frame header, content-size field, or carried state. Its last
sequence is literal-only, the final five produced bytes are literals, and the
last match starts at least 12 produced bytes before the end; payloads shorter
than 13 bytes use codec 0. A decoder consumes the entire compressed block and
produces exactly the declared length. Trailing input, short/long output, an
offset before block output, or invalid final sequence is corruption.

Multiple valid LZ4 encodings may represent the same canonical payload;
compressed bytes are not logical identity. The engine writer may replace them
only through an atomic recompression transaction, while page and payload digests
authenticate the unique uncompressed bytes. Golden fixtures fix representative
writer output but readers accept every structurally valid v1 block.

The uncompressed payload is a contiguous sequence of canonical logical pages.
Each starts with an 80-byte header:

| Page offset | Width | Field                            |
| ----------: | ----: | -------------------------------- |
|           0 |     8 | ASCII magic `GHLPAG01`           |
|           8 |     2 | logical page version = 1         |
|          10 |     2 | header length = 80               |
|          12 |     4 | page flags                       |
|          16 |    16 | stream ID                        |
|          32 |     8 | page sequence                    |
|          40 |     4 | row count                        |
|          44 |     2 | segmentation version             |
|          46 |     2 | zero reserved                    |
|          48 |     8 | row directory offset, exactly 80 |
|          56 |     8 | row data offset                  |
|          64 |     8 | total page length                |
|          72 |     8 | zero reserved                    |

Its `row_count` 64-byte entries follow the header. An entry stores, in order:
`row_ordinal:u32`, `row_flags:u16`, `reserved:u16`,
`logical_line_first_page_sequence:u64`,
`logical_line_first_row_ordinal:u32`, `fragment_ordinal:u32`,
`row_record_offset:u64`, `row_record_length:u64`,
`grapheme_directory_offset:u64`, `grapheme_directory_count:u32`,
`reserved:u32`, and `reserved_tail:[8]byte`. Row flags assign bits 0, 1, and 2
to hard break, continuation, and `layout_gap_before`; all other bits are zero.
Ordinals equal the directory index. Row ranges are ordered, nonoverlapping, and
contained in the page.

`row_record_offset` and `grapheme_directory_offset` are absolute from the first
byte of the logical page. `row_data_offset = align8(80 + row_count * 64)`.
Row records appear contiguously in row-ordinal order from `row_data_offset`, with
no inter-row bytes. All grapheme directories follow, in row order, as contiguous
`u32` arrays; final page padding to `total_page_length` is zero. A row record is
an 8-byte-aligned sequence of TLVs
`kind:u16, flags:u16, length:u32, payload:[length]byte, zero-pad-to-8`.
`length` excludes the TLV header and padding. V1 TLV flags are zero, kinds are
strictly increasing, and every present kind occurs once. Atoms kind 1 is
required. Styles=2, hyperlinks=3, semantics=4, protection=5, and Kitty textual
placeholder metadata=6 are omitted exactly when they have no nondefault entry.
Unknown kinds, flags, enum values, nonzero reserved fields, duplicate table
entries, and offsets into headers or padding are invalid in logical page v1; an
extension requires a new logical page version and required container feature.

The atoms payload begins `atom_count:u32, reserved:u32`. It is followed by
`atom_count` variable records. Each record begins
`record_length:u32, atom_flags:u16, cell_width:u8, reserved:u8,
scalar_count:u16, source_cell_count:u16, kitty_metadata_index:u32`, followed by
`scalar_count` Unicode scalar values as `u32` and zero padding included in
`record_length` to a multiple of eight. `record_length` is at least 16 and
exactly `align8(16 + scalar_count * 4)`. Atom flag bit 0 is `explicit_blank` and
bit 1 is `kitty_text_placeholder`; other bits are zero. `cell_width` and
`source_cell_count` are each 1 or 2. Scalar count is zero exactly for an
explicit blank; otherwise every scalar is valid and the stored sequence is not
normalized. `kitty_metadata_index` is `0xffffffff` unless bit 1 is set.

The row's grapheme directory has `atom_count + 1` entries. Its values are byte
offsets relative to the first atom record, immediately after the atoms payload's
8-byte header. Entry zero is zero, each next entry equals the sum of preceding
atom `record_length` values, and the final entry is the complete atom-record byte
length. Consequently one atom is exactly one persisted grapheme and anchor
ordinals do not depend on TLV/header bytes.

The styles payload is
`style_count:u32, run_count:u32`, then `style_count` 48-byte style entries, then
`run_count` 16-byte runs. A color occupies eight bytes:
`kind:u8, reserved:[3]byte, value:u32`; kind 0=default requires value zero,
kind 1=palette requires only value bits 0..7, and kind 2=RGB requires only bits
0..23 in `0x00RRGGBB`. A style entry is foreground, background, and underline
color (24 bytes), `attribute_flags:u32`, `underline_style:u8`,
`font_index:u8`, `reserved:u16`, and `reserved_tail:[16]byte`.
Attribute bits 0..7 are bold, faint, italic, blink, inverse, invisible,
strikethrough, and overline; other bits are zero. Underline style is 0=none,
1=single, 2=double, 3=curly, 4=dotted, or 5=dashed. A run is
`start_atom:u32, end_atom:u32, style_index:u32, reserved:u32`. Runs are sorted,
maximal, nonempty, and exactly cover `[0, atom_count)` without overlap or gaps.
Style entries are deduplicated and ordered by first run use. The TLV is omitted
only when one implicit default style covers all atoms.

The hyperlinks payload header is
`link_count:u32, run_count:u32, string_bytes:u32, reserved:u32`, followed by
`link_count` 24-byte link entries, `run_count` 16-byte runs, then the byte-string
blob. A link entry is three `(offset:u32, length:u32)` pairs for URI, ID, and
parameters. Offsets are relative to the blob start. The canonical blob is the
exact unnormalized bytes for URI, then ID, then parameters for each link in
first-use order, with no gap, overlap, terminator, or padding. Identical triples
are deduplicated. A run is
`start_atom:u32, end_atom:u32, link_index:u32, reserved:u32`; runs are sorted,
nonempty, nonoverlapping, and maximal. Unlinked gaps are implicit.

The semantics payload is `run_count:u32, reserved:u32`, then 16-byte entries
`start_atom:u32, end_atom:u32, semantic_kind:u16, flags:u16,
semantic_id:u32`. Kinds are 1=prompt, 2=command input, and 3=command output;
flags are zero. Runs are sorted, nonempty, nonoverlapping, and coalesced when
kind and ID match. The protection payload has the same 8-byte header followed by
8-byte `start_atom:u32, end_atom:u32` protected ranges, sorted, nonempty,
nonoverlapping, and nonadjacent; unlisted atoms are unprotected.

The Kitty textual-placeholder payload is
`placeholder_count:u32, reserved:u32`, then 32-byte entries
`atom_index:u32, image_id:u32, placement_id:u32, placement_row:u32,
placement_column:u32, placement_rows:u16, placement_columns:u16, flags:u32,
reserved:u32`. Entries are ordered by atom index; rows and columns are nonzero;
v1 flags are zero. Each entry corresponds bijectively to an atom whose
`kitty_text_placeholder` bit is set and whose metadata index equals this entry's
zero-based ordinal. Its original placeholder scalars remain in the atom.

All run endpoints are absolute half-open atom ordinals in this row. Table counts,
fixed-size products, offsets, and endpoints are checked before allocation. These
ordering and omission rules are canonical; an independent implementation can
parse and reproduce every v1 logical payload without native cell knowledge.

Index bodies are arrays of 32-byte entries
`first_page:u64, last_page:u64, segment_id:u64, cumulative_rows:u64`.
A checkpoint body starts with
`first_page:u64, last_page:u64, entry_count:u32, reserved:u32,
total_rows:u64` followed by exactly `entry_count` index entries. A quarantine
body is exactly 104 bytes:
`segment_id:u64, first_page:u64, last_page:u64, failure_stage:u16,
reserved:u16, retry_count:u32, observation_sequence:u64,
expected_digest:[32]byte, observed_digest:[32]byte`.

A manifest body begins with
`previous_manifest_offset:u64, checkpoint_offset:u64, checkpoint_length:u64,
segment_ref_count:u32, quarantine_ref_count:u32, prune_page:u64,
prune_row:u32, delta_record_count:u32, delta_encoded_bytes:u64,
newest_page:u64`. It is followed in this exact order by:

1. `segment_ref_count` 72-byte entries
   `segment_id:u64, object_offset:u64, byte_length:u64, first_page:u64,
last_page:u64, digest:[32]byte`;
2. `quarantine_ref_count` 48-byte entries
   `object_offset:u64, byte_length:u64, digest:[32]byte`; and
3. `delta_record_count` 56-byte entries
   `record_sequence:u64, object_offset:u64, byte_length:u64, digest:[32]byte`.

Delta references are ordered by strictly increasing record sequence and object
offset. Their lengths sum exactly to `delta_encoded_bytes`; each length is the
referenced INDEX record's `total_record_length`. A referenced range must be
after the checkpoint record, within the committed object length, disjoint from
every other referenced record, and before this manifest. Counts, products, and
the delta-byte cap validate before allocation or referenced I/O. No other v1
manifest body bytes are permitted.

Clean open reads only the manifest-listed delta ranges, never scans across
interleaved segment payloads. Every reference must resolve to `GHIDX001` with the
same common-header sequence, byte length, and digest; its record digest and index
ordering must validate before replay. Replay order is the manifest order and
each page range must reference a live segment in the same manifest without
overlap or regression. A missing, duplicate, reordered, overlapping, or
digest-mismatched delta invalidates the complete manifest, causing deterministic
fallback to the other valid superblock/manifest or `needs_full_resync` if none
exists.

Canonical payload is never a native `Page`. Segment hard limits are 4 MiB
compressed, 16 MiB uncompressed, 4096 pages, 1,048,576 rows, and 64:1 expansion.
Readers reject overflow, overlap, out-of-file offsets, nonmonotonic or duplicate
IDs, and every limit violation before allocation.

BLAKE3-256 detects accidental damage and compares content; it does not
authenticate an attacker-controlled store. Container v1 fixes all digest domains
byte-for-byte:

- every input is `ASCII-domain-tag || 0x00 || le64(content_length) || content`;
- `GHOSTTY-HISTORY-V1-BLOCK` covers the exact compressed bytes of one block;
- `GHOSTTY-HISTORY-V1-PAGE` covers one complete uncompressed canonical page
  record, whose digest is stored only in the page directory;
- `GHOSTTY-HISTORY-V1-PAYLOAD` covers the exact concatenation of uncompressed
  page records;
- `GHOSTTY-HISTORY-V1-SEGMENT` covers the complete `total_record_length` bytes,
  including header extensions, reserved bytes, directory, and compressed
  payload, with only its 32-byte record-digest field replaced by zeroes;
- `GHOSTTY-HISTORY-V1-INDEX`, `-CHECKPOINT`, `-QUARANTINE`, and `-MANIFEST`
  each cover their complete record bytes with only that record's digest field
  zeroed; a manifest includes the referenced digest values as ordinary covered
  bytes; and
- `GHOSTTY-HISTORY-V1-SUPERBLOCK` covers all 4096 bytes with only the 32-byte
  superblock checksum field zeroed.

No field is omitted by struct layout and no trailing bytes exist outside the
declared domain. V1 writers zero every reserved byte; v1 readers reject nonzero
reserved bytes. Verification copies or streams zeroes for the named digest field
without modifying source bytes. Future required algorithms get new identifiers
and domains; an old identifier is never reinterpreted.

### Index and checkpoints

A manifest lists ordered live segments, prune frontier, newest logical page,
latest checkpoint, bounded quarantine references, and the complete ordered list
of post-checkpoint index-delta references. Its digest covers every reference and
referenced digest value. A checkpoint has a complete sorted
page-range-to-segment index and sparse row counts. Open replays only the
manifest-listed deltas in their validated sequence; it never discovers them by
scanning interleaved records.

Normal checkpoint cadence is 64 committed segments or 64 MiB of new segment
payload. Independently, the hard post-checkpoint delta cap is 64 incremental
index records and 8 MiB of their encoded bytes. The manifest records all four
counters. The commit that would exceed either delta cap must first write and
flush a complete checkpoint and then reference it from the new manifest.
Checkpoint work is a mandatory append admission charge, not deferrable
maintenance. If its scratch, durable headroom, or host-I/O budget is unavailable,
the durable append returns `checkpoint_required` before publishing a segment or
manifest. Thus open replays at most 64 delta records and 8 MiB of delta bytes. A
bad index is rebuilt by scanning valid segment headers without decoding payloads.

### Commit and crash consistency

An append transaction:

1. encodes and checksums a private segment;
2. appends and durably flushes the segment;
3. appends and durably flushes index delta/checkpoint;
4. appends and durably flushes a complete manifest;
5. writes the older superblock slot with its next sequence and manifest digest;
6. durably flushes that slot, then reports success.

Transport durability is explicit (`flush_data`, then `flush_metadata` where
distinct). A backend lacking durable ordering advertises `volatile`; the engine
reports that crash durability is unavailable.

Recovery ignores bytes after the chosen manifest. A torn newest superblock falls
back. An unreferenced segment is garbage. A manifest never references a segment
before durability. Compaction writes new segments and a manifest before retiring
old extents, so interruption selects either complete set. In-place rewrite is
forbidden.

### Versions, migration, and encryption

Container major versions change incompatible semantics. Minor versions add only
compatible records/features. Unknown required features fail. Writers emit the
current version; readers retain released major versions until an explicit
project-wide support decision removes one.

Migration is copy-on-write: validate old content, write and flush a new
container while preserving stream/page/row IDs and prune frontier, then perform
the host `compare_exchange_reference` transaction defined below. Its expected
reference generation and digest must match the old container, and namespace
durability must be acknowledged before migration succeeds. CAS failure leaves
both containers valid and returns `reference_changed`; interrupted migration
reopens the old referenced container. The only old copy is never edited. The
first release starts an optional empty store and imports live history under
normal budgets; there is no prior disk format to reinterpret.

Compression and projection have separate version IDs. Projection caches do not
migrate. Canonical-record incompatibility requires a new readable record version
or container major; old bytes are never cast as native structures.

Encryption, key storage, and rotation are out of scope. A host requiring it
supplies a layer that encrypts complete engine objects and returns exact
plaintext engine bytes. The engine accepts no keys and never claims checksums
provide confidentiality or authenticity. The host preserves object boundaries,
lengths, ordering, and durability acknowledgments; encryption metadata remains
outside this container absent a future separate specification.

## Memory/disk budgets, pins, and eviction

| Budget           | Charge                                   | Hard-limit response                                 |
| ---------------- | ---------------------------------------- | --------------------------------------------------- |
| logical resident | backing, indexes, tail, write reserve    | evict/prune before admission or return backpressure |
| projection       | rows/indexes for all generations         | evict eligible entries or fail                      |
| scratch          | decode/reflow/compress/repair candidates | do not start an over-budget unit                    |
| durable          | live records plus reclaimable tail       | prune/compact or reject durable append              |
| pin              | bytes protected from eviction/prune      | reject a pin above cap                              |

Active screen, recovery metadata, and a VT-write admission reserve are inside
hard budgets. Accounting uses allocated capacity and overhead, not text length.

Finite resident limits require an additive bounded-write entry point. It
preflights a conservative worst-case mutation charge for the complete input
slice and reports `required_reserve`. If admission fails, it returns
`would_block`, `consumed = 0`, and leaves parser, screen, continuation, and
history unchanged. Once admitted, the whole slice commits and returns
`consumed = input_length`; partial consumption is forbidden. Slices are capped
at 64 KiB, so the reserve calculation is bounded. The PTY owner pauses reads,
persists/prunes eligible history, and retries the identical bytes.

The legacy void `ghostty_terminal_vt_write` remains lossless but cannot report
backpressure. A terminal configured for that entry point may not enable a finite
logical-resident hard limit; attempting to combine them returns
`unsupported_configuration` when history options are installed. It retains the
existing allocator behavior and never drops input. Embedders wanting a finite
hard limit must negotiate the bounded-write capability and use the new call.

Eviction order is:

1. canceled/unpublished candidates;
2. unpinned stale-generation projections;
3. speculative, then least-recently-used cold projections;
4. unpinned backing with a committed durable copy; and
5. rebuildable indexes beyond the required sparse checkpoint index.

The hot projection, mutable tail, executing scratch, manifest, and active pins
are not evictable. Pins are opaque, generation-bound, reference-counted leases
with a byte charge. Optional expiry uses the mutation owner's public
`owner_sequence`, which advances once after every visible owner commit. Creation
returns the absolute `expires_at_sequence`. Renewal is owner-affine, must occur
while status is `active`, repeats the pin-budget check, and atomically returns a
later deadline. Expired pins cannot renew; a caller must acquire a new pin if the
range is still retained.

Before publishing an owner commit at or beyond a deadline, the engine changes
the pin to observable `expired_pending_reclaim`. `pin_status`, the next view
operation, and metrics report `pin_expired`; no new read sublease can begin.
Calls that already acquired a sublease finish against immutable bytes. Physical
reclamation occurs only after their count reaches zero, when status becomes
`expired_reclaimed`. Release is idempotent when not raced with another call.
Pins without a deadline remain until release or parent closing. Session
destruction marks all pins expired and waits through the same sublease rule.

Prune removes oldest complete logical spans. The owner first makes expiration
observable, then publishes the frontier and generation. An active pin makes
prune wait or return `pinned`; an expired pin cannot delay logical prune but its
in-flight subleases delay physical reuse. New reads return `pruned`. No accepted
active pin is revoked silently.

Disk accounting includes live bytes and headroom for one maximum segment,
checkpoint, quarantine record, manifest, and superblock. Compaction has separate
headroom. If pins or minimum retention leave no victim, append returns
`durable_budget_exhausted`; the terminal remains usable in memory.

## Corruption, quarantine, repair, and full resync

Validation order is superblock, manifest, record header, index, frame bounds,
record digest, decompression, page digest, and logical invariants. No invalid
level publishes later data.

- Tail damage after the manifest is ignored and reclaimed.
- Index damage triggers a budgeted header-only rebuild and new checkpoint.
- Isolated segment damage quarantines that identity range while unaffected later
  segments remain available.
- Chain or manifest damage falls back to the previous valid superblock.
- If neither superblock references a complete valid manifest, open
  deterministically returns `needs_full_resync` and leaves the store handle in
  `failed_closed`. It publishes no history and permits only bounded diagnostics,
  destroy, or explicit discard-and-create-new-stream; reads, repair, migration,
  and writes return `needs_full_resync`.

Quarantine state is durable. A versioned `QUARANTINE` record contains the
segment/range, failure stage, safe expected and observed digest, observation
sequence, and retry count. The record uses the exact digest domain above and is
referenced by the manifest; discovery during open is committed with normal
record/manifest/superblock ordering before open reports a writable handle. Until
that commit succeeds, open returns `quarantine_commit_failed` in
`recovery_read_only`, never an ambiguous partially writable state.

Corruption first discovered by a writable demand read uses the same transaction.
The first failing validator atomically installs one in-memory
`quarantine_pending` entry keyed by segment; concurrent readers coalesce on it,
publish no payload, and return `corrupt_pending_quarantine`. The owner serializes
one append of the quarantine record, data/metadata flushes, a manifest containing
the old live set plus the new reference, the alternate superblock write, and its
flush. No later durable append may publish a competing manifest while that owner
transaction is pending.

If repair or prune wins the owner sequence before the quarantine record append,
it may replace/remove the segment and cancel the pending record atomically. If
the quarantine manifest wins, later repair/prune removes its reference in a new
manifest. If any quarantine write or flush fails, the store enters
`recovery_read_only`, all waiters receive `quarantine_commit_failed`, the
in-process pending entry prevents another payload decode, and no further write
is admitted. Reopen starts from the prior valid manifest and may rediscover and
retry the quarantine transaction. Destruction cancels only unissued requests;
acknowledged durable bytes remain unreachable unless a manifest committed them.

The live quarantine table is capped at 1024 records and 256 KiB encoded,
including manifest references. One newest record per segment supersedes earlier
ones. At the cap, another damaged segment returns
`quarantine_capacity_exhausted` and requires repair, prune, or full resync; it
cannot allocate an unbounded diagnostic table. Recovery loads and validates the
table before scheduling any segment decode, so known-bad payload is not retried
after restart. Corrupt quarantine metadata invalidates that manifest and falls
back to the other superblock.

Repair is transactional. An authenticated source must provide exact missing
logical identities/content. The engine validates stream, range, digest, order,
and fidelity, writes replacement segments, then commits a manifest omitting the
repaired quarantine record. Prune removes covered quarantine records in the
same manifest transaction. Old records become unreachable only after the new
superblock is durable. A legacy unit without persistent IDs can only rebuild a
new stream during full resync; it cannot guess a repair identity.

Without complete authenticated coverage, the engine keeps an explicit gap and
does not join neighboring rows. Consumers requiring continuity receive
`needs_full_resync`. Explicit discard creates a new stream; all old anchors then
return `wrong_stream`.

## Concurrent ordering

Visible mutations receive monotonic owner sequences. Commit points serialize as:

```text
VT append/import -> tail seal -> logical append -> prune
                 -> resize publication -> projection publication
                 -> durable manifest publication
```

Immutable worker work occurs between those points.

| Race               | Required result                                                                |
| ------------------ | ------------------------------------------------------------------------------ |
| append/read        | read ends at captured newest ID; later append cannot alter it                  |
| append/resize      | pre-capture append enters candidate; later append projects in a follow-up step |
| resize/cold reflow | old candidate becomes stale and cannot publish                                 |
| prune/read         | accepted pin retains bytes; unpinned crossed read is `pruned`                  |
| prune/reflow       | frontier is checked before decode and publish; crossed work cancels            |
| import/live VT     | imports prepend at old end while VT appends at active end                      |
| reset/anything     | new stream publishes atomically; old tokens/anchors/work stale                 |
| repair/read        | reader sees corrupt or repaired manifest, never partial bytes                  |
| compaction/read    | IDs are unchanged and pins retain selected immutable extents                   |

Snapshot import remains transactional. `READY` publishes the active cut, after
which `vt_write` may continue. Older authenticated units validate independently
and prepend under owner order. Abort removes only the uncommitted prefix. Resize,
reset, wrong generation, or unexpected unit cancels rather than merges.

## Native C and standalone WASM seams

The additive libghostty-vt API follows existing conventions:

- history, view, work, pin, and store are opaque handles;
- option, capability, budget, request, result, metrics, and anchor structs start
  with `size` and use fixed-width protocol scalars;
- calls return `GhosttyResult` plus tagged sized results;
- variable output uses a caller buffer with required/written lengths or an
  explicit `GhosttyAllocator` result freed with that allocator and exact length;
- byte slices are borrowed only for the call;
- owned handles use bounded registry generations with ordered-release behavior;
- no `Page`, Zig slice, native enum/padding, compression state, callback, or file
  descriptor crosses the ABI.

Handle concurrency and lifetime are part of the ABI:

| Handle   | Callers and concurrency                                                             | Parent and closing behavior                                                                                                       |
| -------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| terminal | mutation/write/resize calls are single-owner-thread and never concurrent            | free marks closing; child references defer allocation release; new calls return `terminal_closing`                                |
| history  | create, append, prune, and destroy are owner-thread serialized                      | holds terminal reference; destroy requires no concurrent history call                                                             |
| view     | immutable map/read calls may run concurrently after publication                     | holds history/generation pins; release must follow all reads and is not a use-versus-release synchronization primitive            |
| work     | exactly one `work_step` caller; `work_cancel` may race from any thread              | holds history/store references; destroy follows step; cancel-before-publish wins, cancel-after-publish returns `already_complete` |
| pin      | status may be read concurrently; renew/release are owner-thread serialized          | holds history reference; release follows read subleases                                                                           |
| store    | one thread pumps `next_request`; unique request completions may arrive concurrently | closing stops new requests; outstanding request refs remain until completion/cancel                                               |

The library uses acquire/release synchronization at candidate publication,
cancel flags, request completion, and handle closing. Concurrent release with
any non-status call is caller error; ordered repeated release uses a bounded
registry rather than retaining freed allocations.

Each handle kind has a budgeted slot registry: 4096 slots by default and 65,535
at the hard maximum, counting active entries and one tombstone per reusable
slot. An opaque handle token authenticates kind, slot, parent registry,
`generation:u64`, and random registry nonce. First release changes `active` to
`released_tombstone` and frees all owned resources. A repeated matching release
while that tombstone remains returns success with `already_released`. Allocation
may reuse the oldest tombstone, increments its generation, and makes every older
token for the slot return `stale_handle` without touching the new object. Thus
idempotency is explicit and bounded to the parent registry lifetime and the
slot's most recent generation, not an unbounded promise for arbitrary old bytes.

No free active slot or reusable tombstone returns `handle_limit_exceeded` without
allocation. Generation never wraps: a slot at `maxInt(u64)` is permanently
retired, and a registry with no nonretired slot returns
`handle_generation_exhausted`. Tombstones and retired slots remain within the
fixed registry charge. Parent closing keeps the registry until active children
and outstanding requests reach zero, then invalidates all tokens.

Terminal closing cancels work; a late I/O completion validates its request,
discards bytes, releases the request reference, and returns `store_closing`. If
completion won before cancel, its private result still cannot publish after the
owner observes cancel.

The same C declarations compile native and wasm32. WASM pointers are checked
linear-memory offsets. No retained pointer crosses a call and no JavaScript-only
wire format exists. Large logical lengths use `uint64_t`; one transfer is capped
to an addressable `size_t` buffer.

Computation and host storage are pull-based. The exact v1 request operations are:

| Operation                    | Required fields and acknowledged effect                                                            |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `create_exclusive`           | new object key; fail if it exists, otherwise return generation and length zero                     |
| `stat_object`                | object key; return existence, generation, and exact length                                         |
| `read_exact`                 | object, generation, offset, length; return exactly that range or `short_read`                      |
| `append_compare_size`        | object, generation, expected length, bytes; append only if both match                              |
| `write_exact`                | object, generation, offset, bytes; replace exactly that range and return the new generation        |
| `truncate_compare_size`      | object, generation, expected length, new shorter length; change only if both match                 |
| `flush_data`                 | all prior object data writes are on durable media                                                  |
| `flush_metadata`             | prior object length and metadata changes are durable                                               |
| `compare_exchange_reference` | reference key, expected generation/digest, new object/digest; atomic switch or `reference_changed` |
| `flush_namespace`            | the preceding reference create/replace/delete is durable across crash                              |
| `delete_unreferenced`        | best-effort garbage removal; never a commit prerequisite                                           |

Every request carries an opaque authenticated ID, object generation, and the
IDs of prerequisite requests. The engine does not issue a dependent commit step
until all prerequisites acknowledge success. Hosts must not acknowledge a flush
before its stated durability. Append, write, and truncate return observed
length/generation so stale or reordered completions fail closed. A backend
advertises atomic reference CAS, data flush, metadata flush, namespace flush,
and truncate independently. Durable mode and migration fail with
`durability_unsupported` before the first write if a required operation is
missing; only explicitly requested `volatile` mode may omit flush/CAS promises.

The pump creates work, calls `work_step`, obtains `store_next_request`, performs
the named operation, then calls `store_complete`. Writes copy bounded engine
bytes into a caller buffer. Reads are borrowed only while validating or copied
into budgeted engine memory. Duplicate, reordered, oversized, wrong-store, and
wrong-generation completions fail.

An optional native backend implements this vocabulary internally from a
configured path, not a supplied descriptor. Standalone WASM uses the external
pump. Backend choice does not change IDs or format bytes.

Capabilities report logical/unit/container/projection versions, codecs,
checksums, maximum transfers, host-I/O availability, and fidelity features. They
are engine-produced opaque bytes or sized results, never caller-constructed.

## Snapshot and authenticated cursor evolution

Snapshot v1/v2 remain byte-for-byte immutable. Deferred reflow adds no record,
field, flag, or meaning. A future snapshot grammar change requires v3 and is
separate from container and incremental-unit versions.

Current 32-byte authenticated history lease/checkpoint/cursor/importer tokens
remain opaque process-local registry capabilities. Their private bytes are not
persisted. Existing tokens continue to bind terminal, screen generation,
history generation, registry kind, and secret. Existing `GHUNIT2` bytes remain
accepted by their importer and contain an unchanged snapshot `PAGE` record.
Newest-to-oldest sequencing and strict byte/row budgets remain.

A new capability-negotiated logical unit is additive. A new private magic covers
`stream_id`, logical generation, sequence, canonical payload version, keyed
authenticator, and exactly one absolute half-open page slice:

```text
(page_id, page_total_rows, slice_start, slice_end,
 whole_page_digest, slice_payload_digest)
```

`0 <= slice_start < slice_end <= page_total_rows`; row ordinals in payload are
the absolute interval `[slice_start, slice_end)`. Strict budgets may split a
page, but never renumber it. Newest-to-oldest delivery starts with a slice whose
`slice_end == page_total_rows`; every next same-page slice must have
`slice_end == previous.slice_start`, ending at zero. The importer authenticates
each slice and stores it in a private page assembly keyed by page ID. All slices
must agree on total rows and whole-page digest. Only after coverage is exactly
`[0, page_total_rows)`, with no overlap or gap, does it assemble ordinal order,
verify the canonical whole-page digest, and publish one immutable page
transactionally. Commit rejects an incomplete assembly; abort frees it. The
minimum-budget result describes the next row slice, not a duplicate partial
page.

The unit stays outside snapshot v1/v2. A new cursor kind may use the same opaque
32-byte carrier while binding logical stream, captured generation, and cut.
Callers select a reported version; no caller fields are guessed. The private
registry keeps a mutation-journal position. A compatible transition advances
that private position without changing token bytes; a missing journal link or
incompatible transition returns `stale`.

The logical cursor transition matrix is:

| Mutation                                            | Relation to captured cut                            | Token/result                                                                      |
| --------------------------------------------------- | --------------------------------------------------- | --------------------------------------------------------------------------------- |
| projection reflow/eviction                          | any                                                 | preserved; view token alone becomes stale                                         |
| append newer than captured newest                   | outside                                             | registry generation refreshes; append is excluded                                 |
| committed prepend import older than captured oldest | outside                                             | refreshes; imported rows are excluded                                             |
| mutable-tail rewrite                                | outside, because cursor creation seals its boundary | refreshes; a cursor is never opened over ephemeral tail IDs                       |
| exact-digest repair                                 | outside or inside cut                               | refreshes; inside range changes `corrupt` reads to available without changing IDs |
| repair with different digest/IDs                    | any overlap                                         | prohibited; require full resync, token returns `stale`                            |
| prune wholly older than captured oldest             | outside                                             | refreshes and remains usable                                                      |
| prune crossing cut with active pin                  | overlap                                             | prune returns `pinned`; cursor is preserved                                       |
| prune crossing unpinned cut                         | overlap                                             | token enters permanent `pruned`                                                   |
| compaction/recompression/index rebuild              | any                                                 | preserved; no logical generation change                                           |
| reset/history discard                               | any                                                 | permanent `wrong_stream`                                                          |

Projection-only resize therefore preserves negotiated logical cursors. The
transition matrix applies to the new logical cursor kind; the legacy token and
`GHUNIT2` behavior described above remains unchanged.

Migration rules:

- `GHUNIT2` validates through its existing authenticator/page decoder and gets
  destination-owned logical IDs at commit;
- a new logical unit preserves source IDs only after stream/non-overlap checks
  and complete same-page assembly;
- one importer cannot mix unit versions;
- old/new cursors stay independently bounded and one-way; and
- persistent identity repair requires the new unit or full authenticated resync,
  because `GHUNIT2` has no persistent ID.

Thus tokens/units evolve without changing v1/v2 codec bytes or exposing private
unit headers as ABI structs.

## Security boundaries

- Tokens and I/O request IDs use entropy-backed keyed authentication and
  constant-time comparison.
- Tokens bind owner, kind, stream, and generation; copied bytes do not transfer
  them to another terminal/process.
- Storage adapter bytes are untrusted and pass bounded structural/fidelity
  validation.
- Checked arithmetic and input/output/ratio/row/atom/run/resource limits prevent
  unbounded allocation.
- Errors and metrics contain bounded numeric identifiers, not terminal text,
  paths, tokens, or escape payloads.
- Checksums detect corruption, not malicious replacement.
- Encryption is host-supplied only.
- A native path backend rejects traversal outside its root, platform-supported
  symlink substitution, and non-regular containers.

## Metrics and targets

Required metrics cover logical rows/pages/bytes resident/durable/pruned; raw and
compressed bytes by codec; projection bytes/hits/misses/stale drops/evictions;
resize duration and hot rows; queue depth/charges/cancellations/budget stalls;
I/O bytes/duration without path labels; commits/recovery/index rebuilds/
compactions/quarantines/repairs/full resync; pins/rejections; and anchor mapping
outcomes. Metrics snapshots use sized caller structs and caller-buffer iterators.
Collection does not allocate on VT write or active resize.

Targets use optimized builds on at least four 2024-era laptop performance cores,
NVMe-class storage, a 200x60 viewport, and 10 million history rows. The fixed
gate corpus is 60% ASCII logs, 20% Unicode prose/emoji, 10% style-dense shell
prompts, 5% tabbed hard lines at the 4096-atom reflow-span cap, and 5% valid
Kitty textual placeholders. Each corpus runs 20 unmeasured warmups followed by
200 measured resizes at both default overscan (120 rows for this viewport,
subject to the 2 MiB cap) and hard maximum overscan (512 rows/16 MiB). Report
p50/p95/p99, codec, cache state, charged bytes, and host I/O separately. Every
corpus must pass; an aggregate cannot hide a failure.

| Operation                               | Target                                                                  |
| --------------------------------------- | ----------------------------------------------------------------------- |
| active column resize, default overscan  | p95 <= 8 ms, p99 <= 16 ms, zero cold decode                             |
| active column resize, hard-max overscan | p95 <= 32 ms, p99 <= 50 ms, zero work outside declared hot bytes        |
| row-only active resize                  | p95 <= 2 ms                                                             |
| VT write during cold reflow             | <= 5% throughput loss; p99 owner stall <= 1 ms                          |
| one cooperative step                    | p95 CPU <= 1 ms; cancel within 64 KiB consumed and produced or 256 rows |
| 240 cold rows, resident backing         | p95 engine CPU <= 8 ms                                                  |
| 240 cold rows, durable backing          | p95 engine CPU <= 12 ms plus host I/O                                   |
| warm anchor map                         | p95 <= 50 microseconds, no allocation                                   |
| open clean 10-million-row store         | p95 <= 50 ms CPU, at most 64 delta records/8 MiB delta bytes            |
| recover 1 GiB torn-tail container       | p95 <= 100 ms CPU plus reclaim I/O                                      |
| index rebuild                           | >= 1 GiB segment headers/s, no payload decompression                    |

Memory targets: resize scratch <= twice encoded hot-set bytes plus 1 MiB; sparse
logical indexes <= 24 bytes per row averaged at 10 million rows; disk index <=
3% of durable bytes; projection and scratch never exceed hard budgets including
capacity; canceled candidate memory is released by the next successful step;
clean open allocates <= 32 MiB; median text compression >= 2:1 without active
resize waiting for compression. A miss blocks default enablement.

## Test, fuzz, and benchmark matrix

| Area          | Tests and properties                                                                    | Benchmark                   |
| ------------- | --------------------------------------------------------------------------------------- | --------------------------- |
| identity      | survive compression/move/compact/reopen/width; line spans and sliced pages never alias  | index overhead 1K..10M rows |
| anchors       | round trips for affinity; frozen segmentation keeps anchors across Unicode upgrades     | warm/cold lookup            |
| Unicode       | combining/ZWJ/VS/zero/wide edge/width one; malformed cells; span fences                 | grapheme/reflow throughput  |
| semantics     | prompt/style/hyperlink/protection/blank runs survive split/merge                        | projected run memory        |
| Kitty/glyph   | placeholders atomic; missing/live unsupported state rejects before output               | placeholder-heavy reflow    |
| resize        | provisional tail seal/anchor rollback; layout-gap visibility; exact hot bounds          | both overscan gates         |
| budgets       | zero/exact/one-less; bounded-write admission is atomic; checkpoint cap backpressures    | step/write overhead         |
| cancellation  | cancel at every block boundary; <=64 KiB consumed/produced; no late publish             | cancellation latency        |
| cache/pins    | eviction caps; pin expiration/status/renewal/sublease reclaim schedules                 | hit rate at fixed bytes     |
| concurrency   | deterministic owner/handle use-cancel-close-completion and mutation schedules           | VT throughput during work   |
| container     | independent TLV/golden parser; manifest delta refs; exact offsets/digests/LZ4 mutations | encode/decode/ratio         |
| crashes       | fail/tear/reorder every host op; CAS/reference and each flush old-or-new only           | recovery/tail size          |
| recovery      | no-manifest failed-closed; demand quarantine races/failure/reopen/cap/removal           | open/header scan            |
| repair        | exact authenticated replacement only; slice gaps/overlap/replay/wrong stream rejected   | repair/headroom             |
| ABI           | handle tombstone reuse/limits/exhaustion and thread races; fuzz wasm/native pointers    | boundary copy overhead      |
| compatibility | v1/v2 and `GHUNIT2` goldens unchanged; mixed units reject                               | snapshot regression         |
| security      | token/request forgery, bombs, arithmetic edges, hostile completions                     | auth/checksum cost          |

Every persistent version has checked-in golden bytes and an independent parser
fixture. Crash tests use a fake transport that records and tears operations.
Concurrency tests use deterministic barriers, not sleeps. Corpora include
incompressible bytes, ASCII logs, Unicode prose, prompts, and placeholders.

## Rejected alternatives

- **Reflow every `Page` in place:** remains proportional to all history, forces
  decompression, destroys coordinates, and cannot serve two widths.
- **Physical row or file offset identity:** both change on reflow, split, prune,
  compaction, and repair.
- **Store UTF-8 hard lines only:** loses styles, semantics, significant blanks,
  protection, hyperlinks, width semantics, and placeholders.
- **Persist native `Page` or memory-compressed bytes:** contains pointers,
  padding, target fields, allocator assumptions, and compiler-specific layout.
- **Frontend-owned paging/cache:** duplicates invariants and makes corruption,
  eviction, and tokens embedding-dependent.
- **Callbacks or caller file descriptors:** add reentrancy/lifetime/platform
  hazards and do not map cleanly to standalone WASM.
- **One compressed blob:** makes random access, repair, pruning, and budgets
  unbounded.
- **In-place disk index:** a torn update can publish incomplete references;
  append-only commits have a deterministic boundary.
- **Checksum as encryption/authentication:** unkeyed digests provide neither.
- **Extend snapshot v2:** changing frozen bytes breaks fixtures and decoders;
  container and logical units are independently versioned.

## Phased upstream plan

1. **Identity and instrumentation:** add internal stream/page/row/anchor values,
   checked encoding helpers, generation metrics, properties, and baselines. Map
   current physical history internally without changing resize or ABI.
2. **Canonical backing and active projection:** define golden logical records and
   fidelity validation; add tail sealing, anchor capture, and hot projection.
   Keep eager reflow as fallback and prove cold pages are untouched.
3. **Cooperative cold projection:** add tickets, budgets, cancellation,
   priorities, immutable publication, cache, and pins. Enable only for tests and
   opt-in use until targets pass.
4. **Durable store and recovery:** implement v1 first over fake I/O with crash
   injection, then native path and pull-based host pump. Keep persistence opt-in.
5. **Additive C/WASM ABI:** expose capabilities, anchors, views, work, pins,
   metrics, and store requests from one header; add logical units while retaining
   current tokens and `GHUNIT2`.
6. **Migration and enablement:** add copy-on-write migration, compaction,
   diagnostics, differential tests, and full corpora. Enable deferred reflow by
   default only after fidelity, crash, concurrency, memory, and latency gates.
   Durable paging remains a separate opt-in because storage/privacy differ.

No phase may weaken validation, make a hard budget advisory, or convert a
stale/pruned/corrupt result into silent content loss.
