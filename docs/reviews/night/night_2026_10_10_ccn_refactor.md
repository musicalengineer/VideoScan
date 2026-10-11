# Night shift 2026-10-10 → 10-11: eight high-CCN functions → best-practice Swift

Branch `worktree-agent-ace3d8319d66a502f`, eight commits, one per function.
Method per function (Rick's red-green-revert rule): characterization tests
pinning the CURRENT behaviour first → prove each pin is load-bearing by
mutating the code and watching it go red → restore → refactor → the same
pins green with identical outputs → complexity gate → commit.

## Per-function table

CCN / NLOC from `scripts/complexity_metrics.py` (lizard 1.22.1, the gate's
own numbers). "Excess" is the CCN-15 ratchet sum for the touched file(s).

| # | Function | CCN before → after | NLOC | Concept used | Tests added | Mutation evidence |
|---|---|---|---|---|---|---|
| 1 | `DriveHealthProbe.parseSmartctlJSON` | 42 → 2 (members ≤ 6) | 128 → 37 | **Codable wire model**: `SmartctlReport` (one nested struct per smartctl JSON object, `@Field` tolerant decoding), decisions as named members (`overallStatus`, `mediaTech(refining:)`, `rawValue(id:)`, `partialDataWarning`); ATA ids 5/196/197/198 as named constants | `DriveHealthSmartctlCharacterizationTests` — 14 pins: every field of the two real captures, SATA SSD, USB bridge, NVMe status word, exit-code bits, malformed fields, last-duplicate-wins | swap ids 196/197 + break `~64` mask → 4 pins red |
| 2 | `LedgerNarrator.sentence` | 38 → 16 (one per `Kind` case + 1; templates ≤ 7) | 88 → 34 | **Switch as dispatch**: the exhaustive switch only jumps; one template function per kind (`attestationSentence`, `approvalSentence`, …), place/date share `fieldSetSentence` | `LedgerNarratorCharacterizationTests` — 85 golden rows generated from the pre-refactor code (every kind × actor × detail shape) + a row that fails when a Kind/Actor has no golden | flip attestation "no", approval truncation 5→6 → 2 pins red |
| 3 | `GedcomFamilyGraph.relatives` | 36 → 5 (`route` 11, `walk` 6, `select` 5) | 85 → 17 | **Enum with data**: `ExtendedRelation.route(firstParent:) -> KinshipRoute` (`.chain([Relation])` / `.siblingInLaw(sex:)`), `relativeSex`, `KinshipSide.parentRelation`; then walk (traversal) → select (filter / dedupe / refusal) | `GedcomKinshipPathCharacterizationTests` — 360 golden rows (every relation × side for five subjects of the synthetic tree; full prose paths or exact missing-hop phrase) | shorten cousin route + reword "a male" → 19 rows red |
| 4 | `PersonEvaluationCLI.parse` | 37 → 4 (`Options.apply` 15, `validate` 11) | 72 → 16 | **Vocabulary enum + per-flag apply + validate()**: `Flag: String` spells every flag once; `Options.apply(_:value:)` exhaustive; value parsers named (`floatValue`, `positiveInt`, `setEngine`, …); required-then-coherence checks in `validate()` | `PersonEvaluationCLIParseCharacterizationTests` — 10 tests / ~60 assertions: defaults, exact error text, error precedence, last-wins, the dlib+arcface double-set quirk | reword two messages → 3 tests / 7 assertions red |
| 5 | `TreeIndex.init(graph:)` | 34 → 1 (builders 11 / 10 / 6 / 11) | 179 → 24 | **Builder value types**: `TopologyTables`, `NameTables`, `SidebarTables`, `LaunchTables`, each named for the table it fills; `init` delegates to the memberwise init (fields assigned in one place) | `GedcomTreeIndexBuildCharacterizationTests` — frozen verbatim copy of the old init compared with `==` on 4 graphs (kinship, edge-case, 5k + artifact round trip, 100k) | haystack separator + given-name slot → all 4 pins red |
| 6 | `HallieWebPage.html` | 49 → 1 (every piece 1) | 232 → 29 | **Page as pieces by concern**: `head`, `styles`, `markup`, then `shellScript` / `speechScript` / `renderScript` / `browseScript` / `askScript`; JS without a name is a constant | `HallieWebPageTests` — 4: sections in document order, escaped name in all 6 places, LAN-only promise, pieces brace-balanced and placed verbatim | byte-identity: SHA-256 of the page for 2 names unchanged (584063f5…, 296feb3e…) via a standalone `swiftc` dump before/after |
| 7 | `CatalogView.volumeContextCatalogSection` | 36 → 1 (groups 11 / 6 / 6 / 5 / 5) | 182 → 14 | **Pure decision functions + item groups**: `VolumeContextMenuRules` (`captionableVideoCount`, `offersMigrationReport`, `offersVolumeNameBackfill`, `offersReset`); five `@ViewBuilder` groups named for what their items do | `VolumeContextMenuRulesTests` — truth tables incl. the pinned prefix-match quirk; existing source sensors (`DeleteVolumeCatalogPlanTests`, the CatalogFocusPlan suites) still pass | `offersReset` drops `.stopped`, `offersMigrationReport` `||`→`&&` → 2 tests red |
| 8 | `CatalogContent.catalogTableBase` | 28 → 14 (`icon(for:)` 7) | 138 → 94 | **Cell as a view + glyph ladder as an enum**: `CatalogFilenameCell` and `CatalogRowStateIcon.icon(for:pairTint:)` with `systemImage` / `color` | `CatalogRowStateIconTests` — the priority ladder, pair glyph by stream type, symbols and colours | swap purged/set-aside rungs + rename the hammer symbol → 2 tests red |

(The brief listed #8 at 34; `filenameColor` had already been extracted on
10/10 before this shift, so the starting point tonight was 28.)

## Bugs found (not fixed — pinned as current behaviour, for bug-fix to own)

- `PersonEvaluationCLI.parse`: `--engine dlib --engine arcface` leaves BOTH
  `legacyDlib = true` and `engine = .arcface`; `evaluate` then dispatches on
  `legacyDlib` first, so the later `--engine arcface` is silently ignored
  (the run and the emitted label are both "dlib"). Every other repeated
  flag is last-wins. Pinned, not endorsed, in
  `test_repeatedScalarFlags_lastWins_butDlibTokenStaysSet`.
  File: VideoScan/VideoScan/People/PersonEvaluationCLI.swift (`Options.setEngine`).
- `VolumeContextMenuRules.captionableVideoCount` (was inline in the menu):
  `fullPath.hasPrefix(searchPath)` is a plain prefix match, so a volume at
  `/Volumes/A` counts files under `/Volumes/AB/…`. Pinned in
  `test_captionableVideoCount_isAPlainPrefixMatch_pinnedNotEndorsed`.
- Pre-existing, unrelated to tonight: `scripts/gauntlet/manifest.json` on
  main already fails `inventory.swift --validate` (7 "tests inventory
  changed" files, blocked/selector/floor mismatches in `unit` and
  `integration`). The pre-commit drift check only asks that NEW files be
  assigned, so commits pass; the gauntlet itself would refuse to run.
- Measurement, not code: lizard misreads a JavaScript `//` comment inside a
  Swift `"""` literal as a Swift comment (HallieWebPage.swift line 142
  carried a stray `"`), loses the string state and counts the rest of the JS
  as branches. `html`'s true CCN was 1 all along. `scripts/complexity_metrics.py`
  should blank multi-line literal bodies before lizard — proposed, not done.

## Performance

- `TreeIndex.init` 100k synthetic pedigree: Debug 3309 ms split vs 3310 ms
  frozen single-pass; **Release 678 ms vs 680 ms** (same work, one extra
  dictionary lookup per person). The scale sensor's own "100k index build"
  read 649 / 658 ms in the two Release runs (the test's comment records
  ~300 ms on 2026-08-29 — the frozen copy gives the same number, so this is
  the host tonight, not the split).
- `relatives`: traversal moved verbatim; one enum value per call added.
- Scale sensors asserted in the authoritative lane (Release, coverage off,
  `TEST_RUNNER_VIDEOSCAN_GEDCOM_PERF=1`): 100k token / surname / namedLike /
  given lookups 0.61 / 0.39 / 0.02 / 0.39 ms (budgets 1 ms); sidebar 'bre'
  2.2 ms (5); commonAncestors 0.14 ms (20); relationshipPath 1.4 ms (20);
  100k artifact decode 55.7 ms (150); real 39k artifact decode p95 23 ms
  (60), install p95 5.3 ms (20), warm common-ancestor p95 4.7 ms (20);
  100k install 0.86 ms (50), keystroke 0.54 ms (5); Hallie 100k owner
  binding p50 9.7 ms (50); 32 pointer pins 46 ms (500); 16k real export
  parse 2.47 s (10 s), index build 154–157 ms, install 2.5 ms (100),
  keystroke 0.01 ms (10).

## Release run (every suite touching these files + *Sensor* / *Boundary* + GedcomScaleSensorTests)

App target, `-configuration Release ENABLE_TESTABILITY=YES -enableCodeCoverage NO`,
176 suites selected by name (every suite type in a test file that mentions a
touched symbol or file, plus every `*Sensor*` / `*Boundary*` type — counts
checked non-zero): **1036 Swift Testing tests in 168 suites passed; every
XCTest suite passed except one timing assertion in GedcomScaleSensorTests**
(log: scratchpad `release.log`). Core package, `swift test -c release` over
LedgerNarrator*, GedcomKinshipPath*, GedcomTreeIndexBuild*,
GedcomIndexEquivalence*, GedcomLaunchTablesEquivalence*, GedcomCompiledTree*,
GedcomLaunchPerf, GedcomPerfBaseline, TreeWalkScale, GedcomRelationshipPath
and the two Core sensors: **53 XCTest + 24 Swift Testing tests passed; one
Swift Testing timing sensor failed** (below).

Three timing assertions were red, none on code this shift touched:

1. `GedcomScaleSensorTests.testRealCompiledArtifactLaunchPathWithinBudget`
   — launch-bundle p95 **129 ms vs 60 ms budget** (p50 128 ms, so not an
   outlier), real promoted 39,250-person artifact. The bundle is built from
   the DECODED artifact (index installed, no TreeIndex build), its rows /
   identity legs read index arrays the pins proved byte-identical (rows p95
   2.6 ms, identity p95 26 ms — both fine), and the anchors leg uses only the
   one-hop `relatives(.spouse/.children/.parents, of:)` that was not changed.
   Re-run alone: same 126–129 ms. BASELINE at 4e3210e51: see below.
2. `GedcomScaleSensorTests.testHallieNameRoutesOnHundredThousandPersonTree`
   and `…SurnameRosterOnShared…` — surname roster p50 **257.7 ms / 260.2 ms
   vs 250 ms** (passed at 246.6 ms in the full run). This is the one the
   brief said already sits 5–20 ms over on main; it straddles the line both
   ways tonight, so not made worse. Why it is slow is outside tonight's
   files: the roster path is HallieTurnExecutor → `people(withSurname:)` (0.4
   ms) → HallieWhichOne candidate building over thousands of "Breen"s; the
   index lookups it rests on are all under budget.
3. `GedcomParseContentionSensorTests.parsesOnEightThreadsEachCostAboutWhatOneCostsAlone`
   (Core) — 8 concurrent parses cost 0.88 s CPU each vs 0.136 s alone
   (×6.5; the sensor's line is ×6). The parser was not touched (TreeIndex is
   built lazily, never during parse). Host load averages were 10–19 on 16
   cores all evening (other agents' worktrees were building); the sensor
   itself documents that CPU-seconds are used so a busy host "does not trip
   it", but at ×6.5 it did. BASELINE at 4e3210e51: see below.

**Baseline (same tests, same lane, a detached scratch worktree at the
branch's base 4e3210e51, nothing else running):** all three fail there too,
with the same numbers —

| Sensor | Base 4e3210e51 | This branch | Budget |
|---|---|---|---|
| launch bundle p95 (real 39k artifact) | 128.9 ms (p50 127.5) | 128.9 ms (p50 128.4) | 60 ms |
| Hallie 100k surname roster p50 | 249.0 / 250.6 ms | 246.6 / 257.7 / 260.2 ms | 250 ms |
| parse contention, 8 threads vs alone | 0.851 s vs 0.137 s (×6.2) | 0.882 s vs 0.136 s (×6.5) | ×6 |
| 100k index build (printed, not asserted) | 658 ms | 649 / 658 ms | — |

So none of the three is a regression from this shift; the first is a real
drift on main (budget 60 ms, measured 8.8 ms when written on 2026-08-29,
~128 ms tonight — worth a bug-fix look at `FamilyTreeLaunchBundle.build`'s
anchors leg, which is where the time must be since rows and identity are
each under 26 ms), the second is the known straddler, the third is a
load-sensitive CPU-time ratio that sat at ×6.2–6.5 all evening on a host
with other agents building.

## Self-review against .claude/agents/swift-expert.md

Read cold, per rubric line. Verdict: **Good** — each of the eight is easier
to change than before, and none is a reshuffle (no step1/step2 helpers, no
closure tables, no parameter threading beyond the menu's existing
`targets / first / single` triple that its sibling sections already use).

- Naming & call sites: `report.mediaTech(refining: hint)`,
  `relation.route(firstParent:)`, `VolumeContextMenuRules.offersReset(statuses:)`,
  `CatalogRowStateIcon.icon(for:pairTint:)` read as sentences; Bools read
  as assertions (`isSelected`, `isOffline`). One fix made during review:
  the CLI value parsers `floatValue` / `positiveInt` were internal with a
  single caller — now `private static` (follow-up commit).
- Types & semantics: wire format → `Decodable` struct (1); plan → enum with
  data (3); vocabulary → raw-value enum (4); tables → private builder value
  types (5); glyph ladder → enum with two lookup tables (8). No new
  reference types, no stringly-typed state added.
- Decomposition: every new unit has one nameable job; the only
  ordered pair is `walk` → `select` in (3), which are two different jobs
  (traversal vs. selection) and were already two paragraphs of the old body.
- Concurrency / SwiftUI: untouched by design; the two O(records) walks the
  volume menu does in its builder are named in the file header as debt.
- Error handling: unchanged messages and precedence (pinned); `CLIError`
  kept.
- Testability: 6 new pure seams (`SmartctlReport`, the templates,
  `KinshipRoute`, `Flag`/`apply`/`validate`, `VolumeContextMenuRules`,
  `CatalogRowStateIcon`) each tested without the thing they used to be
  buried in.
- Documentation: every WHY comment moved with its code (Rick's dates, GH
  numbers, incident notes); new doc comments say what each piece decides.
- Where I would still push: `LedgerNarrator.sentence` is an honest 15-case
  dispatch (CCN 16); a `[Kind: template]` table would read worse and lose
  exhaustiveness. `Options.apply` likewise sits at exactly 15. Both are
  the shape of the problem, not debt. `CatalogView+VolumeTable.swift` is
  1052 lines (was 1014) — the doc comments and signatures of five builders;
  the next move there is moving the context-menu sections to their own
  file, a mechanical split for another night.

## Merge

**Not merged — branch left ready.** The worktree isolation guard refuses
every `git -C /Users/rickb/dev/VideoScan …` from this agent ("a
worktree-isolated agent's git operations must target its own worktree"),
so the merge-into-main and push steps in the brief cannot be run from
here and I did not route around it. What is ready for the Manager:

- `main` moved by one docs-only commit (43898635d) during the shift; it is
  merged INTO the branch (2fa395d74), so `git merge worktree-agent-ace3d8319d66a502f`
  on main is a **fast-forward** — no manifest conflicts to resolve.
- Commits: f969a1e34 · 28166f594 · d0dba1978 · b39795b6e · 1376a24a9 · 2ffd065aa · 91c6f3c69 · 798a7a610 · 2fa395d74 (main merged in) · ab87b3266 (self-review tweak) · then this report. Checkout is clean.
- The three red items above are timing sensors on untouched code; the
  baseline comparison below is the evidence the Manager needs to decide
  whether main's nightly would have shown them regardless.

## Exemplar for Rick: the smartctl report (commit 1)

Before — the parser walked an untyped dictionary and made every decision
inline (one of ~12 such blocks):

```swift
let smartStatus: SmartOverall = {
    guard let smart = root["smart_status"] as? [String: Any] else { return .unknown }
    if let passed = smart["passed"] as? Bool { return passed ? .passed : .failingNow }
    if let nvme = smart["nvme"] as? [String: Any],
       let value = (nvme["value"] as? NSNumber)?.intValue { return value == 0 ? .passed : .failingNow }
    return .unknown
}()
```

After — the document is a type, and the decision is a member of it:

```swift
struct SmartctlReport: Decodable {
    @Field var smartStatus: SmartStatus?          // absent / null / wrong type → nil
    struct SmartStatus: Decodable { @Field var passed: Bool?; @Field var nvme: NVMeStatus? }

    var overallStatus: SmartOverall {
        guard let smartStatus else { return .unknown }
        if let passed = smartStatus.passed { return passed ? .passed : .failingNow }
        if let value = smartStatus.nvme?.value { return value == 0 ? .passed : .failingNow }
        return .unknown
    }
}
```

In C++ terms: `Decodable` with `JSONDecoder` is a compiler-generated
deserializer keyed on the member names (`convertFromSnakeCase` maps
`smart_status` → `smartStatus`), so the struct IS the schema — no more
`root["smart_status"] as? [String: Any]` casts. `@Field` is a tiny
template wrapper (`std::optional<T>` with its own `operator>>`) that turns
a decode failure into `nullopt` instead of an exception, which is exactly
the tolerance the old dictionary walk had implicitly. The parser is left
as the one place that assembles the snapshot from named members, so a new
smartctl field is one `@Field` line plus one argument, and each decision
is unit-testable without a snapshot.
