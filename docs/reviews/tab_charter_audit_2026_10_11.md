# Tab-charter audit — 2026-10-11

Read-only audit of `VideoScan/VideoScan/` against `docs/design/tab_charters.md`
(main @ 5f809ad10). Paths below are relative to `VideoScan/VideoScan/`.
Severity: BLOCKER / MAJOR / MINOR / NIT. Red tests for reproducible findings are
in section 4; every structural finding without one says so.

---

## 1. Misplaced features

| # | Feature (what the user sees) | Now in | Belongs in | file:line |
|---|---|---|---|---|
| 1 | **Analyze ▸ Analyze Selected — Duplicates** | Catalog toolbar | Triage ▸ Cleanup | `Catalog/CatalogAnalyzeMenu.swift:85` (hosted at `Catalog/CatalogToolbar.swift:276`) |
| 2 | **Analyze ▸ Analyze Selected — Footage** (Find Similar Footage) and **One Per Footage** toggle | Catalog toolbar | Triage ▸ Events | `Catalog/CatalogAnalyzeMenu.swift:87`, `:95` |
| 3 | **Combine All Correlated Pairs…** | Catalog toolbar | Repair… (Triage) | `Catalog/CatalogAnalyzeMenu.swift:106` |
| 4 | **Stop Combine** button | Catalog toolbar | MFO window (Combine as an MFO job) | `Catalog/CatalogToolbar.swift:316` |
| 5 | **Remove N Unreadable Extensionless Files** (bulk soft-delete) | Catalog ▸ Show menu | Triage ▸ Cleanup | `Catalog/CatalogToolbar.swift:422` |
| 6 | **Copies & Advice…** row item | Catalog row menu | Triage ▸ Cleanup (already also in Triage row menu, `Catalog/TriageView.swift:889`) | `Catalog/CatalogRowContextMenu+Media.swift:105` |
| 7 | **Find ▸ All Matches (N)** (duplicate group browser) | Catalog row menu | Triage ▸ Cleanup | `Catalog/CatalogRowContextMenu+Organize.swift:304` |
| 8 | **Tags ▸ Important / Recoverable / Suspected Junk / Junk / Clear Verdict** (disposition) | Catalog row menu | Triage ▸ All Needing Triage | `Catalog/CatalogRowContextMenu+Organize.swift:71`, `:102-128` |
| 9 | **Combine This Pair…** | Catalog row menu | Repair… (Add sound) | `Catalog/CatalogRowContextMenu+FileOps.swift:32` |
| 10 | **Combine This Pair…** in the pair focus bar | Catalog | Repair… | `Catalog/CatalogHelpers.swift:990` |
| 11 | **Find A/V Pair → "Combine with <sound>…"** alert | Catalog | Repair… | `App/ContentView.swift:1246` (`MediaOps/SoundPairAlert.swift:32`) |
| 12 | **Clean Up Video ▸ <recipe>…** (CleanupJob) | Catalog row menu | Repair… | `Catalog/CatalogRowContextMenu+FileOps.swift:195` |
| 13 | **Verify Audio → Balance / Rebuild** (standalone jobs) | Catalog row menu → sheet | Repair… | `Catalog/CatalogRowContextMenu+Media.swift:133`, `MediaOps/VerifyAudioSheet.swift:553`, `:567` |
| 14 | **Tidy Catalog** (Set Aside N files; "Review copies of archived media…") | Catalog volume pane | Triage ▸ Cleanup | `Catalog/CatalogView+ScanTargetsPane.swift:840`; `Catalog/TidyCatalogSheet.swift:93`, `:147` |
| 15 | **"+ X hidden by a 'deleted' label" caption + Review… link** (ShowAgain) | Catalog footer | Removed (per charter) | `Volumes/VolumeTableTotalsFooter.swift:277-286` → `Catalog/ShowAgain*.swift` |
| 16 | **Catalog Options ▸ Remove from Catalog ▸ Forget <volume> records / Forget all** | Catalog | Storage (Retire a drive) | `Catalog/CatalogView+ScanTargetsPane.swift:~806-823` |
| 17 | **Import…** (Import to Workspace) | Triage toolbar | Catalog (ingest/import) | `Catalog/TriageView.swift:604` |
| 18 | **Analyze ▸ Analyze All / Analyze Selected** (MediaAnalyzer heuristics) | Triage toolbar | Catalog (identify / background analyzers) | `Catalog/TriageView.swift:615-632` |
| 19 | **Compare Footage…** toolbar button and row item | Triage ▸ All Needing Triage | Triage ▸ Events | `Catalog/TriageView.swift:579`, `:1011`; also `Steward/StewardPaneView.swift:404` |
| 20 | **Archive** button, help "Promote selected to Archive vault" (it only stamps a label, see S2) | Triage toolbar | Promote engine (Triage is right; the implementation is wrong) | `Catalog/TriageView.swift:590` |
| 21 | **Repair** toolbar button / **Needs Repair** row item: only sets disposition `.recoverable`; Triage has **no** door to Repair… | Triage | Triage should open Repair… | `Catalog/TriageView.swift:675`, `:902`; Repair… only at `Catalog/CatalogRowContextMenu+Media.swift:47` and `MediaOps/CheckMedia/DiagnosticBannerView.swift:166` |
| 22 | **Delete duplicates here…** card | Storage | Storage shows "Need space?" → Triage ▸ Cleanup | `Volumes/StorageReclaimableCard.swift:87` |
| 23 | **Purge Non-Video Media…** | Storage (Volumes) + app menu | Triage ▸ Cleanup | `Volumes/VolumesWindow.swift:595`; `App/VideoScanApp.swift:799` |
| 24 | **Archived — what next? ▸ Move to Trash** (bulk prune) and **Remove N missing rows** | Archive (sheet raised by Promote and by Tidy) | Triage ▸ Cleanup (Archive: "never bulk delete") | `Archive/ArchivedWhatNextSheet.swift:368`, `:738`, `:795`; raised at `Archive/VideoScanModel+MediaLedger.swift:483` |
| 25 | **Archive Angel strip** — recommendation list, review sheet, Ready disclosure | Archive tab | Triage ▸ Archive Angel recommender | `Archive/ArchiveView+Table.swift:76` → `ArchiveAngel/UI/ArchiveAngelStrip.swift:36`, `:67`, `:87` |
| 26 | **Analyze Dashboard (legacy)** | app menu | Retire, or Catalog | `App/VideoScanApp.swift:1030` |

