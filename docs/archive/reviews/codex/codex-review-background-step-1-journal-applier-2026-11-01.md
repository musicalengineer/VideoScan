# Codex review — Background step 1 journal applier

- Range: `a63a9622..f5b82514`
- Credits spent: unavailable
- Tokens: 100732
- Finding count: 10
- Verdict: fix
- Run: 2026-11-01T16:28:41Z (cycle #187, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 10

1. **P1 — Refusal-write failures silently lose observations.** [JournalApplier.swift:198](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScan/Catalog/JournalApplier.swift:198): Make `refused.jsonl` unwritable while its directory remains writable, then apply an unknown digest. `try?` discards the append failure and `markApplied` advances past the line: neither a database row nor a refusal remains. **Fix:** require successful durable refusal writes before advancing the cursor, including checking `fsync` errors. The existing refusal test exercises only successful writes.

2. **P1 — A crash during refusal logging corrupts the retry.** [ObservationJournal.swift:406](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift:406): Crash after writing part of a refusal record, before its newline. On restart, replay appends the complete refusal directly onto that fragment, then advances the cursor. The concatenation is invalid JSON and `refusedRecords()` drops it. **Fix:** recover/seal interrupted refusal tails before appending, and checkpoint only after a complete refusal is durable. Add a partial-write/relaunch test.

3. **P1 — Cursors silently skip replacement or truncated files.** [ObservationJournal.swift:377](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift:377): After checkpointing byte 10,000, replace that day file with 500 bytes of new observations. The old cursor is accepted; seeking beyond EOF returns no lines, and waiting counts report zero. An equal-sized replacement is also skipped. **Fix:** bind checkpoints to file identity and consumed-content validation; detect replacement/shrink and replay safely. The cursor test covers malformed text, not stale numeric offsets.

4. **P2 — Deduplication discards distinct observations.** [GRDBCatalogRepository+ProvenanceAssertions.swift:61](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+ProvenanceAssertions.swift:61): Two observations with identical subject, field, value, signer and second, but different evidence/confidence, have different journal IDs. The second nevertheless returns `.duplicate`; its evidence disappears when the cursor advances. Reproduced with the SQL predicate in memory. **Fix:** deduplicate by the observation identity, or an equivalently complete persisted payload. Existing replay tests submit identical payloads.

5. **P2 — Canonicalization aliases different numbers.** [ObservationJournal.swift:176](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift:176): Evidence containing `UInt64.max` becomes `-1` through `NSNumber.int64Value`. Otherwise identical observations containing those two different numbers therefore receive identical canonical evidence and IDs. Foundation reproduction confirmed `CFNumberIsFloatType == false` and `int64Value == -1`. **Fix:** preserve unsigned integers exactly or reject unsupported numeric ranges before hashing. Current canonicalization tests use small numbers.

6. **P2 — The archive guard omits files inside the archive root.** [GRDBCatalogRepository+ProvenanceAssertions.swift:52](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/GRDBCatalogRepository+ProvenanceAssertions.swift:52): A scanned file beneath the designated Master Archive root, with `Cataloged`/`None` flags and no promotion row, is archived under the existing predicate but passes this SQL guard. A background `date` or `name` assertion is accepted despite the promised refusal. **Fix:** include the established archive-root protection. The archive test sets both archive flags, hiding this omission. This currently writes an assertion, not the authoritative filename/date.

7. **P2 — One unsupported subject blocks the entire journal queue.** [JournalApplication.swift:77](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/JournalApplication.swift:77): Construct a validly hashed observation with `subjectKind: "file"` and append valid neighbors. Admission accepts it; the schema CHECK throws, rolling back the batch. Every pass retries it and stops before later files. **Fix:** reject unsupported kinds during admission and record the individual refusal. The in-memory DDL reproduction confirmed rollback; existing admission tests omit this case.

8. **P2 — A sufficiently oversized line permanently stops reading.** [ObservationJournal.swift:353](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift:353): Put 2 MiB + 1 bytes before a newline, followed by a valid observation. After reading 2 MiB, the reader returns zero lines with unchanged offset; every subsequent pass repeats this forever. **Fix:** stream through oversized records to their delimiter and produce a bounded refusal while preserving subsequent records. The existing oversized test uses only 256 KiB + 1 bytes and therefore passes.

9. **P2 — UTC rollover strands torn tails permanently.** [ObservationJournal.swift:259](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift:259): Leave yesterday’s last observation without its newline, then restart after UTC midnight. `append` checks only today’s file, so yesterday’s tail is never sealed. The applier ignores `tornAt`, leaving it neither applied nor refused. **Fix:** explicitly recover abandoned previous-day tails without mistaking an active append for a crash. Existing torn-tail tests keep the clock on one day.

10. **P2 — Refusal batches perform hundreds of synchronous flushes on the main actor.** [JournalApplier.swift:197](/Users/rickb/dev/VideoScan-wt/bg-step1/VideoScan/VideoScan/Catalog/JournalApplier.swift:197): A batch of 256 refused lines executes 256 synchronous `fsync` calls, serialization and cursor publication before yielding. At 5 ms per flush, flushing alone freezes the UI for 1.28 seconds. **Fix:** perform refusal persistence and checkpoint I/O off the main actor while preserving ordering and single-pass exclusion. The scale test measures only the Core transaction with volatile durability. Swift suites were sandbox-blocked: **0 tests ran**; validation used source analysis and in-memory probes.

Verdict: fix

## Brief

Credits spent: <amount> | Finding count: <N>

You are the independent adversarial reviewer for a catalog writer in VideoScan (docs/PROCESS.md §Review, CLAUDE.md rules 2, 3, 6, 8, 10). Review ONLY the range given on the command line (branch feat/bg-step1-era, commits "provenance_assertions — schema v1.13", "ObservationJournal", "JournalApplier"). Read CLAUDE.md first.

What it is: the background helper (a separate process) appends observations as JSON lines to background/journal/<day>.jsonl (Core: VideoScan/VideoScanCore/Sources/VideoScanCore/Background/ObservationJournal.swift). The app's JournalApplier (VideoScan/VideoScan/Catalog/JournalApplier.swift) reads unapplied lines from a per-file `.applied` byte cursor, commits ≤ 256 lines per transaction through CatalogCommitter.commitSideTables(via: .observations), writes refused lines to refused.jsonl, then moves the cursor. The batch body is Core JournalApplication.swift; the store door is GRDBCatalogRepository+ProvenanceAssertions.swift (content missing → archived name/date → duplicate (same subject, field, value, by, at) → INSERT; changes()==0 → vetoed by the trigger in CatalogProvenanceAssertionsSchema.swift).

Look for, with a concrete failing scenario each:
1. Any way a journal line is lost (never applied, never refused) or applied twice as two rows: crash between commit / refused.jsonl / cursor; concurrent append by the helper while the app reads; torn tails; a file that shrinks or is replaced; the cursor beyond EOF; day-file rollover at UTC midnight.
2. Any way the applier writes when the session must not (viewer, read-only, write hold, blocked, reopen, file-stop), or blocks the main actor for long.
3. Rule 3: anything that lets a background line change a name or date of an archived content; whether the archived predicate is right.
4. The id / canonical JSON: can two different observations share an id, or the same one get two ids (number formatting, key order, unicode, integral doubles becoming ints)?
5. Schema: the DDL vs the design text (docs/design/provenance_retroactive_2026_10_26.md §v14), the migration's version bump and the version gate.
6. Tests that would pass with the bug present.

Out of scope: UI, the EraJob, Python. Do not propose new features.

Output contract (exactly): first line `Credits spent: <amount> | Finding count: <N>`, then one numbered finding per issue with severity P1/P2/P3, file:line, the failing scenario, and the fix; then a line `Verdict: <merge | fix | block>`.

## Closed

Closed by `caafc68d` at 2026-11-01T16:48:38Z. 10 of 10 fixed red-first (3 P1, 7 P2); no re-review run
