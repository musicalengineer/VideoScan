// ShowAgainDeleteReviewTests.swift
// The Review… sheet's "is it safe to delete these?" table and its one Apply
// (Rick 2026-10-11). Five dimensions:
//   LOGIC     — the classifier's buckets; freed space (copies of each other
//               free only the extras); the table's selection maths and
//               words; which picks survive the Show Again run.
//   SCALE     — 100k records, 10k labelled: projection + classification
//               inside an explicit budget.
//   ISOLATION — the classifier reads the catalog only: a sensor that the new
//               sources never name the night diagnostic's CSV, a path under
//               diagnostics/, or UserDefaults.
//   SENSOR    — an only copy can never be selected or trashed through the
//               sheet (forged input included, and end to end); a pick whose
//               proof fails at the move is HELD, its file untouched.
//   MEDIA     — N/A: nothing here opens media (the engine's own suites
//               cover its reads).
// Synthetic files in temp folders; the Trash is a scratch folder.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func sha256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Logic: the classifier

@Suite("Show again — delete review: the classifier")
struct ShowAgainDeleteClassifierTests {

    typealias File = ShowAgainDeleteFacts.File
    typealias Keeper = ShowAgainDeleteFacts.Keeper

    static func file(_ name: String, size: Int64, _ d: DuplicateDisposition = .none, group: UUID? = nil,
                     digest: String? = nil, junk: Bool = false, protection: String? = nil,
                     candidate: Bool = false, id: UUID = UUID()) -> File {
        File(id: id, filename: name, path: "/Volumes/SanDisk/\(name)", sizeBytes: size, disposition: d,
             groupID: group, digest: digest, isConfirmedJunk: junk, protection: protection,
             hasCopyCandidate: candidate)
    }

    static func keeper(_ id: UUID = UUID(), name: String = "k.mov", digest: String? = "aa",
                       online: Bool = true, hidden: Bool = false) -> Keeper {
        Keeper(id: id, filename: name, path: "/Volumes/LaCie/\(name)", digest: digest, online: online, staysHidden: hidden)
    }