Dead duplicates of a door (MINOR, remove when moving the feature):
- `Catalog/CatalogDuplicatesMenu.swift` is never instantiated; only its `Volume` type is used.
- `App/ContentView.swift:1035-1062` holds a second Delete Duplicates picker and confirmation. `deleteDuplicatesVolumePicker` is never set non-nil, so it is unreachable. The live flow is `MediaOps/DeleteDuplicatesFlow.swift:133`.

Correctly placed (no action): Delete Junk (`TriageView.swift:562`), Excess copies pane (`TriageView.swift:229`), Steward pane (`TriageView.swift:400`), Catalog ⌘⌫ / Move to Trash (`CatalogRowContextMenu.swift:285`), Promote to Archive row item (`CatalogContent+Promote.swift:18`), Mark Retired (`VolumesWindow.swift:647`).

---

## 2. Shared actions with more than one implementation

### 2a. Move to Trash / delete (media files)

Engines that call `trashItem`/`removeItem` on catalog media:

| Engine | Where the file moves | Callers (doors) | Row afterwards |
|---|---|---|---|
| **E1 `deleteConfirmedJunk` → `JunkTurnRunner.perform`** | `MediaOps/VideoScanModel+JunkDelete.swift:237`, trash at `:479` | Catalog ⌘⌫ and row Move to Trash (`MediaOps/VideoScanModel+TrashSelection.swift:119` → `:160`); Triage Delete Junk (`MediaOps/JunkDeleteAction.swift:78` → `VideoScanModel+JunkTrashSnapshot.swift:141`); Archived-what-next prune (`VideoScanModel+PruneApply.swift:739`); Excess copies (`VideoScanModel+ExcessCopies.swift` → `pruneOneCopy` → same) | kept; `purgedAt` + `.trashed` (`JunkDelete.swift:325-329`); `copyTrashed` ledger |
| **E2 Delete Duplicates: `SignatureVerification.quarantine` → `deleteQuarantined(.trash)`** | `MediaOps/SignatureVerification.swift:680`, trash at `:794`; job step `MediaOps/DeleteDuplicatesJob.swift:519`, `:651-654` | Storage card (`StorageReclaimableCard.swift:100`), Steward pane (`StewardPaneView.swift:121`), Copies & Advice "Move This Copy to Trash" (`Catalog/CopiesAdviceTrash.swift:57` → reviewed batch) | **row deleted from `records`** (`VideoScanModel+Duplicates.swift:810`), stamped `.trashed` on a detached object for the ledger only |
| **E3 `discardWorkbench` → `discardTurn`** | `Catalog/VideoScanModel+Workbench.swift:85`, trash at `:156` | Triage Under Construction Discard (`TriageView.swift:734`, `:946`) | kept; `purgedAt` + `.trashed` (`:106-107`); no ignore-list entry, runs synchronously on the main actor |
| **E4 `DerivativeOutputPublish.trashItem` (replace policy)** | `MediaOps/DerivativeOutputPublish.swift:77-79` | Transcode / Reformat re-runs that replace an existing output (`TranscodeJob.swift:384`, `ReformatJob.swift:405`) | not handled by any catalog stamping in E1 (unverified whether a catalogued output row is restamped) |
| **E5 permanent unlink `SignatureVerification.deleteQuarantined(.permanent)`** | `MediaOps/SignatureVerification.swift:759` | **Default** of `deleteQuarantined` (`:681`) and only mode of `quarantineAndDelete` (`:830-833`). No production caller today; tests pin it as desired (`SignatureVerificationOneSidedTests.swift:73`) | — |

