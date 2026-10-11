import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Archived = read-only for dates, in EVERY writer (Rick 2026-10-11)
//
// The rule follows the STAGE, not the folder: a record at the Archived stage
// keeps its dates whatever writer runs, inside the archive root or not. ONE
// seam — VideoScanModel.isDateReadOnly (VideoScanModel+DateReadOnly.swift) —
// is consulted by every writer. Only Update… changes an archived date.
//
// Five dimensions (CLAUDE.md feature-test checklist):
//   logic      the seam's truth table, then one pin per writer that was NOT
//              guarded by the stage before this change (the #1413 unwind and
//              its re-anchor, the sidecar reapply, the human-mark carry used
//              by repair confirm / duplicate delete / prune, Link Repaired
//              Copy, the Archive Angel's promote stamp), each with a control
//              row that IS written; and Update… still writes
//   scale      100k records, 20 % Archived outside the root: the unwind and
//              the catch-up pass inside budget, zero archived rows changed
//   isolation  a stale Master Archive designation (another root) and none
//              at all: the stage rule does not move
//   sensor     (a) every background writer run back to back over one
//              Archived-stage row leaves its persisted date keys identical;
//              (b) a source scan of every date-field assignment in the app
//              against the reviewed writer list — a NEW writer fails here
//              until it consults the seam or is justified
//   media      Link Repaired Copy over a real probed mov (ffmpeg fixture)
//
// The two QA pins (P3-b LiveReload, P3-c DuplicateEnrichment) live in
// QADossierAdmissionRedTests and are now ordinary passing tests.

@MainActor
@Suite("Archived dates are read-only in every writer (2026-10-11)", .serialized)
struct ArchivedDateReadOnlyTests {

    typealias F = DossierAdmissionFixtures

    /// The persisted keys the ruling freezes (CodingKeys names).
    static let dateKeys: Set<String> = [
        "userDate", "userDateConfidence",
        "inferredRecordDate", "inferredDateConfidence", "inferredDateRange",
        "inferredDateReason", "inferredDateSource",
    ]

    /// A row OUTSIDE any archive root, with a propagated date whose donor is
    /// gone (the #1413 unwind's victim shape).
    static func orphanPropagated(_ r: VideoRecord) {
        r.inferredRecordDate = F.utc(1985)
        r.inferredDateConfidence = 0.85
        r.inferredDateReason = "same bytes as gone.mov"
        r.inferredDateSource = VideoScanModel.InferredDateSource.propagatedPrefix + UUID().uuidString
    }

    // MARK: - The seam