    @Test("a proven extra copy whose keeper is outside the set: copies elsewhere, checked, frees its size")
    func provenElsewhere() {
        let g = UUID()
        let f = Self.file("a.mov", size: 1_000, .extraCopy, group: g, digest: "aa")
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(files: [f], keepers: [g: Self.keeper()]))
        let row = s.row(.copiesElsewhere)
        #expect(row?.fileCount == 1 && row?.freeableBytes == 1_000)
        #expect(s.defaultSelection == [.copiesElsewhere])
        #expect(s.duplicatePicks(s.defaultSelection).map(\.recordID) == [f.id])
    }

    @Test("a sampled-only match (no stored whole-file digest, or a different one) is Unsure, unchecked, but still tickable")
    func sampledIsUnsure() {
        let g = UUID()
        let noDigest = Self.file("a.mov", size: 10, .extraCopy, group: g)
        let other = Self.file("b.mov", size: 20, .extraCopy, group: g, digest: "bb")
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(files: [noDigest, other], keepers: [g: Self.keeper()]))
        #expect(s.row(.copiesElsewhere) == nil)
        #expect(s.row(.unsure)?.removableCount == 2)
        #expect(s.defaultSelection.isEmpty)
        #expect(s.totals([.unsure]) == DeleteReviewTotals(fileCount: 2, bytes: 30))
    }

    @Test("copies of each other: the keeper is listed but frees nothing; only the extras are freed")
    func cycleCountsOnlyExtras() {
        let g = UUID()
        let keeperID = UUID()
        let kept = Self.file("Clip 03.dv", size: 13_000, .keep, group: g, digest: "cc", id: keeperID)
        let extra1 = Self.file("Clip 03 copy.dv", size: 13_000, .extraCopy, group: g, digest: "cc")
        let extra2 = Self.file("Clip 03 copy 2.dv", size: 13_000, .extraCopy, group: g, digest: "cc")
        let facts = ShowAgainDeleteFacts(files: [kept, extra1, extra2],
                                         keepers: [g: Self.keeper(keeperID, name: "Clip 03.dv", digest: "cc")])
        let s = ShowAgainDeleteClassifier.summary(facts)
        let row = s.row(.copiesOfEachOther)
        #expect(row?.fileCount == 3)
        #expect(row?.totalBytes == 39_000)
        #expect(row?.freeableBytes == 26_000, "only the two extras are freed")
        #expect(row?.removableCount == 2)
        #expect(!s.duplicatePicks([.copiesOfEachOther]).contains { $0.recordID == keeperID }, "the keeper is never a pick")
        #expect(s.defaultSelection.contains(.copiesOfEachOther))
    }

    @Test("a cycle with one unproven extra: the whole family goes to Unsure, the keeper still never a pick")
    func cycleWithUnprovenExtra() {
        let g = UUID()
        let keeperID = UUID()
        let kept = Self.file("x.dv", size: 5, .keep, group: g, digest: "cc", id: keeperID)
        let proven = Self.file("x copy.dv", size: 5, .extraCopy, group: g, digest: "cc")
        let sampled = Self.file("x copy 2.dv", size: 5, .extraCopy, group: g)
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(
            files: [kept, proven, sampled], keepers: [g: Self.keeper(keeperID, digest: "cc")]))
        #expect(s.row(.unsure)?.items.contains { $0.id == keeperID && $0.removal == nil } == true)
        #expect(s.row(.copiesOfEachOther)?.items.contains { $0.id == keeperID } != true)
    }

    @Test("a keeper whose drive is away, or that stays hidden, puts the copy in Unsure with nothing to move")
    func unreliableKeeper() {
        let g1 = UUID(), g2 = UUID()
        let a = Self.file("a.mov", size: 1, .extraCopy, group: g1, digest: "aa")
        let b = Self.file("b.mov", size: 1, .extraCopy, group: g2, digest: "aa")
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(
            files: [a, b], keepers: [g1: Self.keeper(online: false), g2: Self.keeper(hidden: true)]))
        let unsure = s.row(.unsure)
        #expect(unsure?.fileCount == 2 && unsure?.removableCount == 0 && unsure?.isSelectable == false)
        #expect(unsure?.items.map(\.note).sorted() == [ShowAgainDeleteClassifier.keeperOfflineNote,
                                                       ShowAgainDeleteClassifier.keeperHiddenNote].sorted())
    }

    @Test("a protected file (archive, Read only, A/V pair, Angel) is Unsure with its reason and never a pick")
    func protectedIsHeld() {
        let g = UUID()
        let f = Self.file("V01.mxf", size: 9, .extraCopy, group: g, digest: "aa", protection: "half of a recovered A/V pair")
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(files: [f], keepers: [g: Self.keeper()]))
        #expect(s.row(.unsure)?.items.first?.note == "half of a recovered A/V pair")
        #expect(s.row(.unsure)?.removableCount == 0)
    }

    @Test("no other copy known: Only copy; a copy candidate the catalog never paired: Unsure, nothing to move")
    func uniqueAndUnpaired() {
        let unique = Self.file("AVCHD_00042.MTS", size: 7)
        let unpaired = Self.file("Clip 01.dv", size: 8, candidate: true)
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(files: [unique, unpaired], keepers: [:]))
        #expect(s.row(.onlyCopy)?.items.map(\.id) == [unique.id])
        #expect(s.row(.onlyCopy)?.isSelectable == false)
        #expect(s.row(.unsure)?.items.first?.note == ShowAgainDeleteClassifier.unpairedNote)
        #expect(s.totals(Set(DeleteReviewCategory.allCases)).isEmpty)
    }

    @Test("confirmed junk: its own row; moves only as an extra copy with a keeper")
    func junk() {
        let g = UUID()
        let junkCopy = Self.file("junk copy.mov", size: 3, .extraCopy, group: g, digest: "aa", junk: true)
        let junkOnly = Self.file("junk.mov", size: 4, junk: true)
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(files: [junkCopy, junkOnly], keepers: [g: Self.keeper()]))
        let row = s.row(.markedJunk)
        #expect(row?.fileCount == 2 && row?.removableCount == 1 && row?.freeableBytes == 3)
        #expect(s.defaultSelection == [.markedJunk])
    }

    @Test("rows come in table order and an empty row is hidden")
    func orderAndHiding() {
        let g = UUID()
        let s = ShowAgainDeleteClassifier.summary(ShowAgainDeleteFacts(
            files: [Self.file("u", size: 1), Self.file("e", size: 2, .extraCopy, group: g, digest: "aa")],
            keepers: [g: Self.keeper()]))
        #expect(s.rows.map(\.category) == [.copiesElsewhere, .onlyCopy])
        #expect(s.row(.markedJunk) == nil, "junk row hidden when empty")
    }
}

// MARK: - Logic: the table's words and maths

@Suite("Show again — delete review: the table")
struct DeleteReviewSummaryTests {

