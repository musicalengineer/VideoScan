// CatalogArchivedInsideRootTests.swift
// "Not yet archived" — one definition of archived (Rick 2026-09-11): a
// promoted copy, a source with a master copy, or anything living inside
// the Master Archive root. The live catalog had 18 `.vs.*` versions
// written straight into the archive folders with no promotion record;
// they sat in the to-do view while Promote refused them ("already lives
// inside the archive tree"). LOGIC + SCALE + a sensor that the rule is
// root-based, not drive-based.

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog — inside the Master Archive root counts as archived")
@MainActor
struct CatalogArchivedInsideRootTests {

    private static let root = "/Volumes/TestArchive/Breen_Family_Archive"

    private func model(designated: Bool = true) -> VideoScanModel {
        let m = VideoScanModel()
        if designated {
            m.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: Self.root)
        }
        return m
    }

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    @Test("a stray inside the root — no promotion record — is archived; the same file outside is not")
    func strayInsideRootIsArchived() {
        let m = model()
        let stray = record(Self.root + "/30_Video/1990-1999/1998/CapeCodJune1998-Peekaboo.vs.preserve.mkv")
        let source = record("/Volumes/CrucialX10/editable_versions/CapeCodJune1998-Peekaboo.vs.preserve.mkv")
        let copy = record(Self.root + "/30_Video/1990-1999/1998/1998-xx-xx_CapeCodJune1998-Peekaboo.dv")
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        m.records = [stray, source, copy]

        #expect(!m.isArchiveCopy(stray), "the stray is NOT a promoted copy")
        #expect(!m.pfNotYetArchived(stray), "…but it lives in the archive tree, so it is archived")
        #expect(!m.pfHasMasterCopy(stray), "and it has no master copy of its own")
        #expect(!m.pfNotYetArchived(copy), "a promoted copy stays archived")
        #expect(!m.pfNotYetArchived(source), "its source has a master copy")
        let other = record("/Volumes/CrucialX10/other/Untouched.mov")
        m.records = [stray, source, copy, other]
        #expect(m.pfNotYetArchived(other), "an ordinary source is still to-do")
    }

    @Test("sensor: the rule is the archive ROOT, not the drive — a scratch folder on the archive volume is still to-do")
    func rootNotDrive() {
        let m = model()
        let scratch = record("/Volumes/TestArchive/Scratch/render.mov")
        let sibling = record("/Volumes/TestArchive/Breen_Family_Archive_old/x.mov")
        m.records = [scratch, sibling]
        #expect(m.pfNotYetArchived(scratch))
        #expect(m.pfNotYetArchived(sibling), "a sibling folder sharing the root's prefix is outside (component-wise)")
    }

    @Test("a dotted path inside the root still counts (the prefix fast path must not reject it)")
    func dottedPathInsideRoot() {
        let m = model()
        let dotted = record("/Volumes/TestArchive/./Breen_Family_Archive/30_Video/x.mov")
        let climbed = record("/Volumes/TestArchive/Scratch/../Breen_Family_Archive/30_Video/y.mov")
        m.records = [dotted, climbed]
        #expect(!m.pfNotYetArchived(dotted))
        #expect(!m.pfNotYetArchived(climbed))
    }

    @Test("no Master Archive designated: nothing is inside anything")
    func undesignated() {
        let m = model(designated: false)
        let stray = record(Self.root + "/30_Video/x.vs.archive.mov")
        m.records = [stray]
        #expect(m.pfNotYetArchived(stray))
    }

    @Test("a VERSION of something archived is not to-do; a repair of it still is (Rick: 'or copied to Projects')")
    func versionsOfArchivedAreHidden() {
        let m = model()
        let source = record("/Volumes/CrucialX10/originals/Peekaboo.dv")
        let copy = record(Self.root + "/30_Video/1990-1999/1998/1998-xx-xx_Peekaboo.dv")
        copy.derivedFrom = source.id; copy.derivationKind = ArchivePromotion.derivationKind
        // Balanced audio made FROM the archive copy (the live shape on CrucialX10).
        let balanced = record("/Volumes/CrucialX10/editable_versions/Peekaboo.vs.preserve_balanced.mkv")
        balanced.derivedFrom = copy.id; balanced.derivationKind = BalanceAudioFix.derivationKind
        // A trim made from the SOURCE (which has a master copy).
        let trimmed = record("/Volumes/Projects/edits/Peekaboo_trimmed.mov")
        trimmed.derivedFrom = source.id; trimmed.derivationKind = TrimPlan.derivationKind
        // An older transcode with no kind stamp, two hops up to the source.
        let transcode = record("/Volumes/Projects/edits/Peekaboo.vs.edit.mov")
        transcode.derivedFrom = trimmed.id
        // Repairs of the archived original stay visible.
        let repair = record("/Volumes/Projects/repairs/Peekaboo_repaired.mov")
        repair.derivedFrom = source.id; repair.derivationKind = ExternalRepairAdoption.derivationKind
        let rebuilt = record("/Volumes/Projects/repairs/Peekaboo_rebuilt.mov")
        rebuilt.derivedFrom = copy.id; rebuilt.derivationKind = RebuildAudioFix.derivationKind
        // A version of something NOT archived is still to-do.
        let loose = record("/Volumes/CrucialX10/originals/Loose.dv")
        let looseBalanced = record("/Volumes/Projects/edits/Loose_balanced.mkv")
        looseBalanced.derivedFrom = loose.id; looseBalanced.derivationKind = BalanceAudioFix.derivationKind
        m.records = [source, copy, balanced, trimmed, transcode, repair, rebuilt, loose, looseBalanced]

        #expect(!m.pfNotYetArchived(balanced), "balanced audio of an archive copy")
        #expect(!m.pfNotYetArchived(trimmed), "trim of a source that has a master copy")
        #expect(!m.pfNotYetArchived(transcode), "unstamped transcode, two hops up")
        #expect(m.pfNotYetArchived(repair), "external repair is a candidate in its own right")
        #expect(m.pfNotYetArchived(rebuilt), "rebuilt audio likewise")
        #expect(m.pfNotYetArchived(loose) && m.pfNotYetArchived(looseBalanced), "nothing archived up that chain")
    }

    @Test("derivedFrom cycles and dangling ids never loop or crash")
    func derivedChainSafety() {
        let m = model()
        let a = record("/Volumes/X/a.mov"); let b = record("/Volumes/X/b.mov")
        a.derivedFrom = b.id; b.derivedFrom = a.id
        let dangling = record("/Volumes/X/c.mov"); dangling.derivedFrom = UUID()
        m.records = [a, b, dangling]
        #expect(m.pfNotYetArchived(a) && m.pfNotYetArchived(b) && m.pfNotYetArchived(dangling))
    }

    @Test("SCALE: 100k records with a designated root — the filter predicate stays under budget", .timeLimit(.minutes(1)))
    func scale() {
        let m = model()
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            // 1 in 50 lives in the archive tree (the expensive branch).
            let inside = i % 50 == 0
            records.append(record(inside
                ? Self.root + "/30_Video/2000-2009/2005/clip_\(i).mov"
                : "/Volumes/Src/folder_\(i % 97)/clip_\(i).mov"))
        }
        m.records = records
        let t0 = CFAbsoluteTimeGetCurrent()
        var notYet = 0
        for r in records where m.pfNotYetArchived(r) { notYet += 1 }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(notYet == 98_000)
        #expect(ms < 1_500, "100k predicate calls took \(Int(ms)) ms — budget 1.5 s")
    }
}
