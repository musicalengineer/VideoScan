Brief: C06-switch-to-types | Source: main@b273af96 | Wall clock: ~60 | Files read: 24
Finding count: 15 (REAL 15 / NEEDS-MAC 0 / NOISE 8)
Verdict: Most of the app's big switches are good Swift: exhaustive matches on payload-carrying results, written once. The real offenders fall into two groups. (1) A few subjects are switched on for **behaviour** in many places: `RecognitionEngine` 10 behaviour sites in 6 files, `AnalyzeCycler` 7 in 2, the Angel's prepare steps with 3 copies of one ladder. (2) Some enums hide a **kind tag** behind `default:` arms: `AngelField` and `AngelRuleKind` have about 14 of them, so a new field or floor silently does nothing. Fix those two groups first. The constant-table enums are cheap, low-risk follow-ups.

## Scope and method
- **Input:** the census `docs/reviews/census/switch_census_2026_10_09.md`, used as given (nothing recomputed). Exemplars read: `MediaFileOperationKind` (MediaOps/MediaFileOperations.swift:40-120, commit `0d8c999e`) and `MediaFileOperationKindTests` (MediaFileOperationsTests.swift:421).
- **Census line numbers lag main.** Main moved since the census, so the lizard line numbers are a few lines off in places. Example: census `DeleteDuplicatesJob.swift:294 init` is `phaseOne` on main. Every file:line below was re-read on main@b273af96.
- **Files read** (paths under `VideoScan/VideoScan/` unless noted):
  - MediaOps: `VideoScanModel+JunkDelete`, `DeleteDuplicatesJob` (phaseOne), `VerifyVideoRules` (noteFragment, severity), `TranscodePreset`, `TranscodeJob+Args`, `MediaFileOperations` (Kind, State)
  - ArchiveAngel: `Prepare/ArchiveAngelJob` (prepare, runTranscode, waitForRunningVerify), `Prepare/ArchiveAngelPlan` (StepKind), `Recommend/ArchiveAngelScorer+Rules` (floorFires, mediaFloorFires, signal), `Recommend/AngelRuleLanguage` (AngelField, AngelRuleKind, AngelRuleSection, flag tables), `Promote/ArchiveAngelPromoter` (roleLabel, companionLanding), `Review/ArchiveAngelBufferHygiene` (companionChips), `UI/ArchiveAngelDetailView` (columnTitle, label)
  - People: `PersonFinderTypes` (RecognitionEngine, thresholds), `ConfirmRating` (outline), `PersonEvaluationCLI` (parse)
  - Callees followed for RecognitionEngine: `PersonFinderModel+JobLifecycle` (:657-667, :1118-1140, :1418-1428), `PersonFinderCache` (embedVariant :128-145), `Volumes/MemoryPressure` (:78-110)
  - Analyze: `AnalyzeCyclers`, `AnalyzeRunner`, `AnalyzePanelView` (coverageWords, liveRule)
  - Volumes: `DriveHealth` (parseSmartctlJSON)
  - Catalog: `CatalogQueries` (SearchField)
  - Steward: `StewardCase` (outline)
  - VideoScanCore: `LedgerNarrator.sentence`
  - Hallie: `PronunciationVariations` (outline only)
- **Prior designs cited, not re-argued:**
  - N1007-D-Hallie-rewrite-eval (ordered rules for Hallie)
  - N1011-D-PrunePlan (PrunePlan.plan, top CCN 52; not switch-shaped, so outside this brief)
  - N1020-D-People-F2 (two distance conventions behind one threshold)

## Top 15, ranked by payoff

Payoff = design clarity × how often the code changes × risk. "Sites" counts the places the same subject is switched on. Folders are under the app target unless marked.

