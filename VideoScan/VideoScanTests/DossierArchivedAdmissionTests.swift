import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Dossier admits Archived and In Triage media (Rick 2026-10-10)
//
// Ruling: Dossier (captions + transcript) also analyzes Archived and In
// Triage media. It is read-only analysis that writes catalog metadata only.
// Root cause of the gap: `pfCatalogWideMetadataCandidates` admitted only
// {Cataloged, Workbench}, so no FamilyArchive master ever entered the loop
// (docs/design/segments_and_content_coverage_2026_10_10.md §2).
//
// HARD INVARIANTS pinned here (red before the fix):
//   1. An archived row receives ONLY the dossier fields (captions, OCR,
//      transcript, dossierProcessed*) — never a date, never a purge, never
//      a junk flag, never needsReformat (which would offer to write a
//      reformatted file next to it).
//   2. Analysis never modifies an archived FILE (bytes, size, mtime, and
//      no new file beside it).
//   3. A same-footage sibling's text is carried over with provenance, no
//      decode.
//   4. A file that fails with CaptionRunnerError.videoUnreadable is flagged
//      needsReformat and not retried by the next batch; an explicit
//      single-file Analyze still retries it.
//
// Five dimensions: logic (here), scale + isolation + media matrix + sensor
// in DossierArchivedAdmissionScaleTests / ...MediaMatrixTests.
// (For Rick: `@Test(arguments:)` is a table-driven test — one body, one
// reported case per argument, like a gtest TEST_P.)

/// Throws `videoUnreadable` for the listed file names; otherwise behaves
/// like StubDossierRunner. Counts calls per file name.
actor UnreadableDossierRunner: CaptionRunner {
    nonisolated let modelID = "stub-unreadable-vlm"
    private let unreadable: Set<String>
    private(set) var calls: [String] = []
    init(unreadable: Set<String>) { self.unreadable = unreadable }

    func caption(videoPath: String, atTimestamps timestamps: [Double]) async throws -> [SceneCaption] {
        timestamps.map { SceneCaption(timestamp: $0, text: "scene") }
    }

    func dossier(videoPath: String, atTimestamps timestamps: [Double]) async throws -> DossierExtraction {
        let name = (videoPath as NSString).lastPathComponent
        calls.append(name)
        if unreadable.contains(name) { throw CaptionRunnerError.videoUnreadable(path: videoPath) }
        return DossierExtraction(scenes: timestamps.map { SceneCaption(timestamp: $0, text: "a picnic") },
                                 dates: [], texts: [])
    }

    func callCount(_ name: String) -> Int { calls.filter { $0 == name }.count }
}

@MainActor
enum DossierAdmissionFixtures {

    /// The dossier channels — the ONLY record fields Dossier may write on an
    /// archived row (CodingKeys names as persisted in catalog.json).
    static let dossierKeys: Set<String> = [
        "sceneCaptions", "sceneCaptionModel", "sceneCaptionDate",
        "ocrDateCandidates", "ocrText",
        "audioTranscript", "audioTranscriptModel", "audioTranscriptDate",
        "dossierProcessedAt", "dossierProcessedBy",
    ]

    static let ocr1991 = SceneCaption(timestamp: 1, text: "JUN.21 1991 PM11:29")

    static func utc(_ y: Int) -> Date {
        var dc = DateComponents(); dc.year = y; dc.month = 1; dc.day = 1; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc)!   // swiftlint:disable:this force_unwrapping
    }

    /// Persisted form of a record as a key → JSON value map (the same
    /// encoder catalog.json uses).
    static func persisted(_ r: VideoRecord) throws -> [String: NSObject] {
        let data = try JSONEncoder().encode(VideoRecordDTO(r))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj.mapValues { $0 as? NSObject ?? NSNull() }
    }

    /// Keys whose persisted value differs between two snapshots.
    static func changedKeys(_ a: [String: NSObject], _ b: [String: NSObject]) -> Set<String> {
        Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }
    }

    /// Isolated model: scratch catalog store + log dir; a fake Master
    /// Archive designation that is never touched on disk.
    @MainActor
    final class Sandbox {
        let dir: URL
        let model: VideoScanModel
        init(_ label: String) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_dossier_admit_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
            model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
            let target = CatalogScanTarget(searchPath: dir.path)
            target.isReachable = true
            model.scanTargets = [target]
        }
        func cleanup() {
            MasterArchiveTestSupport.unlockTree(dir)
            try? FileManager.default.removeItem(at: dir)
        }

        /// A video record backed by a real (tiny) file in the sandbox.
        @discardableResult
        func record(_ name: String, stage: LifecycleStage, onDisk: Bool = true,
                    duration: Double = 3.0) -> VideoRecord {
            let r = VideoRecord()
            r.filename = name
            r.fullPath = dir.appendingPathComponent(name).path
            r.directory = dir.path
            r.ext = (name as NSString).pathExtension
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = duration
            r.sizeBytes = 1
            r.lifecycleStage = stage
            if onDisk { FileManager.default.createFile(atPath: r.fullPath, contents: Data("x".utf8)) }
            return r
        }
    }
}

