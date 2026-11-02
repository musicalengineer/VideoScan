# Codex review — Family Tree read-only without the archive — closing

- Range: `19772fd9..feat/family-tree-readonly`
- Credits spent: unavailable
- Tokens: 187411
- Finding count: 4
- Verdict: block — revocation can still permit compiled-store, photo, and CyberBrain writes; F2 is not closed.
- Run: 2026-11-02T01:44:11Z (cycle #192, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: block — revocation can still permit compiled-store, photo, and CyberBrain writes; F2 is not closed.

Reviewed `19772fd9..716576ae`; worktree HEAD matches `716576ae`. No files changed or scope expansion. **The regression recipes below are source-supported, not executed:** both SwiftPM and Xcode stopped before running tests because the read-only sandbox denied required filesystem access.

1. **P1 — The compiled-store guard expires before compilation and promotion.**  
   [FamilyGraphCompiledStore.swift:712](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:712)

   `writesRefused` is checked before acquiring the lock. `ingestLocked` subsequently hashes, compiles, verifies, writes the manifest and sidecars, replaces the pointer, and prunes generations without checking again. Revocation during compilation therefore still permits promotion and removal of older generations. Lock-waiting rollback/repoint/adopt operations have the same entry-only check.

   **Proposed RED:** extend `FamilyGraphCompiledStoreWriteGuardTests` using its existing `Flag`. Revoke inside `store.verify`, then run the original verifier:
   ```swift
   let verify = store.verify
   store.verify = { decoded, source in
       flag.revoke()
       return verify(decoded, source)
   }
   XCTAssertNil(store.ingest(graph: graph, sources: [ged]))
   ```
   The implementation returns a promoted graph. Also assert byte identity from the verification-time revocation onward. Existing tests revoke **before** calling `ingest`, missing this window.

2. **P1 — Ordinary loads and merge-base loads still receive an unguarded compiled store.**  
   [FamilyTreeLiveModel.swift:746](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:746), [FamilySearchPullCoordinator.swift:700](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilySearchPullCoordinator.swift:700)

   Only explicit recompiles install `writeGuard`. A full-mode load already running when access changes can continue reading archive sources and invoke `parseAndPromote`, repoint/adopt, or writable overlay retirement. `loadGeneration` prevents stale installation; it cannot prevent those disk changes. The merge’s new staging gate runs **after** its potentially promoting base load.

   **Proposed RED:** prepare a valid compiled generation and a newer, distinct GEDCOM. In the supplied store’s first source-hash log callback, publish `.unavailable` and snapshot the fixture. Await `model.loadFromDisk()`. The newer GEDCOM is still parsed and promoted; the snapshot changes.

   A second deterministic case queues `installMerged()`, revokes before yielding the main actor, and supplies an empty compiled store with a valid base GEDCOM. Its base load compiles before `stageMerge` refuses.

   The exemption at [FamilyTreeReadOnlyWriteSiteSensorTests.swift:101](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScanTests/FamilyTreeReadOnlyWriteSiteSensorTests.swift:101) does not hold across revocation: the loader’s `readOnly` value was established earlier.

3. **P1 — The captured CyberBrain recorder bypasses the model’s live authority.**  
   [FamilyTreeLiveModel.swift:1999](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:1999)

   The closure retains the original mode and viewer centre. Its later `.current(viewer: center)` reads the **shared** configuration centre, ignoring the model’s injected `configurationCenter` and `accessLatch`. Consequently, `writeAuthority.mode` can refuse while this recorder still writes.

   **Proposed RED:** create a full-mode model with an isolated configuration centre and CyberBrain root; capture `cyberBrainRecorder()`; revoke the injected centre while leaving shared state unchanged; invoke the recorder. Assert a refusal and unchanged CyberBrain bytes. Both assertions fail by this path. Repeat with `configure(source: .unavailable)` to exercise the latch.

   Capture and consult `writeAuthority` at invocation. The isolation suite currently captures the recorder only after entering read-only mode.

4. **P1 — A live photo store can write the image before its later check refuses.**  
   [FamilyAssetStore.swift:1562](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyAssetStore.swift:1562)

   `choosePhoto` checks access before validation. Its subsequent `writePersonPhotoData` performs `openat(O_CREAT)` and writes without rechecking. `recordPhotoChoice` finally checks again, but the image already exists on the rejected archive.

   **Proposed RED:** obtain `centre.makeLiveStore()`, supply valid image bytes, and set `store.importClock` to publish the archive as unavailable and capture a snapshot. Call `choosePhoto` without `chosenAt`. It throws from the later choice-recording check, yet leaves a new portrait file. Assert byte identity at revocation to expose it.

   The new live-store test checks revocation before entering the writer; it does not exercise this gap.

The scoped files below were read with no additional findings:

| File | Result |
|---|---|
| `FamilyTreeWriteGate.swift` | read, no findings |
| `FamilyTreeReadOnlyLoad.swift` | read, no findings |
| `FamilyTreeWalkCenter.swift` | read, no findings |
| `FamilySearchPersonRefreshCoordinator.swift` | read, no findings |
| `FamilySearchPersonRefresh.swift` | read, no findings |
| `FamilyTreeRecompileCenter.swift` | read, no findings |
| `ResearchStore.swift` | read, no findings |
| `RecordFinderFiling.swift` | read, no findings |
| `TreeIdentityCenter.swift` | read, no findings |
| `PersonOfTheDayCenter.swift` | read, no findings |
| `CouplePortrait.swift` | read, no findings |
| `FamilyTreeView.swift` | read, no findings |
| `FamilyTreeCards.swift` | read, no findings |
| `FamilyGraphFileLoader.swift` | read, no findings |
| `RemoteViewerMode.swift` | read, no findings |
| `VideoScanModel+FamilyAssets.swift` | read, no findings |
| `CatalogSync.swift` | read, no findings |
| `FamilyTreeLiveModel+Summaries.swift` | read, no findings |
| `FamilyTreeDocumentsUI.swift` | read, no findings |
| `RecordFinderFoundSheet.swift` | read, no findings |
| `FamilyTreePullDates.swift` | read, no findings |
| `FamilyTreeReadOnlyModeTests.swift` | read, no findings |
| `FamilyTreeReadOnlyIsolationTests.swift` | read, no findings |

`FamilyTreeReadOnlyRevocationTests.swift` and `FamilyGraphCompiledStoreWriteGuardTests.swift` were read; their missing revocation windows are identified above. `git diff --check` passed. **Tests executed in this review: 0.**

## Brief

# Codex review brief — Family Tree read-only when the Master Archive is absent

*Run: `python3 tools/codex_review.py --title "Family Tree read-only (archive absent / viewer)" --range 17de5518..f1da1bf5 --brief .scratch/briefs/codex-ft-readonly-2026-11-01.md`. The brief is not committed; the verdict and closure go in the PR or commit.*

**Workflow in one sentence (the user's words):** "why can't the user see the FT view in read-only mode from the M4?" — show the family tree from the local compiled graph when the Master Archive is not connected (offline or wrong UUID) or this Mac is a viewer, and change nothing anywhere while in that state (DECISIONS 2026-11-01, last line).

**Range:** `17de5518..f1da1bf5` on branch `feat/family-tree-readonly` · **Worktree:** `/Users/rickb/dev/VideoScan-wt/ft-readonly`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/FamilyTree/FamilyTreeWriteGate.swift` — `FamilyTreeAccessMode.resolve/current`, `FamilyTreeWriter`, `FamilyTreeWriteGate.check/refuse/refusalText`
- `VideoScan/VideoScan/FamilyTree/FamilyTreeReadOnlyLoad.swift` — `outcome(store:overlay:log:)`, `refusingWrites`
- `VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift` — `sourceAccess`/`viewerCenter` didSet, `refreshAccessMode`, `checkWrite`/`refusesWrite`, `performLoadFromDisk`, `performReadOnlyLoad`, `installReadOnly`, `loadNow`, `configure(source:)`, `installSteps` (walk trigger), `rebuildScene`, `refreshSelectedDocuments`, `refreshPullDates`, `refilterNow`/`hasRowsToShow`, and every writer: `addNote`, `correctNote`, `recordTestimony`, `cyberBrainRecorder`, `setPronunciation`, `toggleBookmark`, `setRecordHidden`, `recompile`, `removeDocument`, `revealOriginalsFolder`, `setPhotoOverride`
- `VideoScan/VideoScan/FamilyTree/FamilyTreeWalkCenter.swift` — `writeMode`, `treeDidChange`, `save`
- `VideoScan/VideoScan/FamilyTree/FamilySearchPersonRefreshCoordinator.swift` — `launch`, `apply`, `undoLast`
- `VideoScan/VideoScan/FamilyTree/FamilySearchPersonRefresh.swift` — `PersonRefreshOverlayReader.apply` (both overloads)
- `VideoScan/VideoScan/FamilyTree/FamilySearchPullCoordinator.swift` — `launch`, `installFromFile`, `install`, `installMerged`
- `VideoScan/VideoScan/FamilyTree/FamilyTreeRecompileCenter.swift` — `recompile` (path 2 gate)
- `VideoScan/VideoScan/FamilyTree/ResearchStore.swift`, `RecordFinderFiling.swift` (`fileLocked` gate), `TreeIdentityCenter.swift` (`gatedStore`, `autoAccept`), `PersonOfTheDayCenter.swift` (`PersonOfTheDayGatedStore`), `CouplePortrait.swift` (`saveCaption`, `importPhoto`, `remove`)
- `VideoScan/VideoScan/FamilyTree/FamilyTreeView.swift`, `FamilyTreeCards.swift` — banner, `writesEnabled`, the `guard model.isEnabled(...)` lines (UI only; the model refuses regardless)
- Context, read-only: `FamilyAssetStore.swift` (`FamilyAssetConfigurationCenter.configuration`, `requireWriteAccess`), `FamilyGraphFileLoader.swift` (`loadNewestOutcome`, `loadPromotedOnly`), `VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift` (`loadCurrent`, `usableManifest`, `repoint`, `refusesWrites`), `App/RemoteViewerMode.swift`, `FamilyTree/VideoScanModel+FamilyAssets.swift`, `Catalog/CatalogSync.swift` (`viewerRole`)
- Tests: `VideoScanTests/FamilyTreeReadOnlyModeTests.swift`, `FamilyTreeReadOnlyIsolationTests.swift`, `FamilyTreeReadOnlyWriteSiteSensorTests.swift`

**Invariants to attack** (docs/ARCHITECTURE.md §10.0 "Never lose media / rows never deleted", §10.8 "CyberBrain is written only through CyberBrainWriter"; §6 lists FamilyTree/ as data-risk):
1. **Nothing writes in the read-only state.** With access `.unavailable` (archive offline or wrong UUID) or on a viewer, find any path — load, appearance, selection, menu, sheet, background task (walk refresh, Person of the Day, identity auto-accept, overlay retirement, pronunciation default seeding, compiled-store rollback/repoint/adopt, pull-dates, recompile centre, Hallie's recompile chip) — that creates, renames, removes or rewrites a file under App Support/VideoScan/ (family-tree/, cyberbrain/, portrait/, POI/) or anywhere on the archive path, or that creates a directory on an unmounted `/Volumes/<archive>` mount point. The isolation test's fixture-byte-identity is the claim; show me a write it does not drive.
2. **Nothing on the absent archive is READ either, and nothing from a wrong-UUID volume is shown as fact.** In `.readOnly(.archiveUnavailable)` the load must not open the GEDCOM folder, rulings, bookmarks or pull files (a wrong-UUID volume is not the archive). Find a read that reaches `originalsDirectory` / `assetsRoot` in that state (e.g. `configure(source:)`'s `gedcomDirectory()` probe, `FamilyIdentityDecisions.load` in init, `PersonFactOverlayStore.newestPullDate`).
3. **The viewer role is detected the same way CatalogSync does.** `FamilyTreeAccessMode` reads `ViewerModeCenter` (installed once from `catalogSync.viewerRole` in VideoScanApp) — find a writer that decides "viewer?" another way, reads `.shared` where the model's injected `viewerCenter` disagrees, or a process where the role is installed after a model/centre cached its mode.
4. **The archive-back transition re-enables writers without a relaunch,** and the reverse transition disables them before the next write. Attack: a write in flight across the flip (a detached document read or a filer started while full, finishing after the archive went away; `cyberBrainRecorder` captures the mode at creation and re-reads `.current()` at the call — is that enough?); the walk centre's 2 s debounce (`treeDidChange` checks the mode at schedule time; `save` re-checks); `loadGeneration` superseding a read-only load with a full one and vice versa; a cached `FamilyGraphSharedCache` entry from the full session served after the flip.
5. **Every write site checks the access state** (`FamilyTreeReadOnlyWriteSiteSensorTests`): find a write the scanner's token list misses, an inventory `.exempt` whose reason is false, or a `.via` helper reachable from an ungated caller outside the listed ones.
6. **Read-only shows only verified facts.** The compiled generation is served with `trustsManifestSources = true` (the archive's sources cannot be re-hashed). Is that the same trust a viewer already extends, and can a stale or half-written generation be shown? (The manifest's own `verification` must be empty; the artifact must decode.)

**Evidence already run:** Debug, worktree DerivedData `/Users/rickb/dev/VideoScan-dd/ft-readonly`: new suites 15 tests in 6 suites passed; FamilyTree-related suites 732 tests in 97 suites passed; `scripts/run_sensors.sh` → `sensor lane GREEN (607 tests)` (stamp tree eacb39ee); gauntlet inventory `--validate` 0 errors. Red by mutation in the commit message (M1 old whole-tab refusal, M2 walk save ungated, M3 bookmark gate removed, M4 cards keep photos — each turns the named tests red).

**Known and accepted (do not report):**
- UI preferences in UserDefaults still save in read-only (sidebar visibility, canvas appearance, last focused person, roll-call play count, the People-tab highlight hand-off) — listed as `.exempt` in the sensor; not family data. Export line… writes only the file the user names in a save panel.
- In archive-absent read-only, identity rulings and bookmarks are not in force (they live on the archive): a record Rick hid as a duplicate shows. Accepted consequence of "nothing on the archive is read".
- Viewers no longer show synced People/ photos or documents in the tree (the ruling groups viewers with the archive-absent case; the banner says photos are unavailable). Flagged to Rick for a ruling.
- Hallie's own family-graph load (FamilyGraphSharedCache) still returns nil on `.unavailable`; out of scope.
- `CouplePortraitPreference.remove` unlinks its own derived copy (pre-existing; not changed here).

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside these files unless a finding requires it, and say so.

---

# Re-review delta — cycle #190 (BLOCK, 5 findings) → closing pass

*Run: `python3 tools/codex_review.py --title "Family Tree read-only — closing #190" --range 19772fd9..716576ae --brief .scratch/briefs/codex-ft-readonly-2026-11-01.md`. The branch was rebased onto main `bf947603` (the first commit is now `19772fd9`); review only the fix commit after it.*

**Closing brief (scope):** the fix commit only, the same files as above plus `FamilyTreeLiveModel+Summaries.swift` (pure move), `FamilyTreeDocumentsUI.swift`, `RecordFinderFoundSheet.swift`, `FamilyTreePullDates.swift`, `VideoScanCore/.../FamilyGraphCompiledStore.swift` (`writeGuard`), and the tests `FamilyTreeReadOnlyRevocationTests.swift`, `FamilyGraphCompiledStoreWriteGuardTests.swift`. Do not explore outside these files unless a finding needs it.

**What changed, per finding:**
1. **F1 (P0) rulings and bookmarks from a wrong-UUID or absent archive.** In ANY read-only mode (archive absent or viewer) identity rulings and bookmarks are empty: `init` doesn't read them when the source starts read-only; `refreshAccessMode` → `dropArchiveDerivedState()` empties them whenever the mode is read-only; `configure` loads them only in full mode. `FamilyAssetConfiguration.resolvedGEDCOMDirectory()` never lists an `.unavailable` archive; `init` and `configure` use it. Both read-only reasons now take ONE load (`FamilyTreeReadOnlyLoad`, compiled tree only); the viewer no longer goes through the ruled shared-cache path. Pins: `aWrongUUIDVolumesRulingAndBookmarkNeverReachTheReadOnlyTree` (production source resolution through the new `sourceConfiguration:` init seam, `.unavailable` from the start), `aViewerShowsNoRulingsAndNoBookmarks`, `anUnavailableArchiveIsNeverListedToResolveTheGEDCOMFolder` (FileManager spy), and a sensor check that `init` and `configure` contain no `.gedcomDirectory()`.
2. **F2 (P1) writers re-check at the moment of the write.**
   - `FamilyTreeWriteAuthority` = published configuration + CatalogSync role + the model's access (via a thread-safe latch); the strictest wins. It's read at each call and handed to detached work.
   - Core `FamilyGraphCompiledStore.writeGuard` is asked at every ingest / rollback / repoint / adopt. Both recompile paths set it.
   - The merge's staging step (`stageMerge`) and its activation (`abandonIfRevoked`) both re-ask. A revoked activation creates nothing and removes nothing. `cancel` in read-only leaves staging in place, and the sensor no longer exempts it.
   - Document removal (inside the detached move), walk save (inside the detached write), the person-refresh overlay write (`writeOverlay(mode:)`) and its journal, and record filing (`writeDocument` start) all re-check.
   - View-started asset-store writes use `FamilyAssetConfigurationCenter.makeLiveStore()`. Its `requireWriteAccess` re-reads the centre and refuses a different archive's roots.
   - Pins: snapshot-at-revocation byte-identity for the merge (with the mount point absent), cancel, both recompiles, document removal, refresh apply and filing; the live-store test; the Core guard tests; and the sensor `everyAsyncWriterRechecksAtTheMomentOfTheWrite`.
3. **F3 (P1) stale access.** `checkWrite` → `refreshAccessMode()` → `writeAuthority.mode` reads the published centre at call time. Pin: `aPublishedRevocationRefusesTheNextWriteWithoutReappearing`.
4. **F4 (P2) document reads.** Any mode change or source change clears the document caches and counts and bumps the generation. A landing read also checks the current mode. Pin: `aHeldListingReleasedAfterTheTransitionPublishesNothing` (the read is taken before the transition and published after it).
5. **F5 (P2) viewer pull dates.** Pull-date refresh is skipped in every read-only mode. Pin: `aViewerAppearanceNeverSearchesManifestSourceFolders` (a search-root observer, with a master-mode control showing the instrument sees).

**Attack these next:**
- (a) Anywhere `writeAuthority` / the live store is captured as a VALUE of the mode rather than re-read.
- (b) A record filing revoked AFTER its first write: its later steps refuse, and its existing undo then trashes the filed document. That's an undo of a write started under authority; is it acceptable?
- (c) The viewer's pre-existing synced rulings no longer apply anywhere in the tab (ruling: read-only → empty).
- (d) Hallie and the People tab still use `FamilyGraphSharedCache` (out of scope).

**Known and accepted, added:** the walk save's in-detached re-check has no test hook between the entry gate and the write (the entry gate already refuses a revocation that comes before `save`); it is pinned by the sensor only.

**Evidence (closing):** Debug, worktree DerivedData: FamilyTree-related suites 747 tests in 103 suites passed; read-only suites 30 tests in 12 suites; Core FamilyGraphCompiledStore* 7 XCTests; `sensor lane GREEN (619 tests)` (stamp tree 919761a2); inventory --validate 0 errors. Red-before-fix table and mutation table: commit 716576ae message.
