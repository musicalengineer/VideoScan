# Codex review — Family Tree read-only without the archive

- Range: `17de5518d689145eb035987cd789e345a7aecd79..feat/family-tree-readonly`
- Credits spent: unavailable (not exposed)
- Tokens: 193722
- Finding count: 5
- Verdict: block — rejected-volume metadata can affect the displayed tree, and writers can continue after access is revoked.
- Run: 2026-11-02T01:00:12Z (cycle #190, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (not exposed) | Finding count: 5  
Verdict: block — rejected-volume metadata can affect the displayed tree, and writers can continue after access is revoked.

Reviewed `17de5518..f1da1bf5` directly from Git. The supplied worktree was mid-merge at `bf947603`; I changed nothing. **Independent tests executed: 0** — Xcode failed before execution because the read-only sandbox denied its package-state lock and result-bundle writes. Regression cases below are proposed, not observed RED.

1. **P0 — Wrong-UUID rulings survive initialization and affect the displayed tree.**  
   [FamilyTreeLiveModel.swift:505](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:505), also lines 496–509, 1122 and 1264–1290.

   Initialization reads identity rulings and bookmarks before checking archive access. When production access is already `.unavailable`, configuring that same source finds no change and therefore never clears those values. `installReadOnly` subsequently applies the rejected volume’s rulings to the verified local graph. Separately, `configure` calls `gedcomDirectory()` before checking access; that helper enumerates the archive directory.

   **Reproduction:** Publish an unavailable configuration pointing at a fixture representing the wrong-UUID volume. Seed it with a ruling hiding a person in the local compiled graph. Construct the model using production source resolution, then prepare it with the same configuration. The person remains suppressed in read-only mode.

   **Regression:** Assert that the ruling has no effect and archive reads never occur. `FamilyTreeReadOnlyModeTests.swift` misses this because its harness injects an originals directory, initially giving the model `.readWrite`, then changes access during configuration.

2. **P1 — Entry gates do not protect writes across asynchronous work.**  
   [FamilySearchPullCoordinator.swift:631](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilySearchPullCoordinator.swift:631), especially lines 749–781.

   `installMerged` checks once before scheduling. After staging and suspension, activation checks only parse generation and phase. It can recreate the absent archive directory and publish the merged GEDCOM after access becomes unavailable.

   **Reproduction:** Start a merge with `writeMode == .full` and a nonzero `parseDelay`. Wait until staging finishes, move the fixture archive away, switch `writeMode` to unavailable, then await completion. Activation still calls `createDirectory` and installs the file.

   The same gate-before-background-work pattern remains in:
   - `FamilyTreeLiveModel.swift:955` and `:2609` — recompile and document removal.
   - `FamilyTreeRecompileCenter.swift:114` — standalone recompile.
   - `FamilySearchPersonRefreshCoordinator.swift:347` — overlay mutation/quarantine after the caller’s gate.
   - `FamilyTreeWalkCenter.swift:325` — detached save.
   - `FamilyTreeView.swift:2137` — photo write using captured configuration.
   - `RecordFinderFiling.swift:545` — subsequent hashing and document filing use captured writable authority.

   **Regression:** Snapshot fixture bytes at revocation and require identity afterward, including an absent mount point. The isolation suite exercises operations *starting* read-only, not these transitions. The write-site sensor also falsely exempts `cancel`: cancelling a previously started merge in read-only mode removes its staging directory.

3. **P1 — Model writers consult stale source access.**  
   [FamilyTreeLiveModel.swift:235](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:235).

   `checkWrite` refreshes from the model’s cached `sourceAccess`, not the currently published configuration. Publication does not update that field; the view’s appearance task does. A retained model can therefore allow a new write after the process-wide mode has become read-only. Hallie’s registered-model recompile path also uses this gate.

   **Reproduction:** Load a writable model, publish `.unavailable` through `FamilyAssetConfigurationCenter`, and call `addNote` before another `configure`/appearance. `FamilyTreeAccessMode.current()` refuses, but the model still writes CyberBrain.

   **Regression:** Publish revoked access without reappearing the tab; assert that the next model writer refuses and leaves fixture bytes unchanged.

4. **P2 — Document results and counts survive the read-only transition.**  
   [FamilyTreeLiveModel.swift:2474](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:2474), also lines 1130–1134 and 2497–2513.

   Configuration changes do not invalidate document generations or clear document caches. Reloading the same compiled graph keeps the same source key, so installation does not clear them either. Pending listings can republish documents after read-only installation, and existing document counts remain visible on cards.

   **Reproduction:** Hold a `.selection` listing using `documentListing`, transition to unavailable and reload the same compiled graph, then release the listing. Its generation checks still pass.

   **Regression:** Require `selectedDocuments` and document counts to remain empty after releasing both selection and card-count reads. The existing isolation fixture starts read-only and misses this sequence.

5. **P2 — Viewer pull-date refresh still opens archive source paths.**  
   [FamilyTreeLiveModel.swift:859](/Users/rickb/dev/VideoScan-wt/ft-readonly/VideoScan/VideoScan/FamilyTree/FamilyTreeLiveModel.swift:859).

   Only `.readOnly(.archiveUnavailable)` suppresses pull-date reads. Viewers pass the graph into `FamilyTreePullDates.describe`, which adds every manifest source’s original directory to its search roots. Those can be absent archive paths—or paths occupied by a wrong-UUID volume—even though the viewer’s configured roots are local.

   **Reproduction:** Load a viewer’s compiled generation whose manifest names an archive directory containing a fixture GEDCOM. Pull-date refresh searches and hashes that directory.

   **Regression:** Instrument archive reads during viewer appearance and require zero; byte-identity snapshots cannot detect this.

The remaining scoped files were **read, no findings**:

| File | Verdict |
|---|---|
| `FamilyTreeWriteGate.swift` | read, no findings |
| `FamilyTreeReadOnlyLoad.swift` | read, no findings |
| `FamilySearchPersonRefresh.swift` | read, no findings |
| `ResearchStore.swift` | read, no findings |
| `TreeIdentityCenter.swift` | read, no findings |
| `PersonOfTheDayCenter.swift` | read, no findings |
| `CouplePortrait.swift` | read, no findings |
| `FamilyTreeCards.swift` | read, no findings |
| `FamilyGraphFileLoader.swift` | read, no findings |
| `FamilyGraphCompiledStore.swift` | read, no findings |
| `RemoteViewerMode.swift` | read, no findings |
| `VideoScanModel+FamilyAssets.swift` | read, no findings |
| `CatalogSync.swift` | read, no findings |

`FamilyAssetStore.swift` supports findings 1–2; all three scoped test files were read and their gaps are described above. The compiled-only path retains the required empty-verification and successful-decode checks and refuses repoint writes.

Scope expansion was limited to startup wiring and the directly implicated helpers: compiled-store app configuration, pull-date discovery, identity-ruling loading, overlay storage, and document removal.

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
