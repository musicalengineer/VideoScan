# Codex review — Family Tree read-only without the archive — closing 2

- Range: `716576ae..feat/family-tree-readonly`
- Credits spent: unavailable
- Tokens: 171897
- Finding count: 4
- Verdict: block — The closing commit still permits writes after revocation in the recorder, compiled store, overlay retirement, and photo-choice paths.
- Run: 2026-11-02T02:12:29Z (cycle #193, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: block — The closing commit still permits writes after revocation in the recorder, compiled store, overlay retirement, and photo-choice paths.

Reviewed `716576ae..7e9d93fc`. These are remaining gaps in the stated read-only invariant.

1. **P1 — The captured recorder checks before waiting for the CyberBrain lock.**  
   [FamilyTreeLiveModel.swift:2007](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:2007) calls `authority.check`, then enters `CyberBrainWriter.record`. That writer can block on `withRootLock`; after acquiring it, it creates directories, saves the archive, and rotates backups without consulting authority again.

   **Reproduction:** Hold the root lock, start the captured recorder while access is full, let it reach the lock, revoke access, snapshot the brain directory, then release the lock. The pending testimony writes after revocation.  
   **Proposed RED:** `aCapturedRecorderRevokedWhileWaitingForRootLockWritesNothing`. Pass the live guard into persistence and check it under the lock before mutation.

2. **P1 — Promotion guards do not cover artifact creation and cleanup.**  
   [FamilyGraphCompiledStore.swift:745](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift:745) writes `tree.vsft` without rechecking after compilation. An ingest waiting for the lock likewise enters `ingestLocked` and creates a generation after revocation. Separately, the changed-source branch at line 782 removes the generation **before** reaching the new promotion guard.

   **Reproduction A:** Revoke and snapshot from the existing `"Compiling family tree"` progress callback. The artifact subsequently appears, although promotion returns nil.  
   **Reproduction B:** In `store.verify`, change the source, revoke, and snapshot the compiled root. The subsequent hash mismatch deletes the generation.  
   **Proposed REDs:** `testARevocationBeforeArtifactWriteChangesNothing` and `testSourceChangeAndRevocationDuringVerificationRemoveNothing`. Check authority at these mutations; retain staged bytes when revoked.

3. **P1 — Overlay retirement still captures permission as a Boolean.**  
   [FamilyTreeLiveModel.swift:797](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:797) and [FamilyAssetStore.swift:264](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyAssetStore.swift:264) evaluate permission before calling the overlay reader. `PersonFactOverlayStore.effective` subsequently reads the overlay, finds stale entries, logs them, and saves using that captured Boolean.

   **Reproduction:** Seed an overlay superseded by a newer pull. In the overlay store’s existing retirement-log callback, revoke the injected configuration centre and snapshot `overlay.json`. Loading continues and rewrites it.  
   **Proposed RED:** `anOverlayRetirementRevokedBeforeSaveChangesNothing`. Carry live authority through to the retirement save.

4. **P1 — Recording the photo choice can overwrite its sidecar after revocation.**  
   [FamilyAssetStore.swift:1593](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyAssetStore.swift:1593) writes the choice sidecar after image validation and `importClock()`, with no second access check. The new guard in `writePersonPhotoData` does not protect this separate write.

   **Reproduction:** Seed a valid photo and existing choice, obtain `makeLiveStore()`, then make `importClock` revoke the centre and snapshot the directory. Call `recordPhotoChoice` without `chosenAt`. It overwrites the choice after revocation.  
   **Proposed RED:** `aLivePhotoChoiceRevokedAtImportClockChangesNothing`. Recheck immediately before publishing the sidecar.

**Validation:** No tests executed. The scoped Core attempt exited with `permissionDenied`; the Debug app attempt exited 74 because sandbox permissions blocked package-state locking and result output. The proposed RED tests above were not added or run. No files changed.

Scope expansion was limited to direct callees needed for findings: Core `PersonFactOverlay.swift`, `CyberBrainWriter+Persistence.swift`, and `CyberBrainWriter+RootLock.swift`.

Remaining scoped-file verdicts:

| File | Verdict |
|---|---|
| `FamilyTreeWriteGate.swift` | read, no findings. |
| `FamilyTreeReadOnlyLoad.swift` | read, no findings. |
| `FamilyTreeWalkCenter.swift` | read, no findings. |
| `FamilySearchPersonRefreshCoordinator.swift` | read, no findings. |
| `FamilySearchPullCoordinator.swift` | read, no findings. |
| `FamilyTreeRecompileCenter.swift` | read, no findings. |
| `ResearchStore.swift` | read, no findings. |
| `RecordFinderFiling.swift` | read, no findings. |
| `TreeIdentityCenter.swift` | read, no findings. |
| `PersonOfTheDayCenter.swift` | read, no findings. |
| `CouplePortrait.swift` | read, no findings. |
| `FamilyTreeView.swift` | read, no independent findings. |
| `FamilyTreeCards.swift` | read, no findings. |
| `FamilyGraphFileLoader.swift` | read, no findings. |
| `FamilyGraphCompiledStore+App.swift` | read, no findings. |
| `RemoteViewerMode.swift` | read, no findings. |
| `VideoScanModel+FamilyAssets.swift` | read, no findings. |
| `CatalogSync.swift` (`viewerRole`) | read, no findings. |
| `FamilyTreeLiveModel+Summaries.swift` | read, no findings. |
| `FamilyTreeDocumentsUI.swift` | read, no findings. |
| `RecordFinderFoundSheet.swift` | read, no findings. |
| `FamilyTreePullDates.swift` | read, no findings. |
| `FamilyTreeReadOnlyModeTests.swift` | read, no independent findings. |
| `FamilyTreeReadOnlyIsolationTests.swift` | read, no independent findings. |
| `FamilyTreeReadOnlyWriteSiteSensorTests.swift` | read, no independent findings. |
| `FamilyTreeReadOnlyRevocationTests.swift` | read, no independent findings. |
| `FamilyGraphCompiledStoreWriteGuardTests.swift` | read, no independent findings. |
| `FamilyTreeReadOnlyClosingTests.swift` | read, no independent findings. |

`FamilySearchPersonRefresh.swift` participates in finding 3; its Boolean hand-off is the uncovered retirement path.

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

---

# Re-review delta — closing #192 (BLOCK, 4 × P1 on F2) → second closing pass

*Run: `python3 tools/codex_review.py --title "Family Tree read-only — closing #192" --range 716576ae..7e9d93fc --brief .scratch/briefs/codex-ft-readonly-2026-11-01.md`. Review only the commit after `716576ae`. Same scope as above, plus `FamilyGraphCompiledStore+App.swift` and the test `FamilyTreeReadOnlyClosingTests.swift`.*

**What changed, per finding:**
1. **The compiled-store guard expired before promotion (Core).** `writesRefused` is now asked at promotion:
   - after verify, before the manifest;
   - before sidecars and pointer;
   - before a failed-verification prune;
   - inside `writePointer` itself, so every ingest, rollback, repoint and adopt is refused at the write, after any wait for the lock.

   A refusal changes nothing from that moment on. The half-built generation stays, unreferenced; the catch path no longer removes it when refused. The integrity audit moved into `logIntegrityAudit`, a pure move for the complexity gate. Pin: `testARevocationDuringVerificationPromotesNothing`, which revokes inside `store.verify` and checks the pointer is unchanged and the root is byte-identical from the revocation on.
2. **Unguarded stores handed out.**
   - `FamilyGraphCompiledStore.app` carries the process-wide live guard (`guarded(by:)` composes guards). That covers Hallie, the prewarm and the kinship centre.
   - The model hands out only `liveCompiledStore`, guarded by its own `writeAuthority`, to the full load, `loadNow`, the read-only load, pull dates and recompile.
   - The merge's base loader and the recompile centre's pending-sources read are guarded too.
   - The pull coordinator's default store is now `.app`, not the raw `.production`.
   - Overlay retirement during a load (both the injected-model path and the shared cache) asks the live mode.
   - Pins: `aLoadRevokedWhileItCompilesANewerPullPromotesNothing`, `aMergeRevokedBeforeItsBaseLoadCompilesNothing`, and the sensor `everyCompiledStoreHandedOutCarriesTheLiveGuard`. The sensor lists every hand-out in FamilyTree/ and fails on a new one, a raw store, an unguarded `.app`, or the model handing out `compiledStore`.
3. **The captured recorder.** It captures `writeAuthority` (the model's latch, its injected centre and its viewer centre) and checks it at each record. Pins: `aCapturedRecorderRefusesAfterTheInjectedCentreIsRevoked` and `…AfterTheModelIsConfiguredUnavailable`.
4. **Photo write before the check.** `writePersonPhotoData` calls `requireWriteAccess()` immediately before the first byte, after validation, naming and the descriptor walk. `ensureSafeDirectory` checks before creating a folder. A refused write creates no file. Pin: `aLivePhotoStoreRevokedMidChooseWritesNoPortrait`, which revokes from `importClock`.

**Attack these next:**
- (a) Any compiled-store write path that doesn't go through `writePointer` or the promotion checks. For example, prune called from somewhere else.
- (b) The window between `requireWriteAccess()` and `openat` / `write(2)` (synchronous, no suspension point): is this good enough?
- (c) An image written while allowed, then its choice record refused: the image stays, written under authority.
- (d) Callers outside FamilyTree/ (Hallie) that construct a store other than `.app`.

**Evidence:** see the commit message for counts and the red/green table.