    @Test("footer and button words")
    func words() {
        #expect(DeleteReviewTotals(fileCount: 0, bytes: 0).footerLine == "Nothing selected: no file will move to the Trash")
        let t = DeleteReviewTotals(fileCount: 701, bytes: 836_000_000_000)
        #expect(t.footerLine == "Selected: 701 files, \(MediaBytes.display(836_000_000_000)) will move to the Trash (you can Put Back from Finder)")
        #expect(t.moveTitle == "Move 701 to Trash")
        #expect(DeleteReviewTotals(fileCount: 1, bytes: 5).footerLine.hasPrefix("Selected: 1 file, "))
    }

    @Test("row titles are plain words, no internal names")
    func titles() {
        for c in DeleteReviewCategory.allCases {
            #expect(!c.title.contains("manuallyDeleted") && !c.title.contains("archiveStage"))
        }
        #expect(DeleteReviewCategory.copiesElsewhere.title == "Copies exist elsewhere: safe to delete")
        #expect(DeleteReviewCategory.onlyCopy.title == "Only copy: recommend keeping")
        #expect(DeleteReviewCategory.unsure.title == "Unsure: needs review")
    }

    @Test("totals are the sum of the ticked rows only")
    func totalsSumTickedRows() {
        func item(_ size: Int64) -> DeleteReviewItem {
            let id = UUID()
            return DeleteReviewItem(id: id, filename: "f", path: "/p/\(id)", sizeBytes: size, note: "",
                                    removal: .duplicate(ReviewedDuplicatePick(recordID: id, path: "/p/\(id)", keeperID: UUID())))
        }
        let s = DeleteReviewSummary(rows: [
            DeleteReviewRow(category: .copiesElsewhere, items: [item(100), item(200)]),
            DeleteReviewRow(category: .unsure, items: [item(7)]),
        ])
        #expect(s.totals([.copiesElsewhere]) == DeleteReviewTotals(fileCount: 2, bytes: 300))
        #expect(s.totals([.copiesElsewhere, .unsure]) == DeleteReviewTotals(fileCount: 3, bytes: 307))
        #expect(s.removals([.unsure]).count == 1)
        #expect(s.logLine.contains("Copies exist elsewhere: safe to delete 2"))
    }
}

// MARK: - Logic: which picks survive the Show Again run

@Suite("Show again — delete review: picks after the run")
struct ShowAgainTrashPicksTests {

    @Test("a pick stands only when its file was shown again and its keeper is not left hidden")
    func eligible() {
        let shownCopy = UUID(), notShown = UUID(), keeperOut = UUID(), keeperShown = UUID(), keeperHidden = UUID()
        let a = ReviewedDuplicatePick(recordID: shownCopy, path: "/a", keeperID: keeperOut)
        let b = ReviewedDuplicatePick(recordID: notShown, path: "/b", keeperID: keeperOut)
        let c = ReviewedDuplicatePick(recordID: shownCopy, path: "/c", keeperID: keeperShown)
        let d = ReviewedDuplicatePick(recordID: shownCopy, path: "/d", keeperID: keeperHidden)
        let out = ShowAgainTrashPicks.eligible([a, b, c, d], shown: [shownCopy, keeperShown],
                                               labelled: [shownCopy, notShown, keeperShown, keeperHidden])
        #expect(out == [a, c])
    }

    @Test("the Trash step follows only a clean Show Again")
    func mayProceed() {
        #expect(ShowAgainTrashPicks.mayProceed(after: .shown))
        #expect(ShowAgainTrashPicks.mayProceed(after: .nothingToDo))
        #expect(!ShowAgainTrashPicks.mayProceed(after: .refused("x")))
        #expect(!ShowAgainTrashPicks.mayProceed(after: .stopped))
        #expect(!ShowAgainTrashPicks.mayProceed(after: .saveUnconfirmed))
    }
}

// MARK: - Sensor: only copies never move; a failed proof is held

@Suite("Show again — delete review: sensor", .serialized)
@MainActor
struct ShowAgainDeleteReviewSensorTests {

    @Test("a forged only-copy item that carries a removal can never be selected or counted")
    func onlyCopyNeverSelectable() {
        let id = UUID()
        let forged = DeleteReviewItem(id: id, filename: "only.mov", path: "/only.mov", sizeBytes: 9, note: "",
                                      removal: .duplicate(ReviewedDuplicatePick(recordID: id, path: "/only.mov", keeperID: UUID())))
        let s = DeleteReviewSummary(rows: [DeleteReviewRow(category: .onlyCopy, items: [forged])])
        let row = s.row(.onlyCopy)
        #expect(row?.isSelectable == false && row?.removableCount == 0 && row?.freeableBytes == 0)
        #expect(!DeleteReviewCategory.onlyCopy.allowsRemoval && !DeleteReviewCategory.onlyCopy.checkedByDefault)
        #expect(s.defaultSelection.isEmpty)
        #expect(s.totals([.onlyCopy]).isEmpty)
        #expect(s.removals(Set(DeleteReviewCategory.allCases)).isEmpty)
    }

