# Codex review — Promote dates + lock

- Range: `cc3b156d55414e3b9947c1462e7fdcb1b0ed1ee0..a9893539`
- Credits spent: unavailable
- Tokens: 116129
- Finding count: 5
- Verdict: merge-after-fixes
- Run: 2026-09-27T23:06:56Z (cycle #10, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 5
Verdict: merge-after-fixes

Reviewed `cc3b156d..a9893539` on the requested branch; checkout remains `main`. Static review only; no builds or tests run.

1. **P1 — Lock-all can prevent Update rollback.** `ArchiveLockJob.swift:317` changes flags without coordinating with Update’s transaction. Counterexample: lock-all opens the original; Update unlocks and renames it; lock-all sets immutable through its still-open descriptor; index publication fails. Rollback now fails with EPERM, leaving the file and manifest at different paths. **Pin:** add `lockAllCannotInterruptUpdateRollback` in `ArchiveLockUpdateAndJobTests.swift`, using barriers around descriptor opening, rename, and failed publication.

2. **P1 — Manifest adoption loses the archived date.** `PromoteToArchiveJob+Steps.swift:440` skips the date decision when a manifest row exists, but line 488 registers using the source’s current fields (`VideoScanModel+MasterArchive.swift:1017`). Counterexample: promote with typed 1947, lose the unsaved catalog registration, then adopt with source userDate 1990. Filename/index remain 1947; archived record becomes 1990. **Pin:** `adoptionPreservesManifestDate` in `PromoteDatesAndLockTests.swift`, including a nil source date.

3. **P2 — An undated interrupted placement does not win.** `PromoteDateChoice.swift:256` only follows filename hints having a year. Counterexample: journal points to `30_Video/Undated/xxxx-xx-xx_Clip.mov`; retry supplies typed 1984. Reconciliation writes 1984 into manifest/userDate while retaining the undated placement. **Pin:** `reconcileUndatedPlacementWins` in `PromoteDatesAndLockTests.swift`; also cover an earlier decade placement with a different retry override.

4. **P2 — Angel guesses provenance from date equality.** `ArchiveAngel/Promote/ArchiveAngelPromoter.swift:62` classifies any choice equal to the current machine hint as machine-derived. Counterexample: Rick explicitly enters 2004, matching that hint; no userDate or dateSet is written, including for companions. Conversely, a stale machine proposal differing from today’s hint becomes `.typed`. **Pin:** both cases in `ArchiveAngelReviewDatesTests.swift`.

5. **P2 — Malformed manifest rows bypass whole-manifest validation.** `ArchiveLockJob.swift:289` uses `ArchiveRefile.parseRows`, which silently skips short rows (`ArchiveRefile.swift:209`). Append a truncated escaping row after valid rows: lock-all flags valid files instead of refusing. **Pin:** `truncatedPoisonRefusesBeforeFlags` in `ArchiveLockUpdateAndJobTests.swift`, asserting zero setter calls.

Other listed scoped changes: read, no findings.

## Brief

Review, SCOPED to branch `feat/promote-dates-and-lock` against `main` (range `cc3b156d..HEAD`; commits 732bc66a, aba783fa and the ones after it). Use `git diff cc3b156d..HEAD` and `git show <sha>`. Read-only; do not build or run. Do not explore outside the files listed below.

ONE-SENTENCE WORKFLOW (Rick, 2026-09-27): "When I promote a file, use the date I already gave its copies; and once it's in the archive, nothing but Update… can change or delete it."

CUT (not in this branch, by design): locking folders; the system flag (`schg`); any automatic re-dating of files already archived; a ledger line per file for the lock-all job (START / every failure / OUTCOME are logged instead); reading "when set" from anything but the Media Ledger.

FILES
- App: `ArchiveFileLock.swift` (new — the only flag primitive), `ArchiveLockJob.swift` + `ArchiveLockDetailView.swift` (new — Lock / Unlock Archive Files… job), `PromoteDateChoice.swift` (new — copies-date gather/decide + `dateDecision`), `ArchiveAngel/Review/ArchiveAngelReviewDates.swift` (new), `PromoteToArchiveJob.swift`, `PromoteToArchiveJob+Steps.swift`, `PromoteToArchiveSheet.swift`, `ArchiveRefile.swift`, `VideoScanModel+ArchiveUpdate.swift`, `VideoScanModel+Rename.swift`, `VerifyArchiveCopiesJob.swift`, `ArchiveVolumeProtection.swift` (inventory only), `ArchiveAngel/Promote/ArchiveAngelPromoter.swift`, `ArchiveAngel/UI/ArchiveAngelReviewSheet.swift`, `ArchiveAngel/Prepare/ArchiveAngelPlan.swift` (one additive field), `VideoScanModel+MasterArchive.swift` (one plan property), `MediaFileOperations.swift` / `MediaFileOperationsWindow.swift` (the `.lockArchive` kind), `ArchiveView.swift` (two menu items), `VideoScanCore/MediaLedgerEvent.swift` (Detail `locked`).
- Tests: `PromoteDatesAndLockTests.swift`, `ArchiveLockUpdateAndJobTests.swift`, `ArchiveAngelReviewDatesTests.swift`, `ArchiveUpdateTests.swift` (item 0), fixture changes in `MasterArchiveTestSupport.swift`, `VerifyArchiveCopiesTests.swift`, `PruneApplyTests.swift`, `MediaFileOperationsWindowForwarderTests.swift`.

WHAT CHANGED
0. (732bc66a, a live bug) Update…: when the index's date is Rick's (`user-known`/`user-estimated`) or the user changed the date, the target is Promote's placement for it. A misfiled file (index 1984, folder/prefix 1884) lists `Name: 1884-xx-xx_X → 1984-xx-xx_X` + `Folder: …` even with nothing typed and moves. A correctly filed file maps to its exact path (confidence-only = zero renames). A MACHINE date in the index never moves a file on its own.
1. Copies' dates: a file with no userDate gathers the userDates on (a) records with the same whole-file SHA-256 (ContentFixity / ArchiveFixity digest + byte count) and (b) its Find Similar Footage group when the group's confidence ≥ `likely`. One distinct date known by ≥1 copy → pre-selected line; disagreement or estimated-only → ask (Use / Enter a date… / Promote undated), Promote disabled until answered. Same rule on the Promote sheet and in Angel Review (answer stored on the plan row: `proposedDate` + `inheritedDate` + `dateFromCopiesAnswered`).
2. GH #219: `archiveDateOverrides` (hint) + `archiveDateSources` (`.typed` / `.copy(name, known)`; absent = machine proposal) → `PromoteToArchiveJob.dateDecision` → the SAME hint for placement, manifest `record_date`, and (only when the source is Rick's) the archived copy's `userDate` with provenance note + a `dateSet` ledger line. The filename prefix of the path the file IS at is the final word (an earlier interrupted run's placement wins; nothing written then).
3. Locks: Promote locks after fixity (failure → outcome row `notLocked`, summary "N promoted — NOT locked", ledger `archived` locked=false; the copy stays). Update: unlock is the first mutation inside the index transaction (fails → refused), rename, relock target (fails → `Done.lockProblem` → `updatedWithWarnings`), every rollback relocks the original found by identity (fails → text appended to the outcome). Lock-all job: manifest rows only; ALL rows validated before any flag; non-media buckets skipped + listed; chunked `@concurrent`; Pause/Stop. Verify Copies: report-only `notLocked` tally. Catalog rename refuses a locked archive file.

OUTCOMES (each has a test)
- Promote: promoted + locked · promoted, NOT locked (warn) · refused (filing-year guard) · rolled back (barrier failure: no file, no partial, no row).
- Update: updated + relocked (same inode, flag set) · updated, NOT relocked (warn, file intact) · refused (incl. locked-and-cannot-unlock; nothing moved, still locked, manifest byte-identical) · rolledBack (original back AND relocked; relock failure said in the text) · mixedState / incompleteRecovery as before.
- Lock-all: "Locked N · already locked N · failed N" (failed listed with reason; missing file = failed) · refused (poisoned manifest row, symlinked manifest, read-only Mac, no/other archive) — nothing flagged.

INVARIANTS TO ATTACK
1. No path deletes or moves a locked file except Update…: find any code path that clears UF_IMMUTABLE other than `Reason.updateUnlock` / `.unlockAll`, calls `fchflags`/`chflags`/`lchflags` outside `ArchiveFileLock.swift`, or unlinks/renames an archive file after clearing the flag without relocking. Include the Update sequence: unlock happens inside `ArchiveIndexRename.apply`'s `moveMedia` — is there any throw between the unlock and the rename whose outcome skips `relockAfterFailure`?
2. Update always relocks or reports that it didn't: every exit of `ArchiveRefileEngine.commit` after a successful unlock (refused after unlock, rolledBack, incompleteRecovery, mixedState with/without an identity-found original, refiled) — is the file either locked or the outcome text saying "not locked"?
3. The Promote date agrees across filename, index and record: typed / Review / copy date; the reconcile path (journal entry from an earlier run, override present or absent); the adopt-from-manifest path (manifest row already exists — the record must not be re-dated); decade hints (`1940s` → folder decade, filename `xxxx`, manifest `1940s`, no userDate); companions promoted with an Angel original.
4. The copies-date prompt never prefers a machine date over Rick's: a machine date never enters `gather`; a machine override (no source) is never written as a userDate; in Angel Review a pre-selection must not overwrite a date the person typed; "Promote undated" must not silently keep a copy's date.
5. Lock-all "refuse before mutating": can any row be flagged before a later row proves the manifest poisoned? Can a row outside the root, a symlinked intermediate, or `00_Index` / `40_Family_Tree` be flagged? Race: lock-all running while Update clears → renames → relocks the same file.

EVIDENCE (M4, Debug): item 0 pin red on main's logic (6 issues) then green — 18 tests / 3 Update suites. GH #219 pins red by mutation (override removed from the manifest/record path: 6 issues in 2 tests), green after. Affected suites by `-only-testing` SUITE: 1204 tests in 210 suites, 2 issues, neither from this branch (`ArchiveAngelVocabularyTests.ledgerKinds` predates it — main added `archiveUpdated`/`archiveUpdateRolledBack` without updating that pin; `VerifyArchiveCopiesIsolationTests` snapshots the live App Support tree, which the running daemons write every few seconds). New suites: 39 tests / 8 suites green. 100k-row lock pass (stub setter) runs 0 flag changes on the main actor, within `loadAwareDebugCeiling(20 s)`.

OUTPUT (stdout, Markdown, under 400 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / merge-after-fixes / hold`
then findings, each with file:line, a concrete counterexample, and the test that would pin it. Do not explore outside these files.

## Closed

Closed by `5fb050ee` at 2026-09-27T23:44:44Z. #1 #5 fc41de7b (one-time catch-up, index lock, per-row report; Unlock-all removed per Rick), #2 dcb323bb, #3 69ba2516, #4 d5874660

---

# Codex review — Promote dates + lock r2 (re-run after outage)

- Range: `a9893539..5fb050ee`
- Credits spent: unavailable
- Tokens: 83049
- Finding count: 3
- Verdict: merge-after-fixes
- Run: 2026-09-28T18:09:11Z (cycle #12, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: merge-after-fixes

1. **P2 — Reconciliation can retain the rejected source date.** `PromoteToArchiveJob+Steps.swift:511,522`: manifest-date correction applies only when adopting an existing row; a placement-following decision has no `recordUserDate`, so neither branch corrects the date inherited during registration. Counterexample: an interrupted file sits under `Undated`, the source now has userDate `1990`, and reconciliation appends an undated manifest row. The archived record retains `1990`. **Pin:** extend `reconcileUndatedPlacementWins` with source userDate `1990`/known; require nil archived userDate and confidence for both Undated and decade placement.

2. **P2 — Preselection still overrides explicit typing through value equality.** `ArchiveAngel/Review/ArchiveAngelReviewDates.swift:48`: `untouched` ignores `proposedDateSource`. Counterexample: Rick types `2004`, matching the machine default; the binding sets `.typed` but leaves `dateFromCopiesAnswered` unset. Applying preselection on reload replaces it with the copy’s `1984` and `.fromCopy`. **Pin:** add `preselectionPreservesExplicitTypedMachineDate`, applying preselection to that state and asserting `2004`/`.typed` remain.

3. **P2 — CRLF rows disappear from lock planning.** `ArchiveLockJob.swift:320`: Swift treats CRLF as one `Character`; splitting on the LF character does not separate CRLF records. Counterexample: pass a header and two valid rows joined with `"\r\n"` to `plan`: the entire input is dropped as the header, yielding a successful empty plan without skipped-row reporting. The completion branch at line 191 accepts empty plans for the marker. **Pin:** `crlfManifestRowsAreAllPlanned`, plus a later escaping row requiring refusal; verify incomplete parsing cannot hide the catch-up action.

Other scoped changes **read, no findings**: ArchiveFileLock, ArchiveLockDetailView, ArchiveView, ArchiveRefile’s message changes, PromoteDateChoice, PromoteToArchiveJob, ArchiveAngelPromoter, ArchiveAngelPlan, ArchiveAngelJob’s source assignment, ArchiveAngelReviewSheet’s date binding, and matching test changes.

Static review only; no builds or tests run. Merge commit skipped. Index-lock internals and other excluded dependencies were not inspected, so their timing/concurrency behavior was not independently verified.

## Brief

Re-review, SCOPED to the fix commits for your r1 findings (docs/codex-review-promote-dates-and-lock-2026-09-27.md) on `feat/promote-dates-and-lock`: range `a9893539..HEAD`. The fix commits are fc41de7b (#1, #5 and Rick's simplification), dcb323bb (#2), 69ba2516 (#3), d5874660 (#4), 2a0909b6 and 74911295 (tests only). feb938bd is a merge of origin/main (one conflict in a badge-colour switch, nothing else touched) — skip it. Use `git show <sha>`. Read-only; do not build or run. Do not explore outside the files these commits touch: ArchiveLockJob.swift, ArchiveLockDetailView.swift, ArchiveFileLock.swift, ArchiveView.swift, ArchiveRefile.swift (message text only), PromoteDateChoice.swift, PromoteToArchiveJob.swift, PromoteToArchiveJob+Steps.swift, ArchiveAngel/Promote/ArchiveAngelPromoter.swift, ArchiveAngel/Review/ArchiveAngelReviewDates.swift, ArchiveAngel/Prepare/ArchiveAngelPlan.swift, ArchiveAngel/Prepare/ArchiveAngelJob.swift (one line), ArchiveAngel/UI/ArchiveAngelReviewSheet.swift (the date binding), and the matching tests.

ONE-SENTENCE WORKFLOW: "When I promote a file, use the date I already gave its copies; and once it's in the archive, nothing but Update… can change or delete it."

RICK'S RULING (2026-09-27, applied in fc41de7b): Promote locks every file by default; only Update… unlocks → changes → relocks. There is NO Unlock job (removed: menu item, mode, `Reason.unlockAll`; `mayUnlock` is `.updateUnlock` only). "Lock Archive Files…" became "Lock files already in the archive (one-time)…" — a catch-up for files promoted before locking existed, hidden once it has completed cleanly (no failed, no busy file) by a marker file beside the catalog (App Support in production). Short/malformed manifest rows are skipped and REPORTED, not a whole-job refusal; a whole row whose path escapes the root still refuses the job before any flag.

FIXES (each red first)
- #1 (fc41de7b) `ArchiveLockJob.lockOne` sets each flag inside `ArchiveIndexLock.withExclusive(root:holder:wait: .zero)` — the lock Update holds for its whole `ArchiveIndexRename.apply` (move, publish, rollback) — through `ArchiveFileLock.set`, which opens the path through the dirfd chain under that lock. Busy → `.busy`: skipped, reported "busy — being updated", job not complete. Pin `lockAllCannotInterruptUpdateRollback` (lock-all driven from inside Update's failing publish): red 4 issues (rollback EPERM), green.
- #5 (fc41de7b) `ArchiveLockJob.plan(manifestText:root:)` reads EVERY line; a row with < 12 fields or no relpath is skipped + reported, its text never used as a path; `ArchiveRefile.parseRows` is no longer used here. Pin `truncatedRowReportedValidRowsLocked`: red by mutation (silent skip, 2 issues), green.
- #2 (dcb323bb) when the manifest already has a row for the source (adoption / reconcile), the archived record's date comes from the row (`userDate(fromManifestFields:)` — a user date only for `user-known`/`user-estimated`), never the source. Pin `adoptionPreservesManifestDate` (source 1990, and nil): red 2, green.
- #3 (69ba2516) `placementHint(relPath:)`: prefix year, else Undated → unknown, decade folder → decade, year folder → year. When it differs from the chosen date the placement wins (no user date written) and the retry's date is refused: outcome `.failed("… already filed this under … ; the date … was NOT applied — use Update… …")`. Pin `reconcileUndatedPlacementWins` (Undated, and 1940-1949): red 6, green.
- #4 (d5874660) `Entry.proposedDateSource` (typed / fromCopy / machine; additive, nil = machine) set where the value is set (plan build, Review field, Use / pre-selection, Enter a date…, Promote undated); `ArchiveAngelPromoter.dateSource(entry:hint:)` reads it, no machine-hint comparison. Pins `promoterSourceIsExplicit` + `reviewAnswersSetSource`: red 6 with the old inference, green.

ATTACK
1. #1: any flag change by lock-all outside the index lock; `wait: .zero` on a thread where `withExclusive` still sleeps; Update's relock-after-success and relock-after-failure run OUTSIDE apply's lock — can lock-all and those interleave into a wrong final state (they both only lock)? Promote's own lock call is outside the index lock — can it meet an Update of the same file?
2. #5: a malformed row that `ArchiveManifestCSV.fields` splits into ≥ 12 fields with a dangerous relpath; CR/LF and quoted newlines; the one-time marker written when the run was not complete.
3. #2/#3: `placementHint` on legacy / catalog-renamed paths (no prefix, year folder) and `_NN` suffixes — can a correctly placed fresh promote ever "follow" and drop month/day precision? A conflict message produced for a file Promote then reports as adopted.
4. #4: a Review path that changes `proposedDate` without setting the source (catalog-rename follow, plan reload), leaving a stale `.fromCopy` / `.typed`.

EVIDENCE (M4, Debug; a Gauntlet Release build ran on the same machine): after the merge, the affected suites by SUITE: 1209 tests in 210 suites, 1 issue — the index-lock inventory sensor, fixed in 74911295 (6/6 green). ArchiveAngelVocabularyTests now green (2a0909b6). The Angel run (94 suites, 518 tests) had one timing sensor (A4 determinism, 0.3 s) over under load; it passed alone 5/5.

OUTPUT (stdout, Markdown, under 400 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / merge-after-fixes / hold`
then findings, each with file:line, a concrete counterexample, and the test that would pin it. Do not explore outside these files.