App-owned scratch (out of scope, OK): Angel buffer `ArchiveAngelPlan.swift:888` (fenced to `<buffer>/batch-…`), Spectrum runs `FootageSpectrumHelper.swift:211`, partials in Relocate, Trim, Cleanup and Combine. People reference photos `People/FamilyGroup.swift:176` and `People/PersonEditSheet.swift:934` are not catalog media.

**One engine: E1, with E2's proof as a pluggable step.** E1 already has every gate the charter needs: archive and read-only volume per file, offline, read-only viewer, the `copyTrashed` ledger line, `purgedAt` + `.trashed`, the ignore list (via the ⌘⌫ wrapper), and the result/receipt shape that Catalog, Triage and Prune share. E2's quarantine-and-reverify is the best "proved byte for byte" step in the codebase. It should become E1's `beforeRemoval` proof hook (the seam is already there: `JunkDeletionGuard.beforeRemoval`) instead of a separate trash and settle path that removes the row. E3 should become a thin E1 call (it already copies E1's gates). E4 should go through E1's primitive for the move itself. E5 should be deleted (Trash-only ruling, 2026-10-09).

### 2b. "Gone" labelling (writers that mean removed/trashed/deleted)

Four separate encodings of "gone":

| Encoding | Writers |
|---|---|
| `purgedAt` + `lifecycleStage .trashed/.deletedPermanently` | `JunkDelete.swift:325-329` (E1); `Workbench.swift:106-107` (E3); `Duplicates.swift:826-827` (E2, on a detached snapshot); `CatalogAuditFixer.swift:25` (stage only, repair) |
| `purgedAt` only ("Remove from Catalog") | `SoftDelete.swift:74` `purgeRecords`, from: Catalog row (`CatalogRowContextMenu.swift:258`), Music Triage (`MusicTriageSheet.swift:193`), what-next missing rows (`VideoScanModel+MediaLedger.swift:402`), unreadable extensionless (`SoftDelete.swift:111`); **plus direct writers that skip `purgeRecords`' archive gate and undo banner**: Archive Angel companions settle (`VideoScanModel+ArchiveAngelCompanions.swift:179`), analysis auto-purge of missing files (`Media/CaptionOrchestrator+Activity.swift:143`, called from `+DossierSteps.swift:172`) |
| `archiveStage .manuallyDeleted` | Migrate Bucket B (`MediaOps/VideoScanModel+Relocate.swift:390`); Show Again reverse (`Catalog/ShowAgain+Apply.swift:258`). Read as "disposed" by Retire (`Volumes/VideoScanModel+RetireVolume.swift:72`, `:124`), hidden from footer totals (`Catalog/CatalogStorageTotals.swift:384`) |
| row removed from `records` | Delete Duplicates settle (`Duplicates.swift:810`); forget-volume (`Volumes/VideoScanModel+DeleteScanTarget.swift:317`); Purge Non-Video Media (`VideoScanModel+NonVideoMediaPurge.swift:69`) |