@MainActor
@Suite("Dossier — Archived / In Triage admission and the read-only invariant", .serialized)
struct DossierArchivedAdmissionTests {

    typealias F = DossierAdmissionFixtures

    // MARK: - Admission through the real catalog-wide entry point

    /// SENSOR: Archived and In Triage records ARE analyzed by a catalog-wide
    /// Dossier pass; Trashed / Deleted are not. RED before 2026-10-10.
    @Test func catalogWideDossierAnalyzesArchivedAndInTriage() async throws {
        let sb = try F.Sandbox("catalogwide")
        defer { sb.cleanup() }
        let archived = sb.record("test_archived.mov", stage: .archived)
        let triage = sb.record("test_triage.mov", stage: .reviewing)
        let cataloged = sb.record("test_cataloged.mov", stage: .cataloged)
        let trashed = sb.record("test_trashed.mov", stage: .trashed)
        let deleted = sb.record("test_deleted.mov", stage: .deletedPermanently)
        sb.model.records = [archived, triage, cataloged, trashed, deleted]

        let stub = StubDossierRunner(modelID: "stub-admit")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        let called = Set(await stub.pathsCalled().map { ($0 as NSString).lastPathComponent })
        #expect(called == ["test_archived.mov", "test_triage.mov", "test_cataloged.mov"], "\(called)")
        #expect(archived.dossierProcessedAt != nil && !archived.sceneCaptions.isEmpty)
        #expect(triage.dossierProcessedAt != nil && !triage.sceneCaptions.isEmpty)
        #expect(trashed.dossierProcessedAt == nil && deleted.dossierProcessedAt == nil)
    }

    /// The per-volume entry point (dashboard "Analyze" on a volume row)
    /// admits them too — the doc names both call sites.
    @Test func perVolumeAnalyzeAdmitsArchivedAndInTriage() async throws {
        let sb = try F.Sandbox("pervolume")
        defer { sb.cleanup() }
        let archived = sb.record("test_archived.mov", stage: .archived)
        let triage = sb.record("test_triage.mov", stage: .reviewing)
        sb.model.records = [archived, triage]
        let stub = StubDossierRunner(modelID: "stub-admit")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        _ = await orch.startAnalyzing(volumePrefix: sb.dir.path, model: sb.model, transcriber: nil)
        #expect(await stub.countCalled() == 2)
        #expect(archived.dossierProcessedAt != nil && triage.dossierProcessedAt != nil)
    }

    // MARK: - INVARIANT: applyDossier writes only dossier fields on archived rows

    enum ArchivedShape: String, CaseIterable, CustomTestStringConvertible {
        /// lifecycleStage == .archived, OUTSIDE the archive root (604 such
        /// rows under SanDiskWorkspace/FromCheesegrater on 2026-10-10).
        case archivedStage
        /// A promoted copy inside the Master Archive root.
        case archiveElement
        var testDescription: String { rawValue }
    }

