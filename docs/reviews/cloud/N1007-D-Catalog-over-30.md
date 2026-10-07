Brief: N1007-D-Catalog-over-30 | Source: main@74bbd255 | Wall clock: 40 | Files read: 29
Finding count: 6 (REAL 5 / NEEDS-MAC 1 / NOISE 0)
Verdict: Model/ has nothing over 30; Catalog/ has 8 baseline offenders, 3 of which merged refactors already cut on 10-07 (the baseline predates those merges), and the other 5 each have a design-led split below that brings every piece to 15 or less. Two of the findings matter more than the debt: Open-in-viewer skips the volume-identity check that preview enforces, and "Reset & Re-probe" forgets a volume's records with no confirmation.

## Measurement

- `ci/baselines/complexity_debt.json` (last refreshed by `de2e0ac9`, nightly 2026-10-07 02:55 -0400), filtered to `VideoScan/VideoScan/Catalog/` and `VideoScan/VideoScan/Model/` with CCN > 30.
- `origin/metrics` latest row: ts 2026-10-07T11:26Z, sha `4b79bbbb`. It shows Catalog `ccn_over_30: 8` and Model `ccn_over_30: 0`, which matches the baseline. That nightly ran **before** the 13:35Z and 13:44Z merges of `85b74445` and `be8cbe8f`, so three rows below are stale. Expect the next nightly to show Catalog at 5.
- Model/: the worst function is `VideoScanModel.init` at CCN 16. Nothing is over 30, so Model/ needs no plan.
- I could not run lizard (see Blockers). To check that the merged splits did not leave a new piece over 30, I used a rough branch counter: it counts `if/guard/case/for/while/catch`, `&&`, `||`, `??` and ternaries after stripping strings and comments. It overcounts lizard by roughly 10–20%. In the three refactored files, no function now reaches 20 on it.

| file::function | CCN | nloc | status |
|---|---|---|---|
| Catalog/CatalogAudit.swift::CatalogAuditor.run | 66 | 165 | **skipped**, changed by `85b74445` (merge of `30361149` and `1264b5f5`: "run 66→1"). Current source is a tally plus a table of 10 named check functions. Rough count: about 2. |
| Catalog/InspectorPanel.swift::InspectorPanel.body | 57 | 424 | **skipped**, changed by `be8cbe8f` (merge of `0bab172f`: "body 57→2"). Current body is a straight list of 23 section builders. Rough count: about 2. |
| Catalog/VideoScanModel+DateInference.swift::VideoScanModel.catchUpInferredDates | 51 | 134 | **skipped**, changed by `be8cbe8f` (merge of `8f6ec15a` and `65413af1`: "51→3"). Current source is one call per rule over an `inout` pass. Rough count: about 3. |
| Catalog/CatalogView+VolumeTable.swift::CatalogView.volumeContextCatalogSection | 36 | 182 | planned (§1) |
| Catalog/VideoScanModel+RescanPreservation.swift::RescanPreservedFields.isWorthRestoring | 36 | 38 | planned (§2). `b78d047f` touched the file but deliberately left this function alone: it added `carriesKeptFingerprint` beside it. |
| Catalog/CatalogContent+Table.swift::CatalogContent.catalogTableBase | 34 | 143 | planned (§3). The 10-05/10-06 commits (`96291653`, `835065cf`, focus work) changed the file but not this function, and the 34 was measured after them. |
| Catalog/InspectorPanel.swift::InspectorPanel.formatAllMetadata | 32 | 137 | planned (§4). `0bab172f` split `body`, not this function; `2eb96ebf` changed one line in it. |
| Catalog/CatalogHelpers.swift::CatalogContent.previewPlayer | 31 | 233 | planned (§5). The 10-05/10-06 commits did not refactor it. |

Suggested order, cheapest and best pinned first: §2 (S, but data-risk) → §4 (S/M) → §3 (M) → §1 (M, data-risk menu) → §5 (M). Every plan keeps each piece at 15 or less, so Σ max(0, CCN−15) over the touched files drops by about 79 and the gate passes.

Backlog, Catalog functions at CCN 16–30 (one line each, not planned tonight): `CatalogToolbar.body` 30 / 260 lines, sitting exactly on the line; `CatalogContent.computeFiltered` 26; `VideoScanModel.renameRecord` 26 (renames a record, so data-adjacent); `CatalogView.volumeTable` 25 / 156 lines; `CatalogAuditFixer.apply` 24 (it fixes the catalog, so data-risk).

