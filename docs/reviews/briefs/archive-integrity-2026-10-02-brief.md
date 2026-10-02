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
