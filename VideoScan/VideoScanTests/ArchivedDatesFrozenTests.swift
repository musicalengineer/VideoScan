import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - ArchivedDatesFrozenTests (Rick 2026-09-27)
//
// "Once a file is in the archive… only I will update name/date, though the
// system may add metadata notes… archived elements mostly read-only."
//
// A Master Archive file (`VideoScanModel.isArchiveElement`: a promoted copy,
// or anything inside the archive root) is never WRITTEN by a background
// date writer. It may still DONATE its date to other copies.
//
// Five dimensions (docs/testing_retrospective_2026_07_05.md):
//   logic      every writer, both ways (control changes / archived frozen)
//   scale      100k archive files through the whole-catalog pass, 0 written
//   isolation  scratch CatalogStore + log dir; a fake archive root that is
//              never touched on disk; the real App Support is never written
//   sensors    backgroundWriterSkipsAnArchivedRecord (one row per writer —
//              a NEW background writer belongs in `Writer`),
//              dateColumnShowsTheFiledDateOverAStrongerInference
//   media      n/a — no media file is opened; the writers read stored fields
//
// (For Rick: `enum Writer: CaseIterable` + `@Test(arguments:)` ≈ a
// table-driven test in C++ — one test body run once per enum case, each
// case reported separately.)

@MainActor
@Suite("ArchivedDatesFrozen — background date writers skip Master Archive files")
struct ArchivedDatesFrozenTests {

    // MARK: - Fixtures

    static let archiveTarget = "/Volumes/TestFamilyArchiveFrozen"
    static let archiveRoot = archiveTarget + "/Breen_Family_Archive"
    static let ocr1991 = SceneCaption(timestamp: 12, text: "JUN.21 1991 PM11:29")

