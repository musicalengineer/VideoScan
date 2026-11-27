import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #528: the archived-content index and the commit's refusal
//
// ArchivedContentIndex answers the date seam's twin question ("is a LIVE
// archived copy of this content in the catalog?") in O(1), rebuilt only when
// its answer can change. ArchivedContentDateRefusal is the commit's second
// wall. The writer pins (seen RED) live in ArchivedTwinDateWritersTests.
//
// Dimensions:
//   logic      the index agrees with the plain scan (InspectorDateEdit.
//              archivedCopy over the per-row rule) on a mixed catalog; the
//              refusal's truth table (twin refused, archived writer passes,
//              no archived copy untouched, a row the store never saw)
//   truth      archivedCopyFixingDate names the archived row (what the
//              Inspector shows and where Update… goes), never the twin
//   scale      100k rows: the seam asked for every row inside a Debug
//              budget with ONE rebuild; a 100k commit refusal pass in budget
//   isolation  poisoned state — two fixities that disagree, a fixity that
//              does not cover the size, a stale archive root: no twin
//   sensor     an in-place write of every archive fact on an indexed row
//              moves the generation (a fact added without a bump would
//              leave the index stale); a clone starts untracked
//   scale      (round 2, P2) a notes-only save — the commit's loaded copy of
//              the stored row — and a snapshot clone rebuild nothing
//   media      n/a here — no media file is opened (the MEDIA pin is
//              ArchivedTwinDateWritersTests.linkRepairedCopyOntoATwin)

@MainActor
@Suite("GH #528 — ArchivedContentIndex and the commit's date refusal")
struct ArchivedContentIndexTests {

    typealias W = ArchivedTwinDateWritersTests
    typealias F = DossierAdmissionFixtures