    @Test func seamFollowsTheStageAndStillCoversArchiveFiles() throws {
        let sb = try F.Sandbox("seam")
        defer { sb.cleanup() }
        let root = sb.dir.appendingPathComponent("test_Archive", isDirectory: true).path
        sb.model.masterArchive = MasterArchiveDesignation(targetPath: sb.dir.path, rootPath: root)
        let outsideArchived = sb.record("test_out_archived.mov", stage: .archived, onDisk: false)
        let outsideCataloged = sb.record("test_out_cataloged.mov", stage: .cataloged, onDisk: false)
        let promotedCopy = sb.record("test_copy.mov", stage: .cataloged, onDisk: false)
        promotedCopy.derivationKind = ArchivePromotion.derivationKind
        let insideRoot = sb.record("test_inside.mov", stage: .cataloged, onDisk: false)
        insideRoot.fullPath = root + "/30_Video/test_inside.mov"
        #expect(sb.model.isDateReadOnly(outsideArchived), "the stage rule: outside the root, still frozen")
        #expect(!sb.model.isDateReadOnly(outsideCataloged))
        #expect(sb.model.isDateReadOnly(promotedCopy), "a promoted copy stays protected whatever its stage")
        #expect(sb.model.isDateReadOnly(insideRoot), "a file inside the root stays protected whatever its stage")
        for stage in LifecycleStage.allCases where stage != .archived {
            outsideCataloged.lifecycleStage = stage
            #expect(!sb.model.isDateReadOnly(outsideCataloged), "\(stage.rawValue) outside the root is writable")
        }
        #expect(sb.model.isDossierReadOnly(outsideArchived) == sb.model.isDateReadOnly(outsideArchived),
                "Dossier's read-only rule IS the date seam")
    }

    // MARK: - Writers newly routed through the seam

    /// #1413 unwind: it used `isArchiveElement` only, so an Archived-stage
    /// source outside the root had its (machine) date cleared.
    @Test func unwindNeverClearsAnArchivedStageRow() throws {
        let sb = try F.Sandbox("unwind")
        defer { sb.cleanup() }
        let archived = sb.record("test_unwind_archived.mov", stage: .archived, onDisk: false)
        let control = sb.record("test_unwind_control.mov", stage: .cataloged, onDisk: false)
        Self.orphanPropagated(archived); Self.orphanPropagated(control)
        sb.model.records = [archived, control]
        let before = try F.persisted(archived)
        let r = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                        trigger: "test")
        #expect(r.unwound == 1, "only the control is unwound")
        #expect(control.inferredRecordDate == nil, "control: an unverified propagated date IS cleared")
        #expect(F.changedKeys(before, try F.persisted(archived)).isEmpty)
    }

    /// #1413 re-anchor: A (own) → B (victim) → C (verified against A). C is
    /// re-anchored to A — unless C is Archived, whose provenance stands.
    @Test("unwind re-anchor skips an Archived-stage row", arguments: [true, false])
    func reanchorSkipsArchivedStage(_ archivedC: Bool) throws {
        let sb = try F.Sandbox("reanchor-\(archivedC)")
        defer { sb.cleanup() }
        let a = sb.record("test_a.mov", stage: .cataloged, onDisk: false)
        a.contentHash = "hash-a"; a.inferredRecordDate = F.utc(1991); a.inferredDateConfidence = 0.9
        let b = sb.record("test_b.mov", stage: .cataloged, onDisk: false)
        b.contentHash = "hash-b"; b.inferredRecordDate = F.utc(1991); b.inferredDateConfidence = 0.9
        b.inferredDateSource = VideoScanModel.InferredDateSource.propagated(from: a)
        let c = sb.record("test_c.mov", stage: archivedC ? .archived : .cataloged, onDisk: false)
        c.contentHash = "hash-a"; c.inferredRecordDate = F.utc(1991); c.inferredDateConfidence = 0.9
        c.inferredDateSource = VideoScanModel.InferredDateSource.propagated(from: b)
        sb.model.records = [a, b, c]
        let r = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                        trigger: "test")
        #expect(r.unwound == 1 && b.inferredRecordDate == nil)
        let expected = VideoScanModel.InferredDateSource.propagated(from: archivedC ? b : a)
        #expect(c.inferredDateSource == expected, "archived=\(archivedC): \(c.inferredDateSource ?? "nil")")
        #expect(r.reanchored == (archivedC ? 0 : 1))
    }

    /// The sidecar undo puts a date back only where the seam allows — an
    /// old sidecar may name a row that is Archived now.
    @Test func reapplyNeverRestoresOntoAnArchivedStageRow() throws {
        let sb = try F.Sandbox("reapply")
        defer { sb.cleanup() }
        let archived = sb.record("test_reapply_archived.mov", stage: .archived, onDisk: false)
        let control = sb.record("test_reapply_control.mov", stage: .cataloged, onDisk: false)
        sb.model.records = [archived, control]
        let entries = [archived, control].map {
            VideoScanModel.UnwoundDateEntry(recordID: $0.id, fullPath: $0.fullPath, inferredRecordDate: F.utc(1985),
                                            inferredDateConfidence: 0.85, inferredDateSource: "propagated from x")
        }
        let restored = VideoScanModel.reapplyUnwoundDates(entries, to: sb.model.records,
                                                          isDateReadOnly: sb.model.isDateReadOnly)
        #expect(restored.map(\.id) == [control.id])
        #expect(control.inferredRecordDate == F.utc(1985))
        #expect(archived.inferredRecordDate == nil && archived.inferredDateSource == nil)
    }

    /// The human-mark carry (duplicate delete's keeper fold, Archived — what
    /// next?'s prune fold, repair confirm) wrote Rick's date onto an
    /// Archived keeper. The date stays as filed — and the log says what was
    /// declined; the place still rides (the ruling is about dates).
    @Test func humanMarkCarryLeavesAnArchivedKeepersDate() async throws {
        let sb = try F.Sandbox("human")
        defer { sb.cleanup() }
        let keeper = sb.record("test_keeper.mov", stage: .archived, onDisk: false)
        let extra = sb.record("test_extra.mov", stage: .cataloged, onDisk: false)
        extra.userDate = "1987-06"; extra.userDateConfidence = "known"; extra.userPlace = "Cape Cod"
        sb.model.records = [keeper, extra]
        let carried = sb.model.applyHumanMetadataInheritance(from: extra, to: keeper)
        #expect(keeper.userDate == nil && keeper.userDateConfidence == nil)
        #expect(!carried.contains("date") && carried.contains("place"), "\(carried)")
        #expect(keeper.userPlace == "Cape Cod")
        // The console flushes on a 0.15 s debounce (DashboardState.log).
        func logged() -> Bool {
            sb.model.dashboard.consoleLines.contains {
                $0.contains("test_keeper.mov is archived — date left as filed") && $0.contains("1987-06 from test_extra.mov")
            }
        }
        for _ in 0..<40 where !logged() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(logged(), "the declined date is in the log, not lost silently")
    }

    /// Control + the snapshot rule: a NEW repair of an Archived original
    /// takes the original's stage AND its date in the same fold — the seam
    /// is judged on the repair as it was BEFORE the fold.
    @Test func repairOfAnArchivedOriginalStillTakesTheDate() throws {
        let sb = try F.Sandbox("repair")
        defer { sb.cleanup() }
        let original = sb.record("test_original.mov", stage: .archived, onDisk: false)
        original.userDate = "1994-11"; original.userDateConfidence = "estimated"
        let repair = sb.record("test_repair.mov", stage: .cataloged, onDisk: false)
        sb.model.records = [original, repair]
        let carried = sb.model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(carried.contains("date") && carried.contains("lifecycle stage"), "\(carried)")
        #expect(repair.userDate == "1994-11" && repair.userDateConfidence == "estimated")
        #expect(repair.lifecycleStage == .archived)
    }

    /// The Archive Angel's promote stamp: never a date onto an Archived row;
    /// place still rides. Control: a cataloged original IS stamped.
    @Test("Angel stamp skips the date on an Archived row", arguments: [true, false])
    func angelStampSkipsArchivedDate(_ archived: Bool) {
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "tape.mov"; original.fullPath = "/Volumes/TestAngel/tape.mov"
        original.lifecycleStage = archived ? .archived : .cataloged
        let sibling = VideoRecord()
        sibling.filename = "copy.mov"; sibling.fullPath = "/Volumes/TestAngel/copy.mov"
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"; sibling.userPlace = "Cape Cod"
        let e = ArchiveAngelPlan.Entry(id: original.id, sourcePath: original.fullPath, filename: "tape.mov", sizeBytes: 1,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "tape.mov", proposedDate: nil)
        let r = ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [], family: [original, sibling],
                                              isDateReadOnly: { model.isDateReadOnly($0) })
        #expect(original.userDate == (archived ? nil : "1987-06"))
        #expect(original.userPlace == "Cape Cod", "place is not a date — it still rides")
        #expect(r.facts.contains { $0.field == .date } == !archived)
    }

    /// Link Repaired Copy onto a path the catalog already holds as an
    /// Archived row: provenance is linked, the filed date is not replaced.
    /// MEDIA: a real ProRes mov probed by ffprobe.
    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func linkRepairedCopyKeepsAnArchivedRowsDate() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("adopt_archived")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: "test_recovered_archived.mov",
                                                     videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
                                                     audioCodec: "pcm_s16le")
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "test_damaged.mov"; original.fullPath = "/Volumes/TestT/test_damaged.mov"
        original.streamTypeRaw = StreamType.videoAndAudio.rawValue
        original.userDate = "1994-11"; original.userDateConfidence = "estimated"
        let existing = VideoRecord()
        existing.filename = "test_recovered_archived.mov"; existing.fullPath = path
        existing.directory = dir.path; existing.lifecycleStage = .archived
        model.records = [original, existing]
        let adopted = try await model.adoptExternalRepair(originalID: original.id, fileURL: URL(fileURLWithPath: path))
        #expect(adopted === existing)
        #expect(adopted.derivedFrom == original.id, "provenance is still linked")
        #expect(adopted.userDate == nil && adopted.userDateConfidence == nil, "the archived row's date is left as filed")
    }

    // MARK: - Controls for the two QA pins (the guard is not over-broad)

    @Test func liveReloadStillDatesACatalogedRow() throws {
        let sb = try F.Sandbox("livereload-control")
        defer { sb.cleanup() }
        let t = sb.record("test_live.mov", stage: .cataloged, onDisk: false)
        t.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        sb.model.records = [t]
        let fresh = VideoRecord()
        fresh.fullPath = t.fullPath; fresh.filename = t.filename
        fresh.inferredRecordDate = F.utc(1991); fresh.inferredDateConfidence = 0.95
        fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = sb.model.mergeDossierFields(from: [fresh])
        #expect(t.inferredRecordDate == F.utc(1991))
    }

    @Test func duplicateEnrichmentStillDatesACatalogedKeeper() throws {
        let sb = try F.Sandbox("dupenrich-control")
        defer { sb.cleanup() }
        let master = sb.record("test_keeper.mov", stage: .cataloged, onDisk: false)
        let extra = sb.record("test_extra.mov", stage: .cataloged, onDisk: false)
        extra.inferredRecordDate = F.utc(1991); extra.inferredDateConfidence = 0.8
        sb.model.records = [master, extra]
        let carried = sb.model.applyEnrichmentInheritance(from: extra, to: master)
        #expect(master.inferredRecordDate == F.utc(1991) && carried.contains("inferred date"))
    }

    // MARK: - Update… still writes (the one door)

    /// The explicit Update… flow changes an archived record's date even
    /// when the record is at the Archived stage (the seam says read-only).
    @Test func updateStillWritesAnArchivedStageRecordsDate() async throws {
        let a = try UpdateFixture.make("stage_rule")
        defer { a.sb.cleanup() }
        a.copy.lifecycleStage = .archived
        #expect(a.model.isDateReadOnly(a.copy), "precondition: every other writer is refused this record")
        let p = try await UpdateFixture.preview(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true)
        #expect(r.kind == .updated, "\(r.message)")
        #expect(a.copy.userDate == "1984" && a.copy.userDateConfidence == "known")
    }

    // MARK: - Isolation: a stale designation, or none

    @Test("the stage rule does not depend on the Master Archive designation", arguments: [false, true])
    func stageRuleIgnoresTheDesignation(_ staleRoot: Bool) throws {
        let sb = try F.Sandbox("poison-\(staleRoot)")
        defer { sb.cleanup() }
        // Poisoned: a designation for an unrelated root (a drive since
        // renamed) — or none at all.
        sb.model.masterArchive = staleRoot
            ? MasterArchiveDesignation(targetPath: "/Volumes/TestGoneDrive", rootPath: "/Volumes/TestGoneDrive/Archive")
            : nil
        let archived = sb.record("test_poison.mov", stage: .archived, onDisk: false)
        Self.orphanPropagated(archived)
        let copy = sb.record("test_poison_copy.mov", stage: .cataloged, onDisk: false)
        copy.derivationKind = ArchivePromotion.derivationKind
        Self.orphanPropagated(copy)
        sb.model.records = [archived, copy]
        #expect(sb.model.isDateReadOnly(archived) && sb.model.isDateReadOnly(copy))
        let before = try [archived, copy].map(F.persisted)
        _ = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                    trigger: "test")
        sb.model.catchUpInferredDates(trigger: "test")
        let after = try [archived, copy].map(F.persisted)
        #expect(F.changedKeys(before[0], after[0]).isEmpty && F.changedKeys(before[1], after[1]).isEmpty)
    }

    // MARK: - Scale: 100k

    /// 100k records — 20 % Archived outside any root (half with an unwind-
    /// shaped propagated date, half undated with caption evidence under a
    /// bare-year folder), 20 % cataloged unwind victims, 20 % cataloged with
    /// caption evidence. The unwind and the full catch-up pass each run
    /// inside budget, and not ONE archived row's date keys change.
    @Test("scale: 100k — no archived row re-dated, inside budget", .timeLimit(.minutes(3)))
    func scale100kArchivedRowsUntouched() throws {
        let sb = try F.Sandbox("scale")
        defer { sb.cleanup() }
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        var archived: [VideoRecord] = []
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "c\(i).mov"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.partialMD5 = "solo-\(i)"; r.sizeBytes = Int64(1_000 + i)
            r.fullPath = "/Volumes/TestScaleSrc/\(i % 10 == 5 ? "1991/" : "")c\(i).mov"
            switch i % 5 {
            case 0:
                r.lifecycleStage = .archived
                if i % 10 == 0 { Self.orphanPropagated(r) } else {
                    r.sceneCaptions = [SceneCaption(timestamp: 1, text: "Christmas 1991 by the tree")]
                }
                archived.append(r)
            case 1: Self.orphanPropagated(r)
            case 2: r.sceneCaptions = [SceneCaption(timestamp: 1, text: "Christmas 1991 by the tree")]
            default: break
            }
            recs.append(r)
        }
        sb.model.records = recs
        func snapshot() -> [[AnyHashable?]] {
            archived.map { [$0.userDate, $0.userDateConfidence, $0.inferredRecordDate, $0.inferredDateConfidence,
                             $0.inferredDateReason, $0.inferredDateSource, $0.inferredDateRange?.displayString] }
        }
        let before = snapshot()

        let clock = SuspendingClock()
        var unwind = VideoScanModel.UnwindResult()
        let tUnwind = clock.measure {
            unwind = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                             trigger: "scale")
        }
        var pass = VideoScanModel.InferredDateCatchUpResult()
        let tPass = clock.measure { pass = sb.model.catchUpInferredDates(trigger: "scale") }

        #expect(unwind.unwound == 20_000, "the cataloged victims only: \(unwind.unwound)")
        #expect(pass.inferredFromEvidence == 20_000, "the cataloged evidence rows only: \(pass.inferredFromEvidence)")
        #expect(pass.folderYear == 0, "every bare-year-folder row is Archived: \(pass.folderYear)")
        #expect(snapshot() == before, "an Archived-stage row's dates changed at scale")
        #expect(tUnwind < PerformanceLane.debugCeiling(.seconds(3)), "unwind took \(tUnwind)")
        #expect(tPass < PerformanceLane.debugCeiling(.seconds(3)), "catch-up took \(tPass)")
        print("ArchivedDateReadOnly scale: unwind \(tUnwind), catch-up \(tPass)")
    }

    // MARK: - SENSOR (a): every background writer, back to back

    /// One Archived-stage row outside the root, run through every machine
    /// date writer in the app. Its persisted date keys are byte-identical
    /// afterwards. Red if any writer drops the seam.
    @Test func everyBackgroundWriterLeavesAnArchivedStageRowsDates() throws {
        let sb = try F.Sandbox("sensor")
        defer { sb.cleanup() }
        let t = sb.record("test_sensor.mov", stage: .archived, onDisk: false)
        t.fullPath = "/Volumes/TestSensorSrc/1991/test_sensor.mov"
        t.partialMD5 = "md5-sensor"; t.sizeBytes = 77
        Self.orphanPropagated(t)
        t.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let twin = sb.record("test_twin.mov", stage: .cataloged, onDisk: false)
        twin.partialMD5 = "md5-sensor"; twin.sizeBytes = 77
        twin.userDate = "1990"; twin.userDateConfidence = "known"
        twin.inferredRecordDate = F.utc(1990); twin.inferredDateConfidence = 0.95
        sb.model.records = [t, twin]
        let before = try F.persisted(t)

        // Dossier writeback (own pass) and its group propagation.
        sb.model.applyDossier(DossierExtraction(scenes: [SceneCaption(timestamp: 1, text: "Christmas 1991")],
                                                dates: [], texts: []),
                              to: t.fullPath, vlmModel: "stub-sensor", transcript: "it is 1991", whisperModel: "w")
        // External merger (live reload).
        let fresh = VideoRecord()
        fresh.fullPath = t.fullPath; fresh.filename = t.filename
        fresh.inferredRecordDate = F.utc(1992); fresh.inferredDateConfidence = 0.95
        fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_900_000_000)
        _ = sb.model.mergeDossierFields(from: [fresh])
        // Duplicate delete folds (machine + human).
        _ = sb.model.applyEnrichmentInheritance(from: twin, to: t)
        _ = sb.model.applyHumanMetadataInheritance(from: twin, to: t)
        // The catch-up pass, the #1413 unwind, and its undo.
        sb.model.catchUpInferredDates(trigger: "sensor")
        let unwind = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                             trigger: "sensor")
        if let sidecar = unwind.sidecar { _ = try sb.model.reapplyUnwoundDates(from: sidecar) }

        let changed = F.changedKeys(before, try F.persisted(t)).intersection(Self.dateKeys)
        #expect(changed.isEmpty, "an Archived-stage row's dates were written by: \(changed.sorted())")
    }

    // MARK: - SENSOR (b): the reviewed list of date writers

    /// Every file in the app that assigns a record date field (receiver not
    /// `self`), and why it may. A file that starts writing a date fails
    /// here: route it through `isDateReadOnly`, then add it with a reason.
    /// A file that stops writing fails too, so the list stays true.
    static let reviewedDateWriters: [String: String] = [
        // Routed through the seam.
        "Catalog/VideoScanModel+DateInference.swift": "catch-up pass (pass.archived), #1413 unwind + re-anchor, reapply — all isDateReadOnly",
        "Catalog/VideoScanModel+LiveReload.swift": "external merger — isDateReadOnly (QA P3-b)",
        "MediaOps/VideoScanModel+DuplicateEnrichment.swift": "duplicate-delete enrichment — isDateReadOnly (QA P3-c)",
        "Archive/VideoScanModel+DateReadOnly.swift": "carryHandEnteredDate — the seam's own carry rule",
        "ArchiveAngel/Promote/ArchiveAngelFamilyStamp.swift": "stampDateIfMissing — called only via ArchiveAngelFamilyFacts.stampDate, which consults the seam",
        "MediaOps/VideoScanModel+RepairLifecycle.swift": "undoConfirmRepair restores the repair's own pre-confirm snapshot (the carry itself goes through carryHandEnteredDate)",
        // Exempt: the filing itself, the one door, and Rick's hand.
        "Archive/PromoteToArchiveJob+Steps.swift": "Promote dates the archive copy it just registered — the filing act",
        "Archive/VideoScanModel+MasterArchive.swift": "registerPromotedCopy / orphan copy — builds the new archive record",
        "Archive/VideoScanModel+ArchiveUpdate.swift": "Update… — the one door (Rick 2026-09-27)",
        "Catalog/InspectorDateView.swift": "Rick typing a date in the Inspector — his hand, not a writer the ruling names (flagged to Rick 2026-10-11)",
        "ArchiveAngel/Promote/ArchiveAngelFamilyFacts.swift": "restore — undo of the Angel's own stamp on a promote that did not land",
        "Catalog/VideoScanModel+RescanPreservation.swift": "puts the record's OWN preserved values back after a rescan",
        // New records (not an existing row) and value types.
        "MediaOps/TrimJob.swift": "new trim record",
        "MediaOps/BalanceAudioJob.swift": "new balanced record",
        "MediaOps/RebuildAudioJob.swift": "new rebuilt record",
        "MediaOps/Repair/MediaRepairJob.swift": "new repaired-copy record",
        "Archive/ArchiveReadiness.swift": "ArchiveReadiness.Inputs — a value type, not a record",
    ]

    @Test func sensorEveryDateWriterIsReviewed() throws {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
        let fields = "userDate|userDateConfidence|inferredRecordDate|inferredDateConfidence|inferredDateRange|inferredDateReason|inferredDateSource"
        let regex = try NSRegularExpression(pattern: "(?<![\\w.])([A-Za-z_]\\w*)\\.(\(fields))\\s*=(?!=)")
        var writers = Set<String>()
        let walker = try #require(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let hit = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { m in
                guard let r = Range(m.range(at: 1), in: text) else { return false }
                return text[r] != "self"
            }
            if hit { writers.insert(String(url.path.dropFirst(appDir.path.count + 1))) }
        }
        #expect(writers.count > 10, "the scan found the app sources: \(writers.count)")
        let unreviewed = writers.subtracting(Self.reviewedDateWriters.keys)
        #expect(unreviewed.isEmpty, "new date writer(s) — consult isDateReadOnly, then list with a reason: \(unreviewed.sorted())")
        let stale = Set(Self.reviewedDateWriters.keys).subtracting(writers)
        #expect(stale.isEmpty, "listed but no longer writing a date — drop from the list: \(stale.sorted())")
    }
}
