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

| Term | Meaning |
| --- | --- |
| logical stream | one screen's ordered history within a reset epoch |
| logical row | stable hard-line fragment independent of display width |
| logical page | bounded immutable group of consecutive logical rows |
| anchor | stable position between grapheme atoms in a logical row |
| projection | physical rows and anchor mappings for one width profile |
| hot set | active area plus bounded engine-owned overscan |
| cold history | logical pages not required by the hot set |
| backing | canonical encoded logical pages, compressed or raw |
| pin | engine lease preventing eviction or pruning of a range |
| segment | independently checksummed immutable group of logical pages |
| manifest | committed segment set and pruning boundary |

A logical row is not today's physical `Page.Row`. It ends at a terminal hard
line. Soft wraps are projection information. Very long hard lines are split into
bounded fragments, with a continuation bit preserving one logical line for
copy, search, semantics, and later projections.

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
`(LogicalPageId, row_ordinal)`, where the ordinal is a checked `u32` index in the
immutable page directory. Identity survives compression, movement, compaction,
index rebuild, process restart, and every width. Re-encoding during migration
keeps identity. Editing content allocates new identity.

The mutable tail has an ephemeral identity. Sealing atomically publishes a map
from tail positions to new logical IDs. An API requiring durable identity forces
a bounded seal or returns `pending`; it never exposes a future sequence.

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

| Outcome | Meaning |
| --- | --- |
| `mapped` | exact result is available |
| `pending` | backing or projection was queued |
| `stale_generation` | requested projection is no longer retained |
| `wrong_stream` | anchor belongs to another reset epoch or screen |
| `pruned` | identity is older than the committed frontier |
| `corrupt` | its segment failed validation |
| `quarantined` | policy isolated the failed segment |
| `canceled` | request was canceled before publication |
| `budget_exhausted` | next unit cannot start under the hard budget |

A stale projection does not stale the anchor; map it in the current generation.
`pruned`, `wrong_stream`, and reset are permanent for that identity.

## Reflow generations and active resize

A width profile includes columns, cell-width policy version, Unicode
segmentation/width table version, tab policy, and projection format version. Any
field that changes row boundaries is part of the key. A monotonic
`projection_generation` distinguishes publications with identical profiles.

A column resize is a mutation-owner transaction:

1. capture cursor, viewport, selection, and semantic positions as anchors;
2. seal only mutable fragments needed to stabilize the hot boundary;
3. reflow active rows plus bounded hot overscan into a candidate generation;
4. map required anchors into the candidate;
5. validate screen invariants and memory limits; and
6. atomically publish dimensions, hot projection, and generation.

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
Units are a validated frame header, one row directory entry, or one grapheme
atom. Compressed blocks are format-capped. Actual charges include scratch
allocation and are returned.

A host deadline is only a cancellation signal. Work checks cancellation before
each frame, at least every 256 rows, and every 64 KiB of input, whichever comes
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
- Segmentation and width table versions are in the width profile. An update
  creates a projection, never new logical identity.
- Invalid scalars, orphan continuation cells, or a wide trail without its lead
  are corruption or unsupported fidelity, never decoder replacement.