---

## §1 `CatalogView.volumeContextCatalogSection` (CCN 36, 182 nloc), CatalogView+VolumeTable.swift:404

**What it does:** builds the "Catalog" section of the volume table's right-click menu. That section holds the scan verbs, the per-volume analysis jobs, the catalog-wide analysis jobs and the two verbs that forget records.

**DATA-RISK:** this section contains *Remove from catalog* (`presentDeleteVolumeCatalog` / `presentDeleteVolumesCatalog`, which plan and confirm) and *Reset & Re-probe* (`model.resetTarget`, which removes records with no confirmation; see F2). It also launches *Bind Fixity to Volume* (fixity). The move must carry those three actions over byte for byte.

**Concept the split follows:** the menu already has four groups that a person can see, and each group answers a different question:
- (a) *scan this volume*: Catalog Info, Rescan/Resume, Update Catalog…, Verify Catalog, Show Migrated…
- (b) *analyse this volume*: File Signatures, Find Similar Footage, Bind Fixity, Caption Videos
- (c) *analyse every reachable volume*: Caption All, Dossier All, Backfill Volume Names
- (d) *forget*: Remove from catalog, Reset & Re-probe

Each group becomes a `@ViewBuilder` function named after that group. The four O(records) counts the menu does today (signature coverage, captionable count, reachable captionable count, missing-volume-name check) move into one value type computed once per right-click by a pure function. The view code then reads facts and makes no decisions about records.

**Canonical source:** Apple HIG, *Menus* ("group related items; separate groups"); *SwiftUI data flow* (Apple "Model data" docs, WWDC19 "Data Flow Through SwiftUI": views read derived values, and the derivation lives outside the view); *The Swift Programming Language*, Functions (pure function over values). In-repo precedent: `volumeContextMenu(for:)` already splits Catalog, Workflow and Volume this way.

**Before / after:**
```swift
// before
@ViewBuilder private func volumeContextCatalogSection(
    targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool) -> some View

// after
struct VolumeMenuFacts: Equatable {
    let signatures: (signed: Int, missing: Int, total: Int)?   // single only
    let volumeCaptionable: Int                                 // single only
    let reachableCaptionable: Int
    let offerBackfillNames: Bool
    @MainActor static func compute(targets: [CatalogScanTarget], single: Bool,
                                   records: [VideoRecord], scanTargets: [CatalogScanTarget]) -> VolumeMenuFacts
}
@ViewBuilder private func volumeContextCatalogSection(targets:first:single:) -> some View   // ≈2
@ViewBuilder private func volumeScanVerbs(_ targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool) -> some View // ≈8
@ViewBuilder private func volumeAnalysisJobs(first: CatalogScanTarget, facts: VolumeMenuFacts) -> some View   // ≈12
@ViewBuilder private func catalogWideAnalysis(facts: VolumeMenuFacts) -> some View                              // ≈6
@ViewBuilder private func volumeForgetVerbs(_ targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool) -> some View // ≈6
```
All stay `private` to the same file, so no access is widened. They remain inside ONE `Section("Catalog")`, which keeps the item order and leaves out any new dividers. If Rick wants dividers between the groups, that is a separate, visible change.

**Behaviour-preserving steps:**
1. Add the pinning tests below.
2. Add `VolumeMenuFacts.compute`, transcribing the four counts verbatim. Keep the raw `hasPrefix` for the per-volume caption count; F3 is a separate fix.
3. Replace the in-body counts with `facts.*`.
4. Cut the four group functions, preserving item order.
5. Fix the identical ternary (F4) in its own commit.

