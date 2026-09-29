# Codex review — 9/28 day bundle (r2 fixes, notes signing, #567)

- Range: `3a849ba2..405b615f`
- Credits spent: unavailable
- Tokens: 53748
- Finding count: 1
- Verdict: fix
- Run: 2026-09-29T02:56:37Z (cycle #14, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 1
Verdict: fix

- **[A][P1] fb544a3d — partial plans still receive the completion marker.** [ArchiveLockJob.swift:275](/Users/rickb/dev/VideoScan/VideoScan/ArchiveLockJob.swift:275). Counterexample: a valid header, one complete media row for `30_Video/a.mov`, and a truncated row for existing, unlocked `30_Video/b.mov`. Planning records two data rows, schedules only `a.mov`, and reports the truncated row as skipped. After successfully locking `a.mov`, `failed == busy == 0` and `relPaths.isEmpty == false`; `notCompleteReason` returns nil. The job writes the one-time marker despite leaving `b.mov` unlocked, hiding the normal retry action even after the manifest is repaired. Preserve skip-and-report behavior, but withhold completion when malformed rows remain unresolved; distinguish these from intentional non-media exclusions and duplicates. **Pin:** `partialMalformedManifestKeepsCatchUpAvailable`: assert the valid file locks, the malformed row is reported, and no marker exists; repair that row, rerun, and assert both files lock before the marker appears.

Other scoped results:

- **A — fa4d3e35 / 4f354556:** `PromoteDateChoice.swift`, `PromoteToArchiveJob+Steps.swift`, and `ArchiveAngelReviewDates.swift`: read, no findings. **e9277d5d:** LF/CRLF splitting and trailing-CR handling read, no additional findings.
- **B — 319ba883:** both notes call sites read, no findings. Each passes current notes directly into the signed append without an intervening suspension. `MachineNote` itself was outside the permitted files, so separator handling and exact text preservation remain unverified.
- **C — 405b615f:** `HallieAppTurnCoordinator+TurnMemo.swift` and coordinator wiring skimmed, no findings. Fresh memo creation and invalidation on all three wrapped writes are present. No concrete reentrant loader was established within scope.

Static review only; no builds or tests run.

## Brief

Review of the 9/28 fixes that no codex pass has seen yet, on `main`. Rick authorized this pass ("feel free any new work from today with codex", 9/28 night). Read-only; do not build or run. Use `git show <sha>` for each commit below — they are NOT contiguous; the rest of the day's range (merges, test-only sensors, gauntlet manifests, the fixity branch you already closed in cycle #13) is out of scope — skip it. Do not explore outside the files listed.

COMMITS IN SCOPE (six)
A. Your promote-dates-and-lock r2 findings, fixed red-first after your cycle #12 — the fixes themselves were never re-reviewed:
- fa4d3e35 (r2 #1) — VideoScan/VideoScan/PromoteDateChoice.swift, VideoScan/VideoScan/PromoteToArchiveJob+Steps.swift: a placement-following row no longer leaves the source's date on the archived record.
- 4f354556 (r2 #2) — VideoScan/VideoScan/ArchiveAngel/Review/ArchiveAngelReviewDates.swift: a typed date survives pre-selection on reload.
- e9277d5d (r2 #3) + fb544a3d (follow-up) — VideoScan/VideoScan/ArchiveLockJob.swift: CRLF manifest rows are each planned and locked; a non-empty manifest that plans nothing never writes the one-time lock marker.
B. 319ba883 — VideoScan/VideoScan/VideoScanModel+ArchiveUpdate.swift, VideoScan/VideoScan/PromoteToArchiveJob+Steps.swift: Archive Update… and Promote now write their machine lines to `.notes` through `MachineNote.line(author: .promote, …)` + `MachineNote.append` (were unsigned, indistinguishable from Rick's own notes).
C. 405b615f (#567) — VideoScan/VideoScan/HallieAppTurnCoordinator+TurnMemo.swift, the 3-line call site at the top of `HallieAppTurnCoordinator.execute`, and the `let`→`var` on five Dependencies closures: People and CyberBrain are read once per Hallie turn; any record* write in the turn drops the memo. Not a data path — lowest priority; skim.

ONE-SENTENCE INVARIANTS
- Promote/lock: "The archived record carries exactly the date Rick chose (never the source's leftover), every manifest row is planned and locked regardless of line endings, and the one-time lock marker is written only when the catch-up really locked what the manifest lists."
- Notes: "Every machine line in `.notes` is signed and Rick's existing text is never altered or lost."
- Hallie: "No answer within a turn is built from a read older than a write Hallie made in that same turn, and the next turn always reads fresh."

ATTACK
1. fa4d3e35: any row shape (placement-following, pre-selected, typed, cleared, conflicting copies) where the archived record ends with a date Rick did not choose, or with none when he chose one; the 00_Index manifest and the record disagreeing.
2. 4f354556: typed date lost or overwritten by a later pre-selection / reload / sibling selection.
3. e9277d5d/fb544a3d: mixed LF/CRLF, trailing CR on the last line, BOM, blank lines, a row that is only whitespace; the marker written after a partial plan or a lock failure; a re-run after a marker that should not exist.
4. 319ba883: `MachineNote.append` on existing notes — separator/newline handling, a note that ends without newline, empty notes, concurrent Update + Promote on one record; anything that rewrites rather than appends.
5. 405b615f: a write path that mutates People/CyberBrain but is NOT one of the three wrapped record* closures (so the memo stays stale); TurnMemo holding its lock while a load re-enters the memo (deadlock); `readingIdentitySourcesOncePerTurn` missed on an entry point that bypasses `execute`.

EVIDENCE (M4, macOS 27, Xcode 27)
- A: 275 tests / 40 suites green on the r2 fix branch (Debug), each fix red first; merged 66bdb7c2.
- B: NotesAuthorshipSensorTests red on main then green; 44 tests / 8 suites (Notes sensor, MachineNote, ArchiveUpdate ×4, PromoteDatesAndLock end-to-end).
- C: follow-up test red on old code (profiles ×2, cyberbrain ×2); green: 152 Hallie suites + new HallieTurnMemoTests, 1,051 tests, 0 known issues (Debug).
- Main CI green at d60e783b; Release gauntlet at d60e783b equal to baseline.

OUTPUT (stdout, Markdown, under 450 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / fix / block`
then findings, each tagged A/B/C with commit sha, file:line, a concrete counterexample, and the test that would pin it. Do not explore outside these files.

## Closure (Claude, 2026-09-28 night)

- **[A][P1] partial plans receive the completion marker** — FIXED 5c4d7f07. `Plan.malformedRows`; any malformed row → `notCompleteReason` ("N manifest row(s) could not be read … repair, then run again"). Skip-and-report unchanged; non-media rows and duplicates still complete. Pins: `partialMalformedManifestKeepsCatchUpAvailable` (red on the old code: marker written, state finished; green after) and `nonMediaAndDuplicateRowsStillComplete` (boundary). 15 lock/Update/Promote-dates/notes suites, 88 Swift Testing + 31 XCTest, 0 failures (Debug).
- **B — MachineNote separator/text preservation** was outside codex's permitted files. Not re-reviewed; covered by the MachineNote suite and NotesAuthorshipSensorTests. Left for a future scoped pass if Update… notes ever show a joining defect.
- No re-review of 5c4d7f07: a one-predicate change with a red→green pin; the loop stops per the safety-critical rule (remaining findings ≤ P2, core path covered).

## Closed

Closed by `5c4d7f07` at 2026-09-29T03:05:07Z. P1 fixed red-first; B MachineNote internals out of scope, covered by suites