    /// End to end on real files: the review, the table, Show Again, then the
    /// ticked rows through the real Delete Duplicates engine (scratch Trash).
    ///   * proven copy, keeper intact ............ moves to the Trash
    ///   * proven copy whose keeper changed after
    ///     the review (its proof fails at the move) ... HELD, untouched
    ///   * only copy ............................ never offered, never moves
    @Test("only copies never move; a pick that fails its proof at the move is held")
    func endToEnd() async throws {
        let sb = try ShowAgainSandbox.make("delrev"); defer { sb.cleanup() }
        let model = sb.model
        func pair(_ name: String) throws -> (copy: VideoRecord, keeper: VideoRecord) {
            let keeper = try sb.record("\(name) keeper.mov", bytes: 6_000, stage: .none)
            let copy = try sb.record("\(name) copy.mov", bytes: 6_000)
            try Data(contentsOf: URL(fileURLWithPath: keeper.fullPath)).write(to: URL(fileURLWithPath: copy.fullPath))
            let g = UUID()
            for (r, d) in [(keeper, DuplicateDisposition.keep), (copy, .extraCopy)] {
                r.duplicateGroupID = g; r.duplicateDisposition = d; r.duplicateConfidence = .high
                r.durationSeconds = 61; r.partialMD5 = "m-\(name)"
                r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: sha256(URL(fileURLWithPath: r.fullPath)),
                                                         byteCount: r.sizeBytes)
            }
            return (copy, keeper)
        }
        let good = try pair("good")
        let liar = try pair("liar")
        let only = try sb.record("AVCHD_00042.MTS", bytes: 5_000)

        let plan = await model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        let summary = await model.showAgainDeleteReview(plan: plan, disk: ShowAgainSandbox.onlineRealStat)
        try #require(summary.row(.copiesElsewhere)?.fileCount == 2, "\(summary.logLine)")
        try #require(summary.row(.onlyCopy)?.items.map(\.id) == [only.id], "\(summary.logLine)")
        let picks = summary.duplicatePicks(Set(DeleteReviewCategory.allCases))   // tick EVERYTHING
        #expect(!picks.contains { $0.recordID == only.id }, "an only copy is never a pick")

        // After the review: the liar's keeper is rewritten (same size, other bytes).
        try Data(repeating: 0x5A, count: 6_000).write(to: URL(fileURLWithPath: liar.keeper.fullPath))

        let job = ShowAgainJob(model: model, reviewed: plan)
        job.disk = ShowAgainSandbox.onlineRealStat
        job.start(); await job.task?.value
        try #require(job.result?.outcome == .shown, "\(String(describing: job.result?.outcome))")

        let hooks = SignatureVerification.Hooks.live.withScratchTrash(in: sb.root)
        let plans = sb.root.appendingPathComponent("plans", isDirectory: true)
        let run = await model.showAgainTrashAfter(job: job, picks: picks, labelled: Set(plan.items.map(\.id))) { batch in
            let run = DeleteDuplicatesBatchRun(batch: batch)
            run.start(make: { DeleteDuplicatesJob(model: model, reviewed: $0, hooks: hooks, planRoot: plans) },
                      launch: { $0.start() })
            return run
        }
        await run?.task?.value
        let report = try #require(run?.outcomeReport)

        let trash = sb.root.appendingPathComponent("Trash", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: good.copy.fullPath), "positive control: the proven copy moves")
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent(good.copy.filename).path))
        #expect(FileManager.default.fileExists(atPath: good.keeper.fullPath), "the keeper stays")
        #expect(FileManager.default.fileExists(atPath: liar.copy.fullPath), "a failed proof is held, the file untouched")
        #expect(FileManager.default.fileExists(atPath: only.fullPath), "an only copy never moves")
        #expect(report.count(.moved) == 1, Comment(rawValue: report.line))
        #expect(report.rows.contains { $0.kind != .moved && !$0.reason.isEmpty }, Comment(rawValue: report.line))
        #expect(only.archiveStage == .none, "the only copy is shown again")
    }

    @Test("Show Again refused: nothing is handed to the engine")
    func refusedShowAgainMovesNothing() async throws {
        let sb = try ShowAgainSandbox.make("delrev_refused"); defer { sb.cleanup() }
        let job = ShowAgainJob(model: sb.model, reviewed: .empty)
        job.refuseToStart(reason: "test")
        let pick = ReviewedDuplicatePick(recordID: UUID(), path: "/x", keeperID: UUID())
        let run = await sb.model.showAgainTrashAfter(job: job, picks: [pick], labelled: []) { _ in
            Issue.record("nothing may be started after a refused Show Again")
            return DeleteDuplicatesBatchRun(batch: DeleteDuplicatesBatch(plans: []))
        }
        #expect(run == nil)
    }
}

