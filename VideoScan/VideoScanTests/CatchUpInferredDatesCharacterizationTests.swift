import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - CatchUpInferredDatesCharacterizationTests (refactor R4, GH #281)
//
// `catchUpInferredDates` (CCN 51, 134 NLOC) WRITES inferred dates onto
// records, so before it was split these tests pinned what it does today:
// one synthetic catalog with a row for every branch of rules 0 – 3, run
// four ways (whole catalog; the same catalog a second time; a budget of 2;
// a scoped refresh pass). Each run's result, every row's five date fields,
// the "no date" memo and the log lines are snapshotted as text. The
// goldens below were captured from the UNSPLIT function (`ebcd2f09`) and
// were not edited after the move.
//
// Five dimensions: logic (every branch, below); scale / media / isolation
// are already covered by InferredDatePropagationTests and
// DateTriangulatorTests (100k budget, no media opened, scratch store +
// own log dir here too); this file is the sensor for the split itself.

@MainActor
struct CatchUpInferredDatesCharacterizationTests {

    // MARK: - Fixture

    static let nv12OCR = SceneCaption(timestamp: 192.99665, text: "JUN.21 1991 PM11:29")
    static let noDateOCR = SceneCaption(timestamp: 3, text: "HELLO WORLD")

    static let june21_1991: Date = {
        var dc = DateComponents()
        dc.year = 1991; dc.month = 6; dc.day = 21; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc)!  // swiftlint:disable:this force_unwrapping
    }()

    static let old1985 = Date(timeIntervalSince1970: 489_024_000)   // 1985-07-01 UTC

    @MainActor
    final class Sandbox {
        let dir: URL
        let model: VideoScanModel
        init(_ label: String) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_CatchUpCharacterization-\(label)-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model = VideoScanModel(logDirectory: dir)
            model.catalogStore = CatalogStore(directory: dir)
            model.dateInferencePeople = []
        }
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    private static func rec(_ name: String, dir: String = "/Volumes/Src/tapes",
                            md5: String = "", size: Int64 = 1_000,
                            ocr: [SceneCaption] = []) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.directory = dir
        r.fullPath = dir + "/" + name
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.partialMD5 = md5
        r.sizeBytes = size
        r.ocrDateCandidates = ocr
        return r
    }

    private static func footage(_ group: UUID, rank: Int, original: UUID,
                                confidence: FootageConfidence = .likely) -> FootageMembership {
        FootageMembership(groupID: group, groupSize: 2, confidence: confidence,
                          role: rank == 0 ? .original : .copy, rank: rank,
                          likelyOriginalID: original, originalInCatalog: true,
                          evidence: ["same name + length"], scannedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          algorithmVersion: 1)
    }

    /// One row per branch. Names say which branch; order is fixed.
    static func catalog() -> [VideoRecord] {
        var out: [VideoRecord] = []
        // Rule 1: undated, own evidence → catch-up.
        out.append(rec("r1_own_ocr.mov", ocr: [nv12OCR]))
        // Rule 1: legacy own-pass date (source nil, no reason) + evidence → re-triangulated, keeps source nil.
        let legacyOwn = rec("r1_legacy_own.mov", ocr: [nv12OCR])
        legacyOwn.inferredRecordDate = old1985; legacyOwn.inferredDateConfidence = 0.75
        out.append(legacyOwn)
        // Rule 1: legacy catch-up date (no reason) + evidence → re-triangulated as catch-up.
        let legacyCatch = rec("r1_legacy_catchup.mov", ocr: [nv12OCR])
        legacyCatch.inferredRecordDate = old1985; legacyCatch.inferredDateConfidence = 0.75
        legacyCatch.inferredDateSource = VideoScanModel.InferredDateSource.catchUp
        out.append(legacyCatch)
        // Rule 1: a folder-year placeholder that gained evidence → settles as catch-up.
        let placeholder = rec("r1_placeholder.mov", dir: "/Volumes/Src/1991", ocr: [nv12OCR])
        placeholder.inferredRecordDate = old1985; placeholder.inferredDateConfidence = 0.30
        placeholder.inferredDateSource = VideoScanModel.InferredDateSource.folderYear
        placeholder.inferredDateReason = "bare-year folder '1985' — a placeholder any real evidence replaces"
        out.append(placeholder)
        // Rule 1: evidence naming no date, never dated → memo + reason.
        out.append(rec("r1_no_date.mov", ocr: [noDateOCR]))
        // Rule 1: an old date that rests on nothing the rules accept → cleared with the reason.
        let hadDate = rec("r1_had_date_now_none.mov", ocr: [noDateOCR])
        hadDate.inferredRecordDate = old1985; hadDate.inferredDateConfidence = 0.60
        out.append(hadDate)
        // Rule 1: settled (own pass with a reason) → skipped.
        let settled = rec("r1_settled.mov", ocr: [nv12OCR])
        settled.inferredRecordDate = old1985; settled.inferredDateConfidence = 0.80
        settled.inferredDateReason = "settled earlier"
        out.append(settled)
        // Rick's own date → never written.
        let user = rec("user_dated.mov", dir: "/Volumes/Src/1977", ocr: [nv12OCR])
        user.userDate = "1977"
        out.append(user)
        // Purged → not eligible, never written.
        let purged = rec("purged.mov", dir: "/Volumes/Src/1978", ocr: [nv12OCR])
        purged.purgedAt = Date(timeIntervalSince1970: 1_790_000_000)
        out.append(purged)
        // Rule 0: legacy filesystem-tier date, no evidence → cleared; then rule 3 dates it from its folder.
        let fsLegacy = rec("r0_fs_legacy.mov", dir: "/Volumes/Src/1983")
        fsLegacy.inferredRecordDate = old1985; fsLegacy.inferredDateConfidence = 0.30
        out.append(fsLegacy)
        // Rule 0: footage-shared from a donor that no longer exists → cleared (stale).
        let stale = rec("r0_stale_share.mov")
        stale.inferredRecordDate = old1985; stale.inferredDateConfidence = 0.75
        stale.inferredDateSource = VideoScanModel.InferredDateSource.footageSharedPrefix
            + "00000000-0000-0000-0000-00000000D0D0"   // a donor that left the catalog
        stale.inferredDateReason = "shared from gone.mov (same footage); own evidence said 1984"
        out.append(stale)
        // Rule 2: a content group — a donor dated by rule 1 this pass, and a twin with no evidence.
        out.append(rec("r2_donor.mov", md5: "aaaa", size: 5_000, ocr: [nv12OCR]))
        out.append(rec("r2_recipient.mov", dir: "/Volumes/Other/1999", md5: "aaaa", size: 5_000))
        // Rule 2: a group with no donor (both undated, no evidence, no folder year) → nothing.
        out.append(rec("r2_nodonor_a.mov", md5: "bbbb", size: 6_000))
        out.append(rec("r2_nodonor_b.mov", md5: "bbbb", size: 6_000))
        // Archived: an archive copy is never written but still donates to its byte twin.
        let archived = rec("archived_copy.mov", md5: "cccc", size: 7_000, ocr: [nv12OCR])
        archived.derivationKind = ArchivePromotion.derivationKind
        archived.derivedFrom = UUID()
        out.append(archived)
        let archivedSettled = rec("archived_settled.mov", md5: "dddd", size: 8_000, ocr: [nv12OCR])
        archivedSettled.derivationKind = ArchivePromotion.derivationKind
        archivedSettled.derivedFrom = UUID()
        archivedSettled.inferredRecordDate = june21_1991; archivedSettled.inferredDateConfidence = 0.75
        archivedSettled.inferredDateReason = "archived own date"
        out.append(archivedSettled)
        out.append(rec("archived_twin.mov", md5: "dddd", size: 8_000))
        // Rule 2b: a likely footage group — donor with evidence, twin without.
        let fg = UUID()
        let fDonor = rec("r2b_donor.mov", ocr: [nv12OCR])
        let fTwin = rec("r2b_twin.mov", dir: "/Volumes/Other/2001")
        fDonor.footage = footage(fg, rank: 0, original: fDonor.id)
        fTwin.footage = footage(fg, rank: 1, original: fDonor.id)
        out.append(fDonor); out.append(fTwin)
        // Rule 2b: a merely 'possible' footage group → not bucketed, the twin gets its folder year.
        let pg = UUID()
        let pDonor = rec("r2b_possible_donor.mov", ocr: [nv12OCR])
        let pTwin = rec("r2b_possible_twin.mov", dir: "/Volumes/Other/2002")
        pDonor.footage = footage(pg, rank: 0, original: pDonor.id, confidence: .possible)
        pTwin.footage = footage(pg, rank: 1, original: pDonor.id, confidence: .possible)
        out.append(pDonor); out.append(pTwin)
        // Rule 3: nothing else spoke, bare-year folder → placeholder.
        out.append(rec("r3_folder_year.mov", dir: "/Volumes/Src/1987"))
        // Rule 3: an embedded stamp means rule 3 stays out.
        let stamped = rec("r3_embedded.mov", dir: "/Volumes/Src/1988")
        stamped.embeddedCreationDate = old1985
        out.append(stamped)
        return out
    }

    // MARK: - Snapshot

    private static func iso(_ d: Date?) -> String {
        guard let d else { return "nil" }
        return String(Int(d.timeIntervalSince1970))
    }

    /// UUIDs in a source / reason are replaced by the record's filename, so the
    /// snapshot is stable across runs.
    private static func named(_ s: String?, _ names: [String: String]) -> String {
        guard var s else { return "nil" }
        for (id, name) in names { s = s.replacingOccurrences(of: id, with: "<\(name)>") }
        return s
    }

    static func snapshot(_ result: VideoScanModel.InferredDateCatchUpResult, model: VideoScanModel,
                         records: [VideoRecord], logFrom: Int) -> String {
        var names: [String: String] = [:]
        for r in records { names[r.id.uuidString] = r.filename }
        var out: [String] = []
        out.append("result examined=\(result.examined) alreadyClassified=\(result.alreadyClassified) "
                   + "deferred=\(result.deferred) own=\(result.inferredFromEvidence) propagated=\(result.propagated) "
                   + "folderYear=\(result.folderYear) footageShared=\(result.footageShared) "
                   + "retriangulated=\(result.retriangulated) cleared=\(result.cleared) truncated=\(result.truncated)")
        for r in records {
            let conf = r.inferredDateConfidence.map { String(format: "%.3f", $0) } ?? "nil"
            let range = r.inferredDateRange.map { "\($0)" } ?? "nil"
            out.append("\(r.filename): date=\(iso(r.inferredRecordDate)) conf=\(conf) range=\(range) "
                       + "src=\(named(r.inferredDateSource, names)) reason=\(named(r.inferredDateReason, names))")
        }
        let memo = records.filter { model.inferredDateNoDateEvidence[$0.id] != nil }.map(\.filename)
        out.append("noDateMemo=\(memo)")
        for line in logLines(model).dropFirst(logFrom) { out.append("log: " + line) }
        return out.joined(separator: "\n")
    }

    /// This pass's lines from the sandbox's own catalog.log, with the
    /// timing ("12 ms") and the log's own timestamp prefix masked.
    static func logLines(_ model: VideoScanModel) -> [String] {
        let text = (try? String(contentsOf: model.dashboard.catalogLog.url, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n")
            .compactMap { line -> String? in
                guard let at = line.range(of: "date inference:") ?? line.range(of: "date triangulation:")
                else { return nil }
                return String(line[at.lowerBound...])
            }
            .map { $0.replacingOccurrences(of: #", \d+ ms, "#, with: ", <ms> ms, ", options: .regularExpression) }
    }

    private func diff(_ actual: String, _ golden: String) -> Comment {
        let a = actual.components(separatedBy: "\n"), g = golden.components(separatedBy: "\n")
        var lines: [String] = []
        for i in 0..<max(a.count, g.count) where (i < a.count ? a[i] : "<none>") != (i < g.count ? g[i] : "<none>") {
            lines.append("line \(i): expected «\(i < g.count ? g[i] : "<none>")»\n          actual   «\(i < a.count ? a[i] : "<none>")»")
        }
        return Comment(rawValue: "ACTUAL SNAPSHOT:\n\(actual)\n\nDIFF:\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Runs

    @Test func wholeCatalogPassThenASecondPass() throws {
        let box = try Sandbox("whole")
        let records = Self.catalog()
        box.model.records = records
        let first = box.model.catchUpInferredDates(trigger: "test")
        let snap1 = Self.snapshot(first, model: box.model, records: records, logFrom: 0)
        #expect(snap1 == Self.goldenWholeFirst, diff(snap1, Self.goldenWholeFirst))

        let logged = Self.logLines(box.model).count
        let second = box.model.catchUpInferredDates(trigger: "again")
        let snap2 = Self.snapshot(second, model: box.model, records: records, logFrom: logged)
        #expect(snap2 == Self.goldenWholeSecond, diff(snap2, Self.goldenWholeSecond))
    }

    @Test func aBudgetOfTwoDefersTheRest() throws {
        let box = try Sandbox("budget")
        let records = Self.catalog()
        box.model.records = records
        let result = box.model.catchUpInferredDates(limit: 2, trigger: "budget")
        let snap = Self.snapshot(result, model: box.model, records: records, logFrom: 0)
        #expect(snap == Self.goldenBudget, diff(snap, Self.goldenBudget))
    }

    @Test func aScopedRefreshPassReachesItsGroups() throws {
        let box = try Sandbox("scoped")
        let records = Self.catalog()
        box.model.records = records
        let scope = records.filter { ["r1_settled.mov", "r2_donor.mov", "r2b_donor.mov"].contains($0.filename) }
        let result = box.model.catchUpInferredDates(scope: scope, trigger: "scoped", refreshScope: true)
        let snap = Self.snapshot(result, model: box.model, records: records, logFrom: 0)
        #expect(snap == Self.goldenScoped, diff(snap, Self.goldenScoped))
    }

    // MARK: - Goldens (captured from the unsplit function at ebcd2f09)

    static let goldenWholeFirst = """
    result examined=9 alreadyClassified=0 deferred=0 own=4 propagated=2 folderYear=3 footageShared=1 retriangulated=3 cleared=3 truncated=false
    r1_own_ocr.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r1_legacy_own.mov: date=677505600 conf=0.750 range=nil src=nil reason=on-screen date 1991-06-21 ×1
    r1_legacy_catchup.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r1_placeholder.mov: date=677505600 conf=0.887 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1; folder '1991' names 1991
    r1_no_date.mov: date=nil conf=nil range=nil src=nil reason=no evidence
    r1_had_date_now_none.mov: date=nil conf=nil range=nil src=nil reason=no evidence
    r1_settled.mov: date=489024000 conf=0.800 range=nil src=nil reason=settled earlier
    user_dated.mov: date=nil conf=nil range=nil src=nil reason=nil
    purged.mov: date=nil conf=nil range=nil src=nil reason=nil
    r0_fs_legacy.mov: date=410270400 conf=0.300 range=InferredDateRange(startYear: 1983, endYear: 1983) src=folder-year reason=bare-year folder '1983' — a placeholder any real evidence replaces
    r0_stale_share.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2_recipient.mov: date=677505600 conf=0.750 range=nil src=propagated from <r2_donor.mov> reason=same bytes as r2_donor.mov: on-screen date 1991-06-21 ×1
    r2_nodonor_a.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_nodonor_b.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_copy.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_settled.mov: date=677505600 conf=0.750 range=nil src=nil reason=archived own date
    archived_twin.mov: date=677505600 conf=0.750 range=nil src=propagated from <archived_settled.mov> reason=same bytes as archived_settled.mov: archived own date
    r2b_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2b_twin.mov: date=677505600 conf=0.750 range=nil src=footage-shared from <r2b_donor.mov> reason=shared from r2b_donor.mov (same footage): on-screen date 1991-06-21 ×1
    r2b_possible_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2b_possible_twin.mov: date=1009886400 conf=0.300 range=InferredDateRange(startYear: 2002, endYear: 2002) src=folder-year reason=bare-year folder '2002' — a placeholder any real evidence replaces
    r3_folder_year.mov: date=536500800 conf=0.300 range=InferredDateRange(startYear: 1987, endYear: 1987) src=folder-year reason=bare-year folder '1987' — a placeholder any real evidence replaces
    r3_embedded.mov: date=nil conf=nil range=nil src=nil reason=nil
    noDateMemo=["r1_no_date.mov", "r1_had_date_now_none.mov"]
    log: date inference: 13 records caught up (4 from own evidence, 2 propagated, 1 footage-shared, 3 re-triangulated, 3 folder-year prior; 9 examined, <ms> ms, test)
    log: date triangulation: 1 took their footage group's date, 3 re-triangulated with a written reason, 3 cleared (test)
    """

    static let goldenWholeSecond = """
    result examined=0 alreadyClassified=2 deferred=0 own=0 propagated=0 folderYear=0 footageShared=0 retriangulated=0 cleared=0 truncated=false
    r1_own_ocr.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r1_legacy_own.mov: date=677505600 conf=0.750 range=nil src=nil reason=on-screen date 1991-06-21 ×1
    r1_legacy_catchup.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r1_placeholder.mov: date=677505600 conf=0.887 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1; folder '1991' names 1991
    r1_no_date.mov: date=nil conf=nil range=nil src=nil reason=no evidence
    r1_had_date_now_none.mov: date=nil conf=nil range=nil src=nil reason=no evidence
    r1_settled.mov: date=489024000 conf=0.800 range=nil src=nil reason=settled earlier
    user_dated.mov: date=nil conf=nil range=nil src=nil reason=nil
    purged.mov: date=nil conf=nil range=nil src=nil reason=nil
    r0_fs_legacy.mov: date=410270400 conf=0.300 range=InferredDateRange(startYear: 1983, endYear: 1983) src=folder-year reason=bare-year folder '1983' — a placeholder any real evidence replaces
    r0_stale_share.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2_recipient.mov: date=677505600 conf=0.750 range=nil src=propagated from <r2_donor.mov> reason=same bytes as r2_donor.mov: on-screen date 1991-06-21 ×1
    r2_nodonor_a.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_nodonor_b.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_copy.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_settled.mov: date=677505600 conf=0.750 range=nil src=nil reason=archived own date
    archived_twin.mov: date=677505600 conf=0.750 range=nil src=propagated from <archived_settled.mov> reason=same bytes as archived_settled.mov: archived own date
    r2b_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2b_twin.mov: date=677505600 conf=0.750 range=nil src=footage-shared from <r2b_donor.mov> reason=shared from r2b_donor.mov (same footage): on-screen date 1991-06-21 ×1
    r2b_possible_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2b_possible_twin.mov: date=1009886400 conf=0.300 range=InferredDateRange(startYear: 2002, endYear: 2002) src=folder-year reason=bare-year folder '2002' — a placeholder any real evidence replaces
    r3_folder_year.mov: date=536500800 conf=0.300 range=InferredDateRange(startYear: 1987, endYear: 1987) src=folder-year reason=bare-year folder '1987' — a placeholder any real evidence replaces
    r3_embedded.mov: date=nil conf=nil range=nil src=nil reason=nil
    noDateMemo=["r1_no_date.mov", "r1_had_date_now_none.mov"]
    """

    static let goldenBudget = """
    result examined=2 alreadyClassified=0 deferred=7 own=1 propagated=1 folderYear=5 footageShared=0 retriangulated=1 cleared=2 truncated=true
    r1_own_ocr.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r1_legacy_own.mov: date=677505600 conf=0.750 range=nil src=nil reason=on-screen date 1991-06-21 ×1
    r1_legacy_catchup.mov: date=489024000 conf=0.750 range=nil src=catch-up reason=nil
    r1_placeholder.mov: date=489024000 conf=0.300 range=nil src=folder-year reason=bare-year folder '1985' — a placeholder any real evidence replaces
    r1_no_date.mov: date=nil conf=nil range=nil src=nil reason=nil
    r1_had_date_now_none.mov: date=489024000 conf=0.600 range=nil src=nil reason=nil
    r1_settled.mov: date=489024000 conf=0.800 range=nil src=nil reason=settled earlier
    user_dated.mov: date=nil conf=nil range=nil src=nil reason=nil
    purged.mov: date=nil conf=nil range=nil src=nil reason=nil
    r0_fs_legacy.mov: date=410270400 conf=0.300 range=InferredDateRange(startYear: 1983, endYear: 1983) src=folder-year reason=bare-year folder '1983' — a placeholder any real evidence replaces
    r0_stale_share.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_donor.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_recipient.mov: date=915192000 conf=0.300 range=InferredDateRange(startYear: 1999, endYear: 1999) src=folder-year reason=bare-year folder '1999' — a placeholder any real evidence replaces
    r2_nodonor_a.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_nodonor_b.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_copy.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_settled.mov: date=677505600 conf=0.750 range=nil src=nil reason=archived own date
    archived_twin.mov: date=677505600 conf=0.750 range=nil src=propagated from <archived_settled.mov> reason=same bytes as archived_settled.mov: archived own date
    r2b_donor.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2b_twin.mov: date=978350400 conf=0.300 range=InferredDateRange(startYear: 2001, endYear: 2001) src=folder-year reason=bare-year folder '2001' — a placeholder any real evidence replaces
    r2b_possible_donor.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2b_possible_twin.mov: date=1009886400 conf=0.300 range=InferredDateRange(startYear: 2002, endYear: 2002) src=folder-year reason=bare-year folder '2002' — a placeholder any real evidence replaces
    r3_folder_year.mov: date=536500800 conf=0.300 range=InferredDateRange(startYear: 1987, endYear: 1987) src=folder-year reason=bare-year folder '1987' — a placeholder any real evidence replaces
    r3_embedded.mov: date=nil conf=nil range=nil src=nil reason=nil
    noDateMemo=[]
    log: date inference: 8 records caught up (1 from own evidence, 1 propagated, 1 re-triangulated, 5 folder-year prior; 2 examined, limit 2 hit — more next pass, <ms> ms, budget)
    log: date triangulation: 0 took their footage group's date, 1 re-triangulated with a written reason, 2 cleared (budget)
    """

    static let goldenScoped = """
    result examined=3 alreadyClassified=0 deferred=0 own=2 propagated=1 folderYear=0 footageShared=1 retriangulated=1 cleared=0 truncated=false
    r1_own_ocr.mov: date=nil conf=nil range=nil src=nil reason=nil
    r1_legacy_own.mov: date=489024000 conf=0.750 range=nil src=nil reason=nil
    r1_legacy_catchup.mov: date=489024000 conf=0.750 range=nil src=catch-up reason=nil
    r1_placeholder.mov: date=489024000 conf=0.300 range=nil src=folder-year reason=bare-year folder '1985' — a placeholder any real evidence replaces
    r1_no_date.mov: date=nil conf=nil range=nil src=nil reason=nil
    r1_had_date_now_none.mov: date=489024000 conf=0.600 range=nil src=nil reason=nil
    r1_settled.mov: date=677505600 conf=0.750 range=nil src=nil reason=on-screen date 1991-06-21 ×1
    user_dated.mov: date=nil conf=nil range=nil src=nil reason=nil
    purged.mov: date=nil conf=nil range=nil src=nil reason=nil
    r0_fs_legacy.mov: date=489024000 conf=0.300 range=nil src=nil reason=nil
    r0_stale_share.mov: date=489024000 conf=0.750 range=nil src=footage-shared from 00000000-0000-0000-0000-00000000D0D0 reason=shared from gone.mov (same footage); own evidence said 1984
    r2_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2_recipient.mov: date=677505600 conf=0.750 range=nil src=propagated from <r2_donor.mov> reason=same bytes as r2_donor.mov: on-screen date 1991-06-21 ×1
    r2_nodonor_a.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2_nodonor_b.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_copy.mov: date=nil conf=nil range=nil src=nil reason=nil
    archived_settled.mov: date=677505600 conf=0.750 range=nil src=nil reason=archived own date
    archived_twin.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2b_donor.mov: date=677505600 conf=0.750 range=nil src=catch-up reason=on-screen date 1991-06-21 ×1
    r2b_twin.mov: date=677505600 conf=0.750 range=nil src=footage-shared from <r2b_donor.mov> reason=shared from r2b_donor.mov (same footage): on-screen date 1991-06-21 ×1
    r2b_possible_donor.mov: date=nil conf=nil range=nil src=nil reason=nil
    r2b_possible_twin.mov: date=nil conf=nil range=nil src=nil reason=nil
    r3_folder_year.mov: date=nil conf=nil range=nil src=nil reason=nil
    r3_embedded.mov: date=nil conf=nil range=nil src=nil reason=nil
    noDateMemo=[]
    log: date inference: 5 records caught up (2 from own evidence, 1 propagated, 1 footage-shared, 1 re-triangulated, 0 folder-year prior; 3 examined, <ms> ms, scoped)
    log: date triangulation: 1 took their footage group's date, 1 re-triangulated with a written reason, 0 cleared (scoped)
    """
}
