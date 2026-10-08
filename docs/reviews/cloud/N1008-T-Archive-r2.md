Brief: N1008-T-Archive (second pass) | Source: main@4873c46 | Wall clock: ~25 | Files read: 9
Finding count: 1 (REAL 1 / NEEDS-MAC 0 / NOISE 0)
Verdict: The Archive code added since 10-06 arrived well tested: the new "identical bytes already archived" promote refusal has red-on-revert tests for every edge, and the CopyFamilyAssessor split was pinned before it moved. One gap: the new Audit store treats a damaged or future-version sidecar as empty and saves over it, and its only test pins that behaviour as correct.

## Why a second pass
This row already ran on 10-06 (`N1008-T-Archive.md`, on main). Merge `c313f32a` pinned its 10 guards, "each shown red by mutation". Rick asked for the row again on 10-08, so this pass covers the **Archive code changed since** (`c86b926..4873c46`) and does not re-map the first report's guards. Those were pinned and mutation-tested on the Mac, which a Linux session cannot redo.

**Changed in range (`Archive/`):**
- `ArchiveAuditStore` (new), `ArchiveAuditYear` (new), `ArchiveAuditYearSheet`, `ArchiveView+AuditYear`, `ArchiveOccasion`, `ArchiveOccasionCueView`, `ArchiveDecadeRibbon`
- `ArchiveTimelineModel`, `ArchiveView+Timeline/Table`, `ArchiveReadiness`
- `CopyFamilyAssessor` (the #281 split)
- `VideoScanModel+MasterArchive` (the digest-index "already archived" leg)

**Read:**
- `ArchiveAuditStore.swift` (all of it)
- `ArchiveView+AuditYear.swift` (`persistArchiveAudit`, `loadArchiveAuditIfNeeded`)
- the `VideoScanModel+MasterArchive` diff
- `ArchiveAuditYearTests.swift` (the store tests)
- `PromoteDuplicateRefusalTests.swift`
- the commit list for `CopyFamilyAssessor`

**Callers followed:** every `isArchived(` caller in the app target (to recheck N1016-F2) and every `archiveAuditTag` / `archiveAuditKeepBoth` caller.

## New code: guard → test

| Guard (new since 10-06) | Test that goes red if it is deleted | Verdict |
|---|---|---|
| `identicalArchivedCopy`: a source whose stored sha256 equals an archive copy's verified digest is refused at plan time (`.alreadyPromoted`) | `PromoteDuplicateRefusalTests.anUnlinkedSiblingWithTheArchivedDigestIsRefusedAtPlanTime`, `.requestPromoteThenTheJobWritesNothingAndKeepsOneCopy` | Pinned |
| …but only while the stored fingerprint still names the file (`fingerprintStillNamesFile`) | `.aFingerprintWhoseFileHasSinceChangedIsNotRefusedAtPlanTime` | Pinned |
| …and only on equal byte counts | `.aDigestWhoseByteCountDisagreesWithTheCopyIsNotTrusted` | Pinned |
| …never matching the archive copy against itself | `.theArchiveCopyItselfIsStillRefusedAsACopyNotAsItsOwnDuplicate` | Pinned |
| The digest leg is an index lookup, not an O(records) walk | `.theDigestLegStaysAnIndexLookupOverALargeCatalog` (scale) | Pinned |
| Every promote entry point goes through the preflight | `.everyPromoteEntryPointGoesThroughTheDuplicatePreflight` (source sensor that matches function bodies, not comments) | Pinned |
| The To-do view never offers what the plan refuses | `.theToDoViewDoesNotOfferWhatThePlanRefuses` | Pinned |
| `CopyFamilyAssessor.assess` split, 57 → 10 | Guards pinned **before** the split (`32b69963`); suites `CopyFamilyAssessorTests`, `CopyFamilyGuardTests` and `CopyFamilyExternalLineageTests` | Pinned |
| Audit store: the test host never writes Rick's real sidecar | `ArchiveAuditYearTests.defaultDirectoryIsScratchUnderATestHost` | Pinned (isolation) |
| Audit store: a damaged or future-version sidecar is **not overwritten** | none (see F1) | **Unpinned, and the guard is missing** |

**N1016-F2 recheck:** the Angel promoter no longer calls `isArchived`. Every remaining caller is display or analysis: `ArchiveHomeState`, `ArchiveView`, `FamilyMusicShelf`, `CatalogShowingSummary`, `CatalogSizeTotals`, `CatalogContent+Promote` (offer gating), `PersonVideosSection`, and `PerceptualFingerprints` (analysis). `isArchived` now also returns true through `identicalArchivedCopy`, without the stamp check that the refusal path applies. That is acceptable only while no destructive path reads it. A sensor pinning "no destructive caller of `isArchived`" would keep it that way; it is backlog, not counted.

## Finding

### N1008-T-Archive-r2-F1 — P2 · REAL · The Audit store reads a damaged or future-version sidecar as empty and the next tag or "keep both" saves over it; the only test pins the empty start as correct
- **Symbols:**
  - `ArchiveAuditStore.loadOffMain` — Archive/ArchiveAuditStore.swift:229-241. A decode failure or `storeVersion != 1` returns nil.
  - `loadIfNeeded` (:212-216): with nil, memory stays empty and `isLoaded = true`.
  - `persistArchiveAudit` (Archive/ArchiveView+AuditYear.swift:135-140) calls `store.save()` after every tag or decision.
  - `saveOffMain` (:243-256) writes the whole in-memory file over the old one through `AtomicFilePublish`. Atomic, but **total**: no backup, no refusal.
- **Why it is curated data:** occasion tags ("Christmas", "Trip", or a word Rick typed) and "these are different, keep both" rulings are Rick's own hand gestures. The header calls an empty start "the safe failure" for decisions (over-reporting repeats). For **tags** it is a loss: the tags are erased, not just shown again.
- **Scenario:**
  1. A newer build on the M5 Ultra writes `archive-audit.json` with `storeVersion: 2`. The file is in App Support, which is migrated or synced with the user's data.
  2. The older build on the M4 loads it, sees version 2, and starts empty. It logs one line.
  3. Rick tags one card. The save writes `{version 1, one tag}` over the version-2 file. Every earlier tag and decision is gone, on both Macs, the next time the file travels.
  4. The same happens with a file truncated by a crash or a disk-full write.
- **Test status:** `ArchiveAuditYearTests.poisonedSidecarStartsEmpty` (:203-217) asserts only the load half (empty in memory). Nothing asserts that the file is still there after the next save, so the overwrite ships green. That test will need updating on purpose when this is fixed.
- **Same bug class, sixth time:** N1009-F1 (identity rulings), N1012-F2 (photo "not of" sidecar), N1020-F1 and F4 (validation labels, holdout-clear store), N1013-F2 (bookmarks). The store's header says "Shape follows IgnoredContentStore / HoldoutClearStore", and N1020-F4 flagged HoldoutClearStore for exactly this. **The pattern is spreading by copy.** N1013's top refactor (one shared helper for saving hand-curated JSON files) and the playbook's job 9 (`docs/practices/swift_playbook.md`) are the cure. This store should move onto that helper, not be patched alone.
- **Pinning test (add to `ArchiveAuditYearTests`):**
  1. Write a version-99 file (or a truncated one).
  2. `loadIfNeeded()`, then `setTag(…)`, then `await save()`.
  3. Expect the original bytes to be preserved: either the save refuses and reports it, or the damaged file is first set aside as `archive-audit.json.damaged-<stamp>`.
  4. Today the original bytes are replaced by a one-tag file.
- **Secondary (same fix, not counted):** `persistArchiveAudit` does not wait for `isLoaded`. A tag made while the first load is still in flight saves partial state, then the load result replaces memory. The window is tiny (a small file, loaded when the tab appears), and the shared helper's load-then-mutate contract would close it.

## Not covered
- **First-pass guards:** not re-verified by mutation (Mac only). `c313f32a`'s commit states each was shown red by mutation.
- **New UI files not read:** `ArchiveDecadeRibbon`, `ArchiveOccasionCueView`, `ArchiveAuditYearSheet` layout. The five-dimension check on them is for the local `testing` agent.
- **Audit-store size cap:** the `maxEntries` drop-oldest cap (50,000) has no test. Low risk; human gestures stay in the hundreds.
- Nothing was built or run.