- Zero-width atoms remain attached to their base. State that cannot represent
  this exactly is rejected before persistence or history output.

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
| manifest commit records     |
| unreachable crash tail      |
+-----------------------------+
```

A superblock has magic, container major/minor, checksum algorithm, required
features, `stream_id`, sequence, committed manifest offset/length/digest, prune
frontier, and its checksum. Slots alternate. Recovery chooses the highest valid
sequence whose manifest also validates. Fixed size reserves versioned space
without C or Zig padding.

A segment record contains:

- magic, version, header length, and total length;
- monotonic segment ID and previous committed segment ID;
- first/last logical page sequences, page count, and row count;
- codec, compressed length, and uncompressed length;
- a bounded page directory of offsets, lengths, rows, and BLAKE3-256 page
  digests; and
- BLAKE3-256 canonical-payload and complete-record digests.

Canonical payload is explicit logical-page records, never `Page`. Proposed hard
limits are 4 MiB compressed, 16 MiB uncompressed, 4096 pages, 1,048,576 rows,
and 64:1 expansion per segment. Readers reject overflow, overlap, out-of-file
offsets, nonmonotonic/duplicate IDs, and limits before allocation.

BLAKE3 detects accidental damage and compares content; it does not authenticate
an attacker-controlled store. The required algorithm is versioned and is never
reinterpreted.

### Index and checkpoints

A manifest lists ordered live segments, prune frontier, newest logical page, and
latest checkpoint. Its digest covers its fields and segment record digests. A
checkpoint has a complete sorted page-range-to-segment index and sparse row
counts. Incremental index records after it replay in commit order.

Default checkpoint cadence is 64 committed segments or 64 MiB of new segments,
under maintenance budgets. Opening reads two superblocks, one manifest, one
checkpoint, and a bounded delta. A bad index is rebuilt by scanning valid
segment headers without decoding payloads.

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

Migration is copy-on-write: validate old content, write a new container while
preserving stream/page/row IDs and prune frontier, then atomically switch the
host reference. The only old copy is never edited. Interrupted migration reopens
it. The first release starts an optional empty store and imports live history
under normal budgets; there is no prior disk format to reinterpret.

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

| Budget | Charge | Hard-limit response |
| --- | --- | --- |
| logical resident | backing, logical indexes, mutable tail | evict durable cold backing or reject seal/append |
| projection | rows/indexes for all generations | evict eligible entries or fail |
| scratch | decode/reflow/compress/repair candidates | do not start an over-budget unit |
| durable | live records plus reclaimable tail | prune/compact or reject durable append |
| pin | bytes protected from eviction/prune | reject a pin above cap |

Active screen and recovery metadata are reserved inside, not outside, hard
budgets. Accounting uses allocated capacity and overhead, not text length.

Eviction order is:

1. canceled/unpublished candidates;
2. unpinned stale-generation projections;
3. speculative, then least-recently-used cold projections;
4. unpinned backing with a committed durable copy; and
5. rebuildable indexes beyond the required sparse checkpoint index.

The hot projection, mutable tail, executing scratch, manifest, and pins are not
evictable. Pins are opaque, generation-bound, reference-counted leases with byte
charge and optional expiration sequence. Session destruction releases them.
Unbounded ranges cannot be pinned without passing the pin budget.

Prune removes oldest complete logical identities. The owner publishes frontier
and generation before reclamation, so new reads return `pruned`. Existing pins
may delay physical reclaim but do not make published-pruned content visible to
new reads. Policy waits or rejects prune; it does not revoke a pin silently.

Disk accounting includes live bytes and headroom for one maximum segment,
checkpoint, manifest, and superblock. Compaction has separate headroom. If pins
or minimum retention leave no victim, append returns
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
- No complete manifest yields read-only recovery mode or `needs_full_resync`,
  never partial published history.

Quarantine records bounded metadata: segment/range, failure stage, safe expected
and observed digest, observation sequence, retry count. It does not log terminal
payload. Quarantined bytes are not decoded on every read.

Repair is transactional. An authenticated source must provide exact missing
logical identities/content. The engine validates stream, range, digest, order,
and fidelity, writes replacement segments, then commits a manifest removing the
quarantine. A legacy unit without persistent IDs can only rebuild a new stream
during full resync; it cannot guess a repair identity.

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

| Race | Required result |
| --- | --- |
| append/read | read ends at captured newest ID; later append cannot alter it |
| append/resize | pre-capture append enters candidate; later append projects in a follow-up step |
| resize/cold reflow | old candidate becomes stale and cannot publish |
| prune/read | accepted pin retains bytes; unpinned crossed read is `pruned` |
| prune/reflow | frontier is checked before decode and publish; crossed work cancels |
| import/live VT | imports prepend at old end while VT appends at active end |
| reset/anything | new stream publishes atomically; old tokens/anchors/work stale |
| repair/read | reader sees corrupt or repaired manifest, never partial bytes |
| compaction/read | IDs are unchanged and pins retain selected immutable extents |

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
- owned handles have idempotent destroy/release; and
- no `Page`, Zig slice, native enum/padding, compression state, callback, or file
  descriptor crosses the ABI.

The same C declarations compile native and wasm32. WASM pointers are checked
linear-memory offsets. No retained pointer crosses a call and no JavaScript-only
wire format exists. Large logical lengths use `uint64_t`; one transfer is capped
to an addressable `size_t` buffer.

Computation and host storage are pull-based:

1. create/request opaque work;
2. call `work_step(budget)` until ready or terminal;
3. on `needs_io`, call `store_next_request`;
4. inspect sized request ID, operation, object key, offset, and length;
5. perform I/O outside the engine; and
6. call `store_complete` with status and caller buffer.

Writes copy bounded engine bytes into a caller buffer. Read completion borrows
only while validating or copies into budgeted engine memory. Request IDs are
unforgeable, store/generation-bound capabilities. Duplicate, reordered,
oversized, and wrong-store completions fail.

An optional native backend may implement the request protocol internally using
a configured path, not a supplied descriptor. Standalone WASM uses the external
pump. Backend does not change IDs or format bytes.

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
`stream_id`, logical generation, page/row interval, sequence, canonical payload
version/digest, and keyed authenticator. It stays outside snapshot v1/v2. A new
cursor kind may use the same opaque 32-byte carrier while binding logical stream
and generation. Callers select a reported version; no caller fields are guessed.

Projection-only resize leaves logical content unchanged: a logical cursor
survives, while every view token is projection-generation-bound. A cursor
captures newest/oldest cuts; later append is excluded. A pinned cut delays
prune, while an unpinned crossed cut reports `pruned`.

Migration rules:

- `GHUNIT2` validates through its existing authenticator/page decoder and gets
  destination-owned logical IDs at commit;
- a new logical unit preserves source IDs only after stream/non-overlap checks;
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
NVMe-class storage, a 200x60 viewport, and 10 million history rows. Report
p50/p95/p99, corpus, codec, cache state, charged bytes, and host I/O separately.

| Operation | Target |
| --- | --- |
| active column resize, resident hot set | p95 <= 8 ms, p99 <= 16 ms, zero cold decode |
| row-only active resize | p95 <= 2 ms |
| VT write during cold reflow | <= 5% throughput loss; p99 owner stall <= 1 ms |
| one cooperative step | p95 CPU <= 1 ms; cancel within 64 KiB or 256 rows |
| 240 cold rows, resident backing | p95 engine CPU <= 8 ms |
| 240 cold rows, durable backing | p95 engine CPU <= 12 ms plus host I/O |
| warm anchor map | p95 <= 50 microseconds, no allocation |
| open clean 10-million-row store | p95 <= 50 ms engine CPU, no full scan |
| recover 1 GiB torn-tail container | p95 <= 100 ms CPU plus reclaim I/O |
| index rebuild | >= 1 GiB segment headers/s, no payload decompression |

Memory targets: resize scratch <= twice encoded hot-set bytes plus 1 MiB; sparse
logical indexes <= 24 bytes per row averaged at 10 million rows; disk index <=
3% of durable bytes; projection and scratch never exceed hard budgets including
capacity; canceled candidate memory is released by the next successful step;
clean open allocates <= 32 MiB; median text compression >= 2:1 without active
resize waiting for compression. A miss blocks default enablement.

## Test, fuzz, and benchmark matrix

| Area | Tests and properties | Benchmark |
| --- | --- | --- |
| identity | survive compression/move/compact/reopen/width; random traces never alias | index overhead 1K..10M rows |
| anchors | logical/physical round trips for affinity and old generations | warm/cold lookup |
| Unicode | combining/ZWJ/VS/zero/wide edge/width one; fuzz valid scalars and malformed lead/trail | grapheme/reflow throughput |
| semantics | prompt/style/hyperlink/protection/blank runs survive split/merge | projected run memory |
| Kitty/glyph | placeholders atomic; missing/live unsupported state rejects before output | placeholder-heavy reflow |
| resize | instrumented cold backing is untouched; failed transaction keeps dimensions | resize percentiles |
| budgets | zero/exact/one-less and charges; arbitrary multidimensional budgets | step overhead/fairness |
| cancellation | every state releases scratch and cannot publish after cancel | cancellation latency |
| cache/pins | eviction order, caps, generation retention, oversized pin rejection | hit rate at fixed bytes |
| concurrency | deterministic append/prune/read/resize/import/repair schedules | VT throughput during work |
| container | golden bytes; mutate every length/count/offset/digest/frame | encode/decode/ratio |
| crashes | fail/tear after every write/flush; old or new manifest only | recovery/tail size |
| recovery | index rebuild, quarantine, fallback, arbitrary segment graphs | open/header scan |
| repair | exact authenticated replacement only; replay/reorder/wrong stream rejected | repair/headroom |
| ABI | size/null/buffer/ownership/double release; fuzz wasm32 offsets and native pointers | boundary copy overhead |
| compatibility | v1/v2 and `GHUNIT2` goldens unchanged; mixed units reject | snapshot regression |
| security | token/request forgery, bombs, arithmetic edges, hostile completions | auth/checksum cost |

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
