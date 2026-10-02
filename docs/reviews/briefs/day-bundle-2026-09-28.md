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