| # | Symbol | file:line | CCN | Shape | Sites | Data-risk? | Effort |
|---|---|---|---:|---|---|---|---|
| 1 | `RecognitionEngine` (dispatch + 7 tables) | People/PersonFinderTypes.swift:80 | 14 (`set`), spread | **4** (+2 for the tables) | 10 behaviour sites in 6 files, plus 7 constant tables | No; correctness of tag tiers (N1020-F2) | L |
| 2 | `AngelField` / `AngelRuleKind`: kind tags hidden behind `default:` | ArchiveAngel/Recommend/AngelRuleLanguage.swift:72, :657; `floorFires` ArchiveAngelScorer+Rules.swift:84 | 33 (`floorFires`), 17 (`candidateFlag`) | **2**, done by splitting into nested enums | about 14 `default:` arms over two enums | Yes, the floors (`onMasterArchive`, `angelWorkingCopy`) | M |
| 3 | `ArchiveAngelJob.prepare`: a 4-step pipeline in one function; one sub-job verdict ladder written 3 times | ArchiveAngel/Prepare/ArchiveAngelJob.swift:674 (ladders :716-725, :775-792, :893-913) | 37 | **4** | 4 steps; 3 copies of the ladder | Yes (writes and removes buffer companions) | M |
| 4 | `AnalyzeCycler` dispatch | Analyze/AnalyzeCyclers.swift:23; AnalyzeRunner.swift:53, :149, :165, :177, :191; AnalyzePanelView.swift:199, :225 | 7 sites, each 10-20 | **4** | 7 behaviour sites in 2 files, plus 6 tables | No | M |
| 5 | `deleteConfirmedJunk`: mode switched 3 times; the removal-boundary chain inlined | MediaOps/VideoScanModel+JunkDelete.swift:210 (mode :402, :469, :478, :507, :510) | 30 | **2** (mode) + **5** (boundary checks) | 5 mode decisions | **Yes**: the one Trash routine | S-M |
| 6 | `ArchiveAngelPlan.StepKind`: tables scattered over 4 files | ArchiveAngel/Prepare/ArchiveAngelPlan.swift:27; Promoter.swift:69, :166; BufferHygiene.swift:298; DetailView.swift:397, :406 | ≤10 each | **2** | 6 constant switches in 4 files | Yes: `roleLabel` is written into the archive manifest | S |
| 7 | `TranscodePreset` (6 parallel tables) | MediaOps/TranscodePreset.swift:15 | 6 × 4-5 | **2** | 6 tables + 1 recipe switch | No (it names derived files) | S |
| 8 | `DriveHealthProbe.parseSmartctlJSON`: `[String: Any]` digging | Volumes/DriveHealth.swift:519 | 42 | **6** (`Decodable` model) | n/a | No (feeds drive health shown before a retire) | M |
| 9 | Hand-rolled CLI parsers (`PersonEvaluationCLI.parse`, `RecipeCalibrationCLI.parse`, `HallieShellCLI.parse`, `FindTagCLI.run`) | People/PersonEvaluationCLI.swift:272; People/RecipeCalibrationCLI.swift:191; Hallie/Shell/HallieShellCLI.swift:570 | 37 / 21 / 15 / 32 | **6** | 4 parsers, one idiom | No | M |
| 10 | `ConfirmRating` (6 tables + 1 behaviour) | People/ConfirmRating.swift:20 | 6 × ~6 | **2** | 6 tables | No (Codable; the rating is a hand gesture) | S |
| 11 | `VolumeStatusEnums+Presentation` (icon + colour pairs per enum) | ModelsUI/VolumeStatusEnums+Presentation.swift:12-100 | ≤8 | **2** | 8 tables over 4 enums | No | S |
| 12 | `StewardCaseKind` (chip, lane, systemImage) | Steward/StewardCase.swift:26 | ≤8 | **2** | 3 tables | No (presentation only) | S |
| 13 | `HallieTurnExecutor.execute` / `executePresenceLike` / `executeOrdered` | Hallie/HallieTurnExecutor.swift:1155 | 38 / 44 / 29 | **5** (per N1007-D) | `route` 19 sites, `Route`/executor 28 blocks in 13 files | No | L (N1007-D plan) |
| 14 | `PronunciationVariations` vowel tables (`stressedVowels`, `unstressedVowel`, `vowelSpelling`, `vowelName`) | Hallie/Voice/PronunciationVariations.swift:244, :278, :524, :676 | 32 / 17 / 28 / 16 | **3** | 4 switches over the same IPA strings | No | M |
| 15 | `SearchField.parse` alias list | Catalog/CatalogQueries.swift:36 | 12 | **2** (small) | 2 | No | S |

