import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #528: archived means fixed, for EVERY copy, in EVERY date writer
//
// catalog.sqlite keeps one date per content (`user_dates` / `inferred_dates`
// keyed by the whole-file digest, joined by digest at load). Codex #383 made
// the Inspector refuse a twin of archived content and the commit-time copy
// step decline to write onto the archived copy in memory — but every OTHER
// writer judged only its own target, so a date it wrote on the unarchived
// twin became the archived copy's date after relaunch.
//
// Fix: the date seam `isDateReadOnly` is twin-aware (a live archived copy of
// the same whole-file digest freezes every copy's dates), so every writer
// that asks it refuses; and the commit refuses a date group on such a twin
// (defence in depth, one log line).
//
// These tests use only APIs that existed before the fix, so each one was run
// RED against the pre-fix code (red/green table in the commit message).
//
// Dimensions:
//   logic      the seam on a twin; one pin per date writer, each with a
//              control row of NON-archived content that IS written
//   writer     through catalog.sqlite: a twin's date written behind the
//              seam's back, inside a debounce window, during a write hold and
//              across a viewer flip, is refused at commit; the relaunch shows
//              the filed date on both copies
//   sensor     one twin through every background writer back to back: its
//              persisted date keys are byte-identical afterwards
//   media      Link Repaired Copy onto a real probed ProRes mov that is a twin
//   (scale, isolation and the index's own truth table: ArchivedContentIndexTests;
//    production shape: ProductionShapeArchivedTwinDateTests)

@MainActor
@Suite("GH #528 — every date writer refuses every copy of archived content", .serialized)
struct ArchivedTwinDateWritersTests {

    typealias F = DossierAdmissionFixtures

    static let digestA = String(repeating: "a1", count: 32)
    static let digestC = String(repeating: "c3", count: 32)

