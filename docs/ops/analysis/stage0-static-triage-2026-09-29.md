# Stage 0 — static-analysis triage, 2026-09-29

**Session:** ~10 min wall clock (21:34 → 21:44 UTC; three qa subagents ran in parallel for ~3.5 min of it), cloud session on Linux, read-only analysis. Nothing was built and no source was changed.
**Source analysed:** `main` @ `3b1fc6b0`. The warnings come from nightly runs
[#163](https://github.com/musicalengineer/VideoScan/actions/runs/36558911631) (`8898e444`, 09-29) and
[#162](https://github.com/musicalengineer/VideoScan/actions/runs/36415055633) (`a994e0f8`, 09-28). Line numbers are from those builds and may be a few lines off on `main`; the symbols are the stable key.

## One-screen summary

| Source | Nightly count | Triaged here | REAL | NOISE | NEEDS-MAC |
|---|---:|---:|---:|---:|---:|
| Strict-concurrency: concurrency / Sendable / isolation | 176 | ~100 unique (file, message) → **9 root causes** | 0 | all | 0 (TSan would only confirm) |
| Strict-concurrency: other compiler warnings (unused values, deprecations, `.none`) | ~30 | 13 | **1** (+2 found while reading) | 10 | 0 |
| Strict-concurrency: `ExistentialAny` (`any P`) | ~70 | as a group | 0 | group (P3 migration) | 0 |
| Type-check timing | 172 identities | top 20 + the gated one | 1 gate breach (P3, **turned the nightly red**) | — | — |
| **CodeQL security-and-quality** | **17** | **0: the alert details could not be read** | ? | ? | ? |

**Bottom line:**
- **No data race.** None of the concurrency warnings is a real runtime race. Every one resolves to one of: a lock that is really held; a `concurrentPerform` join; a serial queue; immutable `static let` data; or main-actor work hopped correctly.
- **Not a crash risk today.** The project builds in Swift 5 mode (`SWIFT_VERSION = 5.0`, `SWIFT_STRICT_CONCURRENCY = complete`), so none of these warnings can trap at runtime now. They are a Swift 6 migration backlog.
- **The real findings are small and sit next to the warnings.** Each came from reading the code a warning pointed at; the warning itself was not the bug.

### Top 5 real, by severity

1. **P2: a full family-tree decode on the main actor, where the comments promise a manifest read.** `FamilySearchPullCoordinator.swift:417` and `:678` call `compiledStore()?.loadCurrent()?.manifest` from a `@MainActor` type. `loadCurrent()` decodes the whole graph and can also `repoint` (a disk write). With the 39k-person tree this is a likely beachball on the FamilySearch pull and refresh sheet. NEEDS-MAC to measure.
2. **P3: the type-check ratchet turned last night's nightly red.** It has one NEW identity over 500 ms: `DeleteDuplicatesDetailView.swift:145` `body`, at 525 ms. In the same run, `CatalogContent+Table.swift:186` `tableWithCatalogTriggers` took **21.7 s**. That is the same shape as the 2026-09-01 CI-red saturation.
3. **P3: Show Copies can mislabel a copy as the "original source" when its parent record is gone.** `CopyFamilyAssessor.swift:342-372`. `hasExternalLineage` is computed and never read, so its reason text ("…not derived from any other copy") can be false. It is advisory only; nothing is deleted on this basis.
4. **P3: the Verify Video menu label counts the wrong files.** `CatalogContent+Table.swift:1246-1247` counts `activeRecs` but runs only `verifiableRecs`. With 3 files selected and 1 of them audio-only or offline, it says "(3 Files)" and starts 2 jobs.
5. **P3: `ExistentialAny` plus the `nonisolated` hygiene backlog, about 150 warnings.** They are mechanical and become errors when the target moves to Swift 6.

### What could not be done from here, and how to finish it

- **CodeQL.** The code-scanning alerts API needs a GitHub token. The GitHub tools this session had cannot reach code-scanning alerts. The SARIF artifact (`codeql-results`, id 11031340594) and the full run-log zip are served from `productionresultssa2.blob.core.windows.net` and `results-receiver.actions.githubusercontent.com`, and this environment's network policy blocks both hosts.
  - Trend from `metrics/static_analysis.jsonl`: 5 (09-10) → 7 (09-14) → 9 (09-18) → 11 (09-25) → **17 (09-27, `0564185f`)** → 17. The 09-19…09-24 rows read 0 because those jobs failed, not because the alerts were clean.
  - The jump from 11 to 17 lands in `f95138f5..0564185f`, which touched 132 Swift files.
  - **To finish:** on the Mac, run `gh api repos/musicalengineer/VideoScan/code-scanning/alerts?state=open --paginate > codeql-open.json`, or `gh run download 36558911631 -n codeql-results`. Then triage the output with the same REAL / NOISE / NEEDS-MAC template as this doc.
- **Strict-concurrency coverage.** Each MCP job-log fetch returns only the last 5,000 of the log's ~16,000 lines.
  - I took the union of the two nightly tails: 452 of the 583 unique warning lines, about 78%.
  - The missing ~22% come from files the compiler happened to build early. Given how uniform the root causes below are, they are very likely more of the same families.
  - To confirm on the Mac: `gh run download 36558911631 -n strict-concurrency-log`, then diff `concurrency-findings.txt` against the file list in the appendix.

---

## Real findings

### R1 — P2 — Compiled-tree "manifest read" decodes the whole graph on the main actor
- **Where:**
  - `FamilySearchPullCoordinator.swift:417` (`finish(output:generation:)`) and `:678` (the baseline read before staging). The type is `@MainActor` (`:19`).
  - The callee is `VideoScanCore/.../FamilyGraphCompiledStore.swift:360-378`, `loadCurrent()`.
- **Where the warnings led:** the unused locals `gedcomDirectory` / `fileManager` (`:407-408`) and `compiledStore` (`:670`). These are leftovers from a19b7cb4 and 132bfa70; nothing that should have run is missing. The problem is in the lines that replaced them.
- **What happens:**
  - `loadCurrent()` reads the pointer and manifest, then calls `decode(generation:)` on the whole graph, only for the caller to keep `.manifest`.
  - Both calls run on the main actor. For Rick's tree (about 39k people) that is a full decode on the UI thread when the pull finishes and when Add/Refresh stages. That is the beachball class tracked in GH #104.
  - If the current generation is unreadable, `loadCurrent()` also calls `repoint(...)` to roll back to the previous generation. That is a pointer write inside code whose comment (`:410-416`) says "a pure manifest read that cannot promote anything". A rollback is not a promotion, so it is consistent with the store's normal behaviour, but it contradicts the stated contract of these call sites.
- **Classification:** REAL (a UI hang). How long it takes needs the Mac. Open the sheet with the full tree under Instruments' Time Profiler, or wrap the call in a signpost.
- **Fix:** add a manifest-only `loadCurrentManifest()` to `FamilyGraphCompiledStore`, with no decode and no repoint, and call it at `:417` / `:678`, or from inside the existing detached task. Delete the three dead locals.

### R2 — P3 — Nightly red: type-check ratchet (plus a 21.7 s outlier)
- **Where:** `DeleteDuplicatesDetailView.swift:145`, getter `body`, at 525 ms. This is the only NEW identity over the 500 ms gate in `scripts/typecheck_timing_ratchet.py`, and it is why run #163 concluded `failure`. All build steps succeeded.
- **Also in the run:**
  - `CatalogContent+Table.swift:186-187` `tableWithCatalogTriggers` took **21,751 ms**. It is grandfathered, but it is one runner-speed wobble away from "unable to type-check in reasonable time", which is how CI went red on 2026-09-01.
  - Ten known entries grew by more than 50%, including `FamilyTreeCards.swift:154` `body` (266 ms → 2,043 ms) and `VolumeCompare.swift:1108` `runningRescueBanner` (2,027 ms → 3,214 ms).
- **Fix:** break `DeleteDuplicatesDetailView.body` into sub-views or `@ViewBuilder` helpers, or baseline it deliberately. Split the modifier chain in `tableWithCatalogTriggers` into typed intermediate `some View` properties before it saturates.

### R3 — P3 — Show Copies can call a copy "the original" when its parent record is gone
- **Where:** `CopyFamilyAssessor.swift:342` (`hasExternalLineage`, set at `:356-360`, **never read**) and `:365-372` (original election).
- **Where the warning led:** "`var drafts` never mutated" at `:344`. That warning is harmless on its own; the unused field in the same struct is the defect.
- **Scenario:**
  - A DV trim or cleanup render has `derivedFrom` = the UUID of a record that has since been purged, or that lies outside the family walked by `ArchiveAngelShowCopies.swift:130`.
  - `idToSig[d] == nil`, so the copy counts as a lineage root. Its codec is native, so it wins `natives.first` and becomes `.originalSource`, with the reason "Native acquisition encoding … and not derived from any other copy."
  - That statement is false.
- **Impact:** advisory UI only. Show Copies deletes nothing on this basis, but the wrong label feeds a human Keep/Promote decision.
- **Fix:** exclude `hasExternalLineage` drafts from `natives`, which drops them to `.presumedOriginal`, and add a caution: "derived from a file no longer in the catalog". If this behaviour is intended, delete the field instead.
- **Suggested pinning test** (the qa agent wrote it; not run here, since this is Linux):
  ```swift
  @Test func nativeCopyDerivedFromAbsentRecordIsNotCalledTheProvenOriginal() {
      let orphan = CopyFamilyInput(fullPath: "/Volumes/X/Clip 01 trim.dv", sizeBytes: 12_960_000_000,
          durationSeconds: 3604, videoCodec: "dvvideo", audioCodec: "pcm_s16le", container: "dv",
          resolution: "720x480", frameRate: "29.97", scanType: "tb", audioChannels: "2",
          audioSampleRate: "48000", bitDepth: "8", contentHash: "v1:trim", derivedFrom: UUID())
      let a = CopyFamilyAssessor.assess([orphan])
      #expect(a.recommendedRepresentation?.role == .presumedOriginal)
  }
  ```

### R4 — P3 — "Verify Video (N Files)" counts files it will not verify
- **Where:** `CatalogContent+Table.swift:1241-1251` (`verifyVideoMenuItem`).
- **Where the warning led:** a redundant `_ =` on a Void call at `:1249`. That warning itself is NOISE.
- **Scenario:** select 3 records, 1 of them audio-only or on an unmounted volume. The menu says "Verify Video (3 Files)" and starts 2 jobs.
- **Fix:** use `verifiableRecs.count` in the label, and drop the `_ =`.

---

## NOISE, grouped by root cause

Each group gives the files, why nothing can go wrong, and the cheapest fix. Spot-checks I made myself (the qa agents did the rest): the POIStorage lock (N1) and the trash planner (N6).

### N1 — Mutable statics that are lock-guarded or never written (P3)
- **`POIStorage.swift:533` / `:559` / `:571`** (`migrationStates`, `pendingCatalogLogLines`, `reportedSkips`):
  - Every access holds `uuidMigrationLock`. `migrateToUUIDFoldersIfNeeded` locks at `:610` for its whole body, including `:883`. `rollbackUUIDMigration` locks at `:897`, and the other accessors lock at `:538` and `:562`.
  - No re-entrant call is made while the lock is held.
  - **Fix:** `nonisolated(unsafe)` plus a "guarded by uuidMigrationLock" comment, or fold the three into an `OSAllocatedUnfairLock<State>` so the compiler enforces the lock.
- **`RAMAssetLoader.swift:202-204`** (`PageCacheWarmer.isEnabled` / `maxFileSizeBytes` / `budgetBytes`): never written anywhere, and `isEnabled` is never read. **Fix:** `static let`, and delete `isEnabled`.
- **`CatalogWriteError.swift:180`** `maxBytes`: only `CatalogLockRobustnessTests` writes it, with save and restore. **Fix:** `nonisolated(unsafe)` with a "test-only" comment, or pass the cap as a parameter.
- **`MemoryPressure.swift:40`** `vm_kernel_page_size`: a C global set once at process start and read-only here. **Fix:** `getpagesize()`.
- **`PersonFinderTypes.swift:1318`** (and `:271`), `static let defaults = UserDefaults.standard`: `UserDefaults` is thread-safe. **Fix:** mirror `ScanPerformanceSettings.swift:19`, which already uses `nonisolated(unsafe)` with a comment.
- **`HallieModeClassifier.swift:35`** `Oracle.none`: its closures capture nothing. **Fix:** make the closure fields `@Sendable` and `Oracle: Sendable`.

### N2 — Constants on `@MainActor` types read from nonisolated code (P3)
- **Files:**
  - `ArchiveAngelJob+Evidence.swift:464,479` (`coverageLookBudget`, `coverageProjectionBudget`)
  - `ArchiveAngelAttention.swift:267`, `ArchiveAngelEvidenceStore.swift:225`, `ArchiveLockJob.swift:400`
  - `HallieWebBridge.swift:837`, `MediaFileOperationsWindow.swift:42-43`
  - `MediaStreamResolver.swift:136-139,288-289`
- **Why nothing can go wrong:** every one is a `static let` of a Sendable value: a String, Int or Set.
  - `MediaStreamResolver` reads `UserDefaults` through an injected instance; only the *key names* are main-actor constants.
  - The port is stored as an Int by `@AppStorage`, so `as? Int` does not silently fall back to the default.
- **Fix:** `nonisolated static let …`.

### N3 — Static `Regex` constants (P3)
- **Files:** `HallieKinshipApposition.swift:63-80`, `HallieLineageQuestion.swift:547,553,1057,1074,1282,1371`, `HalliePropertyAsk.swift:30`, `HallieRepairTurn.swift:76`, `HallieTreeStatisticsQuestion.swift:39-54`.
- **Why nothing can go wrong:**
  - Hallie can match these from the chat window (main) and the web server at the same time.
  - They are all `static let`, and `Regex` is an immutable value whose lazily compiled program is set with an atomic compare-exchange. The type is simply not *marked* Sendable in this SDK.
- **Fix:** `nonisolated(unsafe) static let` with a one-line justification, or wait for an SDK that marks `Regex` Sendable.
- **Related:** `DateTriangulator.swift:241,250` (and the same pattern at 259-299) has the opposite problem: `nonisolated(unsafe)` is no longer needed because `NSRegularExpression` is now Sendable. **Fix:** drop the `(unsafe)`.

### N4 — Parallel writes into disjoint slots through unsafe pointers, joined by `concurrentPerform` (none)
- **Files:**
  - `FamilyTreeLaunchBundle.swift:60-94`: 4 jobs, each writing its own `*Out.pointee`; `slots[i]` is written once per `i`.
  - `FamilyTreeLiveModel.swift:989-1006`: chunked, disjoint rows; `initialized = count` is set after the join.
  - `VideoScanCore/.../FamilyTreeNameSearch.swift:136-163`: the same pattern.
- **Why nothing can go wrong:** `concurrentPerform` blocks until every iteration finishes, and all reads happen after it returns. The shared `GedcomFamilyGraph` index sits behind the NSLock in `TreeIndexBox`.
- **Fix:** none needed. Optionally add a `// SAFETY: disjoint slots; concurrentPerform joins` comment.

### N5 — Values sent into `Task.detached` from main-actor code (P3)
- **Files:**
  - `FamilyTreeLiveModel.swift:786`, `FamilyTreeRecompileCenter.swift:104`, `FamilySearchPullCoordinator.swift:421`, `FamilyTreeLaunchBundle.swift:144`.
  - The "sending self" warnings in `ArchiveAngelJob.swift:~1016`, `VideoScanModel+ArchiveAngelBufferHygiene.swift:~284` and `VideoScanModel+Thumbnail.swift:~859`.
  - The captured `var` / weak references in `ThumbnailPrecache.swift:239,309`, `IdentifyFamilyModel.swift:244`, `HallieTurnExecutor+Relationship.swift:317` and `HallieShellCLI.swift:1313,1822`.
- **Why nothing can go wrong:**
  - The closures capture values: URLs, Sets, manifests, and structs whose only non-Sendable parts are `appLog.write`-style log closures.
  - Every touch of `self` / `model` is inside `MainActor.run` or a `Task { @MainActor }` hop.
  - Captured `var`s are read only while the caller is suspended on `await task.value`.
  - The delete path in `ArchiveAngelJob.finishCancelled` removes files using captured values, not `self`.
- **Fix:** make `FamilyGraphCompiledStore.log` / `verify` and `FamilyGraphFileLoader.progress` `@Sendable` and conform both structs to `Sendable`. That clears three warnings at once. Use `let subjects = subjects` before the detached call. Type `prewarm(log:)` as `@Sendable`.
- **Minor ordering note:** `IdentifyFamilyModel` sends each process output line through its own `Task { @MainActor }`. FIFO order is not formally guaranteed, though it holds in practice. If strict order ever matters, drain the lines through one `AsyncStream`.

### N6 — Main-actor predicate converted to a nonisolated function type on the delete path (P3)
- **Where:** `VideoScanModel+TrashSelection.swift:93-100`.
- **Why nothing can go wrong:** the default `isOffline` (`isRecordOnOfflineVolume`, main-actor-isolated) and `isMasterArchive` are non-escaping. They are called synchronously inside the `nonisolated static` planner, whose only production caller, `trashSelectedRecords`, is on the main actor. Every predicate call therefore runs on main. `deleteConfirmedJunk` re-checks the archive and offline gates in any case.
- **Fix:** type the planner parameters as `@MainActor (VideoRecord) -> Bool`, so nobody can later call the planner from a background task with these predicates without the compiler stopping them.

### N7 — Framework-thread callbacks (none)
- **`HallieWebServer.swift:339-414`** (`receive()` / `buffer`, `next()` / `offset`):
  - Callbacks run on a private serial queue (`:266`).
  - Each receive is re-armed only from the previous callback, and each send is chained from `.contentProcessed`, so callbacks cannot overlap.
  - The buffer is capped by `maximumHeaderBytes` / `maximumBodyBytes`.
- **`HallieSpeaker.swift:416`:** the `AVAudioPlayerNode` completion only hops to main with weak `self` and a UUID. **Fix:** type it `@Sendable`.
- **`HallieSpeaker.swift:575`:** `synthesizer` is `self.synthesizer`, and it is read on main. **Fix:** don't capture the parameter.
- **`FamilySearchPullCenter.swift:169` and `VideoScanModel+RelocateQueue.swift:283`:** `UNUserNotificationCenter` is documented thread-safe. **Fix:** call `UNUserNotificationCenter.current()` inside the callback instead of capturing `center`.

### N8 — Core ML / MLX model captures (none)
- **`ArcFaceEngine.swift:180-214`:**
  - `lock.withLock` runs its body synchronously, and `VSCatchObjCException` is `NS_NOESCAPE` (`ObjCExceptionCatcher.h:9`). So both writes to `output` / `swiftError` finish before the read at `:213`, on the same thread.
  - **Fix:** use `withLockUnchecked`, or return a tuple from the closure instead of mutating captured variables.
- **`ArcFacePredictor.swift:29-90` and `NativeRecipeScorer.swift:160`:**
  - Every `MLModel` comes back from the loader actor as a *fresh instance* (`ArcFaceEngine.swift:101-167`).
  - Every prediction runs under the global `arcfacePredictionLock` or its slot's lock, so no single instance ever sees two predictions at once.
  - The pool state is guarded by `stateLock`.
  - The known K>1 parallel-model risk (the MLE5 crash of 2026-05-12) is opt-in, off by default, and firewalled; it is not new.
  - **Fix:** declare `ArcFacePredictor` `@unchecked Sendable` with a lock comment, and mark the loaders' `getModel()` return as `sending (MLModel?, String?)`.
- **`CaptionRunner.swift:573`:** `chat` is a fresh, immutable local, read only inside `perform` while the actor awaits.
- **`MLXSafety.swift:143`:**
  - The three `runMLX` bodies (`:479`, `:571`, `:685`) touch only locals, never actor state.
  - **Fix:** mark `runMLX` `nonisolated(nonsending)` (Swift 6.2), or give it an `isolation: isolated (any Actor)? = #isolation` parameter.
  - `:123` is a deliberate trick to silence a deprecation warning; accept the warning.
- **NEEDS-MAC, though not a warning finding:** it is unconfirmed whether `runMLX`'s task-local error handler covers errors thrown inside MLXLMCommon's own generation task. **To check:** force a shape error, for example with `resize = 512×512` on Qwen2.5-VL (see `CaptionRunner.swift:531-537`), and check whether it surfaces as `MLXError.caught` or only in `recentGlobalMLXError()`.

### N9 — Other compiler warnings that are harmless (P3)
- **`ArchivistFollowUpResolver+Refinement.swift:274` (and `:298`), `.none` read as `Optional.none`:**
  - The author meant `Resolution.none`, but the only caller (`ArchivistFollowUpResolver.swift:215-219`) maps both `nil` and `.some(.none)` to `.none`, so behaviour is identical.
  - **Fix:** write `nil`.
- **`BundleImporter.swift:196`** unused `fm`: left over from f0b71589, and nothing is missing. **Fix:** delete it.
- **`ArchiveAngelJob.swift:264`** unused `MainActor.run` result: the dropped value is an `Int?` count; errors are logged elsewhere. **Fix:** `_ = await`.
- **`ArchiveAngelJob+Evidence.swift:~180`** `.pick` with 6 associated values bound as a tuple: every field is read by label, so values cannot be swapped. **Fix:** bind each value by name.
- **`ConfirmPersonSheet.swift:644`:** `keyboardKey` is a non-optional `Character`, so no `Optional(...)` can leak into the UI. **Fix:** `Text(verbatim:)`.
- **`SeekingFrameProvider.swift:108`** deprecated synchronous `copyCGImage`: it runs on a private serial queue, never on main. **Fix:** migrate to the async `image(at:)` when convenient.
- **`ExistentialAny` (about 70):** `use of protocol 'P' as a type must be written 'any P'`. It is a pure spelling migration and can be done mechanically, file by file.

---

## Appendix — method and provenance
- **Warnings.**
  - Taken from the `Swift strict concurrency (max)` job logs, jobs 109374745482 (#163) and 108904096359 (#162). Each fetch returns the last 5,000 lines.
  - Kept the lines matching `\.swift:N:N: warning:`, normalised the runner path, and took the union: 452 unique lines against the nightly's 583.
  - Bucketed by message shape, then deduplicated by (file, message): about 117 non-perf, non-`any` items.
- **Classification.**
  - Three read-only `qa` subagents classified the items in parallel against `main` @ `3b1fc6b0`.
  - I re-checked their REAL claims myself (R1, R3, R4 against source) plus the two delete- and lock-adjacent NOISE calls (N1 POIStorage, N6 trash planner).
- **Counts and trend:** `metrics/static_analysis.jsonl` on `origin/metrics` and the aggregate job log.
- **Build mode:** from `VideoScan.xcodeproj/project.pbxproj`, `SWIFT_VERSION = 5.0` with `SWIFT_STRICT_CONCURRENCY = complete`, so there are no runtime isolation traps today.