    static func row(_ name: String, stage: LifecycleStage = .cataloged, digest: String?, size: Int64 = 4_096) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/TestIndex528/" + name
        r.lifecycleStage = stage
        r.sizeBytes = size
        if let digest { r.contentFixity = W.fixity(digest, size) }
        return r
    }

    static func hex(_ i: Int) -> String { String(format: "%064x", i) }

    // MARK: Logic + truth

    @Test("LOGIC: the index agrees with the plain scan on every row of a mixed catalog; TRUTH: it names the archived row")
    func agreesWithTheScan() {
        let model = VideoScanModel()
        var rows: [VideoRecord] = []
        for i in 0..<300 {
            let stage: LifecycleStage = i % 7 == 0 ? .archived : (i % 5 == 0 ? .reviewing : .cataloged)
            let r = Self.row("r\(i).mov", stage: stage, digest: i % 11 == 0 ? nil : Self.hex(i % 40),
                             size: Int64(4_096 + i % 40))
            if i % 13 == 0 { r.removal = .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash) }
            rows.append(r)
        }
        model.records = rows
        // 2026-11-27: the seam hoisted for one pass (the catch-up bucketing walk)
        // answers exactly as the per-row seam.
        let rule = model.dateReadOnlyRule()
        for r in rows {
            let scan = InspectorDateEdit.archivedCopy(fixing: r, in: rows, isReadOnly: model.isDateReadOnlyItself)
            let indexed = model.archivedCopyFixingDate(of: r)
            #expect(scan === indexed, "\(r.filename): scan \(scan?.filename ?? "nil") vs index \(indexed?.filename ?? "nil")")
            #expect(model.isDateReadOnly(r) == (scan != nil))
            #expect(rule.isDateReadOnly(r) == (scan != nil), "\(r.filename): the pass rule disagrees with the seam")
            if let indexed { #expect(model.isDateReadOnlyItself(indexed), "the fixing row is archived ITSELF") }
        }
        #expect(model.archivedContentIndex.rebuildCount == 1, "one rebuild for \(rows.count * 2) lookups")
    }

    @Test("LOGIC: rebuilds only when an archive fact or the array changes — never for a date write")
    func rebuildsOnlyWhenTheAnswerCanChange() {
        let model = VideoScanModel()
        let archived = Self.row("a.mov", stage: .archived, digest: W.digestA)
        let twin = Self.row("t.mov", digest: W.digestA)
        model.records = [archived, twin]
        #expect(model.isDateReadOnly(twin))
        let built = model.archivedContentIndex.rebuildCount
        for _ in 0..<1_000 {
            twin.userDate = "1992"; twin.inferredRecordDate = Date()   // date writes bump nothing
            _ = model.isDateReadOnly(twin)
        }
        #expect(model.archivedContentIndex.rebuildCount == built)
        archived.lifecycleStage = .cataloged
        #expect(!model.isDateReadOnly(twin), "an in-place stage change is seen")
        #expect(model.archivedContentIndex.rebuildCount == built + 1)
        model.records.append(Self.row("x.mov", digest: nil))
        _ = model.isDateReadOnly(twin)
        #expect(model.archivedContentIndex.rebuildCount == built + 2, "an array change rebuilds")
    }

    /// Codex round 2 (#528 P2): the generation was process-wide, so the
    /// commit's own `VideoRecord(loaded:)` (the stored row it diffs against)
    /// and any `snapshotClone()` bumped it — a notes-only save forced an
    /// O(records) rebuild at the next Inspector render.
    @Test("RED before #528 round 2 (SCALE): a notes-only save and a snapshot clone do not rebuild the index; an archive fact on a live row still does")
    func aNotesOnlySaveDoesNotRebuild() async throws {
        let scene = try CutoverScene.make("t528_p2_rebuild"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let model = scene.model
        let original = try scene.record(.curatedConflictA)
        let copy = try scene.record(.curatedConflictB)
        copy.lifecycleStage = .archived
        #expect(model.saveCatalogNow())
        #expect(model.isDateReadOnly(original), "the fixture: a twin of archived content")
        let built = model.archivedContentIndex.rebuildCount

        original.userNotes = "a note, nothing about the archive"
        #expect(model.saveCatalogNow())
        let clone = copy.snapshotClone()
        clone.lifecycleStage = .cataloged; clone.fullPath = "/Volumes/TestClone528/x.mov"   // a detached copy's facts
        #expect(model.isDateReadOnly(original))
        #expect(model.archivedContentIndex.rebuildCount == built,
                "a notes-only save and a detached clone rebuilt the index \(model.archivedContentIndex.rebuildCount - built)×")

        copy.lifecycleStage = .cataloged                      // a LIVE row's archive fact
        #expect(!model.isDateReadOnly(original), "an in-place change on a live row is still seen")
        #expect(model.archivedContentIndex.rebuildCount == built + 1)
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    @Test("TRUTH: a promoted copy inside the archive root fixes its twin; a twin's 'left as filed' line names the archived copy")
    func archiveElementFixesAndTheLineNamesIt() async throws {
        let sb = try F.Sandbox("t528_element"); defer { sb.cleanup() }
        let root = sb.dir.appendingPathComponent("test_Archive", isDirectory: true).path
        sb.model.masterArchive = MasterArchiveDesignation(targetPath: sb.dir.path, rootPath: root)
        let inside = Self.row("1984-xx-xx_Trip.mov", digest: W.digestA)
        inside.fullPath = root + "/30_Video/1984-xx-xx_Trip.mov"
        let twin = Self.row("trip.mov", digest: W.digestA)
        let extra = Self.row("extra.mov", digest: nil)
        extra.userDate = "1992"
        sb.model.records = [inside, twin, extra]
        #expect(sb.model.archivedCopyFixingDate(of: twin) === inside)
        #expect(sb.model.archivedCopyFixingDate(of: inside) === inside)
        // The pass rule reads the same root: inside (in the root) and its twin fixed, extra not.
        let rule = sb.model.dateReadOnlyRule()
        #expect(rule.isDateReadOnly(inside) && rule.isDateReadOnly(twin) && !rule.isDateReadOnly(extra))
        _ = sb.model.applyHumanMetadataInheritance(from: extra, to: twin)
        func logged() -> Bool {
            sb.model.dashboard.consoleLines.contains {
                $0.contains("trip.mov is a copy of archived 1984-xx-xx_Trip.mov — date left as filed")
                    && $0.contains("Use Update… on 1984-xx-xx_Trip.mov")
            }
        }
        for _ in 0..<40 where !logged() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(logged())
    }

    // MARK: The commit's refusal (pure)

    private static func item(_ r: VideoRecord, baseline: VideoRecord?) -> CatalogCommit.Item {
        let snap = VideoRecordDTO(r)
        return CatalogCommit.Item(id: r.id, snapshot: snap, fingerprint: CatalogChangeDetector.fingerprint(snap),
                                  sharedBaseline: baseline.map { CatalogSharedCurated($0) })
    }

    @Test("LOGIC: the refusal puts a twin's date back, passes the archived writer, leaves other content and non-date edits alone")
    func refusalTruthTable() {
        let archived = Self.row("a.mov", stage: .archived, digest: W.digestA)
        archived.userDate = "1984"; archived.userDateConfidence = "known"
        let twin = Self.row("t.mov", digest: W.digestA)
        let twinBaseline = twin.snapshotClone()
        twinBaseline.userDate = "1984"; twinBaseline.userDateConfidence = "known"
        twin.userDate = "1992"; twin.userDateConfidence = "estimated"
        let notesOnly = Self.row("n.mov", digest: W.digestA)
        notesOnly.userDate = "1984"; notesOnly.userDateConfidence = "known"
        let notesBaseline = notesOnly.snapshotClone()
        notesOnly.userNotes = "edited"
        let other = Self.row("o.mov", digest: W.digestC)
        let otherBaseline = other.snapshotClone()
        other.userDate = "2001"
        let fresh = Self.row("f.mov", digest: W.digestA)       // never stored by this session
        fresh.userDate = "1999"
        let updated = archived                                    // Update… on the archived copy itself
        let updatedBaseline = archived.snapshotClone()
        updated.userDate = "1985"

        let items = [Self.item(twin, baseline: twinBaseline), Self.item(notesOnly, baseline: notesBaseline),
                     Self.item(other, baseline: otherBaseline), Self.item(fresh, baseline: nil),
                     Self.item(updated, baseline: updatedBaseline)]
        let result = ArchivedContentDateRefusal.refuse(items, records: [archived, twin, notesOnly, other, fresh],
                                                       isArchivedItself: { $0.lifecycleStage == .archived },
                                                       owns: { _ in true }, baselinePrints: [:])
        #expect(twin.userDate == "1984" && twin.userDateConfidence == "known",
                "the twin is put back to its baseline — it writes no date (Update…'s 1985 reaches it by the copy step)")
        #expect(fresh.userDate == "1985", "a row the store never saw cannot bring a date either")
        #expect(other.userDate == "2001", "other content is not touched")
        #expect(notesOnly.userNotes == "edited" && notesOnly.userDate == "1984", "a notes edit is not a date write")
        #expect(updated.userDate == "1985", "the archived copy's own date write passes")
        #expect(result.lines.count == 2, "\(result.lines)")
        #expect(result.items.count == 5)
        let twinItem = result.items.first { $0.id == twin.id }
        #expect(twinItem?.snapshot.userDate == "1984", "the sent snapshot carries the put-back date")
        #expect(twinItem.map(ArchivedContentDateRefusal.writesDate) == false, "the twin no longer writes the date group")
        #expect(result.lines.allSatisfy { !$0.contains(".mov") }, "ids and a digest prefix only (ARCH-7)")
    }

    @Test("LOGIC: a row whose only change was the refused date is dropped from the commit")
    func refusalDropsAnEmptiedRow() {
        let archived = Self.row("a.mov", stage: .archived, digest: W.digestA)
        archived.userDate = "1984"; archived.userDateConfidence = "known"
        let twin = Self.row("t.mov", digest: W.digestA)
        twin.userDate = "1984"; twin.userDateConfidence = "known"
        let baseline = twin.snapshotClone()
        let stored = CatalogChangeDetector.fingerprint(VideoRecordDTO(twin))
        twin.userDate = "1992"
        let result = ArchivedContentDateRefusal.refuse([Self.item(twin, baseline: baseline)], records: [archived, twin],
                                                       isArchivedItself: { $0.lifecycleStage == .archived },
                                                       owns: { _ in true }, baselinePrints: [twin.id: stored])
        #expect(result.items.isEmpty && twin.userDate == "1984" && result.lines.count == 1)
    }

    // MARK: Scale

    @Test("SCALE: 100k rows — the seam for every row inside budget, ONE rebuild; the commit refusal pass inside budget")
    func scale() {
        let model = VideoScanModel()
        var rows: [VideoRecord] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = Self.row("s\(i).mov", stage: i % 20 == 0 ? .archived : .cataloged,
                             digest: Self.hex(i % 50_000), size: Int64(10_000 + i % 50_000))
            rows.append(r)
        }
        model.records = rows
        let clock = ContinuousClock()
        var fixed = 0
        let seam = clock.measure { for r in rows where model.isDateReadOnly(r) { fixed += 1 } }
        // Rows i and i+50_000 share content; i % 20 == 0 archives both halves of 2 500 pairs.
        #expect(fixed == 5_000, "\(fixed)")
        #expect(model.archivedContentIndex.rebuildCount == 1)
        let budget = PerformanceLane.debugCeiling(.milliseconds(1_500))
        print("[ArchivedContentIndexTests] seam over 100k: \(seam), fixed \(fixed)")
        #expect(seam < budget, "seam over 100k took \(seam) (budget \(budget))")
        var ruleFixed = 0
        let hoisted = clock.measure {
            let rule = model.dateReadOnlyRule()
            for r in rows where rule.isDateReadOnly(r) { ruleFixed += 1 }
        }
        print("[ArchivedContentIndexTests] pass rule over 100k: \(hoisted) (per-row seam \(seam))")
        #expect(ruleFixed == fixed && model.archivedContentIndex.rebuildCount == 1, "\(ruleFixed)")
        #expect(hoisted < budget, "pass rule over 100k took \(hoisted) (budget \(budget))")

        let twin = rows[1]                     // digest 1, shares with row 50_001 — neither archived
        rows[50_001].lifecycleStage = .archived
        let baseline = twin.snapshotClone()
        twin.userDate = "1992"
        let refusal = clock.measure {
            _ = ArchivedContentDateRefusal.refuse([Self.item(twin, baseline: baseline)], records: rows,
                                                  isArchivedItself: { model.isDateReadOnlyItself($0) },
                                                  owns: { _ in true }, baselinePrints: [:])
        }
        #expect(twin.userDate == nil)
        print("[ArchivedContentIndexTests] commit refusal over 100k: \(refusal)")
        #expect(refusal < budget, "refusal took \(refusal)")
    }

    // MARK: Isolation (poisoned state)

    @Test("ISOLATION: disagreeing fixities, a fixity short of the size, a stale archive root — no twin, no refusal")
    func poisoned() {
        let model = VideoScanModel()
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestGoneDrive",
                                                       rootPath: "/Volumes/TestGoneDrive/Archive")
        let archived = Self.row("a.mov", stage: .archived, digest: W.digestA)
        let disagree = Self.row("d.mov", digest: W.digestA)
        disagree.archiveFixity = ArchiveFixity(digest: W.digestC, verifiedAt: Date(), sizeBytes: 4_096)
        let short = Self.row("s.mov", digest: nil)
        short.contentFixity = W.fixity(W.digestA, 1_000)          // covers 1 000 of 4 096 bytes
        let underStaleRoot = Self.row("u.mov", digest: W.digestC)
        underStaleRoot.fullPath = "/Volumes/TestOtherDrive/Archive/30_Video/u.mov"
        let cTwin = Self.row("c.mov", digest: W.digestC)
        model.records = [archived, disagree, short, underStaleRoot, cTwin]
        #expect(!model.isDateReadOnly(disagree), "two fixities that disagree name no identity")
        #expect(!model.isDateReadOnly(short), "a fixity that does not cover the file is no identity")
        #expect(!model.isDateReadOnly(cTwin), "a path under some OTHER drive's 'Archive' folder is not the archive")
    }

    // MARK: Sensor

    @Test("SENSOR: every archive fact written in place on an indexed row moves VideoRecord.archiveFactsGeneration")
    func everyArchiveFactBumps() {
        let r = VideoRecord()
        let model = VideoScanModel()
        model.records = [r]
        #expect(!r.tracksArchiveFacts, "untracked until an index reads it")
        _ = model.isDateReadOnly(r)                               // the index rebuilds over it
        #expect(r.tracksArchiveFacts, "a rebuild tracks every row it reads")
        #expect(!r.snapshotClone().tracksArchiveFacts, "a clone starts untracked (round 2, P2)")
        let writes: [(String, () -> Void)] = [
            ("lifecycleStage", { r.lifecycleStage = .archived }),
            ("derivationKind", { r.derivationKind = ArchivePromotion.derivationKind }),
            ("fullPath", { r.fullPath = "/Volumes/TestGen/x.mov" }),
            ("removal", { r.removal = .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash) }),
            ("sizeBytes", { r.sizeBytes = 9 }),
            ("contentFixity", { r.contentFixity = W.fixity(W.digestA, 9) }),
            ("archiveFixity", { r.archiveFixity = ArchiveFixity(digest: W.digestA, verifiedAt: Date(), sizeBytes: 9) }),
        ]
        for (name, write) in writes {
            let before = VideoRecord.archiveFactsGeneration
            write()
            #expect(VideoRecord.archiveFactsGeneration != before, "\(name) must bump the generation")
        }
    }
}