    static func fixity(_ digest: String, _ size: Int64) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 0), computedAt: Date())
    }

    /// Same whole-file digest (and, for the pre-#523 code, the same sample).
    static func identity(_ r: VideoRecord, _ digest: String, size: Int64 = 4_096) {
        r.sizeBytes = size
        r.partialMD5 = "md5-" + digest.prefix(8)
        r.contentFixity = fixity(digest, size)
    }

    /// The archived copy (Archived stage, outside any archive root), its
    /// unarchived twin, and a control: a cataloged row of OTHER content.
    struct Shape {
        let archived: VideoRecord
        let twin: VideoRecord
        let control: VideoRecord
    }

    static func shape(_ sb: F.Sandbox, _ tag: String) -> Shape {
        let archived = sb.record("test_\(tag)_archived.mov", stage: .archived, onDisk: false)
        let twin = sb.record("test_\(tag)_twin.mov", stage: .cataloged, onDisk: false)
        let control = sb.record("test_\(tag)_control.mov", stage: .cataloged, onDisk: false)
        identity(archived, digestA); identity(twin, digestA); identity(control, digestC)
        archived.userDate = "1984"; archived.userDateConfidence = UserDateConfidence.known.rawValue
        return Shape(archived: archived, twin: twin, control: control)
    }

    static let dateKeys = ArchivedDateReadOnlyTests.dateKeys

    static func dates(_ r: VideoRecord) throws -> [String: NSObject] {
        try F.persisted(r).filter { dateKeys.contains($0.key) }
    }

    // MARK: - The seam

    @Test("RED before #528: the seam calls a live twin of archived content read-only; a removed archived copy, other content, no digest do not")
    func seamIsTwinAware() throws {
        let sb = try F.Sandbox("t528_seam"); defer { sb.cleanup() }
        let s = Self.shape(sb, "seam")
        let unhashed = sb.record("test_seam_unhashed.mov", stage: .cataloged, onDisk: false)
        unhashed.sizeBytes = 4_096; unhashed.partialMD5 = s.twin.partialMD5
        sb.model.records = [s.archived, s.twin, s.control, unhashed]
        #expect(sb.model.isDateReadOnly(s.twin), "a copy of archived content: its date IS the archived copy's")
        #expect(!sb.model.isDateReadOnly(s.control), "other content is editable")
        #expect(!sb.model.isDateReadOnly(unhashed), "no whole-file digest: never a twin (a sample is not identity)")
        // In place, no array change: the archived copy goes to the Trash …
        s.archived.removal = .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash)
        #expect(!sb.model.isDateReadOnly(s.twin), "a copy that is gone fixes nothing")
        s.archived.removal = nil
        #expect(sb.model.isDateReadOnly(s.twin))
        // … and the control's content gains an archived copy by a stage flip.
        let controlTwin = sb.record("test_seam_control_twin.mov", stage: .cataloged, onDisk: false)
        Self.identity(controlTwin, Self.digestC)
        sb.model.records.append(controlTwin)
        #expect(!sb.model.isDateReadOnly(s.control))
        controlTwin.lifecycleStage = .archived
        #expect(sb.model.isDateReadOnly(s.control), "an in-place stage flip is seen at once")
    }

    // MARK: - One pin per writer

    @Test("RED before #528: the catch-up pass (rule 1, own evidence) never dates a twin; the control is dated")
    func catchUpRuleOne() throws {
        let sb = try F.Sandbox("t528_rule1"); defer { sb.cleanup() }
        let s = Self.shape(sb, "rule1")
        for r in [s.twin, s.control] { r.ocrDateCandidates = [F.ocr1991] }
        sb.model.records = [s.archived, s.twin, s.control]
        let before = try Self.dates(s.twin)
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(try Self.dates(s.twin) == before, "the twin's dates are the archived copy's")
        #expect(s.control.inferredRecordDate != nil, "control: own evidence dates other content")
    }

    @Test("RED before #528: rule 2 never propagates onto a twin, even from the archived copy; the control twin pair shares")
    func catchUpRuleTwo() throws {
        let sb = try F.Sandbox("t528_rule2"); defer { sb.cleanup() }
        let s = Self.shape(sb, "rule2")
        s.archived.inferredRecordDate = F.utc(1991); s.archived.inferredDateConfidence = 0.95
        let controlDonor = sb.record("test_rule2_control_donor.mov", stage: .cataloged, onDisk: false)
        Self.identity(controlDonor, Self.digestC)
        controlDonor.inferredRecordDate = F.utc(1991); controlDonor.inferredDateConfidence = 0.95
        sb.model.records = [s.archived, s.twin, s.control, controlDonor]
        let before = try Self.dates(s.twin)
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(try Self.dates(s.twin) == before)
        #expect(s.control.inferredRecordDate == F.utc(1991), "control: same-digest, unarchived copies share")
    }

    @Test("RED before #528: the #1413 unwind never clears a twin's date, and its undo never restores onto one")
    func unwindAndReapply() throws {
        let sb = try F.Sandbox("t528_unwind"); defer { sb.cleanup() }
        let s = Self.shape(sb, "unwind")
        for r in [s.twin, s.control] { ArchivedDateReadOnlyTests.orphanPropagated(r) }
        sb.model.records = [s.archived, s.twin, s.control]
        let before = try Self.dates(s.twin)
        let r = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                        trigger: "test")
        #expect(r.unwound == 1 && s.control.inferredRecordDate == nil, "control: an orphaned propagated date is cleared")
        #expect(try Self.dates(s.twin) == before)
        // The undo, onto an emptied twin and the control.
        VideoScanModel.clearInferredDate(s.twin, reason: nil)
        let emptied = try Self.dates(s.twin)
        let entries = [s.twin, s.control].map {
            VideoScanModel.UnwoundDateEntry(recordID: $0.id, fullPath: $0.fullPath, inferredRecordDate: F.utc(1985),
                                            inferredDateConfidence: 0.85, inferredDateSource: "propagated from x")
        }
        let restored = VideoScanModel.reapplyUnwoundDates(entries, to: sb.model.records, isDateReadOnly: sb.model.isDateReadOnly)
        #expect(restored.map(\.id) == [s.control.id])
        #expect(try Self.dates(s.twin) == emptied)
    }

    @Test("RED before #528: the duplicate-delete enrichment fold never gives a twin a machine date")
    func duplicateEnrichment() throws {
        let sb = try F.Sandbox("t528_enrich"); defer { sb.cleanup() }
        let s = Self.shape(sb, "enrich")
        let extra = sb.record("test_enrich_extra.mov", stage: .cataloged, onDisk: false)
        extra.inferredRecordDate = F.utc(1991); extra.inferredDateConfidence = 0.8
        sb.model.records = [s.archived, s.twin, s.control, extra]
        let before = try Self.dates(s.twin)
        _ = sb.model.applyEnrichmentInheritance(from: extra, to: s.twin)
        _ = sb.model.applyEnrichmentInheritance(from: extra, to: s.control)
        #expect(try Self.dates(s.twin) == before)
        #expect(s.control.inferredRecordDate == F.utc(1991))
    }

    @Test("RED before #528: the human-mark carry (repair confirm, keeper fold, prune fold) never writes Rick's date onto a twin; the place rides")
    func humanMarkCarry() throws {
        let sb = try F.Sandbox("t528_human"); defer { sb.cleanup() }
        let s = Self.shape(sb, "human")
        let extra = sb.record("test_human_extra.mov", stage: .cataloged, onDisk: false)
        extra.userDate = "1992"; extra.userDateConfidence = "known"; extra.userPlace = "Cape Cod"
        sb.model.records = [s.archived, s.twin, s.control, extra]
        let before = try Self.dates(s.twin)
        let carried = sb.model.applyHumanMetadataInheritance(from: extra, to: s.twin)
        _ = sb.model.applyHumanMetadataInheritance(from: extra, to: s.control)
        #expect(try Self.dates(s.twin) == before, "\(carried)")
        #expect(!carried.contains("date") && carried.contains("place"), "\(carried)")
        #expect(s.control.userDate == "1992")
    }

    @Test("RED before #528: the Archive Angel's promote stamp never dates a twin; the control is stamped")
    func angelStamp() throws {
        let sb = try F.Sandbox("t528_angel"); defer { sb.cleanup() }
        let s = Self.shape(sb, "angel")
        let sibling = sb.record("test_angel_sibling.mov", stage: .cataloged, onDisk: false)
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        sb.model.records = [s.archived, s.twin, s.control, sibling]
        func stamp(_ original: VideoRecord) -> ArchiveAngelFamilyFacts.StampResult {
            let e = ArchiveAngelPlan.Entry(id: original.id, sourcePath: original.fullPath, filename: original.filename,
                                           sizeBytes: 1, durationSeconds: 60, score: 1, evidence: [],
                                           proposedName: original.filename, proposedDate: nil)
            return ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [], family: [original, sibling],
                                                 isDateReadOnly: { sb.model.isDateReadOnly($0) })
        }
        let before = try Self.dates(s.twin)
        let r = stamp(s.twin)
        _ = stamp(s.control)
        #expect(try Self.dates(s.twin) == before)
        #expect(!r.facts.contains { $0.field == .date })
        #expect(s.control.userDate == "1987-06")
    }

    @Test("RED before #528: applyDossier writes the twin's dossier channels but never its triangulated date")
    func dossierWriteback() throws {
        let sb = try F.Sandbox("t528_dossier"); defer { sb.cleanup() }
        let s = Self.shape(sb, "dossier")
        sb.model.records = [s.archived, s.twin, s.control]
        let before = try Self.dates(s.twin)
        for r in [s.twin, s.control] {
            sb.model.applyDossier(DossierExtraction(scenes: [SceneCaption(timestamp: 1, text: "Christmas 1991")],
                                                    dates: [F.ocr1991], texts: []),
                                  to: r.fullPath, vlmModel: "stub-528", transcript: "it is 1991", whisperModel: "w")
        }
        #expect(!s.twin.sceneCaptions.isEmpty, "the channels land (metadata notes)")
        #expect(try Self.dates(s.twin) == before)
        #expect(s.control.inferredRecordDate != nil)
    }

    @Test("RED before #528: the Inspector's save / clear on a twin is refused even when the caller's own check said 'not archived'")
    func inspectorEditBelt() throws {
        let sb = try F.Sandbox("t528_inspector"); defer { sb.cleanup() }
        let s = Self.shape(sb, "inspector")
        s.twin.userDate = "1984"; s.twin.userDateConfidence = UserDateConfidence.known.rawValue
        sb.model.records = [s.archived, s.twin, s.control]
        let edits = CuratedRecordEdits(model: sb.model)
        #expect(edits.saveUserDate(entry: "1992", known: true, on: s.twin, archived: false) == .refusedArchived)
        #expect(edits.clearUserDate(on: s.twin, archived: false) == .refusedArchived)
        #expect(s.twin.userDate == "1984")
        #expect(edits.saveUserDate(entry: "1992", known: true, on: s.control, archived: false) == .saved("1992"))
    }

    /// MEDIA: Link Repaired Copy onto a path the catalog already holds as an
    /// unarchived twin of archived content (a real ProRes mov, probed).
    @Test("RED before #528 (MEDIA): Link Repaired Copy onto a twin links provenance but leaves the date as filed",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func linkRepairedCopyOntoATwin() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("t528_adopt_twin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(into: dir, name: "test_recovered_twin.mov",
                                                     videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
                                                     audioCodec: "pcm_s16le")
        let size = try #require((try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value)
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "test_damaged.mov"; original.fullPath = "/Volumes/TestT528/test_damaged.mov"
        original.streamTypeRaw = StreamType.videoAndAudio.rawValue
        original.userDate = "1994-11"; original.userDateConfidence = "estimated"
        let existing = VideoRecord()
        existing.filename = "test_recovered_twin.mov"; existing.fullPath = path
        existing.directory = dir.path; existing.lifecycleStage = .cataloged
        Self.identity(existing, Self.digestA, size: size)
        let archived = VideoRecord()
        archived.filename = "test_recovered_archived.mov"; archived.fullPath = "/Volumes/TestT528/test_recovered_archived.mov"
        archived.lifecycleStage = .archived
        Self.identity(archived, Self.digestA, size: size)
        model.records = [original, existing, archived]
        let adopted = try await model.adoptExternalRepair(originalID: original.id, fileURL: URL(fileURLWithPath: path))
        #expect(adopted === existing)
        #expect(adopted.derivedFrom == original.id, "provenance is still linked")
        #expect(adopted.userDate == nil && adopted.userDateConfidence == nil, "the twin's date is the archived copy's")
    }

    // MARK: - SENSOR: one twin, every background writer

    @Test("RED before #528 (SENSOR): a twin of archived content keeps its persisted dates through every background writer")
    func everyBackgroundWriterLeavesATwinsDates() throws {
        let sb = try F.Sandbox("t528_sensor"); defer { sb.cleanup() }
        let s = Self.shape(sb, "sensor")
        s.twin.fullPath = "/Volumes/TestSensor528/1991/test_sensor_twin.mov"
        ArchivedDateReadOnlyTests.orphanPropagated(s.twin)
        let other = sb.record("test_sensor_other.mov", stage: .cataloged, onDisk: false)
        other.userDate = "1990"; other.userDateConfidence = "known"
        other.inferredRecordDate = F.utc(1990); other.inferredDateConfidence = 0.95
        sb.model.records = [s.archived, s.twin, other]
        let before = try Self.dates(s.twin)

        sb.model.applyDossier(DossierExtraction(scenes: [SceneCaption(timestamp: 1, text: "Christmas 1991")],
                                                dates: [], texts: []),
                              to: s.twin.fullPath, vlmModel: "stub-sensor", transcript: "it is 1991", whisperModel: "w")
        _ = sb.model.applyEnrichmentInheritance(from: other, to: s.twin)
        _ = sb.model.applyHumanMetadataInheritance(from: other, to: s.twin)
        sb.model.catchUpInferredDates(trigger: "sensor")
        let unwind = sb.model.unwindUnverifiedPropagatedDates(sidecarDirectory: sb.dir.appendingPathComponent("sidecars"),
                                                             trigger: "sensor")
        if let sidecar = unwind.sidecar { _ = try sb.model.reapplyUnwoundDates(from: sidecar) }

        let changed = F.changedKeys(before, try Self.dates(s.twin))
        #expect(changed.isEmpty, "a twin's dates were written by: \(changed.sorted())")
    }

    // MARK: - WRITER: the commit refuses (defence in depth), then relaunch

    private func relaunch(_ scene: CutoverScene) async throws -> VideoScanModel {
        if let committer = scene.model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    /// Original + archived copy of one content, both filed 1984, stored.
    private func storedTwins(_ scene: CutoverScene) throws -> (original: VideoRecord, copy: VideoRecord) {
        let original = try scene.record(.curatedConflictA)
        let copy = try scene.record(.curatedConflictB)
        try #require(CatalogCommit.digest(of: original) != nil && CatalogCommit.digest(of: original) == CatalogCommit.digest(of: copy),
                     "the fixture's two rows are copies of one content")
        original.userDate = "1984"
        original.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(scene.model.saveCatalogNow())
        copy.lifecycleStage = .archived
        #expect(scene.model.saveCatalogNow())
        return (original, copy)
    }

    @Test("RED before #528 (WRITER): a date written on the twin behind the seam's back — in a debounce window, during a hold, across a viewer flip — is refused at commit; the relaunch shows 1984 on both")
    func commitRefusesATwinsDate() async throws {
        let scene = try CutoverScene.make("t528_writer"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let (original, copy) = try storedTwins(scene)
        let model = scene.model

        // Inside the debounce window of another edit on the same record.
        original.userNotes = "typed just before the date"
        model.saveCatalogDebounced()
        original.userDate = "1992"                    // any writer that judged only its own target
        #expect(model.saveCatalogNow(), "the notes edit still commits")
        #expect(original.userDate == "1984", "the twin's date is put back to the filed date")
        #expect(copy.userDate == "1984")

        // During a job's write hold: written while held, committed after.
        #expect(await model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        original.userDate = "1993"; original.userDateConfidence = UserDateConfidence.estimated.rawValue
        model.catalogStore.releaseWriteHold()
        #expect(model.saveCatalogNow())
        #expect(original.userDate == "1984" && original.userDateConfidence == UserDateConfidence.known.rawValue)

        // Across a viewer / master flip.
        model.updateReadOnlyFacts { $0.viewerRole = true }
        original.userDate = nil
        model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(model.saveCatalogNow())
        #expect(original.userDate == "1984", "a clear is a date write too")

        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Catalog store: REFUSED date on \(original.id.uuidString)"), "\(log.suffix(800))")
        #expect(log.contains("has an archived copy \(copy.id.uuidString); date left as filed (1984)"))

        let fresh = try await relaunch(scene)
        let backCopy = try #require(fresh.records.first { $0.id == copy.id })
        let backOriginal = try #require(fresh.records.first { $0.id == original.id })
        #expect(backCopy.userDate == "1984" && backCopy.userDateConfidence == UserDateConfidence.known.rawValue,
                "the archived copy shows the date it was filed under after relaunch")
        #expect(backOriginal.userDate == "1984")
        #expect(backOriginal.userNotes == "typed just before the date")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    /// The five inferred-date fields (one `inferred_dates` row per digest).
    private struct Inferred: Equatable {
        let date: Date?, confidence: Float?, source: String?, range: InferredDateRange?, reason: String?
        init(_ r: VideoRecord) {
            date = r.inferredRecordDate; confidence = r.inferredDateConfidence; source = r.inferredDateSource
            range = r.inferredDateRange; reason = r.inferredDateReason
        }
        func put(on r: VideoRecord) {
            r.inferredRecordDate = date; r.inferredDateConfidence = confidence; r.inferredDateSource = source
            r.inferredDateRange = range; r.inferredDateReason = reason
        }
        init(date: Date?, confidence: Float?, source: String?, range: InferredDateRange?, reason: String?) {
            self.date = date; self.confidence = confidence; self.source = source; self.range = range; self.reason = reason
        }
    }

    /// Codex round 2 (#528 P1): identity arrives AFTER inference. A row
    /// with no whole-file digest is no twin, so every inference writer may
    /// date it (legitimately, by the seam); when it later acquires the
    /// archived content's digest, its first commit replaced that content's
    /// `inferred_dates` row (CatalogCommitBody.writeDerived) — the archived
    /// copy showed the newcomer's guess after relaunch.
    @Test("RED before #528 round 2 (WRITER): an unhashed newcomer inferred 1992, then hashed to archived content's digest — the commit keeps the archived copy's five inferred fields; relaunch shows them on both")
    func commitRefusesATwinsInferredDate() async throws {
        let scene = try CutoverScene.make("t528_inferred"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        try #require(scene.model.catalogCutover.isSQLiteAuthority)
        let model = scene.model
        let original = try scene.record(.curatedConflictA)
        let copy = try scene.record(.curatedConflictB)
        let filed = Inferred(date: F.utc(1984), confidence: 0.95, source: "catch-up",
                             range: InferredDateRange(year: 1984), reason: "spoken now-cue 'it is 1984'")
        filed.put(on: original); filed.put(on: copy)        // one content, one inferred date (as a load gives)
        #expect(model.saveCatalogNow())
        copy.lifecycleStage = .archived
        #expect(model.saveCatalogNow())
        try #require(Inferred(copy) == filed, "the fixture's archived copy holds the content's inferred date")

        // A newcomer: not hashed yet (pending row), so not a twin of anything.
        let newcomer = try scene.freshCopy(of: .curatedConflictA, path: "/Volumes/Fixture/New/1992/tape.mov")
        Inferred(date: nil, confidence: nil, source: nil, range: nil, reason: nil).put(on: newcomer)
        model.records.append(newcomer)
        #expect(model.saveCatalogNow())
        #expect(!model.isDateReadOnly(newcomer), "no whole-file digest: no twin, its dates are its own")
        let guess = Inferred(date: F.utc(1992), confidence: 0.30, source: "folder-year",
                             range: InferredDateRange(year: 1992), reason: "folder /1992/")
        guess.put(on: newcomer)                               // the folder-year lane, legitimately
        #expect(model.saveCatalogNow())

        // Its hash lands: it IS the archived content.
        newcomer.sizeBytes = copy.sizeBytes
        newcomer.contentFixity = copy.contentFixity ?? original.contentFixity
        try #require(CatalogCommit.digest(of: newcomer) == CatalogCommit.digest(of: copy))
        #expect(model.saveCatalogNow())
        #expect(Inferred(copy) == filed, "in memory: the archived copy keeps its inferred date")
        #expect(Inferred(newcomer) == filed, "the newcomer is put to the content's filed inferred date")

        let fresh = try await relaunch(scene)
        let backCopy = try #require(fresh.records.first { $0.id == copy.id })
        let backNew = try #require(fresh.records.first { $0.id == newcomer.id })
        #expect(Inferred(backCopy) == filed, "relaunch: the archived copy keeps all five inferred fields")
        #expect(Inferred(backNew) == filed)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }
}