    /// RED before the fix for `.archivedStage`: applyDossier's own
    /// triangulation guard only knew `isArchiveElement`.
    @Test("applyDossier writes only dossier fields on an archived row", arguments: ArchivedShape.allCases)
    func applyDossierWritesOnlyDossierFieldsOnArchivedRow(_ shape: ArchivedShape) throws {
        let sb = try F.Sandbox("apply-\(shape.rawValue)")
        defer { sb.cleanup() }
        let root = "/Volumes/TestFamilyArchiveAdmit/Breen_Family_Archive"
        sb.model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestFamilyArchiveAdmit", rootPath: root)
        let r: VideoRecord
        switch shape {
        case .archivedStage:
            r = sb.record("test_filed.mov", stage: .archived, onDisk: false)
            r.fullPath = "/Volumes/TestSrc/FromCheesegrater/test_filed.mov"
            r.directory = "/Volumes/TestSrc/FromCheesegrater"
        case .archiveElement:
            r = sb.record("1985-xx-xx_test_filed.mov", stage: .archived, onDisk: false)
            r.fullPath = root + "/30_Video/1980-1989/1985/1985-xx-xx_test_filed.mov"
            r.directory = root + "/30_Video/1980-1989/1985"
            r.derivationKind = ArchivePromotion.derivationKind
        }
        r.inferredRecordDate = F.utc(1985); r.inferredDateConfidence = 0.9
        r.inferredDateReason = "filed as 1985"
        sb.model.records = [r]
        let before = try F.persisted(r)

        let x = DossierExtraction(scenes: [SceneCaption(timestamp: 0, text: "a birthday cake")],
                                  dates: [F.ocr1991], texts: [SceneCaption(timestamp: 0, text: "HAPPY BIRTHDAY")])
        #expect(sb.model.applyDossier(x, to: r.fullPath, vlmModel: "vlm", transcript: "happy birthday mark",
                                      whisperModel: "whisper"))
        let changed = F.changedKeys(before, try F.persisted(r))
        #expect(changed.isSubset(of: F.dossierKeys), "non-dossier fields written: \(changed.subtracting(F.dossierKeys).sorted())")
        #expect(r.inferredRecordDate == F.utc(1985) && r.inferredDateReason == "filed as 1985")
        #expect(r.sceneCaptions.count == 1 && r.audioTranscript == "happy birthday mark", "the channels still land")
    }

    /// CONTROL: the same call on a Cataloged row DOES move the date — proves
    /// the archived fixture's poison (OCR date evidence) is live.
    @Test func applyDossierControlWritesDateOnCatalogedRow() throws {
        let sb = try F.Sandbox("apply-control")
        defer { sb.cleanup() }
        let r = sb.record("test_live.mov", stage: .cataloged, onDisk: false)
        r.fullPath = "/Volumes/TestSrc/FromCheesegrater/test_live.mov"
        r.inferredRecordDate = F.utc(1985); r.inferredDateConfidence = 0.9
        r.inferredDateReason = "filed as 1985"
        sb.model.records = [r]
        let x = DossierExtraction(scenes: [], dates: [F.ocr1991, F.ocr1991], texts: [])
        _ = sb.model.applyDossier(x, to: r.fullPath, vlmModel: "vlm", transcript: nil, whisperModel: nil)
        #expect(r.inferredRecordDate != F.utc(1985), "control must change, or the archived rows prove nothing")
    }

    /// The INDIRECT path: Dossier gives an Archived row (outside the archive
    /// root) OCR date evidence; the date lane's next catch-up pass must not
    /// turn that evidence into a date on it. CONTROL: a Cataloged row with
    /// the same evidence IS dated by the same pass. RED before the date
    /// lane's frozen set used `isDossierReadOnly`.
    @Test func dateLaneNeverDatesAnArchivedRowFromDossierEvidence() throws {
        let sb = try F.Sandbox("datelane")
        defer { sb.cleanup() }
        let archived = sb.record("test_filed_evidence.mov", stage: .archived, onDisk: false)
        archived.fullPath = "/Volumes/TestSrc/FromCheesegrater/test_filed_evidence.mov"
        let control = sb.record("test_live_evidence.mov", stage: .cataloged, onDisk: false)
        control.fullPath = "/Volumes/TestSrc/FromCheesegrater/test_live_evidence.mov"
        sb.model.records = [archived, control]
        let x = DossierExtraction(scenes: [], dates: [F.ocr1991, F.ocr1991], texts: [])
        #expect(sb.model.applyDossier(x, to: archived.fullPath, vlmModel: "vlm", transcript: nil, whisperModel: nil))
        control.ocrDateCandidates = [F.ocr1991, F.ocr1991]
        let before = try F.persisted(archived)
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(control.inferredRecordDate != nil, "control: the date lane dates a live row from the same evidence")
        #expect(archived.inferredRecordDate == nil, "the date lane wrote a date on an archived row")
        #expect(F.changedKeys(before, try F.persisted(archived)).isEmpty)
    }

    // MARK: - INVARIANT: a whole batch never mutates an archived file or its non-dossier fields

    /// A locked (UF_IMMUTABLE, as Promote leaves it) archived file through a
    /// full batch: bytes, size, mtime unchanged, nothing new in its folder,
    /// and only dossier fields changed on the row.
    @Test func batchNeverModifiesAnArchivedFileOrItsNonDossierFields() async throws {
        let sb = try F.Sandbox("file-untouched")
        defer { sb.cleanup() }
        let r = sb.record("test_master.mov", stage: .archived)
        try Data(repeating: 0xA5, count: 4096).write(to: URL(fileURLWithPath: r.fullPath))
        r.sizeBytes = 4096
        r.inferredRecordDate = F.utc(1985); r.inferredDateConfidence = 0.9
        r.inferredDateReason = "filed as 1985"
        _ = lchflags(r.fullPath, UInt32(UF_IMMUTABLE))
        sb.model.records = [r]
        let attrsBefore = try FileManager.default.attributesOfItem(atPath: r.fullPath)
        let shaBefore = MasterArchiveTestSupport.sha256(ofFile: r.fullPath)
        let listingBefore = try FileManager.default.contentsOfDirectory(atPath: sb.dir.path).sorted()
        let rowBefore = try F.persisted(r)

        let stub = StubDossierRunner(modelID: "stub-file")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        #expect(await stub.countCalled() == 1, "the archived file must be analyzed (read)")
        let attrsAfter = try FileManager.default.attributesOfItem(atPath: r.fullPath)
        #expect(MasterArchiveTestSupport.sha256(ofFile: r.fullPath) == shaBefore)
        #expect((attrsAfter[.size] as? NSNumber) == (attrsBefore[.size] as? NSNumber))
        #expect((attrsAfter[.modificationDate] as? Date) == (attrsBefore[.modificationDate] as? Date))
        #expect(MasterArchiveTestSupport.isLocked(r.fullPath), "still locked")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sb.dir.path).sorted() == listingBefore)
        let changed = F.changedKeys(rowBefore, try F.persisted(r))
        #expect(changed.isSubset(of: F.dossierKeys), "non-dossier fields written: \(changed.subtracting(F.dossierKeys).sorted())")
        #expect(r.dossierProcessedAt != nil)
    }

    /// An archived row whose file is missing on a MOUNTED volume is left as
    /// is: never soft-purged, never junk-flagged. CONTROL: a Cataloged row
    /// in the same state is auto-purged as before.
    @Test func missingArchivedFileIsNeverPurged() async throws {
        let sb = try F.Sandbox("missing")
        defer { sb.cleanup() }
        let archived = sb.record("test_gone_archived.mov", stage: .archived, onDisk: false)
        let control = sb.record("test_gone_live.mov", stage: .cataloged, onDisk: false)
        sb.model.records = [archived, control]
        let before = try F.persisted(archived)
        let stub = StubDossierRunner(modelID: "stub-missing")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(control.purgedAt != nil, "control: missing live row is auto-purged")
        #expect(archived.purgedAt == nil, "an archived row must never be purged by analysis")
        #expect(archived.junkReasons.isEmpty)
        #expect(F.changedKeys(before, try F.persisted(archived)).isEmpty)
    }

    /// The auto-purge of a missing file (Rick 2026-06-13) was ruled for the
    /// live pool. A newly admitted In Triage row is left as is: on Rick's
    /// catalog 12 such rows sit on the FamilyArchive volume, where nothing
    /// may be removed (2026-09-22), and the purge does not pass through
    /// that volume guard.
    @Test func missingInTriageFileIsNotAutoPurged() async throws {
        let sb = try F.Sandbox("missing-triage")
        defer { sb.cleanup() }
        let triage = sb.record("test_gone_triage.mov", stage: .reviewing, onDisk: false)
        sb.model.records = [triage]
        let before = try F.persisted(triage)
        let stub = StubDossierRunner(modelID: "stub-missing")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(triage.purgedAt == nil && triage.junkReasons.isEmpty)
        #expect(F.changedKeys(before, try F.persisted(triage)).isEmpty)
        #expect(orch.liveSkipMissing == 1, "still counted as missing")
    }

    // MARK: - videoUnreadable: flagged once, not retried, explicit retry still works

    @Test func videoUnreadableIsFlaggedAndNotRetriedByTheNextBatch() async throws {
        let sb = try F.Sandbox("unreadable")
        defer { sb.cleanup() }
        let bad = sb.record("test_unreadable.mxf", stage: .cataloged)
        let good = sb.record("test_fine.mov", stage: .cataloged)
        sb.model.records = [bad, good]
        let runner = UnreadableDossierRunner(unreadable: ["test_unreadable.mxf"])
        let orch = CaptionOrchestrator(runnerFactory: { runner })

        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await runner.callCount("test_unreadable.mxf") == 1)
        #expect(bad.needsReformat, "videoUnreadable must flag needsReformat")
        #expect(bad.unanalyzableReason != nil, "the reason is visible in the UI badge")
        #expect(bad.dossierProcessedAt == nil)
        guard case .finished(_, _, let failed1) = orch.currentStatus else { Issue.record("\(orch.currentStatus)"); return }
        #expect(failed1 == 1)

        // Second batch: not retried, not counted as a failure.
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await runner.callCount("test_unreadable.mxf") == 1, "re-tried on the next run")
        guard case .finished(_, let skipped2, let failed2) = orch.currentStatus else { Issue.record("\(orch.currentStatus)"); return }
        #expect(failed2 == 0)
        #expect(skipped2 == 2, "the analyzed file + the needs-reformat file")

        // Explicit single-file Analyze (right-click) still tries it.
        _ = await orch.startAnalyzing(volumePrefix: bad.fullPath, model: sb.model, transcriber: nil, ignoringScope: true)
        #expect(await runner.callCount("test_unreadable.mxf") == 2, "explicit per-file Analyze must retry")
    }

    /// An ARCHIVED row that fails to decode is never flagged needsReformat
    /// (the Reformat offer would write a new file beside an archive master).
    @Test func unreadableArchivedRowIsNotFlagged() async throws {
        let sb = try F.Sandbox("unreadable-archived")
        defer { sb.cleanup() }
        let bad = sb.record("test_unreadable_master.mov", stage: .archived)
        sb.model.records = [bad]
        let before = try F.persisted(bad)
        let runner = UnreadableDossierRunner(unreadable: ["test_unreadable_master.mov"])
        let orch = CaptionOrchestrator(runnerFactory: { runner })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await runner.callCount("test_unreadable_master.mov") == 1)
        #expect(!bad.needsReformat)
        #expect(F.changedKeys(before, try F.persisted(bad)).isEmpty)
    }

    // MARK: - Carry-over: same footage, zero decode, provenance

    @Test func byteTwinTextIsCarriedOverWithProvenance() async throws {
        let sb = try F.Sandbox("carry-bytes")
        defer { sb.cleanup() }
        let donor = sb.record("test_twin_a.mov", stage: .cataloged)
        donor.partialMD5 = "md5-carry"; donor.sizeBytes = 4_242
        donor.sceneCaptions = [SceneCaption(timestamp: 1, text: "Thanksgiving dinner")]
        donor.sceneCaptionModel = "vlm-x"
        donor.audioTranscript = "next to him we have Mr. Glenn Hudson"
        donor.audioTranscriptModel = "whisper-x"
        donor.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        donor.dossierProcessedBy = "vlm-x+whisper-x"
        let twin = sb.record("test_twin_b.mov", stage: .archived)
        twin.partialMD5 = "md5-carry"; twin.sizeBytes = 4_242
        twin.inferredRecordDate = F.utc(1984); twin.inferredDateReason = "filed as 1984"
        sb.model.records = [donor, twin]
        let before = try F.persisted(twin)

        let stub = StubDossierRunner(modelID: "stub-carry")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        #expect(await stub.countCalled() == 0, "zero decode: the twin's text is copied")
        #expect(twin.sceneCaptions == donor.sceneCaptions)
        #expect(twin.audioTranscript == donor.audioTranscript)
        #expect(twin.dossierProcessedAt != nil)
        #expect(twin.dossierProcessedBy == "from \(donor.id.uuidString) (same bytes)", "\(twin.dossierProcessedBy ?? "nil")")
        let changed = F.changedKeys(before, try F.persisted(twin))
        #expect(changed.isSubset(of: F.dossierKeys), "\(changed.subtracting(F.dossierKeys).sorted())")
    }

    static func footage(_ g: UUID, _ confidence: FootageConfidence, original: VideoRecord, rank: Int) -> FootageMembership {
        FootageMembership(groupID: g, groupSize: 2, confidence: confidence, role: rank == 0 ? .original : .reEncode,
                          rank: rank, likelyOriginalID: original.id, originalInCatalog: true,
                          evidence: ["same name + length"], scannedAt: Date(), algorithmVersion: 1)
    }

    @Test func sameFootageTextIsCarriedOverOnlyWhenLengthsMatchAndConfident() async throws {
        let sb = try F.Sandbox("carry-footage")
        defer { sb.cleanup() }
        let g = UUID()
        let donor = sb.record("test_master.mkv", stage: .archived, duration: 5_640)
        donor.sceneCaptions = [SceneCaption(timestamp: 281, text: "a dinner table")]
        donor.audioTranscript = "happy birthday"
        donor.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
        donor.footage = Self.footage(g, .likely, original: donor, rank: 0)
        let reEncode = sb.record("test_master_improved.mp4", stage: .reviewing, duration: 5_640.4)
        reEncode.footage = Self.footage(g, .likely, original: donor, rank: 1)
        let trim = sb.record("test_master_trim.mp4", stage: .cataloged, duration: 120)
        trim.footage = Self.footage(g, .likely, original: donor, rank: 2)
        let weak = sb.record("test_master_weak.mp4", stage: .cataloged, duration: 5_640)
        weak.footage = Self.footage(g, .possible, original: donor, rank: 3)
        let refused = sb.record("test_master_notsame.mp4", stage: .cataloged, duration: 5_640)
        refused.footage = Self.footage(g, .likely, original: donor, rank: 4)
        refused.footageDecisions = [FootageDecision(otherID: donor.id, verdict: .notSame)]
        sb.model.records = [donor, reEncode, trim, weak, refused]

        let stub = StubDossierRunner(modelID: "stub-carry")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)

        #expect(reEncode.dossierProcessedBy == "from \(donor.id.uuidString) (same footage)", "\(reEncode.dossierProcessedBy ?? "nil")")
        #expect(reEncode.audioTranscript == "happy birthday")
        let analyzed = Set(await stub.pathsCalled().map { ($0 as NSString).lastPathComponent })
        #expect(analyzed == ["test_master_trim.mp4", "test_master_weak.mp4", "test_master_notsame.mp4"],
                "a trim (different length), a weak link and a 'not the same' decision are analyzed, not carried: \(analyzed)")
    }

    /// Within one batch: two never-analyzed byte twins — the first is
    /// analyzed, the second inherits it (one copy per footage group).
    @Test func secondTwinInTheSameBatchInheritsTheFirst() async throws {
        let sb = try F.Sandbox("carry-inbatch")
        defer { sb.cleanup() }
        let a = sb.record("test_pair_a.mov", stage: .archived)
        let b = sb.record("test_pair_b.mov", stage: .reviewing)
        for r in [a, b] { r.partialMD5 = "md5-pair"; r.sizeBytes = 77 }
        sb.model.records = [a, b]
        let stub = StubDossierRunner(modelID: "stub-carry")
        let orch = CaptionOrchestrator(runnerFactory: { stub })
        await orch.startCatalogWideDossier(model: sb.model)
        #expect(await stub.countCalled() == 1)
        #expect(b.dossierProcessedBy == "from \(a.id.uuidString) (same bytes)", "\(b.dossierProcessedBy ?? "nil")")
        #expect(b.sceneCaptions == a.sceneCaptions)
    }
}