// MARK: - Isolation: the catalog is the only input

@Suite("Show again — delete review: isolation")
struct ShowAgainDeleteReviewIsolationTests {

    static let files = ["ShowAgainDeleteClassifier.swift", "DeleteReviewSummary.swift",
                        "DeleteReviewSummaryView.swift", "ShowAgainThenTrash.swift", "ShowAgainReview.swift"]

    @Test("the classifier and the table never read the diagnostics CSV or global defaults")
    func catalogOnly() throws {
        for name in Self.files {
            let code = try SourceTree.appSource(named: name).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for forbidden in ["diagnostics", "manually_deleted_959", ".csv", "UserDefaults", "contentsOfFile"] {
                #expect(!code.contains(forbidden), "\(name) mentions \(forbidden)")
            }
        }
    }

    @Test("the table's selection and the ShowAgain label-only sources never move a file themselves")
    func noDirectFileOperations() throws {
        for name in Self.files {
            let code = try SourceTree.appSource(named: name).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in ["trashItem", "removeItem", "moveItem", "unlink(", "rename("] {
                #expect(!code.contains(call), "\(name) calls \(call)")
            }
        }
    }
}

// MARK: - Scale

@Suite("Show again — delete review: scale (100k records)", .serialized)
@MainActor
struct ShowAgainDeleteReviewScaleTests {

    /// 100k records; every tenth labelled (10k, ten times Rick's ~1,000).
    /// Labelled i pairs with i+1 as its keeper in half the cases (proven
    /// digests), shares a sampled hash in a quarter, is unique otherwise.
    /// Budgets (Debug, M4 Max, headroom ×3+): facts projection < 1 s,
    /// classification < 0.5 s.
    @Test("100k records, 10k labelled: projection and classification within budget")
    func hundredThousand() async throws {
        let sb = try ShowAgainSandbox.make("delrev_scale"); defer { sb.cleanup() }
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 1, mtimeNs: 1, ctimeNs: 1, volumeUUID: UUID().uuidString)
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/Scale/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i)
            records.append(r)
        }
        for i in stride(from: 0, to: 100_000, by: 10) {
            let r = records[i], k = records[i + 1]
            r.archiveStage = .manuallyDeleted
            switch (i / 10) % 4 {
            case 0, 1:
                let g = UUID()
                k.sizeBytes = r.sizeBytes
                r.duplicateGroupID = g; k.duplicateGroupID = g
                r.duplicateDisposition = .extraCopy; k.duplicateDisposition = .keep
                let f = ContentFixity(digest: "d\(i)", byteCount: r.sizeBytes, stamp: stamp)
                r.contentFixity = f; k.contentFixity = f
            case 2:
                k.sizeBytes = r.sizeBytes
                r.contentHash = "v1:\(i)"; k.contentHash = "v1:\(i)"
            default:
                break
            }
        }
        sb.model.records = records
        let sizes = Dictionary(uniqueKeysWithValues: records.filter { $0.archiveStage == .manuallyDeleted }
            .map { ($0.fullPath, $0.sizeBytes) })
        let disk = ShowAgainDisk(volumeOnline: { _ in true },
                                 stat: { sizes[$0].map { .file(size: $0) } ?? .missing })
        let plan = await sb.model.showAgainReview(disk: disk)
        try #require(plan.showCount == 10_000)

        let t0 = Date()
        var facts = sb.model.showAgainDeleteFacts(plan: plan)
        let projection = -t0.timeIntervalSinceNow
        for g in facts.keepers.keys { facts.keepers[g]?.online = true }
        let t1 = Date()
        let summary = ShowAgainDeleteClassifier.summary(facts)
        let classify = -t1.timeIntervalSinceNow

        #expect(summary.row(.copiesElsewhere)?.fileCount == 5_000)
        #expect(summary.row(.unsure)?.fileCount == 2_500)
        #expect(summary.row(.onlyCopy)?.fileCount == 2_500)
        #expect(summary.fileCount == 10_000)
        #expect(projection < 1, "facts projection took \(projection) s")
        #expect(classify < 0.5, "classification took \(classify) s")
    }
}