    static func utc(_ y: Int, _ m: Int = 1, _ d: Int = 1) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc)!   // swiftlint:disable:this force_unwrapping
    }

    /// Every field a background writer could move. Equatable snapshot.
    struct DateFields: Equatable, CustomStringConvertible {
        var userDate: String?
        var userDateConfidence: String?
        var inferredRecordDate: Date?
        var inferredDateConfidence: Float?
        var inferredDateSource: String?
        var inferredDateRange: InferredDateRange?
        var inferredDateReason: String?
        init(_ r: VideoRecord) {
            userDate = r.userDate; userDateConfidence = r.userDateConfidence
            inferredRecordDate = r.inferredRecordDate; inferredDateConfidence = r.inferredDateConfidence
            inferredDateSource = r.inferredDateSource; inferredDateRange = r.inferredDateRange
            inferredDateReason = r.inferredDateReason
        }
        var description: String {
            "user=\(userDate ?? "nil") inferred=\(inferredRecordDate.map { "\($0)" } ?? "nil") "
                + "conf=\(inferredDateConfidence.map { "\($0)" } ?? "nil") src=\(inferredDateSource ?? "nil") "
                + "reason=\(inferredDateReason ?? "nil")"
        }
    }

    @MainActor
    final class Sandbox {
        let dir: URL
        let model: VideoScanModel
        init(_ label: String) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_ArchivedDatesFrozen-\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model = VideoScanModel(logDirectory: dir)
            model.catalogStore = CatalogStore(directory: dir)
            model.masterArchive = MasterArchiveDesignation(targetPath: ArchivedDatesFrozenTests.archiveTarget,
                                                           rootPath: ArchivedDatesFrozenTests.archiveRoot)
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    /// A plain record at `dir/name`.
    static func record(_ dir: String, _ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = dir + "/" + name
        r.filename = name
        r.directory = dir
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        return r
    }

    /// The record under test. `archived`: a promoted copy filed in
    /// `<root>/30_Video/1990-1999/1994/` (its path is inside the archive
    /// root AND it carries the promotion kind). Otherwise an ordinary
    /// source at `controlDir` — the control that proves the poison works.
    static func target(archived: Bool, controlDir: String = "/Volumes/Src/tapes") -> VideoRecord {
        if archived {
            let r = record(archiveRoot + "/30_Video/1990-1999/1994", "1994-xx-xx_clip.mov")
            r.derivationKind = ArchivePromotion.derivationKind
            r.derivedFrom = UUID()   // the source left the catalog; irrelevant here
            return r
        }
        return record(controlDir, "clip.mov")
    }

    static func footage(_ group: UUID, rank: Int, of r: VideoRecord) -> FootageMembership {
        FootageMembership(groupID: group, groupSize: 2, confidence: .likely,
                          role: rank == 0 ? .original : .copy, rank: rank,
                          likelyOriginalID: r.id, originalInCatalog: true,
                          evidence: ["same name + length"], scannedAt: Date(), algorithmVersion: 1)
    }

    // MARK: - The writer inventory (SENSOR — add every new background writer here)

    enum Writer: String, CaseIterable, CustomTestStringConvertible {
        /// catchUpInferredDates rule 0 — legacy filesystem-tier date cleared.
        case rule0LegacyFilesystemClear
        /// rule 0 — a footage-shared date whose donor is gone, cleared.
        case rule0StaleFootageShareClear
        /// rule 1 — an old own-pass date re-triangulated from its evidence.
        case rule1Retriangulate
        /// rule 1 — evidence but no date: caught up.
        case rule1CatchUp
        /// rule 2 — a verified same-bytes sibling's date propagated.
        case rule2Propagation
        /// rule 2b — the footage group's strongest claim shared.
        case rule2bFootageShare
        /// rule 3 — the bare-year folder placeholder.
        case rule3FolderYear
        /// applyDossier's own triangulation.
        case applyDossier
        /// LiveReload.mergeDossierFields — an external merger's date.
        case liveReloadMerge
        /// DuplicateEnrichment — the removed twin's inferred date.
        case duplicateEnrichment
        /// codex #1413 unwind of an unverified propagated date.
        case unwindUnverifiedPropagated

        var testDescription: String { rawValue }
    }

    /// Build the scenario, run the writer, return (before, after, record).
    static func run(_ w: Writer, archived: Bool) throws -> (before: DateFields, after: DateFields, rec: VideoRecord) {
        let sb = try Sandbox("\(w.rawValue)-\(archived)")
        let m = sb.model
        var t = target(archived: archived)
        var others: [VideoRecord] = []
        var action: () -> Void = { _ = m.catchUpInferredDates(trigger: "test") }

        switch w {
        case .rule0LegacyFilesystemClear:
            t.inferredRecordDate = utc(1994); t.inferredDateConfidence = 0.30
        case .rule0StaleFootageShareClear:
            t.footage = footage(UUID(), rank: 1, of: t)
            t.inferredRecordDate = utc(1990); t.inferredDateConfidence = 0.8
            t.inferredDateSource = VideoScanModel.InferredDateSource.footageSharedPrefix + UUID().uuidString
            t.inferredDateReason = "shared from gone.mov (same footage): 1990"
        case .rule1Retriangulate:
            t.ocrDateCandidates = [ocr1991]
            t.inferredRecordDate = utc(1985); t.inferredDateConfidence = 0.6   // legacy: no reason
        case .rule1CatchUp:
            t.ocrDateCandidates = [ocr1991]
        case .rule2Propagation:
            t.partialMD5 = "aa11"; t.sizeBytes = 4_242
            let donor = record("/Volumes/Donor/tapes", "clip.mov")
            donor.partialMD5 = "aa11"; donor.sizeBytes = 4_242
            donor.inferredRecordDate = utc(1991, 6, 21); donor.inferredDateConfidence = 0.75
            donor.inferredDateReason = "on-screen date 1991-06-21"
            others = [donor]
        case .rule2bFootageShare:
            let g = UUID()
            let donor = record("/Volumes/Donor/tapes", "clip.mov")
            donor.userDate = "1992"; donor.userDateConfidence = UserDateConfidence.known.rawValue
            donor.footage = footage(g, rank: 0, of: donor)
            t.footage = footage(g, rank: 1, of: donor)
            others = [donor]
        case .rule3FolderYear:
            if !archived { t = target(archived: false, controlDir: "/Volumes/Src/1994") }
        case .applyDossier:
            t.inferredRecordDate = utc(1985); t.inferredDateConfidence = 0.9
            t.inferredDateReason = "filed as 1985"
            let path = t.fullPath
            action = {
                let x = DossierExtraction(scenes: [SceneCaption(timestamp: 0, text: "a birthday cake")],
                                          dates: [ocr1991], texts: [])
                _ = m.applyDossier(x, to: path, vlmModel: "vlm", transcript: nil, whisperModel: nil)
            }
        case .liveReloadMerge:
            t.inferredRecordDate = utc(1985); t.inferredDateConfidence = 0.9
            t.inferredDateReason = "filed as 1985"
            t.dossierProcessedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let fresh = record(t.directory, t.filename)   // matched by path
            fresh.ocrDateCandidates = [ocr1991]
            fresh.inferredRecordDate = utc(1991, 6, 21); fresh.inferredDateConfidence = 0.95
            fresh.inferredDateReason = "on-screen date 1991-06-21 ×3"
            fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_800_000_000)
            action = { _ = m.mergeDossierFields(from: [fresh]) }
        case .duplicateEnrichment:
            let extra = record("/Volumes/Extra/tapes", "clip.mov")
            extra.inferredRecordDate = utc(1991, 6, 21); extra.inferredDateConfidence = 0.8
            extra.inferredDateReason = "on-screen date 1991-06-21"
            let master = t
            action = { _ = m.applyEnrichmentInheritance(from: extra, to: master) }
        case .unwindUnverifiedPropagated:
            t.inferredRecordDate = utc(1990); t.inferredDateConfidence = 0.7
            t.inferredDateSource = VideoScanModel.InferredDateSource.propagatedPrefix + UUID().uuidString
            t.inferredDateReason = "same bytes as gone.mov"
            let dir = sb.dir
            action = { _ = m.unwindUnverifiedPropagatedDates(sidecarDirectory: dir, trigger: "test") }
        }
        m.records = [t] + others
        #expect(m.isArchiveElement(t) == archived, "fixture: archived=\(archived) for \(t.fullPath)")
        let before = DateFields(t)
        action()
        return (before, DateFields(t), t)
    }

    // MARK: - SENSOR: every background writer skips an archived record

    /// Poisoned state: each archived fixture holds exactly the state its
    /// writer would change. The CONTROL (same state, ordinary source path)
    /// must change — proving the poison is live — and the archived copy
    /// must not move one field.
    @Test("background writer skips an archived record", arguments: Writer.allCases)
    func backgroundWriterSkipsAnArchivedRecord(_ w: Writer) throws {
        let control = try Self.run(w, archived: false)
        #expect(control.before != control.after,
                "control: \(w.rawValue) must change an ordinary record, or this row proves nothing — \(control.after)")

        let frozen = try Self.run(w, archived: true)
        #expect(frozen.before == frozen.after,
                "\(w.rawValue) wrote to an archived record: before \(frozen.before) after \(frozen.after)")
    }

    /// The channels are metadata notes (Rick: "the system may add metadata
    /// notes"): they still land on an archived file; only the date is frozen.
    @Test("dossier channels still land on an archived record", arguments: [Writer.applyDossier, .liveReloadMerge])
    func channelsStillLandOnAnArchivedRecord(_ w: Writer) throws {
        let frozen = try Self.run(w, archived: true)
        #expect(frozen.rec.ocrDateCandidates == [Self.ocr1991])
        #expect(frozen.before == frozen.after)
    }

    // MARK: - Donor, never recipient

    /// Rule 2b: an archived file DONATES its filed date to its footage group.
    @Test func footageShareDonatesFromAnArchivedRecord() throws {
        let sb = try Sandbox("donor-2b")
        let g = UUID()
        let a = Self.target(archived: true)
        a.inferredRecordDate = Self.utc(1991, 6, 21); a.inferredDateConfidence = 0.9
        a.inferredDateReason = "on-screen date 1991-06-21"
        a.footage = Self.footage(g, rank: 0, of: a)
        let b = Self.record("/Volumes/Src/tapes", "clip.mov")
        b.footage = Self.footage(g, rank: 1, of: a)
        sb.model.records = [a, b]
        let aBefore = DateFields(a)
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: a),
                "\(b.inferredDateSource ?? "nil")")
        #expect(b.inferredRecordDate == a.inferredRecordDate)
        #expect(DateFields(a) == aBefore)
    }

    /// An archived file's date is frozen, so even a date it once received
    /// as a footage share is its FILED date and donates (a live row's
    /// derived share never does — it is re-derived every pass).
    @Test func archivedFootageSharedDateStillDonates() throws {
        let sb = try Sandbox("donor-2b-derived")
        let g = UUID()
        let a = Self.target(archived: true)
        a.inferredRecordDate = Self.utc(1991, 6, 21); a.inferredDateConfidence = 0.8
        a.inferredDateSource = VideoScanModel.InferredDateSource.footageSharedPrefix + UUID().uuidString
        a.inferredDateReason = "shared from gone.mov (same footage): on-screen date 1991-06-21"
        a.footage = Self.footage(g, rank: 0, of: a)
        let b = Self.record("/Volumes/Src/tapes", "clip.mov")
        b.footage = Self.footage(g, rank: 1, of: a)
        sb.model.records = [a, b]
        let aBefore = DateFields(a)
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(DateFields(a) == aBefore, "rule 0 must not clear the archived share (its donor is gone)")
        #expect(b.inferredRecordDate == a.inferredRecordDate, "\(DateFields(b))")
        #expect(b.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: a))
        // Second pass: the share B holds is not stale (A still donates it).
        sb.model.catchUpInferredDates(trigger: "test")
        #expect(b.inferredDateSource == VideoScanModel.InferredDateSource.footageShared(from: a))
    }

    /// Rule 2: an archived file with its own date donates to a same-bytes twin.
    @Test func propagationDonatesFromAnArchivedRecord() throws {
        let sb = try Sandbox("donor-2")
        let a = Self.target(archived: true)
        a.partialMD5 = "bb22"; a.sizeBytes = 9_999
        a.inferredRecordDate = Self.utc(1991, 6, 21); a.inferredDateConfidence = 0.75
        a.inferredDateReason = "on-screen date 1991-06-21"
        let b = Self.record("/Volumes/Src/tapes", "clip.mov")
        b.partialMD5 = "bb22"; b.sizeBytes = 9_999
        sb.model.records = [a, b]
        let aBefore = DateFields(a)
        let r = sb.model.catchUpInferredDates(trigger: "test")
        #expect(r.propagated == 1)
        #expect(b.inferredDateSource == VideoScanModel.InferredDateSource.propagated(from: a))
        #expect(DateFields(a) == aBefore)
    }

    /// Rule 2b recipient side, through the static the pass calls: an
    /// archived member is never written even when a stronger claim exists.
    @Test func footageShareNeverWritesAnArchivedRecipient() throws {
        let g = UUID()
        let donor = Self.record("/Volumes/Src/tapes", "clip.mov")
        donor.userDate = "1992"; donor.userDateConfidence = UserDateConfidence.known.rawValue
        donor.footage = Self.footage(g, rank: 0, of: donor)
        let a = Self.target(archived: true)
        a.inferredRecordDate = Self.utc(1985); a.inferredDateConfidence = 0.7
        a.inferredDateReason = "filed as 1985"
        a.footage = Self.footage(g, rank: 1, of: donor)
        let before = DateFields(a)
        let written = VideoScanModel.shareDateAcrossFootageGroup([donor, a], now: Date(), archived: [a.id])
        #expect(written.isEmpty)
        #expect(DateFields(a) == before)
        // Control: without the archived id the same call writes it.
        #expect(VideoScanModel.shareDateAcrossFootageGroup([donor, a], now: Date()).map(\.id) == [a.id])
    }

    // MARK: - The predicate

    @Test func archiveElementPredicate() throws {
        let sb = try Sandbox("predicate")
        let m = sb.model
        let source = Self.record("/Volumes/Src/tapes", "clip.mov")
        // A promoted copy whose path is OUTSIDE the root (a rename, an old
        // designation): still an archive file by its kind.
        let copyOutside = Self.record("/Volumes/Elsewhere", "1991-06-21_clip.mov")
        copyOutside.derivationKind = ArchivePromotion.derivationKind
        copyOutside.derivedFrom = source.id
        // Inside the root with no promotion record (older tooling).
        let inside = Self.record(Self.archiveRoot + "/30_Video/Undated", "legacy.vs.archive.mov")
        let unrelated = Self.record("/Volumes/Src/other", "x.mov")
        m.records = [source, copyOutside, inside, unrelated]
        #expect(m.isArchiveElement(copyOutside))
        #expect(m.isArchiveElement(inside))
        #expect(!m.isArchiveElement(unrelated))
        // The SOURCE of a promotion is "archived" for the to-do view but is
        // NOT an archive file: it keeps the ordinary date rules.
        #expect(m.isArchived(source))
        #expect(!m.isArchiveElement(source))
        // No designation → only the promotion kind counts.
        m.masterArchive = nil
        #expect(!m.isArchiveElement(inside))
        #expect(m.isArchiveElement(copyOutside))
    }

    // MARK: - SENSOR: the Date column shows the filed date

    @Test func dateColumnShowsTheFiledDateOverAStrongerInference() {
        let a = Self.record(Self.archiveRoot + "/30_Video/1940-1949/1947", "1947-03-xx_Wedding.mov")
        a.derivationKind = ArchivePromotion.derivationKind
        a.inferredRecordDate = Self.utc(1991, 6, 21); a.inferredDateConfidence = 0.95
        a.inferredDateReason = "on-screen date 1991-06-21 ×3"
        a.embeddedCreationDate = Self.utc(2026, 9, 1)
        #expect(a.archiveFiledDate == "1947-03")
        #expect(a.resolvedDateDisplay == "1947-03", "got \(a.resolvedDateDisplay)")
        #expect(a.resolvedDateSortKey == UserDateEntry.date(from: "1947-03"))
        #expect(a.resolvedDateHelp.contains("filed"))

        // Rick's own date (e.g. written by Archive Update) still comes first.
        a.userDate = "1948"; a.userDateConfidence = UserDateConfidence.known.rawValue
        #expect(a.resolvedDateDisplay == "1948")

        // The same name on a record that is NOT an archive copy: no filed
        // date; the column reads exactly as before.
        let plain = Self.record("/Volumes/Src/tapes", "1947-03-xx_Wedding.mov")
        plain.inferredRecordDate = Self.utc(1991, 6, 21); plain.inferredDateConfidence = 0.95
        #expect(plain.archiveFiledDate == nil)
        #expect(plain.resolvedDateDisplay == "1991-06-21", "got \(plain.resolvedDateDisplay)")
    }

    @Test("filed-date prefix grammar", arguments: [
        ("1992-07-15_Beach.mov", "1992-07-15"),
        ("1992-07-xx_Beach.mov", "1992-07"),
        ("1992-xx-xx_Beach.mov", "1992"),
        ("1992-07-15_Beach_02.mov", "1992-07-15"),
        ("xxxx-xx-xx_Beach.mov", nil),
        ("1992-13-xx_Beach.mov", nil),
        ("1992-02-30_Beach.mov", nil),
        ("1992-xx-15_Beach.mov", nil),
        ("1992-07-15-Beach.mov", nil),
        ("Beach.mov", nil),
        ("", nil),
    ] as [(String, String?)])
    func filedDatePrefixGrammar(_ name: String, _ expected: String?) {
        #expect(VideoRecord.filedDatePrefix(of: name) == expected)
    }

    // MARK: - Scale

    /// 100k archive files through the whole-catalog pass: every rule would
    /// write something (legacy dates, evidence, folder years, twins) and
    /// nothing is written. The predicate is O(1) per row.
    @Test("scale: 100k archived records, whole-catalog pass writes nothing", .timeLimit(.minutes(2)))
    func scale_100kArchivedRecordsNoWrites() throws {
        let sb = try Sandbox("scale")
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = Self.record(Self.archiveRoot + "/30_Video/1990-1999/1994", "1994-xx-xx_c\(i).mov")
            r.derivationKind = ArchivePromotion.derivationKind
            switch i % 4 {
            case 0: r.inferredRecordDate = Self.utc(1994); r.inferredDateConfidence = 0.30   // rule 0 bait
            case 1: r.ocrDateCandidates = [Self.ocr1991]                                        // rule 1 bait
            case 2: r.partialMD5 = "twin-\(i / 4)"; r.sizeBytes = 7                            // rule 2 bait
                    r.inferredRecordDate = Self.utc(1991, 6, 21); r.inferredDateConfidence = 0.8
                    r.inferredDateReason = "on-screen"
            default: r.partialMD5 = "twin-\(i / 4)"; r.sizeBytes = 7                           // recipient + rule 3 bait
            }
            recs.append(r)
        }
        sb.model.records = recs
        let clock = SuspendingClock()
        var result = VideoScanModel.InferredDateCatchUpResult()
        let elapsed = clock.measure { result = sb.model.catchUpInferredDates(trigger: "scale") }
        #expect(result.total == 0 && result.cleared == 0 && result.examined == 0, "\(result)")
        #expect(recs[3].inferredRecordDate == nil)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(3)), "pass took \(elapsed)")
    }
}
