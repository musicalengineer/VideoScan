# Codex review — Archive integrity #219 #190 #167 #109

- Range: `main..review/archive-integrity-2026-10-02`
- Credits spent: unavailable
- Tokens: 65695
- Finding count: 8
- Verdict: fix — adoption, designation persistence, and overlap guards still have bypasses; Verify and logging also need corrections.
- Run: 2026-10-02T19:12:15Z (cycle #27, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 8
Verdict: fix — adoption, designation persistence, and overlap guards still have bypasses; Verify and logging also need corrections.

Ranked by data-loss and archive-truth risk:

1. **P1 — A lying stored digest can make Promote adopt different bytes.** [PromoteToArchiveJob+Steps.swift:665](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/PromoteToArchiveJob+Steps.swift:665)

   `chooseDestinationOffMain` compares an existing destination against cached `knownSourceSHA`. Adoption then skips `copyVerifyPublish`, bypassing the source-byte reproof.

   **Reproduction:** create source A and different, same-size B at A’s planned base destination, with no manifest/catalog entry for B. Assign A a fresh stamp-bound `ContentFixity` containing SHA(B). Promote reports `.adopted` and registers B as A’s archive copy.

   Add this case beside `lyingFixityRefusedThenHonestLands`; these assertions fail:

   ```swift
   #expect(H.outcome(job, a.id)?.kind != .adopted)
   #expect(model.masterArchiveCopy(of: a)?.archiveFixity?.digest != shaB)
   ```

   Adoption must prove the current source bytes match the existing copy before journaling or registration.

2. **P1 — The first designation can be persisted, then removed without Clear.** [CatalogStore.swift:1431](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Catalog/CatalogStore.swift:1431)

   The guard checks only `persistedMasterArchive`, which remains nil until an async write’s main-actor completion. A subsequent synchronous nil save passes its precondition, waits behind the designated write, and overwrites it.

   **Red test:** using the existing scratch/designation helpers:

   ```swift
   @Test @MainActor
   func pendingFirstDesignationCannotBeLost() async throws {
       let dir = scratch("pending")
       defer { try? FileManager.default.removeItem(at: dir) }
       let store = CatalogStore(directory: dir)
       let d = designation(under: dir)

       store.testWriteDelay = 0.2
       store.masterArchive = d
       store.saveAsync(records: [])
       store.masterArchive = nil // no Clear

       #expect(!store.saveNow(records: []))
       try await Task.sleep(nanoseconds: 600_000_000)
       #expect(reread(dir) == d)
   }
   ```

   Current behavior: `saveNow` succeeds and disk carries nil. Existing `outOfOrderCompletion` seeds a durable designation first, missing this window. Include accepted pending writes in the guard’s baseline.

3. **P1 — Symlink followed by `..` bypasses the shared overlap guard.** [RelocatePathGuard.swift:92](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/MediaOps/RelocatePathGuard.swift:92)

   Standardization collapses `..` before `realpath` follows symlinks, changing filesystem meaning.

   **Reproduction:** create sibling directories `source` and `other`, with `other/alias → source/sub`. Destination `other/alias/..` physically equals `source`; the guard checks `other` and allows it.

   ```swift
   #expect(RelocatePathGuard.refusal(
       source: source.path,
       destination: alias.path + "/.."
   ) == .identical)
   ```

   Current result is nil. Enqueue, start, and preview share this resolver. The runner preserves the original destination spelling through reconciliation and path rewriting. Resolve existing symlink prefixes before collapsing parent components.

4. **P2 — Digest-mismatch refusal occurs after archive mutations.** [PromoteToArchiveJob+Steps.swift:314](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/PromoteToArchiveJob+Steps.swift:314), [ArchivePromoteEngine.swift:429](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/ArchivePromoteEngine.swift:429)

   Promote appends `.intent`, creates destination directories and a partial, and copies the entire source before checking `expectedSourceSHA` at engine line 456. Partial cleanup leaves the journal and new directories.

   **Reproduction:** extend `lyingFixityRefusedThenHonestLands` to snapshot journal bytes/existence and archive directories before the run, then assert equality afterward. Those assertions fail. Publication is prevented, but the requested ARCH-7 pre-intent/zero-byte guarantee is not met.

5. **P2 — Verify misses disagreement with the copy’s current placement.** [VerifyArchiveCopiesJob.swift:469](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/VerifyArchiveCopiesJob.swift:469)

   After a record-ID/source-ID fallback match, the sensor receives `row.relPath`, comparing the manifest’s placement against itself.

   **Reproduction:** construct a synthetic manifest row filed under year 2001; give its matching catalog record `userDate = "2001"` but a current path under year 2002. `collectPlan` returns zero date disagreements.

   A pure synthetic red test should assert:

   ```swift
   #expect(plan.dateDisagreements.count == 1)
   ```

   Compare against the record’s current relative path.

6. **P3 — Verify falsely flags agreeing dates with different precision.** [ArchiveDateAgreement.swift:125](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/ArchiveDateAgreement.swift:125)

   Placement/index comparison uses exact inequality instead of the specified coarser-precision agreement.

   ```swift
   #expect(ArchiveDateAgreement.problems(
       relPath: "30_Video/2000-2009/2001/2001-02-03_test_clip.mov",
       manifestDate: "2001-xx-xx",
       userDate: "2001",
       filedDate: "2001-02-03"
   ).isEmpty)
   ```

   This currently reports a disagreement. Use `agree` for that comparison.

7. **P2 — New persistent logs expose media paths and identifying filenames.**

   Relevant sites: [RelocatePathGuard.swift:152](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/MediaOps/RelocatePathGuard.swift:152), [CatalogStore.swift:1438](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Catalog/CatalogStore.swift:1438), [MasterArchiveReadoption.swift:67](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/MasterArchiveReadoption.swift:67), [PromoteToArchiveJob+Steps.swift:837](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/PromoteToArchiveJob+Steps.swift:837).

   **Reproduction:** use a synthetic folder/filename containing `PRIVATE_SUBJECT_SENTINEL`, then trigger overlap refusal, designation auditing, readoption, or duplicate refusal. Persistent lines contain the sentinel and raw paths/names; several use public unified-log interpolation. Digest-mismatch errors also propagate the full source path.

   Keep identifying details in the UI; persistent logs can carry operation IDs, counts, digest prefixes, refusal codes, and corrective actions. `auditLines` currently explicitly requires raw target paths, pinning the leakage.

8. **P2 — Verify’s disagreement log is unbounded.** [VerifyArchiveCopiesJob.swift:866](/Users/rickb/dev/VideoScan/.claude/worktrees/archive-integrity/VideoScan/VideoScan/Archive/VerifyArchiveCopiesJob.swift:866)

   The console caps its sample at 20; `appLog` joins every disagreement.

   **Reproduction:** run Verify with the existing 100k-record sensor shape containing 50k disagreements. One persistent message contains all 50k filename-bearing entries. Add a bounded-message assertion and retain the total count.

The six named test files provide substantial coverage, but the supplied green runs and mutation results do not exercise these seams:

| Invariant | Coverage read | Remaining gaps |
|---|---|---|
| ARCH-7 | Date/duplicate/poisoned-index refusals; lying-fixity test | Complete journal/tree/catalog immutability on mismatch |
| ARCH-13 | Cross-run, batch, concurrent jobs, fixity/index legs, five-container matrix, 100k index budget | Lying-digest adoption; deterministic cancellation/release; end-to-end duplicate sensor uses only five unique sources |
| #219 | Agreement rules, four-way Promote checks, Verify sensor and 100k budget | Current-path fallback; mixed placement/index precision |
| #167 | All save paths, explicit Clear, reader/OCC/`.prev` isolation, readoption confirmation, 100k refusal budget | First designation pending; privacy assertions; 100k reader budget |
| #109 | Symlinks, firmlinks, case variants, nesting, simulated volume aliases | Symlink-plus-`..`; behavioral start-time alias change and preview refusal |
| Claims/locks | Concurrent duplicate jobs; release after lying-fixity failure | Deterministic cancellation and destination-selection failure sensors |

Claim acquisition is atomic on the main actor; ordinary pre-publication failures/cancellations release through `defer`. Index loading and hashing use off-main entry points. No additional deadlock or claim-leak finding.

Per-file disposition for clean files:

- `ArchiveDigestIndex.swift` — **read, no findings**.
- `PromoteToArchiveJob.swift` — **read, no independent findings**; logging propagation covered above.
- `PersonFinderCatalogFilter.swift` — **read, no findings**.
- `VideoScanModel.swift` — **read, no findings**.
- `ArchiveView.swift` — **read, no findings**.
- `VideoScanModel+RelocateQueue.swift` — **read, no independent findings**; shared resolver affected.
- `VideoScanModel+Relocate.swift` — **read, no independent findings**; shared resolver affected.
- `RelocateSheet.swift` — **read, no independent findings**; shared resolver affected.
- `docs/practices/invariants/Archive.md` — **read, no findings**.
- `PromoteArchiveIntegrityTests.swift` — **read, no independent findings**; coverage gaps above.
- `PromoteArchiveIntegrityRuleTests.swift` — **read, no independent findings**; coverage gaps above.
- `MasterArchiveDesignationReloadTests.swift` — **read, no findings**.
- `MasterArchiveDesignationGuardTests.swift` — **read**; privacy assertion covered by finding 7.
- `RelocateSourceDestGuardTests.swift` — **read, no independent findings**; coverage gaps above.
- `RelocateIntegrationTests.swift` — **read, no findings**.

Remaining scoped files were read and are cited in findings above; `CatalogWriteError.swift` and `VideoScanModel+MasterArchive.swift` also participate in finding 7.

No files changed or Swift suites rerun: this session’s sandbox is read-only. Your supplied test results remain prior evidence. Exact credit-spend telemetry is unavailable.

## Brief

Scoped data-risk pass — archive integrity bundle (GH #219, #190, #167, #109), 2026-10-02. Range main..review/archive-integrity-2026-10-02 (two fix branches merged: fix/promote-archive-integrity-219-190 6dfae767..d9d0f2cf and fix/167-109-designation-and-migrate-guards e1d0a272..de379fd3).

Files in scope (do not explore outside these; named callers are for reading only):
- VideoScan/VideoScan/Archive/PromoteToArchiveJob+Steps.swift — copyOrAdopt (claim/release/landed), dateRefusal, recordDateRefusal, claimSourceDigest, DigestClaim, duplicateRefusal, trustedSourceDigestOffMain, hashSourceOffMain, finishPublished, chooseDestinationOffMain, copyOffMain
- VideoScan/VideoScan/Archive/PromoteToArchiveJob.swift — run() (index load/refusal), archiveDigests
- VideoScan/VideoScan/Archive/ArchiveDigestIndex.swift (new) — parse, isLexicallyContained, load, addArchiveCopies; VideoScanModel claimPromoteDigest / notePromotedDigest / releasePromoteDigest
- VideoScan/VideoScan/Archive/ArchiveDateAgreement.swift (new) — agree, catalogClaim, promoteRefusal, problems
- VideoScan/VideoScan/Archive/ArchivePromoteEngine.swift — copyVerifyPublish (expectedSourceSHA)
- VideoScan/VideoScan/Archive/VerifyArchiveCopiesJob.swift — VerifyArchiveManifestIndex.parse (recordDate), collectPlan, run, finishRun, summaryLine
- VideoScan/VideoScan/Catalog/CatalogStore.swift — readRecordsWithoutAdopting, writePrecondition, finishWrite, asyncSaveDidFinish, saveNow, saveAsync, saveAcknowledged, load, authorizeDesignationClear, designationLossRefusal, noteDesignationWriteStart
- VideoScan/VideoScan/Catalog/CatalogWriteError.swift — designationLossRefused
- VideoScan/VideoScan/People/PersonFinderCatalogFilter.swift — pfCatalogSkipSet, pfPersonScanSkipResult
- VideoScan/VideoScan/Archive/VideoScanModel+MasterArchive.swift — clearMasterArchive, installDesignationAuditSink
- VideoScan/VideoScan/Model/VideoScanModel.swift — init, catalogStore didSet, promoteDigestClaims
- VideoScan/VideoScan/Archive/MasterArchiveReadoption.swift — findReadoptionCandidates, findMasterArchivesAwaitingReadoption, offerReadoptMasterArchive, manifestDataRows
- VideoScan/VideoScan/Archive/ArchiveView.swift — masterArchivePanel
- VideoScan/VideoScan/MediaOps/RelocatePathGuard.swift — refusal, liveLocation, refuseOverlappingMigrate
- VideoScan/VideoScan/MediaOps/VideoScanModel+RelocateQueue.swift — enqueueRelocate
- VideoScan/VideoScan/MediaOps/VideoScanModel+Relocate.swift — runRelocate(jobID:)
- VideoScan/VideoScan/MediaOps/RelocateSheet.swift — destinationProblem, runPreview
- docs/practices/invariants/Archive.md (ARCH-6 amended, ARCH-7, ARCH-13 new)
- Tests: VideoScan/VideoScanTests/PromoteArchiveIntegrityTests.swift, PromoteArchiveIntegrityRuleTests.swift, MasterArchiveDesignationReloadTests.swift, MasterArchiveDesignationGuardTests.swift, RelocateSourceDestGuardTests.swift, RelocateIntegrationTests.swift

Invariants to attack (rank by data-loss / archive-truth risk):
1. ARCH-7: every Promote refusal (date contradiction, duplicate digest, unreadable/poisoned index, digest mismatch at publish) happens before the journal intent and writes zero bytes to the archive, manifest or catalog.
2. ARCH-13 / #190: identical bytes never land twice — across runs (manifest + in-root archiveFixity), within one batch, and across concurrent Promote jobs (claim table). A lying stored fixity or a source changed after hashing can never publish under the checked digest. Out-of-root or malformed manifest rows never become trusted index entries.
3. #219: the archived copy's folder/filename date, manifest record_date and catalog date agree at the coarser precision, or Promote refuses; the Verify sensor flags (never rewrites) disagreement.
4. #167: a Master Archive designation is never removed from disk without an explicit Clear; nothing is designated without Rick confirming (re-adopt only offers); a refused save writes zero bytes; no reader path (Person Finder or other) resets session state, adopts a foreign generation without merge, or rotates catalog.json.prev.
5. #109: Migrate/Reconcile-preview never runs with overlapping source and destination — identical, symlinked alias, firmlink spelling, case variants, same volume under different names, nested either way; the guard holds in the job layer at enqueue and at start.
6. Claims/locks: no deadlock, leak or main-thread blocking (index load and hashing must be off-main); claim release on every failure/cancel path.

Known and accepted (do not report): claims persist until relaunch (a file renamed by Update… or removed by hand in the same session can be refused falsely — safe direction); one extra full read for sources without a trusted digest; saves stay refused for the session after a designation-loss refusal until Rick re-initializes or clears; the older-build field-stripping class (catalog schema version) is a pending decision for Rick.

Evidence already run (Debug, by suite, counts confirmed): Promote branch — red 13 tests / 9 failing on main; green 43 / 7 suites; 188 Archive/MasterArchive/Promote/VerifyArchive/ArchiveAngel suites 1045 tests, 0 failures; 9 mutations each killed. #167/#109 branch — red 4/5 and 6/7; green 30 tests / 7 suites; 294 Catalog/Volumes/Archive/MasterArchive/Relocate suites 1784 + 53 XCTest; 9/9 mutations killed.

Also check, per Rick's standing directive: new-code test coverage of each invariant (name gaps vs tests run) and logging (actionable START/OUTCOME, no flooding, no person names or full paths of family media in logs).

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: findings with file:line + a concrete reproduction (ideally a Swift Testing red test with synthetic data), and "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Closure (2026-10-02, bug-fix agent, branch `review/archive-integrity-2026-10-02`)

Every finding fixed red-first (codex's red test where it drafted one), Debug, own
`-derivedDataPath`, suites filtered by SUITE (counts confirmed). Each fix was
mutation-checked: the fix was reverted textually, the pinning test went red, then restored.

| # | Sev | Finding | Fix SHA | Pinning test(s) | Red → green | Mutations (all killed) |
|---|-----|---------|---------|-----------------|-------------|------------------------|
| 1 | P1 | Adoption trusted a stored digest | `c404771f` | `PromoteAdoptionProofTests.lyingDigestCannotAdoptDifferentBytes` (+ `honestDigestStillAdopts`, `noDigestDifferentBytesCopiedBeside` controls) | 7 issues → 17 tests / 3 suites | proof branch disabled → 7 issues |
| 2 | P1 | First designation lost to a pending async write | `ea366c34` | `MasterArchiveDesignationGuardTests.pendingFirstDesignationCannotBeLost` (codex's test) + `pendingFirstDesignationThenClearLands` | 2 issues → 20 tests / 4 suites | baseline = persisted only → 2 issues |
| 3 | P1 | Symlink + `..` bypass of the overlap guard | `b7ffd5cd` | `RelocateSourceDestGuardTests.symlinkThenDotDotIsPhysical`, `symlinkLoopRefused`, `danglingSymlinkIntoSourceRefused`, `unsearchableFolderRefused` | 4 issues → green (combined run) | lexical standardize → 1; errno guard dropped → EACCES test red; dangling check dropped → 2 |
| 4 | P2 | Digest-mismatch refusal after intent/dirs/partial | `1ab2274f` (proof before intent: `c404771f`) | `PromoteRefusalRollbackTests.lyingFixityLeavesNoTrace`, `sourceChangedMidCopyRollsBack`, `engineRemovesCreatedFolders`, `engineKeepsPreexistingFolders`, 3 journal-retraction contract tests | 2 issues → 35 tests / 4 suites | no folder rollback → 2; no intent retraction → 1; retract without tail check → 2; pre-intent proof disabled → 1 |
| 5 | P2 | Verify sensor compared the row with itself after a fallback match | `18f6905d` | `VerifyDateSensorReviewTests.fallbackMatchUsesCurrentPath` | 2 issues → 32 tests / 6 suites | `row.relPath` as placement → 2 |
| 6 | P3 | Placement vs index used exact equality | `18f6905d` | `VerifyDateSensorReviewTests.placementVersusIndexUsesCoarserPrecision` (codex's assertion), `exactMatchAgreeing` | 2 issues (incl. control) → green | exact equality → 2 |
| 7 | P2 | Raw paths / filenames in persistent logs | `d7420941` | `ArchiveLogPrivacyTests` (4 tests, PRIVATE_SUBJECT_SENTINEL; catalog.log + appLog + write journal + unified log via `log show`), `MasterArchiveDesignationGuardTests.auditLines` (now requires the volume UUID, forbids the path) | 4/4 leaking (6 issues) → 59 tests / 9 suites | overlap message; designation describe; readoption rootPath; refusal detail in appLog; CHECK os_log filename → each 1 |
| 8 | P2 | Verify disagreement log unbounded | `3324cb95` | `VerifyDisagreementLogBoundTests.boundedAt50k`, `realRunBounded` | 6 issues → 7 tests / 2 suites | sample = whole list → 4 |

Coverage gaps codex named, now pinned (`1ab2274f`):
- Deterministic cancellation and claim release: `PromoteRefusalRollbackTests.deterministicCancelReleasesClaim`
  (cancel at a fixed seam after claim+proof; claim released, archive snapshot unchanged, a later run lands).
- End-to-end duplicate sensor with more than five sources: `duplicateSensorTwelveSources`
  (18 records, 12 distinct digests, twins and a triplet, three mixed batches → 12 files, 12 rows, no digest twice).

Follow-up commit `ff6b0764` (pure moves for file length, run() complexity, ARCH-7/ARCH-13 text) also
restores `PromoteBeginLineSensorTests`' anchor, which my own F4 extraction had broken (`model?.log`)
from `1ab2274f` until then.

Combined run at `ff6b0764` (Debug, by suite): **838 Swift Testing tests in 150 suites + 48 XCTest,
0 failures**: PromoteArchiveIntegrity*, MasterArchive* (designation guard/reload/readoption/hardening/
promote/logic/scale), RelocateSourceDestGuard / PathGuardIdentity / PathGuardSensor, RelocateIntegration,
RelocateReconcile(+PlanMapping), VerifyArchive* (logic/race/matrix/scale/isolation), all ArchiveAngel*
suites, the catalog-store suites, and the new review suites.

Log-format note: #7 changes message CONTENT only. Paths, destinations and line structure are unchanged
and START / OUTCOME / REFUSED prefixes stay.

Declined / not in scope (for Rick):
- Other pre-existing persistent lines still name files or paths: Promote BEGIN/DONE/adopted/skipped/
  FAILED (generic failures), archive-lock lines, Initialize / rehome lines, Migrate per-file lines,
  Verify MISMATCH/MISSING/NOT LOCKED lines, and the 20-entry Verify DATE DISAGREES sample (#8 asked for
  the sample). These are outside the five categories #7 named and are durable forensics Rick relies on,
  so whether they change is his call.
- The proof read means a non-duplicate source with a trusted stored fixity is now read twice (proof +
  copy) where it used to be read once. A stored fixity that disagrees with unchanged-stamp bytes is
  refused every run until the source is re-fingerprinted (refuse over guess).

## Closed

Closed by `28efad09` at 2026-10-02T20:28:22Z.