Rows 10-15 are the cheap tail. Rows 13-14 get brief notes only (the brief's priority 4).

## The top 8 in detail

### 1. `RecognitionEngine`: shape 4, a protocol per engine (keep the enum as the persisted identity)
**Today:**
- 10 places choose what to **do** by switching on the engine:
  - `thresholdForEngine` ×2: PersonFinderTypes.swift:262 (no clamp) and :1254 (clamps). Two answers to one question.
  - `runScan` dispatch: JobLifecycle :1123. Hybrid is written inline as "Vision, then AdaFace on a miss".
  - `visionFeaturePrints`: :1424.
  - The dashboard label: :663, with `default:`. Next to it, the `visionActive` `==` chain at :660.
  - `embedVariant` (the cache key): PersonFinderCache.swift:134.
  - `workerBudgetMB` and `hardCap`: MemoryPressure.swift:80 and :100. All three of `hardCap`'s arms are identical, so that switch is dead.
  - `PersonEvaluationCLI`: :133 and :237.
- 7 more `switch self` blocks return constants (`title`, `displayName`, `shortLabel`, `subtitle`, `capabilitySummary`, `requirementsSummary`, `symbolName`). `title` and `shortLabel` return the same strings.
- Adding an engine means editing about 17 switches in 6 files. The file's own header (:71) tells you to "add a matching case in the `switch settings.recognitionEngine` block".

```swift
protocol FaceRecognitionEngine: Sendable {
    var info: EngineInfo { get }                      // the 7 constants, one value
    var metric: MatchMetric { get }                   // .featurePrintDistance | .cosineSimilarity
    func threshold(in s: PersonFinderSettings) -> Float
    func cacheVariant(_ s: PersonFinderSettings) -> String
    var workerBudgetMB: Int { get }
    func referencePrints(_ faces: [ReferenceFace]) -> [VNFeaturePrintObservation]
    func scan(_ ctx: EngineScanContext) async -> pfVideoResult?
}
struct HybridEngine: FaceRecognitionEngine {          // composition, not a 4th copy
    let primary = VisionEngine(), fallback = AdaFaceEngine()
    func scan(_ ctx: EngineScanContext) async -> pfVideoResult? {
        if let v = await primary.scan(ctx), !v.segments.isEmpty { return v }
        return await fallback.scan(ctx) ?? nil
    }
}
extension RecognitionEngine { var engine: any FaceRecognitionEngine { switch self { … } } }  // the ONE switch
```

- **In C++ terms:** an abstract base `FaceRecognitionEngine` with virtual methods, plus one concrete class per engine. The `enum` is the factory key that is saved to disk.
- **Guarantee kept:** exhaustiveness survives in the one factory switch, and a new protocol requirement makes every conformer fail to compile. `migratePersisted` and the raw values (the UserDefaults and profile tokens) stay on the enum untouched.
- **Bonus:** `metric` makes N1020-F2 (cosine thresholds read as distances) a type question rather than a convention. `splitByConfidence` asks `engine.metric` instead of guessing.
- **Pinning tests:** `PersonFinderEngineDispatchTests` and `PersonFinderCacheTests` (embedVariant per engine, byte-identical strings) already exist. Add:
  - a table test: for each `allCases`, `engine.info` equals the old 7 properties;
  - `workerBudgetMB` equals today's numbers;
  - `threshold(in:)` equals the **clamping** variant. Decide on purpose which copy wins; the profile copy clamps and the settings copy does not.
  - N1020-F2's red test, which goes green here.
- **Expected CCN after:** the factory 4; each conformer ≤5; `runScan`'s dispatch block about 3.
- **What could break:**
  - The cache-key strings (`embedVariant`): rows already cached must keep their keys. Pin them byte for byte.
  - The log lines that print `rawValue`.
  - Concurrency: the conformers are `Sendable` structs, so nothing is shared.

### 2. `AngelField` / `AngelRuleKind`: shape 2, done by splitting the enum by its own `Kind`
**Today:**
- `AngelField` (49 cases) carries a `kind` (text, number, list, choice, flag; AngelRuleLanguage.swift:100). Every reader then switches over **all** fields and ends in `default:`:
  - `candidateFlag` `default: false` (:603)
  - `flag` (:577)
  - `choice` `default: nil` (:614)
  - `text` `default: ""` (:532)
  - `number`, `isClassifierOnly`, `canonicalChoice`, validation (:333, :345, :357)
- `AngelRuleKind` mixes floors and signals in one enum (:657). `floorFires` ends in `default: return nil // a signal kind in the floors list` (ArchiveAngelScorer+Rules.swift:131), and `signal` has its own default at :225. The floors list is written a second time by hand in `AngelRuleSection.allowedKinds` (:686).
- **The defect class:** add a flag field and forget its `candidateFlag` arm, and rules that test it silently read `false`. Add a floor and forget its `floorFires` arm, and it never fires; the safety floors are `onMasterArchive` and `angelWorkingCopy`. The `mediaFloorFires` split (:140, "split out of floorFires (complexity gate)") is the chunking the brief bans, and it disappears in this design.

```swift
enum AngelField: Hashable, Sendable {
    case text(TextField), number(NumberField), names(NamesField), choice(ChoiceField), flag(FlagField)
    init?(jsonName: String) { … }   // FlagField(rawValue:) ?? NumberField(rawValue:) ?? …
    var jsonName: String { … }      // the raw value, unchanged
}
enum FlagField: String, CaseIterable, Sendable { case isPhoneClip, isLivePhotoMotion, … , eligible, vouched, dated }
extension FlagField { func read(_ c: ArchiveAngelCandidate, _ ctx: ClassContext) -> Bool { switch self { … } } } // exhaustive, no default

enum AngelRuleKind: Hashable, Sendable { case match, stars, floor(AngelFloor), signal(AngelSignal) }
enum AngelFloor: String, CaseIterable { case notVideo, onMasterArchive, … , noSound }   // allowedKinds(.floors) = AngelFloor.allCases
```

- **In C++ terms:** replace one big `enum` plus a `type` tag and `default:` fall-throughs with a `std::variant` of five small enums. Each `std::visit` arm must handle every alternative.
- **Guarantee kept:** the JSON names are unchanged (`kind` and field names stay strings in `AngelRule`, decoded through `init?(jsonName:)`). Exhaustiveness gets **stronger**: every switch is total with no `default:`. `allowedKinds(.floors)` becomes `AngelFloor.allCases`, so the hand list can no longer drift.
- **Pinning tests:**
  - A round-trip test: for every old raw value, `AngelField(jsonName:)?.jsonName == raw`, and the same for rule kinds.
  - A characterization oracle: run the current `rules.json` over the testbed candidates (`ArchiveAngelTestbed`, `ArchiveAngelCharacterizationTests`). Recommendations and rejection reasons must be byte-identical before and after.
  - A sensor: every `FlagField` reads a real candidate fact, so no arm returns a constant. It matches source the way the existing sensors do.
- **Expected CCN after:** `floorFires` about 19, one arm per floor with no default. Better, each floor's predicate can live on `AngelFloor` as `func fires(…)`, which brings it to about 3 plus `AngelFloor.fires` around 19. `candidateFlag` stays near 17, but it becomes exhaustive. This item is about **correctness**; the CCN drop is modest.
- **What could break:** rule-file validation messages (they quote `rawValue`, so keep `jsonName` identical) and the docs listing field names.

### 3. `ArchiveAngelJob.prepare`: shape 4, a pipeline of step types plus one sub-job verdict type
**Today:** one function (CCN 37) runs four steps: verify, balance, access copy, lossless. Each step has its own `if / else if` ladder.

The same ladder appears **three times**: verify :716-725, balance :775-792, `runTranscode` :893-913. It translates a finished sub-job into a step outcome: skipped by the user, then finished with output, then failed, then "did not finish". The copies have already **diverged**: "did not finish" is `.skipped` for verify but `.failed` for balance and transcode, and only transcode checks `stopRequested`.

```swift
/// What a finished sub-job means for this step — decided ONCE.
enum SubJobVerdict {
    case skippedByUser, produced(URL?), failed(String), stopped, didNotFinish
    init(job: some MediaFileOperationJob, skipped: Bool, stopRequested: Bool) { … }
}
protocol AngelPrepareStep {
    var kind: ArchiveAngelPlan.StepKind { get }
    func run(_ ctx: inout AngelPrepareContext) async -> StepResult   // ctx carries diagnosis, balancedRecord
}
struct VerifyAudioStep: AngelPrepareStep { … }   struct BalanceAudioStep: AngelPrepareStep { … }
struct AccessCopyStep: AngelPrepareStep { … }    struct LosslessCopyStep: AngelPrepareStep { … }
// prepare():  for step in steps { record(await step.run(&ctx)); await savePlan(); if stop { return } }
```

- **In C++ terms:** the Command (or Chain) pattern. Each step is a class with a virtual `run(Context&)`. The driver is a `for` loop over a `std::vector<std::unique_ptr<Step>>`.
- **Guarantee kept:**
  - **Order** is the array order (verify, balance, access, lossless), and balance reads the diagnosis that verify wrote, through `ctx`.
  - `savePlan` after every step, and the stop/skip check between steps, move into the driver loop, so a new step cannot forget them.
  - Steps are not persisted. `StepKind` is (in `plan.json`), and it stays as it is.
- **Pinning tests:**
  1. **First**, a characterization test per step outcome (the ladder rungs × 4 steps) through the existing testbed seams. `ArchiveAngelTestbed` already drives prepare.
  2. Then a `SubJobVerdict` unit table over every state × skipped × stopRequested.
  3. A decision Rick must make: should verify's "did not finish" be `.skipped` or `.failed`? Today's behaviour is pinned as it is until he rules.
- **Expected CCN after:** `prepare` about 4; each step ≤8; `SubJobVerdict.init` about 6.
- **What could break:** the step notes (shown in the review sheet and the testbed's expectations) must stay word for word. `removeIfPresentOffMain` runs before each output, so keep it inside each step, before the sub-job starts.

### 4. `AnalyzeCycler`: shape 4, one engine type per cycler family
**Today:**
- `runNow`, `engineIsFree`, `pause`, `resume` and `stop` each switch on the cycler (AnalyzeRunner.swift:53, :149, :165, :177, :191). So do `coverageWords` and `liveRule` (AnalyzePanelView.swift:199, :225).
- `pause`, `resume` and `stop` use `default: break`. Whether a cycler can pause is written down **twice**: `isPausable` (AnalyzeCyclers.swift:113) and those three switches. The two lists drift silently (the `MediaFileOperationKind.hasDetailView` lesson).
- Six more constant tables live in AnalyzeCyclers.swift.

```swift
protocol AnalyzeEngine {
    var info: CyclerInfo { get }                  // title, menuTitle, systemImage, help, hasVolumeScope, autoRunsToday
    var control: PauseControl? { get }            // nil = not pausable; replaces isPausable AND 3 default arms
    func refusal(_ m: VideoScanModel) -> String?  // engineIsFree
    func run(volume: String?, _ env: AnalyzeEnv) // runNow arm
    func live(_ s: AnalyzeLiveSnapshot) -> AnalyzeRowStateRule.Live
    func coverage(_ c: AnalyzeCoverageCounts, _ r: AnalyzeCoverageReport, now: Date) -> CoverageWords
}
struct DossierEngine: AnalyzeEngine { let stage: DossierStage }   // sceneCaptions / ocr / transcribe share one
extension AnalyzeCycler { var engine: any AnalyzeEngine { switch self { … } } }
```

- **In C++ terms:** the same abstract-base pattern as item 1. The three dossier stages are one class with a constructor argument, not three copies.
- **Guarantee kept:** the factory switch stays exhaustive. `control == nil` is the single source of "pausable": the UI disables Pause from it, and the runner calls it. The enum stays because `rawValue` keys UserDefaults (`analyze.schedule.<raw>`) and the accessibility ids (`analyze.row.<raw>…`, AnalyzePanelView.swift:422-512).
- **Pinning tests:** `AnalyzePanelSensorTests` and `AnalyzeCoverageTests` exist. Add:
  - a test per cycler that `info` equals the old six properties;
  - `(engine.control != nil) == oldIsPausable`;
  - `coverage(…)` returns identical strings for a fixed `counts`.
- **Expected CCN after:** each method ≤6; the factory 9 (one arm per case); `coverageWords` and `liveRule` disappear.
- **What could break:** the START/OUTCOME log strings (the MFO rule in CLAUDE.md; keep them word for word) and the `refuse(...)` texts.

### 5. `deleteConfirmedJunk`: shape 2 on the mode, shape 5 on the removal-boundary checks
**Today:**
- `JunkDeletionMode` (:69) is decided in five places:
  - the disk op (:402)
  - the lifecycle stage twice, for `alreadyMissing` and `succeeded` (:469, :478)
  - the ledger flag (:507)
  - the log word (:510)
- Inside the detached per-file loop (:343-398), four "last word" checks run in a fixed order, each `continue`-ing with an outcome:
  1. the caller's `beforeRemoval`
  2. the archive volume verdict
  3. the read-only volume verdict
  4. existence
- That order is load-bearing. The comment at :348 says the guard runs **before** the existence check, so a guarded file that is gone is refused, never stamped "already gone".

```swift
extension JunkDeletionMode {
    var lifecycleStage: LifecycleStage { switch self { case .toTrash: .trashed; case .permanent: .deletedPermanently } }
    var logWord: String { switch self { case .toTrash: "trash"; case .permanent: "permanent" } }
    var isPermanent: Bool { self == .permanent }
    func remove(_ url: URL, _ fm: FileManager) throws { switch self { case .toTrash: var r: NSURL?; try fm.trashItem(at: url, resultingItemURL: &r); case .permanent: try fm.removeItem(at: url) } }
}
/// The removal boundary, in its required order. First refusal wins; nil = clear to remove.
struct RemovalBoundary: Sendable {
    let checks: [@Sendable (String) -> JunkDeletionOutcome?]   // [callerGuard, archiveVolume, readOnlyVolumes, existence]
    func verdict(_ path: String) -> JunkDeletionOutcome? { checks.lazy.compactMap { $0(path) }.first }
}
```

- **In C++ terms:** the mode becomes a small value type with member functions instead of `if (mode == …)` scattered around. The boundary is a `std::vector` of predicates evaluated in order, where the first non-null result wins.
- **Why the ordered array is not a banned closure dictionary:** it is a **list** whose order *is* the specification, not a lookup keyed by case. The array literal is the one readable place the order is written. If Rick prefers no stored closures at all, keep `verdict(_:)` as four sequential `if let` lines in one named function. That still names the concept, and the loop body shrinks to one call.
- **Guarantee kept:**
  - The order is pinned by a test (below).
  - Every check stays inside the same synchronous stretch as the removal. `verdict` is called immediately before `mode.remove`, with no `await` between (the JunkDeletionGuard contract).
  - The outcome switch at :444-491 stays as it is: shape 1, associated values, decided once.
- **Pinning tests:** `JunkDeleteActionRegressionTests` and about 48 call sites exist. Add:
  - an **order test**: a guarded file that is also missing → `.refused`, not `.alreadyMissing`;
  - a path on the archive volume that is also read-only → the archive refusal text;
  - mode → lifecycle stage for both outcomes;
  - the log line is unchanged.
- **Expected CCN after:** `deleteConfirmedJunk` about 14; `RemovalBoundary.verdict` 2; the mode members ≤2 each.
- **What could break:** the refusal texts ("— nothing moved") and the ledger `permanent:` flag. **Data-risk: this is the one Trash routine, so it gets a codex pass** (invariant: "no file is removed unless every boundary check returned nil in the same synchronous stretch, in the pinned order").

### 6. `ArchiveAngelPlan.StepKind`: shape 2, one `info` table with an optional companion
**Today:** four cases, but their attributes are spread over 6 switches in 4 files:
- `label` (ArchiveAngelPlan.swift:31)
- `columnTitle` and the done-label switch (DetailView.swift:397, :406)
- `companionChips` (BufferHygiene.swift:298: "access" / "lossless" / "balanced" / nil)
- `roleLabel` (Promoter.swift:69: the **archive manifest** role, nil for verify)
- the landing counter (Promoter.swift:166)

The fact "verify leaves no file" is repeated in four places as `case .verifyAudio: return nil / break`.

```swift
struct StepKindInfo { let label, columnTitle, doneLabel: String; let companion: Companion? }
struct Companion { let chip: String; let manifestRole: String }     // nil = the step leaves no file
extension ArchiveAngelPlan.StepKind {
    var info: StepKindInfo {
        switch self {
        case .verifyAudio:  .init(label: "Verify audio", columnTitle: "Verify Audio", doneLabel: "Audio Verified", companion: nil)
        case .balanceAudio: .init(label: "Balanced audio", columnTitle: "Balance Audio", doneLabel: "Audio Balanced",
                                  companion: .init(chip: "balanced", manifestRole: "Balanced audio"))
        …
        }
    }
}
```

- **In C++ terms:** a `constexpr` table of structs indexed by the enum. The enum stays because it is `Codable` in `plan.json`.
- **Guarantee kept:** one exhaustive switch instead of six. The concept "leaves a companion file" becomes an `Optional` the compiler makes every caller unwrap.
- **Pinning test:** for each case, the old functions' outputs equal the new `info` fields. Pin the **manifest role strings** byte for byte, because they are written into the archive. `ArchiveAngelPromoterTests` exists.
- **Expected CCN after:** 4-5 per function → `info` 4; callers 1-2.
- **What could break:** the manifest role text (pinned) and the review sheet's column titles.

### 7. `TranscodePreset`: shape 2, one `info` table; the recipe switch stays
**Today:** six parallel `switch self` blocks return constants (`codecTag`, `purposeTag`, `fileExtension`, `subtitle`, `humanLabel`, `configurationDescription`). One more switch builds the ffmpeg arguments (TranscodeJob+Args.swift:32). The raw value is not decoded from storage (no `TranscodePreset(rawValue:)` in the app), but `preset.rawValue` is printed in Angel logs (ArchiveAngelJob.swift:888).

```swift
struct TranscodePresetInfo { let codecTag, purposeTag, fileExtension, subtitle, humanLabel, configurationDescription: String }
extension TranscodePreset { var info: TranscodePresetInfo { switch self { … } } }  // ONE table
// transcodeArgs(preset:…) stays a switch: it is the one place recipes are decided, and .preservation reads sourceAudioIsPCM.
```

- **In C++ terms:** six getters merged into one `struct` returned by one function.
- **Why shape 2 and not 3:** callers pattern-match the cases (`preset == .editingLT` inside the args, the Angel's `.archival` / `.preservation`), and the args switch is real per-case behaviour.
- **Guarantee kept:** one exhaustive switch; a new preset cannot compile without all six fields.
- **Pinning tests:** `TranscodeTests` exists. Add a table test that the derived-file names are unchanged (`<stem>.vs.<purpose>.<codec>.<ts>.<ext>`), because Finder searches and old files depend on them.
- **Expected CCN after:** 6 × 4-5 → 1 × 4.
- **What could break:** nothing persisted; the context-menu labels.

### 8. `DriveHealthProbe.parseSmartctlJSON`: shape 6, a `Decodable` model of smartctl's report
**Today:** CCN 42. Hand-digging through `[String: Any]` with `as? NSNumber` chains, plus nested closures that each try the ATA key and then the NVMe key (`power_on_time.hours` then `nvme_smart_health_information_log.power_on_hours`; the same for temperature). The ATA attribute table is a loop with ID lookups.

```swift
struct SmartctlReport: Decodable {
    let model_name: String?; let serial_number: String?; let firmware_version: String?
    let user_capacity: Capacity?;  struct Capacity: Decodable { let bytes: Int64? }
    let smart_status: Status?;     struct Status: Decodable { let passed: Bool?; let nvme: NVMe? }
    let rotation_rate: Int?; let power_on_time: Hours?; let temperature: Temp?
    let nvme_smart_health_information_log: NVMeLog?
    let ata_smart_attributes: ATAAttributes?
}
extension SmartctlReport {
    var powerOnHours: Int? { power_on_time?.hours ?? nvme_smart_health_information_log?.power_on_hours }
    var overall: SmartOverall { … }   // passed → .passed/.failingNow; nvme.value; else .unknown
}
```

- **In C++ terms:** replace walking a `nlohmann::json` with `.at()` and type checks by deserializing into a plain struct once. The "ATA or NVMe" fallbacks become one-line `??` accessors.
- **Guarantee kept:** tolerant decoding. Every field is optional, so an unexpected smartctl version gives `nil` fields, not a failure. Keep a `try?` around the decode so bad JSON still returns `nil`, as today. Use `CodingKeys` if Rick prefers camelCase names.
- **Pinning tests:** `DriveHealthTests` exists. Before the change, add a fixture test per transport (one ATA HDD, one SATA SSD, one NVMe JSON sample, synthetic and with no serials from real drives) asserting today's `DriveHealthSnapshot` field by field. Also assert the warnings list.
- **Expected CCN after:** the mapping function about 10; the accessors ≤3.
- **What could break:** the `NSNumber` bridging quirks. smartctl sometimes emits integers as floats; decode those fields as `Double` and convert, or keep a tiny lossy-int wrapper.

### Rows 9-15, one line each
- **9 · CLI parsers (shape 6):** four hand-rolled `while index < arguments.count { switch argument { … } }` loops. A small shared declarative option table (`[CLIOption(name:, takesValue:, apply: WritableKeyPath …)]`) or Swift ArgumentParser would replace them. **ArgumentParser is a new package dependency and needs Rick's OK.** The table needs none. Keep `PersonEvaluationCLI`'s post-parse coherence checks (`--aggregation` vs `--min-hits`) as explicit validation after the table runs.
- **10 · `ConfirmRating` (shape 2):** six constant tables (`prior`, `symbol`, `color`, `keyboardKey`, `hint`, plus the legacy decode) → one `info`. `writebackTier` stays a separate switch (behaviour). The enum is `Codable`, so the raw values are frozen.
- **11 · `VolumeStatusEnums+Presentation` (shape 2):** each of the four enums has `icon` + `color` (+ `shortLabel`) as parallel switches → one `presentation` per enum. Cheap; low payoff.
- **12 · `StewardCaseKind` (shape 2):** `chip`, `lane`, `systemImage` → one `info`. Presentation only, even though Steward is a data-risk folder.
- **13 · Hallie executor (shape 5):** follow N1007-D-Hallie-rewrite-eval (ordered rule values with an oracle over the old ladder). Not re-argued here.
- **14 · Pronunciation vowel tables (shape 3):** four switches key on the same IPA strings (`"æ"`, `"ɑ"`, …). A `struct Vowel { let ipa, name, respelling…; static let shortA = … }` carries the attributes as data, as in the exemplar. `CaseIterable` becomes an explicit `all` plus a sensor test. Brief note only.
- **15 · `SearchField.parse` (shape 2, small):** move the alias lists onto the enum (`var aliases: [String]`) so `parse` is `allCases.first { $0.aliases.contains(raw) }`, and the search help text can list the aliases from the same data.

## Leave it: high-CCN switches that are good as they are
1. **`MediaFileOperationState`** (MediaOps/MediaFileOperations.swift:403): a five-state machine with payloads (`finished(summary:)`, `failed(message:)`). Its switches (`isActive`, `cancelWasRequested`) are exhaustive on purpose; that comment block is the design.
2. **`VerifyVideoRules.noteFragment`** (MediaOps/VerifyVideoRules.swift:505, CCN 24): one exhaustive switch over `VideoVerifyFinding`, whose 17 cases all carry associated values. The text needs the payload, so a table cannot express it. The three switches on findings (severity, fragment, fix) all live in this one rules file.
3. **The outcome switch in `deleteConfirmedJunk`** (:444-491): it applies a per-file `JunkDeletionOutcome` (with `failed(Error)` and `refused(String)` payloads) once. Only the **mode** switches inside it move (item 5).
4. **`DeleteDuplicatesJob.phaseOne`** (MediaOps/DeleteDuplicatesJob.swift:297, census `init` CCN 20): nested switches over the verification results (`held`, `verified`, `retainedQuarantine` with payloads). This is a proof state machine and reads top to bottom. One small cleanup, not a reshape: the arm `.refused(reason: duplicateRefusalNote(failure, keeper:), cancelled: failure == .cancelled)` is written four times and could be one `DeleteDuplicatesDiskOutcome(refusal:keeper:)` initializer. Do it with the next change that touches this file.
5. **`LedgerNarrator.sentence`** (VideoScanCore/LedgerNarrator.swift:78, CCN 38): one exhaustive switch over the event kind, the one place each event is phrased. The complexity comes from the untyped `detail: [String: String]` bag. The real cure is a typed payload per event, which **changes the ledger format**. That escalates to Rick (CLAUDE.md: log and ledger formats) and is not worth it for a display function.
6. **`SearchField` matching** (`pfFieldTokenMatches`, Catalog/CatalogQueries.swift:278, CCN 21): one behaviour switch, one decision per field. A protocol per field would scatter the search semantics that are now readable on one screen. Only the alias list moves (row 15).
7. **`AngelValue.encode` / `typeName`** (AngelRuleLanguage.swift:51, :61): exhaustive switches over a payload enum. Textbook Swift.
8. **Error enums** (`CatalogWriteError`, five constant switches): error enums stay enums (brief rule). Their message switches are the localizable-text table.

## Batching proposal (one folder per night)

| Night | Folder | Items | Codex? |
|---|---|---|---|
| 1 | `MediaOps/` | 5 (`deleteConfirmedJunk` mode + boundary), 7 (`TranscodePreset`) | **Yes for 5**, invariant above, files `VideoScanModel+JunkDelete.swift` only. 7 is in-house `qa`. |
| 2 | `ArchiveAngel/` (part 1) | 6 (`StepKind.info`), then 3 (prepare pipeline + `SubJobVerdict`) | 3 writes and removes buffer files: ask Rick about a codex pass on `ArchiveAngelJob.swift` (invariant: "every step's output is removed-then-made inside the entry folder, and the plan is saved after every step"). 6 is in-house; pin the manifest role strings. |
| 3 | `ArchiveAngel/` (part 2) | 2 (`AngelField` / `AngelRuleKind` split) | In-house `qa`, plus the characterization oracle over the testbed. Angel ranking heuristics are outside codex scope under the spend policy. Ask Rick only if he wants the floors' "silently never fires" closed with a codex look. |
| 4 | `People/` | 1 (`RecognitionEngine` protocol; fold in N1020-F2's fix), 10 (`ConfirmRating`), 9 (`PersonEvaluationCLI` / `RecipeCalibrationCLI` table) | No (no deletes). Run `testing` on the cache-key pins first. |
| 5 | `Analyze/` | 4 (`AnalyzeCycler` engines) | No |
| 6 | `Volumes/` + `ModelsUI/` + `Steward/` + `Catalog/` | 8 (smartctl `Decodable`), 11, 12, 15 | No |
| — | `Hallie/` | 13, 14 | Follow N1007-D's plan and schedule |

**Order inside every night:** pinning and characterization tests first, red-checked by mutation on the Mac. Then the reshape, with the tests unchanged. Then `swift-expert` (blind idiom review) and `qa` (behaviour). The gate (Σ max(0, CCN−15) over the touched files) should drop on every night above. None of these designs widens access or adds `default:` arms; items 2 and 4 **remove** about 19 of them.

## Not covered (time box)
- **Census functions not opened:** `HallieLineageQuestion.answer`, `HallieShellCLI.init` / `render`, `HallieRepairTurn.describe`, `HallieResponseCommit.apply`, `HallieAncestorStatisticsQuestion.who`, `ArchivistChatWindow.handle`, `HallieWebBridge.payload`, `OllamaQueryTranslator.init`, `ArchivistConversationCommand.smalltalkReply`, `HallieTerminalLineEditor.handle`, `HallieTellingMode.question`, `HallieBiographyCard.countWord` (all Hallie, so N1007-D), `FootageGrouping.text`, `PruneApplyJob.set`, `PersonFinderTypes.swift:1364 set`, `CatalogShowingSummary.words`, `VerifyAudioProbe.noteFragment`, `ArchiveReadiness.sheetLine`.
- **Constant-table files not opened:** `ModelsUI/ArchiveModels+Presentation`, `Hallie/LLM/ArchivistEndpointSettings`, `Archive/ArchiveView+Categories`, `Volumes/VolumeUIStatus`, `ModelsUI/MediaClassification+Presentation`, `ModelsUI/ArchiveHealth`, `FamilyTree/KinshipWarning`, `Catalog/CatalogDistributionPane`, and the rest of the census list below 4 switches. By the census numbers they are rows-10-12 material (shape 2, S effort).
- **The `outcome` subject in `FamilyTree/`** (9 switches in 4 files) was not traced to its type(s), so whether one type is switched on for behaviour 4+ times there is unknown. The `kind` count (82) is spread over many distinct types: Hallie 15, ArchiveAngel 13, Archive 11, FamilyTree 5, the rest ≤4 per folder. Apart from `StepKind` (item 6) and `AngelRuleKind` (item 2), no single `kind` type reached 4 behaviour sites in what I read.
- Nothing was built or run. CCN-after figures are estimates from arm counts, not lizard runs.

## Blockers & environment
- **The brief was not on any branch at session start.** I began from Rick's description. It landed on main (`b273af96`) mid-session; I merged and followed it from there. No work was lost.
- **Branch:** the brief names `cloud/C06-switch-to-types`. This session may push only to its designated branch, so the report is on `claude/compassionate-babbage-kn9mbj`, like the other cloud reports in this batch.
- **No lizard here** (PyPI is blocked, and the brief says not to recompute). I used the census as given. The census line numbers lag main by a few lines in places; every file:line above was re-read on main.
- No other tool failures.