Un-gone writers: `SoftDelete.swift:122-125` (restore), `MissingAudio.swift:148-149`, `ShowAgain+Apply.swift:141`.

**One engine:** a single model-level `markGone(_:how:)` owned by E1. `.trashed` = file in the Trash; `.removedFromCatalog` = `purgedAt` only. Every writer above goes through it, so the archive gate, the publish (#160), the ledger line and the undo path happen once. `archiveStage .manuallyDeleted` should stop meaning "gone". It is an archive-ladder enum and it is the root of the Show Again footer problem. Bucket B should write `purgedAt` + a "missing at Migrate" reason through the same function.

### 2c. Promote

| Implementation | file:function | Effect |
|---|---|---|
| **P1 engine** | `Archive/VideoScanModel+MasterArchive.swift:1203` `requestPromote` → `MediaOps/MediaFileOperations+Promote.swift:28` `startPromote` → `Archive/PromoteToArchiveJob+Steps.swift:206` `promoteOne` → `MasterArchive.swift:1261` `registerPromotedCopy` | copy + fixity + archive row; the Archive tab reads this |
| P1 doors (OK) | Catalog row `Catalog/CatalogContent+Promote.swift:18`; `Catalog/CatalogPromoteCommand.swift:73`; `Archive/PromoteToArchiveSheet.swift`; Archive Angel `ArchiveAngel/Promote/ArchiveAngelPromoter.swift:191` (→ `startPromote`), list/review/ready (`ArchiveAngelListActions.swift:56`, `ArchiveAngelReviewSheet.swift:516`, `ArchiveAngelReadyDisclosure.swift:214`) | |
| **P2 label only** | `Catalog/TriageView.swift:1137` `promoteSelectedToArchive` (toolbar "Archive", `:590`) | sets `lifecycleStage = .archived`; **no copy** |
| **P3 label only** | `Catalog/VideoScanModel+Workbench.swift:24` `promoteWorkbenchToArchive` (Under Construction "Promote" `:710`, row "Promote to Archive" `:929`) | sets `.archived` + `archiveStage .healthy`; **no copy** |
| P4 load-time stamp | `Model/VideoScanModel.swift:1124` | stamps `.archived` from `archiveStage >= .masterAssigned` |

The Archive tab ignores `lifecycleStage == .archived` (`Archive/ArchiveView+Categories.swift:10-13`). `isDateReadOnly` does honour it (`Archive/VideoScanModel+DateReadOnly.swift:47`). So a P2 or P3 "promote" makes the file vanish from Triage and freezes its dates, but it never reaches the archive. **One engine: P1.** P2 and P3 should call `requestPromote`. P4 should go once the legacy stamps are migrated.

### 2d. Repair / Combine

| Implementation | file:function | Notes |
|---|---|---|
| **R1 engine** | `MediaOps/MediaFileOperations+Repair.swift:46` `startRepair` → `Repair/MediaRepairJob.swift:91` → `Repair/MediaRepairEngine.run`; recipe `Repair/MediaRepairRecipe.swift` | MFO job, one ffmpeg pass, verification, adoption via `VideoScanModel+RepairLifecycle.swift:185-199` |
| R2 Combine | `MediaOps/VideoScanModel+Combine.swift:22` `combineSelectedPairs` → `:629` `combineAllPairsInternal` → `CombineEngine.runFFMpeg` (`:307`), own publish (`CombineOutputPublish.swift`), own progress (`dashboard.combineJobs`, `:285-360`), own catalog insert (`:582-589` → `.workbench`) | Repair already has `.addSound`, built from `CombineEngine.buildArgs` (`MediaRepairRecipe.swift:239`): the same mux with two orchestrations. Combine is not an MFO job (CLAUDE.md "Long operations") |
| R3 Rebuild audio | `MediaFileOperations.swift:1374` `startRebuildAudio` → `RebuildAudioJob.ffmpegArgs` (`RebuildAudioJob.swift:100`) | duplicates Repair's `.rebuild` (`MediaRepairRecipe.swift:115`, `:181`) |
| R4 Balance audio | `MediaFileOperations.swift:1321` `startBalanceAudio` → `BalanceAudioJob` | duplicates Repair's `.balance` (`MediaRepairRecipe.swift:121`, `:182`); also called by Archive Angel (`ArchiveAngel/Prepare/ArchiveAngelJob.swift:771`) |
| R5 Clean Up Video | `MediaFileOperations.swift:1252` `startCleanup` → `CleanupJob` / `CleanupFFmpegEngine` | repair-class recipe outside Repair… |
| R6 Reformat | `MediaFileOperations.swift:1206` `startReformat` (`CatalogRowContextMenu+Actions.swift:78`, `:142`) | container remux. Repair has `.remux` (`MediaRepairCommand.remuxArgs`) |

**One engine: R1.** It is the only one with the recipe seam ("THE seam every encoder choice goes through"), duplicate-dispatch refusal, drive pacing and the RepairLifecycle adoption rules. Combine All should become a batch of R1 `.addSound` jobs. R3, R4 and R6 should become R1 fixes; Angel calls R1. Derived outputs today land in two lifecycle policies: Combine → `.workbench`, Repair → inherits the original's stage.

### 2e. Set disposition (bonus, same smell)
- Triage `applyDisposition` (`TriageView.swift:1083-1092`) also sets `lifecycleStage = .reviewing` and notes a Steward decision.
- Catalog `setDisposition` (`CatalogRowContextMenu+Organize.swift:130-133`) does neither.

The `.reviewing` ("In Triage") stage also contradicts charter rule 2 (Triage is a lens, not a stage).

---

## 3. Top 5 smells ranked by data risk

1. **MAJOR — Retire treats a false "deleted" label as disposed.** `isDisposedForRetire` returns true for any `.manuallyDeleted` row (`VideoScanModel+RetireVolume.swift:124`). `filesWithoutAWitnessOnDisk` skips rows without a witness note (`:349`). So a drive whose only copy of a file carries the label the footer itself calls false (`VolumeTableTotalsFooter.swift:268-274`) can be retired, and Retire is the step before Rick wipes a drive. Red test T1.
2. **MAJOR — Promote has two label-only implementations.** Triage "Archive" and Under Construction "Promote" stamp `.archived` with no archive copy (`TriageView.swift:1137`, `VideoScanModel+Workbench.swift:24`). The file leaves Triage, its dates freeze (`DateReadOnly.swift:47`), and the Archive tab never sees it. Rick believes it is kept forever. Red test T2.
3. **MAJOR — Catalog ⌘⌫ never warns on the only copy.** The charter requires the warning. `CatalogTrashConfirmation` (`Catalog/CatalogTrashConfirmation.swift:35-63`) has no copy input and `catalogTrashPlan` (`TrashSelection.swift:60`) never asks. Red test T3.
4. **MAJOR — Five trash engines and four "gone" encodings.** Delete Duplicates removes the row (`Duplicates.swift:810`) where every other path keeps it as Removed, so Show Removed → Restore cannot bring back a dup-trashed file. Two direct `purgedAt` writers skip the archive gate (`ArchiveAngelCompanions.swift:179`, `CaptionOrchestrator+Activity.swift:143`). Design-level red test T4 (needs Rick's ruling on which representation wins).
5. **MINOR (latent) — A permanent unlink is still the default.** `deleteQuarantined(disposal: = .permanent)` and `quarantineAndDelete` unlink outright (`SignatureVerification.swift:681`, `:759`, `:830-833`). There is no production caller today, but the default is the unsafe value and tests pin it. Red test T5.

Also noted, not ranked: Combine runs outside MFO (CLAUDE.md long-ops rule). `discardWorkbench` trashes files synchronously on the main actor (`Workbench.swift:85-123`), a beachball risk on large selections.

---

## 4. Red tests

All are Swift Testing, `@testable import VideoScan`, temp dirs with `test_` prefix, ledger and catalog isolated. Suggested home: a new `VideoScanTests/TabCharterAuditTests.swift`.

```swift
// TabCharterAuditTests.swift — QA red tests from docs/reviews/tab_charter_audit_2026_10_11.md
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Tab charter audit 2026-10-11", .serialized)
@MainActor
struct TabCharterAuditTests {

    private func scratch(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_charter_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func model(in dir: URL) -> VideoScanModel {
        let m = VideoScanModel(logDirectory: dir.appendingPathComponent("logs"))
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog"))
        m.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        return m
    }

    private func record(_ path: String, size: Int64 = 100) -> VideoRecord {
        let r = VideoRecord(); r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = size; r.partialMD5 = "h-\(UUID().uuidString)"; return r
    }

    // T1 — pins VideoScanModel+RetireVolume.swift:124 and :349.
    // A row labelled .manuallyDeleted with no witness note, whose file is
    // STILL on the drive (the footer's "false label" case), lets the drive
    // be retired although it holds the only copy.
    @Test func retireRefusesADriveWhoseFalselyLabelledFileIsStillOnIt() throws {
        let root = try scratch("retire_false_label"); defer { try? FileManager.default.removeItem(at: root) }
        let drive = root.appendingPathComponent("A")
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let file = drive.appendingPathComponent("only-copy.mov")
        try Data(repeating: 7, count: 100).write(to: file)
        let m = model(in: root)
        let labelled = record(file.path)
        labelled.archiveStage = .manuallyDeleted          // the old Migrate / keeper-fold label
        m.records = [labelled]
        m.scanTargets = [CatalogScanTarget(searchPath: drive.path)]
        #expect(!m.retireVolume(at: drive.path, reason: "test", witnesses: []),
                "retired a drive whose only copy of a file is still on it — the label is not a proof")
    }

    // T2 — pins Catalog/VideoScanModel+Workbench.swift:24 (and the same shape
    // at Catalog/TriageView.swift:1137, private to the View).
    // "Promote" must go through the Promote engine; a label alone puts a
    // file nobody copied into the Archived stage and freezes its dates.
    @Test func workbenchPromoteNeverStampsArchivedWithoutAnArchiveCopy() throws {
        let root = try scratch("promote_label"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let produced = record(root.appendingPathComponent("combined.mov").path)
        produced.lifecycleStage = .workbench
        m.records = [produced]
        m.promoteWorkbenchToArchive([produced])
        #expect(!(produced.lifecycleStage == .archived && !m.isArchived(produced)),
                "stamped Archived with no copy in the Master Archive")
        #expect(!m.isDateReadOnly(produced) || m.isArchived(produced),
                "dates frozen on a file that is not in the archive")
    }

    // T3 — pins Catalog/CatalogTrashConfirmation.swift:35-63 and
    // MediaOps/VideoScanModel+TrashSelection.swift:60. Charter (Catalog):
    // "⌘⌫ Move to Trash (Finder-like; it warns when the file is the only copy)".
    @Test func catalogMoveToTrashWarnsWhenTheFileIsTheOnlyCopy() throws {
        let root = try scratch("only_copy"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let only = record(root.appendingPathComponent("only.mov").path)
        m.records = [only]
        let plan = m.catalogTrashPlan(for: [only], isOffline: { _ in false })
        #expect(plan.toTrash == [only.id])
        let confirmation = CatalogTrashConfirmation(plan: plan, sizes: [only.id: only.sizeBytes])
        #expect(confirmation.detail.localizedCaseInsensitiveContains("only copy"),
                "the confirmation never says this is the only copy: \(confirmation.detail)")
    }

    // T4 (design-level, needs Rick's ruling on the one "gone" shape) — pins
    // MediaOps/VideoScanModel+Duplicates.swift:810. Every other Trash path
    // keeps the row as Removed (purgedAt + .trashed) so Show Removed → Restore
    // works; Delete Duplicates deletes the row.
    @Test func aTrashedDuplicateStaysInTheCatalogAsRemovedLikeEveryOtherTrashPath() throws {
        let root = try scratch("dup_row"); defer { try? FileManager.default.removeItem(at: root) }
        let m = model(in: root)
        let keeper = record(root.appendingPathComponent("keeper.mov").path)
        let extra = record(root.appendingPathComponent("extra.mov").path)
        m.records = [keeper, extra]
        m.settleDeletedDuplicate(expectedID: extra.id, expectedPath: extra.fullPath, preAwait: extra,
                                 keeperID: keeper.id, keeperPath: keeper.fullPath, keeperFilename: keeper.filename,
                                 isWorkingCopy: false, batchID: "test", keeperMatchedByStoredFixity: true,
                                 tier: .trash, trashVolume: "Test")
        #expect(m.records.contains { $0.id == extra.id && $0.isPurged && $0.lifecycleStage == .trashed },
                "the trashed duplicate left the catalog — Restore cannot bring it back")
    }

    // T5 — pins MediaOps/SignatureVerification.swift:681, :759, :830-833.
    // Trash only (2026-10-09): the verifier's convenience path must never unlink.
    @Test func quarantineAndDeleteNeverUnlinksOutright() throws {
        let dir = try scratch("never_unlink"); defer { try? FileManager.default.removeItem(at: dir) }
        let size = FileHasher.segmentSize + 333
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let keeper = dir.appendingPathComponent("keeper.mov"); try bytes.write(to: keeper)
        let copy = dir.appendingPathComponent("copy.mov"); try bytes.write(to: copy)
        var hooks = SignatureVerification.Hooks(shouldCancel: { false }, didReadBlock: { _ in })
        let fakeTrash = dir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        hooks.trashItem = { url in
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest); return dest
        }
        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path,
                                                     hooks: hooks).get()
        let result = SignatureVerification.quarantineAndDelete(proof, hooks: hooks)
        #expect(result != .deleted(bytes: Int64(size)), "unlinked outright — the app is Trash only")
        #expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("copy.mov").path))
    }
}
```

Notes for the fix agent:
- T5 contradicts `SignatureVerificationOneSidedTests.swift:73`, `SignatureConcurrencyScaleTests.swift:335`, `:362` and `DeleteDuplicatesCodex1593Tests.swift:104`, which expect `.deleted`. Update them in the same change.
- Check `SignatureVerification.verify`'s full parameter list (`SignatureVerification.swift:257`). If it requires more arguments, build the proof the way `SignatureVerificationOneSidedTests.equalDigestReadsOnlyTheDuplicate` does, via `verifyAgainstStoredKeeper`.
- T2 covers P3. P2 (`TriageView.promoteSelectedToArchive`) is `private` on a View, so it cannot be tested headlessly. Routing it to `requestPromote` makes T2's shape cover it.
- Structural findings in §2 (R2–R6, E3/E4, dead `CatalogDuplicatesMenu` / ContentView picker) have no behavioural red test. Their sensor is a source-scan test of the `DeleteDuplicatesAngelHoldTests.body(of:)` kind: "only `JunkDelete.swift` calls `trashItem` on catalog media", "only `MediaRepairEngine` builds repair ffmpeg args".