**Pinning tests BEFORE the move:**
- Existing: `DeleteVolumeCatalogPlanTests` (the forget wording and the plan); `TargetRemovalSafetyTests` (resetTarget's snapshot over 50 records and coverage); `CatalogKeyboardUITests.test8_catalogInfoFollowsVolumePane` (⌘I Catalog Info).
- Add `VolumeMenuFactsTests`:
  - signature counts skip purged, set-aside, superseded and zero-size records, and use the `/` boundary;
  - `volumeCaptionable` equals today's predicate (`fullPath.hasPrefix(searchPath)` and the stream is V+A or V-only);
  - `offerBackfillNames` is true for multi-select, or for a single target with any record whose volume name is empty;
  - a 100k-record budget (CLAUDE.md scale dimension).
- Add (NEEDS-MAC) `CatalogVolumeMenuUITests.menuTitlesInOrder`: right-click one volume, then two volumes, and assert the menu item titles and order.

**Risk:** medium. This is UI only, but the forget verbs live here. The UI test is the only check on item order. **Size:** M.
**Expected CCN after:** each piece ≤ 12; `compute` ≈ 8.

---

## §2 `RescanPreservedFields.isWorthRestoring` (CCN 36, 38 nloc), VideoScanModel+RescanPreservation.swift:269

**What it does:** answers whether a pre-rescan snapshot carries anything a rescan would lose. If it returns false, the snapshot is left out of the map and its fields are gone after Update Catalog.

**DATA-RISK (high):** this is the rescan-preservation gate. A term dropped from this OR means curated data (notes, people, fixity, the purge tombstone) is silently lost on the next rescan. That is catalog persistence. Per the spend policy, a qa pass is enough for a pure regrouping if the table test below lands first. A codex pass is only worth it if the larger nested-type option is chosen.

**Honest note (Rick 10/7, "not a slave to a low CCN"):** this is a flat OR of 36 terms with no nested branching, so its CCN overstates how hard it is to read. The real debt is that nothing makes a NEW field land in this list. That is how `archiveFixity` and the origin fields were missed on 2026-09-02, as the file's own header records.

**Concept the split follows:** the header comment already sorts the fields by *contract*: dossier products, user edits, archive provenance and fixity, plus lifecycle tombstones. Write one computed predicate per contract, each a pure function of the snapshot's stored values:
```swift
// before
var isWorthRestoring: Bool { /* 36 || terms */ }

// after: same type, same access, no new stored state
var hasDossierProducts: Bool   // sceneCaptions, transcript, ocrDateCandidates, ocrText, dossierProcessedAt, inferredRecordDate, footage   (7)
var hasPeopleTags: Bool        // detected / suspected / confirmedByUser / rejected                                                      (4)
var hasUserEdits: Bool         // disposition, starRating, junkScore, notes, tags, userNotes, userDate(+conf), userPlace(+conf),
                               // backupAttestations, footageDecisions, familyMusic                                                      (13)
var hasLifecycleState: Bool    // lifecycleStage, archiveStage, purgedAt, setAsideReason, supersededByID, repairConfirmedDate,
                               // derivedFrom, derivationKind                                                                            (8)
var hasArchiveProvenance: Bool // archiveFixity, originalFullPath, originVolume, masterLocation                                          (4)
var isWorthRestoring: Bool { hasDossierProducts || hasPeopleTags || hasUserEdits || hasLifecycleState || hasArchiveProvenance }      // 5
```
**Larger option, NOT recommended now (L):** nest the stored fields into `DossierChannels`, `UserEdits`, `ArchiveProvenance` and `LifecycleTombstone` value types, each with its own `init(from:)`, `apply(to:)` and `isEmpty`. That would also split `init(from:)` and `apply`. It is the right long-term shape. The struct is `Sendable` only (in memory, not `Codable`), so persistence is not at stake, but `apply`'s conditional fixity and live-value overrides make it a data-risk rewrite.

**Canonical source:** Swift API Design Guidelines ("name variables… according to their roles"; Boolean properties "read as assertions about the receiver"); *The Swift Programming Language*, Properties (computed properties).

**Behaviour-preserving steps:**
1. Add the table test below.
2. Add the five predicates, cutting the terms verbatim with no term moved or rewritten.
3. Change `isWorthRestoring` to the OR of the five.
4. Add a doc line next to the stored fields: "a new preserved field must join exactly one `has…` group, and the table test."

**Pinning tests BEFORE the move:**
- Existing single-field tests: `fixityAloneMakesSnapshotWorthRestoring` (archiveFixity, originalFullPath, originVolume, masterLocation, userDate, userDateConfidence, userPlace, userPlaceConfidence, attestation; partialMD5 alone = false; a blank record = false), `purgedRecordDoesNotResurrectOnRescan` (purgedAt), `footageDecisionsSurviveRescan`, `FamilyMusicTests:467`, `CatalogSetAsideMigrationTests:381`, `RepairLifecycleSchemaTests:264/269`, `InferredDatePropagationTests:1337` (inferredRecordDate), and `PerceptualFingerprintStoreTests:199` (fingerprint alone is NOT worth restoring).
- **Not individually pinned today:** sceneCaptions, audioTranscript, ocrDateCandidates, ocrText, dossierProcessedAt, the 4 people arrays, mediaDisposition, lifecycleStage, archiveStage, starRating, junkScore, notes, tags, userNotes, derivedFrom, derivationKind, footage.
- Add `eachPreservedFieldAloneIsWorthRestoring`: a parameterized `@Test(arguments:)` over 36 `(name, (VideoRecord) -> Void)` setters. Each case sets one field on a blank `VideoRecord` and asserts `isWorthRestoring`. A companion test asserts that each scan-derived field alone is false.

**Risk:** low if the table test lands first; high without it. **Size:** S.
**Expected CCN after:** max 13 (`hasUserEdits`); `isWorthRestoring` 5.

---

## §3 `CatalogContent.catalogTableBase` (CCN 34, 143 nloc), CatalogContent+Table.swift:212

**What it does:** declares the Catalog files `Table` and its 13 columns. Almost all of the complexity is in two cells: Filename (an icon cascade of 6 branches plus a tint ternary nested 6 deep) and Stream.

**Concept the split follows:** the Filename cell answers one question, "what state is this row in, and how is that shown?", in three places, each with its own priority order (see F5):
- icon: purged → setAside → superseded → unanalyzable → workspace → pair
- tint: purged → setAside → superseded → workspace → offline → pair → base
- tooltip: purged → setAside → superseded → unanalyzable → offline

The plan names the row's display state once, as a value type of facts plus an **enum** for the icon, decided by pure functions. The cell becomes its own SwiftUI view, matching the file's existing cells (`peopleColumnCell`, `tagColumnCell`, `DuplicateDispositionCell`, `DossierChannelDots`).

**Canonical source:** *The Swift Programming Language*, Enumerations (associated values); SwiftUI `Table`/`TableColumn` docs and Apple's sample "Building a great Mac app with SwiftUI" (dedicated cell views per column); SwiftUI data flow (a cell is a function of its inputs).

**Before / after:**
```swift
// before
private var catalogTableBase: some View

// after
struct FilenameCellFacts: Equatable {
    let purged, setAside, superseded, unanalyzable, workspaceActive, offline: Bool
    let pairStream: StreamType?            // non-nil only when showPairsOnly && pairedWith != nil
    @MainActor init(_ rec: VideoRecord, offline: Bool, showPairsOnly: Bool)
}
enum FilenameBadge: Equatable {           // today's icon order, verbatim
    case purged, setAside, superseded, unanalyzable, workspace, pair(StreamType), none
    init(_ f: FilenameCellFacts)          // ≈7
    var systemName: String? ; var color: Color
}
enum FilenameTint { static func color(_ f: FilenameCellFacts, base: Color) -> Color }   // today's tint order, ≈8
private func filenameCell(for rec: VideoRecord) -> some View      // ≈4
private func streamCell(for rec: VideoRecord) -> some View        // ≈5
private var catalogTableBase: some View                           // ≈6 (remaining "—" ternaries; optional dateCell/placeCell/codecCell take it to ≈2)
```
No access is widened: the new types can be `fileprivate`. Only the test target needs internal access, and `@testable import` already gives it.

**Behaviour-preserving steps:**
1. Add the truth-table test against a transcription of today's two cascades.
2. Extract `FilenameCellFacts`, `FilenameBadge` and `FilenameTint` verbatim, with today's three orders as they are. Unifying the orders is Rick's call (F5) and goes in its own commit.
3. Move the cell bodies to `filenameCell` and `streamCell`.
4. Leave `tableWithTrashShortcut` and its focus/focusedValue chain alone (keyboard harness).

**Pinning tests BEFORE the move:**
- Existing: `CatalogKeyboardUITests` (identifier `catalog.filesTable`, arrows, ⌘⌫, Space, Promote scope); `CatalogTableStateTests` (100k budgets).
- Add `FilenameCellStyleTests.truthTable`: all 2^7 boolean combinations times pair/no pair. Assert the badge and tint equal the reference (a hand-transcription of the current ternaries in the test file).
- Add a 100k-row sensor: computing `FilenameCellFacts` for 100k synthetic records stays under budget. `VolumeReachability.isReachable(path:)` is a cache read, so the sensor should prove it stays O(1).

**Risk:** low–medium (display only; the focus chain is adjacent but untouched). **Size:** M.
**Expected CCN after:** every piece ≤ 8.

---

## §4 `InspectorPanel.formatAllMetadata` (CCN 32, 137 nloc), InspectorPanel.swift:93

**What it does:** renders the "Copy All Metadata" plain text for one record: header, General, Video, Audio, Timestamps, Correlation, Duplicates, Avid, Notes, Dossier and Location.

**Concept the split follows:** a **value type that owns the lines**, with mutating `section`, `field` and `line`, plus a **pure renderer** with one static function per section. Today the local `add` and `section` closures capture `lines` and are passed into `formatDuplicateSection` and `formatAvidSection`. That is the shape behind the 2026-05-04 exclusivity crash (`CopyMetadataCrashTests` header). A `mutating` method on a struct passed `inout` is the language's own answer to that crash.

**Canonical source:** *The Swift Programming Language*: Methods ("Modifying Value Types from Within Instance Methods") and Memory Safety (conflicting access to in-out parameters); Swift API Design Guidelines (side-effect-free functions read as nouns: `RecordMetadataText.render`).

**Before / after:**
```swift
// before
func formatAllMetadata(_ rec: VideoRecord) -> String
func formatDuplicateSection(_ rec:, add:, section:, appendLine:)
func formatAvidSection(_ rec:, add:, section:)

// after
struct MetadataText {                         // ≈ a std::vector<string> with append helpers
    private(set) var lines: [String] = []
    mutating func section(_ title: String)    // blank line before all but the first
    mutating func field(_ label: String, _ value: String)   // skips empty
    mutating func line(_ s: String)
    var text: String { lines.joined(separator: "\n") }
}
enum RecordMetadataText {
    struct Environment { let volumeLabel: (String) -> String; let volumeName: (String) -> String; let isReachable: (String) -> Bool }
    static func render(_ rec: VideoRecord, groupMembers: [VideoRecord], env: Environment) -> String  // ≈1
    static func header(_ rec:, into: inout MetadataText, env:)        // ≈6
    static func media(_ rec:, into:)                                  // General/Video/Audio ≈1
    static func timestamps(_ rec:, into:)                             // ≈5
    static func correlation(_ rec:, into:, env:)                      // ≈4
    static func duplicates(_ rec:, members:, into:, env:)             // ≈7
    static func avid(_ rec:, into:)                                   // ≈3
    static func notes(_ rec:, into:)                                  // ≈3
    static func dossier(_ rec:, into:)                                // ≈11
    static func clipTimestamp(_ seconds: Double) -> String            // shared with InspectorDossierView (F6)
}
// InspectorPanel keeps: func formatAllMetadata(_ rec: VideoRecord) -> String { RecordMetadataText.render(rec, groupMembers: duplicateGroupMembers, env: .live) }
```
`formatAllMetadata` keeps its name and access, so the existing tests and the context menu do not change.

**Behaviour-preserving steps:**
1. Add the golden-text test.
2. Introduce `MetadataText` and port section by section, keeping the strings exact (including the duplicated "Tape"/"Clip" lines in the header and the Avid section).
3. Hoist the two per-call `DateFormatter`s into statics with the same style settings.
4. Route `VolumeReachability` through `Environment`; the isolation dimension then becomes testable.

**Pinning tests BEFORE the move:**
- Existing: `CopyMetadataCrashTests` (2 tests, `contains` only).
- Add `copyAllMetadataGoldenText`: a record with every section populated (pair, duplicate group of 2, Avid, user notes, dossier with captions, transcript, OCR and inferred date) plus an empty record. Assert the full string. Fix the dates so the formatter output is computed in the test with the same `DateFormatter` settings, not hard-coded per locale.
- After step 4, add `copyAllMetadataIsolation`: inject a reachability stub that returns false and assert "(offline)" on the group member.

**Risk:** low (pure text, a clipboard-only consumer). **Size:** S/M.
**Expected CCN after:** max ≈ 11 (`dossier`).

---

## §5 `CatalogContent.previewPlayer` (CCN 31, 233 nloc), CatalogHelpers.swift:1265

**What it does:** draws the Catalog's preview strip. On the left: selection count, volume, OFFLINE badge, path, codecs, people and the Stop button. In the centre: one of eight media surfaces. The play button also starts AVPlayer, with streaming in viewer mode.

**Concept the split follows:**
- (1) An **enum with associated values** for the centre surface, chosen by one **pure decision function**. Today that choice is an 8-branch `if/else if` chain mixed with layout code.
- (2) The left column becomes a **SwiftUI subview with its own inputs**.
- (3) The play action leaves the view body and becomes a model-side function. It then builds its resolver through the SAME factory as `MediaOpener.open` (that is how F1 gets fixed afterwards).

**Canonical source:** *The Swift Programming Language*, Enumerations; SwiftUI data flow (a view is a function of its state); NetNewsWire's detail pane, which switches on a `DetailState` enum (no selection / loading / article…) rather than nesting conditionals; Apple "Managing model data in your app".

**Before / after:**
```swift
// before
private var previewPlayer: some View

// after
enum PreviewSurface: Equatable {
    case offline
    case filmstrip(path: String, frames: [PreviewFilmstrip.Frame])
    case extracting(done: Int, total: Int)
    case playing
    case poster(playable: Bool)        // image read from @State in the view
    case unavailable, audioOnly, loading
    static func decide(record: VideoRecord, offlineVolumeName: String?, isReachable: Bool,
                       filmstrip: FilmstripState, isPlaying: Bool, hasPlayer: Bool,
                       hasPreviewImage: Bool, previewUnavailable: Bool) -> PreviewSurface   // ≈12, today's order verbatim
}
struct PreviewSelectionSummary: View { let rec: VideoRecord; let selectedCount: Int; let showStop: Bool; let onStop: () -> Void }  // ≈8
private func previewSurface(_ s: PreviewSurface, rec: VideoRecord) -> some View   // switch, ≈9
private func startPreviewPlayback(_ rec: VideoRecord)                            // route + viewer resolve, ≈8
private var previewPlayer: some View                                             // ≈3
```

**Behaviour-preserving steps:**
1. Add the decision truth-table test.
2. Extract `PreviewSurface.decide` verbatim. Offline means `previewOfflineVolumeName != nil || !reachable`, and it wins over everything; filmstrip and extracting apply only when `stripPath == selected.fullPath`.
3. Move the left column into `PreviewSelectionSummary`. Stop keeps tearing down both modes and `livePreviewMode.stop()`.
4. Move the button action to `startPreviewPlayback` with no change to the `PreviewPlayAction.forRoute` switch.
5. In a SEPARATE commit, share one `MediaStreamResolver` factory between preview and Open (F1).

**Pinning tests BEFORE the move:**
- Existing: `FilmstripRouteGateSensorTests.routeGateSensor` (MKV/FFV1 → filmstrip, never AVPlayer); `MediaStreamResolverTests.identityMismatchNeverPlaysTheWrongDiskAndFallsToStreamOrOffline`.
- Add `PreviewSurfaceDecisionTests`: one case per surface, plus the precedence cases (offline beats a ready filmstrip; a filmstrip for a different path falls through to poster; `isPlaying` without a player falls through).
- Add (NEEDS-MAC) a spot check: Space live-preview on, arrow to an MKV row (filmstrip), then a MOV row (poster), then press Stop.

**Risk:** medium (AVPlayer `@State` lifetime; live-preview interplay). Not data-risk. **Size:** M.
**Expected CCN after:** max ≈ 12.

---

## Findings

**N1007-D-Catalog-over-30-F1 · P2 · REAL** · `MediaOpener.openResolvingForViewer`, CatalogHelpers.swift:1740 (vs `CatalogContent.previewPlayer`, CatalogHelpers.swift:1447)
- **Defect:** two functions answer "where are this record's bytes on a viewer Mac?" differently. Preview builds `MediaStreamResolver.current(designation: model.masterArchive)`, so `volumeIdentityMatches` checks the mounted volume's UUID against the Master Archive designation. Open (double-click / Return / ⌘O, through `openRows` → `MediaOpener.open`) builds `MediaStreamResolver.current()` with no designation. There `designatedName` is nil, so the identity closure returns `true` for every mount (MediaStreamResolver.swift:475).
- **Scenario:** a viewer Mac with the archive volume name mapped, and a *different* disk with the same volume name mounted (for example an older clone). Preview correctly refuses the mount and streams from the master. Open re-roots to `.local` on the wrong disk and plays whatever file sits at that relative path. The contract pinned by `identityMismatchNeverPlaysTheWrongDiskAndFallsToStreamOrOffline` is bypassed on this path.
- **Impact:** read-only (no file is changed), so not P1.
- **Smallest pinning test:** give `MediaOpener` a resolver factory seam (`resolverFactory: () -> MediaStreamResolver`). In viewer role with a mapped mount whose identity does not match, assert that `openResolvingForViewer` returns no `.local` pair. It fails today because the closure always returns true. Running it needs viewer role and a UUID lookup stub, so verify on the Mac.

**N1007-D-Catalog-over-30-F2 · P2 · REAL · DATA-RISK** · `CatalogView.volumeContextCatalogSection` "Reset & Re-probe", CatalogView+VolumeTable.swift:615–620 → `VideoScanModel.resetTarget`, Model/VideoScanModel.swift:1694
- **Defect:** one menu click, with no confirmation, runs `removeCatalogRecords(underTargetRoot:)` for every selected target that is complete, stopped or in error. The *Remove from catalog* item in the same menu was made to "plan at the gesture and confirm first" (codex #1417, comment at :600–603). Reset never got that treatment.
- **Scenario:** a target of 50 records or fewer carrying curated fields (notes, people tags, userDate, archiveFixity, purge tombstones). Rick picks "Reset & Re-probe" expecting a re-probe. `resetTarget` cancels, clears the probe cache and removes the records. Under the 50-record threshold no snapshot is written (`targetRemovalSnapshotThreshold = 50`). Nothing re-probes either: `CatalogScanTarget.reset()` only zeroes counters. When he later rescans, the rescan-preservation snapshot finds no prior records, so the curated fields are gone for good once catalog.json saves. Above 50 records the only way back is a hand restore of `catalog.pre-target-removal.*`.
- **Guards checked:** the coverage check (records under another target are kept), the snapshot over 50, and the log line. None of them asks first.
- **Why not P1:** it takes a deliberate destructive-sounding click. The label promising "Re-probe" is what makes it surprising.
- **Smallest pinning test (fails today):** `resetOfCuratedTargetRequiresConfirmedPlan`. Seed 10 records under one target with `userNotes` set, call `model.resetTarget(t)`, and expect the records still present, or a snapshot written. Today both expectations fail.

**N1007-D-Catalog-over-30-F3 · P3 · REAL** · per-volume "Caption Videos (N)" count, CatalogView+VolumeTable.swift:519–522, and `CaptionOrchestrator.startCaptioning`, Media/CaptionOrchestrator+Lifecycle.swift:62–65, vs `pfCatalogWideMetadataCandidates`, Catalog/CatalogWideMetadataCandidates.swift:34
- **Defect:** "which records are caption work" is answered two ways. The catalog-wide path drops purged, set-aside, confirmed-junk, DRM-protected and non-live lifecycle records. The per-volume count and the per-volume run use only `fullPath.hasPrefix(searchPath)` plus the stream type.
- **Scenario:** a volume with 10 videos, 3 of them purged and 2 confirmed junk. The menu shows "Caption Videos (10)" and the run queues all 10: VLM time spent on cull-marked files, and on files that no longer exist. Next to it, "Caption All Reachable Volumes" counts 5.
- **Secondary issue:** a bare prefix with no trailing `/` also takes in a sibling volume, for example "…/Tape 2" under "…/Tape". `VideoScanModel.isUnder` exists to prevent exactly that.
- **Smallest pinning test:** after extracting `pfVolumeCaptionCandidates(records:prefix:)` verbatim, seed 1 live video under A, 1 purged video under A and 1 video under "A2", and expect a count of 1. Today the count is 3.

**N1007-D-Catalog-over-30-F4 · P3 · REAL** · `CatalogView.volumeContextCatalogSection`, CatalogView+VolumeTable.swift:425
- **Defect:** `systemImage: hasResumable ? "arrow.clockwise" : "arrow.clockwise"` has identical branches. It is a dead decision that adds 1 CCN.
- **Scenario:** a resumable target shows the same icon as a fresh one. Either a distinct resume glyph was intended, or the ternary should go.
- **Test:** none needed. Delete it, or choose the intended glyph.

**N1007-D-Catalog-over-30-F5 · P3 · NEEDS-MAC** · `CatalogContent.catalogTableBase` Filename cell (CatalogContent+Table.swift:214–280) and `filenameTooltip(for:offline:purged:)` (:22–45)
- **Defect:** the row's display state is decided three times, in three different priority orders (listed in §3).
- **Scenario:**
  - A workspace-active record whose codec is unanalyzable shows the red "!" icon (unanalyzable) with mint text (workspace), and the tooltip gives the unanalyzable reason.
  - An offline workspace-active row is mint, not grey-secondary, yet its tooltip says "(offline)".
- **What decides it:** these may be intentional. Rick should look at the rendered rows and choose one order.
- **Smallest pinning test:** the §3 truth table. It pins today's three orders so that any unification is a visible, deliberate diff.

**N1007-D-Catalog-over-30-F6 · P3 · REAL** · duplicated copies that agree today:
- `InspectorPanel.formatAllMetadata`'s local `formatTimestamp` (InspectorPanel.swift:106) is a copy of `InspectorDossierView.formatTimestamp` (InspectorDossierView.swift:215). Its comment admits it is "Local copy".
- `CatalogView.volumeContextVolumeSection`'s "Volume Roles & Archive…" action (CatalogView+VolumeTable.swift, about :650) inlines the body of `openVolumesEditor(for:)` (:385).
- **Scenario:** a future change to one copy (for example h:mm:ss for clips over an hour) leaves the copied metadata and the inspector disagreeing.
- **Smallest pinning test:** `clipTimestampFormat` (0 → "0:00", 61.9 → "1:01", -5 → "0:00", 3600 → "60:00") against the single shared function, once it exists (§4).

Dead code and stale markers: within the five planned functions I found no `TEMPORARY` or diagnostic code and no stale TODO. The only dead decision is F4.

## Callees followed (to settle findings)
`signatureCoverage(for:)` (CatalogView+ScanTargetsPane.swift:144), `VideoScanModel.isUnder` (Media/VideoScanModel+ContentHashBackfill.swift:127), `pfCatalogWideMetadataCandidates` / `pfCatalogWideCaptionCandidates`, `CaptionOrchestrator.startCaptioning`, `VideoScanModel.resetTarget` → `removeCatalogRecords(plan:action:)` (Volumes/VideoScanModel+DeleteScanTarget.swift:277–328), `CatalogScanTarget.reset()`, `MediaStreamResolver.resolve` / `.current(defaults:designation:)`, `PreviewPlayAction.forRoute`, `VideoRecord.filenameColor`, `VolumeReachability.isReachable(path:)`.

## Not covered
- I did not run lizard: CCNs are the baseline's, and I re-counted only roughly. The plans' "expected CCN after" are estimates from that counter.
- I did not plan the Catalog CCN 16–30 offenders, which are only listed in the backlog. `CatalogToolbar.body` at exactly 30 is the next one to tip over.
- I checked the three skipped functions' replacements only for "no piece over 20 by rough count", not reviewed line by line.
- F2 crosses into Volumes/ (`removeCatalogRecords`). The full guard set for it belongs to N1010-H-Volumes.
- UI order, the AVPlayer lifetime and F5's visual question all need the Mac.

## Blockers & environment
- `lizard` is not installed, and per the brief I did not try to pip-install it. I used the M4 baseline plus `origin/metrics` (fetched fine) and a throwaway rough counter in the session scratchpad. Nothing was written to the repo except this report.
- The clone is shallow, but `git log --since=2026-10-05` returned the full 10-05..10-07 history for every file, so I did not need `--deepen`.
- The baseline is stale for 3 of the 8 rows: the 2 AM nightly (`4b79bbbb`) predates the 10-07 merges `85b74445` and `be8cbe8f`. A baseline refresh after those merges would have saved the skip check.
- Per the launching agent's instruction, this report is written but **not committed or pushed**. The README's rule 3 (commit on `cloud/<id>`) is left for the Manager.
