// CleanupTrashPlanTests.swift
// Triage ▸ Cleanup v1 — the PLAN's rules (docs/design/cleanup_kiss_2026_10_12.md),
// ported case by case from tests/test_one_time_cleanup.py and extended with
// codex's design findings. Pure: synthetic rows and disk facts, no files.
//
// Dimensions: LOGIC (each exclusion; the keeper invariant), SCALE (a 100k
// plan under its budget). The disk-facts probe on real files, the move,
// the media matrix and the sensors live in the sibling CleanupTrash* suites.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Cleanup — plan rules")
struct CleanupTrashPlanTests {

    typealias F = CleanupTrashFixture

    // MARK: Copies

    @Test("an identical pair: the SanDisk copy goes, the LaCie copy stays")
    func pairOnRankedDrives() {
        let keep = F.row("/Volumes/LaCieWorkspace/a/clip.mov")
        let extra = F.row("/Volumes/SanDiskWorkspace/b/clip.mov")
        let plan = F.plan([keep, extra])
        #expect(plan.copies.map(\.target.id) == [extra.id])
        #expect(plan.copies.first?.keeper.id == keep.id)
        #expect(plan.copies.first?.digest == "d1")
        #expect(plan.reservedSurvivors.count == 1)
    }

    @Test("groups by the FULL hash and size: same hash, different size are not copies")
    func groupsByDigestAndSize() {
        let a = F.row("/Volumes/LaCieWorkspace/a.mov", size: 100)
        let b = F.row("/Volumes/SanDiskWorkspace/a.mov", size: 101)
        let c = F.row("/Volumes/SanDiskWorkspace/c.mov", size: 100, digest: "other")
        let plan = F.plan([a, b, c])
        #expect(plan.copies.isEmpty)
        #expect(plan.leftAlone.isEmpty, "unique content is not in Cleanup at all")
    }

    @Test("a copy on FamilyArchive is never trimmed, even when it is outranked")
    func familyArchiveCopyNeverATarget() {
        // A precedence list that (wrongly) puts LaCie above FamilyArchive.
        let odd = DuplicateKeeperPolicy(precedence: ["LaCieWorkspace", "FamilyArchive"])
        let lacie = F.row("/Volumes/LaCieWorkspace/a.mov")
        let fa = F.row("/Volumes/FamilyArchive/Movies/a.mov", protection: .archiveVolume)
        let plan = F.plan([lacie, fa], policy: odd)
        #expect(plan.copies.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.familyArchive.key] == 1)
    }

    @Test("FamilyArchive keeps; the copy elsewhere goes")
    func familyArchiveIsTheKeeper() {
        let fa = F.row("/Volumes/FamilyArchive/Movies/a.mov", protection: .archiveVolume)
        let ssd = F.row("/Volumes/SanDiskWorkspace/a.mov")
        let plan = F.plan([fa, ssd])
        #expect(plan.copies.map(\.target.id) == [ssd.id])
        #expect(plan.copies.first?.keeper.id == fa.id)
    }

    @Test("a tie for the copy to keep leaves the WHOLE group alone")
    func tieLeavesGroupAlone() {
        let a = F.row("/Volumes/SanDiskWorkspace/a/c.mov")
        let b = F.row("/Volumes/SanDiskWorkspace/b/c.mov")
        let c = F.row("/Volumes/Unlisted/c.mov")
        let plan = F.plan([a, b, c])
        #expect(plan.copies.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.keeperTie.key] == 3)
        #expect(plan.reservedSurvivors.isEmpty)
    }

    @Test("A/V pair halves, Avid MediaFiles and app libraries are never copies")
    func contentExclusions() {
        let keep = F.row("/Volumes/LaCieWorkspace/a.mxf")
        let pair = F.row("/Volumes/SanDiskWorkspace/x/a.mxf", pair: true)
        let avid = F.row("/Volumes/SanDiskWorkspace/Avid MediaFiles/MXF/1/a.mxf")
        let omfi = F.row("/Volumes/SanDiskWorkspace/OMFI MediaFiles/a.mxf")
        let lib = F.row("/Volumes/SanDiskWorkspace/Photos Library.photoslibrary/originals/a.mxf")
        let plan = F.plan([keep, pair, avid, omfi, lib])
        #expect(plan.copies.isEmpty)
        let r = F.reasons(plan)
        #expect(r[CleanupExclusion.pairHalf.key] == 1)
        #expect(r[CleanupExclusion.avidMediaFiles.key] == 2)
        #expect(r[CleanupExclusion.appLibrary.key] == 1)
    }

    @Test("archived rows and Read-only drives are never copies")
    func archivedAndProtected() {
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov")
        let archived = F.row("/Volumes/SanDiskWorkspace/x/a.mov", archived: true)
        let ro = F.row("/Volumes/SanDiskWorkspace/y/a.mov", protection: .other("lives on X, which you marked Read only"))
        let plan = F.plan([keep, archived, ro])
        #expect(plan.copies.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.archived.key] == 1)
        #expect(plan.leftAlone[.protected("lives on X, which you marked Read only")]?.files == 1)
    }

    @Test("a copy carrying more of Rick's HAND marks than the keeper stays, and the reason says what it saw")
    func humanMarksStay() {
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov")
        let starred = F.row("/Volumes/SanDiskWorkspace/a.mov", marks: CleanupHandMarks(stars: 1))
        let plan = F.plan([keep, starred])
        #expect(plan.copies.isEmpty)
        #expect(plan.leftAlone[.carriesYourMarks("stars")]?.files == 1, "\(plan.leftAlone.keys.map(\.words))")
        let dated = F.row("/Volumes/SanDiskWorkspace/b.mov", digest: "d2", marks: CleanupHandMarks(hasDate: true, noteLines: 1))
        let keep2 = F.row("/Volumes/LaCieWorkspace/b.mov", digest: "d2", marks: CleanupHandMarks(stars: 3))
        let plan2 = F.plan([keep2, dated])
        #expect(plan2.leftAlone[.carriesYourMarks("a date, notes")]?.files == 1, "\(plan2.leftAlone.keys.map(\.words))")
        #expect(CleanupExclusion.carriesYourMarks("stars").words == "has stars the kept copy lacks")
    }

    @Test("dry run 2026-10-12: machine stamps are not marks — a Reconcile line, ffprobe stderr, a recipe line, Migrate's originalFullPath")
    func machineStampsAreNotMarks() {
        let machine = """
            Reconcile 2026-09-20T10:00:00Z: source file not found
            ffprobe: Unsupported codec with id 98314 for input stream 1
            [mov,mp4,m4a,3gp,3g2,mj2 @ 0x7e3018000] moov atom not found
            FindPerson(Donna Recipe): detected Donna* at 00:12
            """
        #expect(CleanupHandMarks.humanNoteLines(machine) == 0)
        #expect(CleanupHandMarks.humanNoteLines(machine + "\nDad's 50th, the porch") == 1)
        #expect(CleanupHandMarks.humanNoteLines("") == 0)
        // Only machine stamps on the copy: it is still a candidate.
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov")
        let stamped = F.row("/Volumes/SanDiskWorkspace/a.mov",
                            marks: CleanupHandMarks(noteLines: CleanupHandMarks.humanNoteLines(machine)))
        #expect(F.plan([keep, stamped]).copies.map(\.target.id) == [stamped.id])
        #expect(CleanupHandMarks.none.lacking(in: .none) == nil)
    }

    @Test("a path through a symlinked folder is never kept or removed")
    func throughLink() {
        let keep = F.row("/Volumes/LaCieWorkspace/real/c.mov")
        let via = F.row("/Users/rickb/Movies/Link/c.mov")
        let plan = F.plan([keep, via], facts: [via.path: .throughLink(nil)])
        #expect(plan.copies.isEmpty)
        let r = F.reasons(plan)
        #expect(r[CleanupExclusion.throughLink.key] == 1)
        #expect(r[CleanupExclusion.onlyUsableCopy.key] == 1)
    }

    @Test("two rows naming one file (hard link / same inode) — neither name is removed")
    func sameInode() {
        let shared = F.stamp(inode: 42, size: 1_000)
        let a = F.row("/Volumes/SanDiskWorkspace/a/clip.mov")
        let b = F.row("/Volumes/SanDiskWorkspace/b/clip.mov")
        let plan = F.plan([a, b], facts: [a.path: .file(shared), b.path: .file(shared)])
        #expect(plan.copies.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.sameFileAsAnotherRow.key] == 1)
        #expect(F.reasons(plan)[CleanupExclusion.onlyUsableCopy.key] == 1)
    }

    @Test("a case-only spelling of the keeper's path is the same file — the alias never goes")
    func caseVariantAlias() {
        let keepStamp = F.stamp(inode: 9, size: 1_000)
        let keep = F.row("/Volumes/LaCieWorkspace/Trip/clip.mov")
        let alias = F.row("/Volumes/LaCieWorkspace/trip/CLIP.mov")
        let extra = F.row("/Volumes/SanDiskWorkspace/clip.mov")
        let plan = F.plan([keep, alias, extra], facts: [keep.path: .file(keepStamp), alias.path: .file(keepStamp)])
        #expect(plan.copies.map(\.target.id) == [extra.id], "the real extra copy still goes")
        #expect(!plan.copies.contains { $0.target.id == alias.id || $0.target.id == keep.id })
        #expect(plan.reservedSurvivors == [CleanupPhysicalID(keepStamp)])
    }

    @Test("a target that is the same file as a row in ANOTHER group is left alone")
    func aliasAcrossGroups() {
        let shared = F.stamp(inode: 77, size: 1_000)
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov", digest: "d1")
        let extra = F.row("/Volumes/SanDiskWorkspace/a.mov", digest: "d1")
        let staleTwin = F.row("/Volumes/SanDiskWorkspace/other-name.mov", digest: "stale")
        let staleKeep = F.row("/Volumes/LaCieWorkspace/other-name.mov", digest: "stale")
        let plan = F.plan([keep, extra, staleTwin, staleKeep], facts: [extra.path: .file(shared), staleTwin.path: .file(shared)])
        #expect(plan.copies.isEmpty, "\(plan.copies.map(\.target.path))")
    }

    @Test("codex r2 F3: an alias through a linked folder carries its REAL file's identity into the index — the canonical row is ambiguous, the alias is not a candidate")
    func aliasThroughLinkIndexesItsRealFile() {
        let shared = F.stamp(inode: 91, size: 1_000)
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov", digest: "d1")
        let extra = F.row("/Volumes/SanDiskWorkspace/a.mov", digest: "d1")
        let alias = F.row("/Users/rickb/Movies/Link/a.mov", digest: nil)
        let plan = F.plan([keep, extra, alias], facts: [extra.path: .file(shared), alias.path: .throughLink(shared)])
        #expect(plan.copies.isEmpty, "\(plan.copies.map(\.target.path))")
        #expect(F.reasons(plan)[CleanupExclusion.sameFileAsAnotherRow.key] == 1)
        // A dangling link names nothing.
        let dangling = F.plan([keep, extra, alias], facts: [extra.path: .file(shared), alias.path: .throughLink(nil)])
        #expect(dangling.copies.map(\.target.id) == [extra.id])
    }

    @Test("codex r1 P2-3: a candidate sharing its physical file with ANY other active row is left alone — unhashed, singleton stale-hash, or set-aside")
    func aliasAcrossAllActiveRows() {
        let shared = F.stamp(inode: 88, size: 1_000)
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov", digest: "d1")
        let extra = F.row("/Volumes/SanDiskWorkspace/a.mov", digest: "d1")
        let cases: [(String, CleanupRow)] = [
            ("unhashed", F.row("/Volumes/SanDiskWorkspace/other-name.mov", digest: nil)),
            ("singleton stale hash", F.row("/Volumes/SanDiskWorkspace/stale.mov", digest: "stale-only")),
            ("set aside", F.row("/Volumes/SanDiskWorkspace/aside.mov", digest: nil, setAside: true)),
        ]
        for (what, alias) in cases {
            let plan = F.plan([keep, extra, alias], facts: [extra.path: .file(shared), alias.path: .file(shared)])
            #expect(plan.copies.isEmpty, "\(what): the extra copy has another name in the catalog — \(plan.copies.map(\.target.path))")
            #expect(F.reasons(plan)[CleanupExclusion.sameFileAsAnotherRow.key] == 1, "\(what): \(F.reasons(plan))")
        }
    }

    @Test("the best copy's drive is not connected: the keeper is elected among connected copies only")
    func offlineMemberNeverKeeper() {
        let offline = F.row("/Volumes/FamilyArchive/a.mov", protection: .archiveVolume)
        let lacie = F.row("/Volumes/LaCieWorkspace/a.mov")
        let ssd = F.row("/Volumes/SanDiskWorkspace/a.mov")
        let plan = F.plan([offline, lacie, ssd], facts: [offline.path: .driveNotConnected])
        #expect(plan.copies.map(\.target.id) == [ssd.id])
        #expect(plan.copies.first?.keeper.id == lacie.id)
        #expect(F.reasons(plan)[CleanupExclusion.driveNotConnected.key] == 1)
    }

    @Test("missing, changed size, not a plain file, set aside")
    func diskAndCatalogStates() {
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov")
        let gone = F.row("/Volumes/SanDiskWorkspace/1/a.mov")
        let grown = F.row("/Volumes/SanDiskWorkspace/2/a.mov")
        let fifo = F.row("/Volumes/SanDiskWorkspace/3/a.mov")
        let aside = F.row("/Volumes/SanDiskWorkspace/4/a.mov", setAside: true)
        let plan = F.plan([keep, gone, grown, fifo, aside],
                          facts: [gone.path: .missing, grown.path: .file(F.stamp(inode: 5, size: 2_000)),
                                  fifo.path: .notRegularFile])
        #expect(plan.copies.isEmpty)
        let r = F.reasons(plan)
        #expect(r[CleanupExclusion.missing.key] == 1)
        #expect(r[CleanupExclusion.sizeChanged.key] == 1)
        #expect(r[CleanupExclusion.notRegularFile.key] == 1)
        #expect(r[CleanupExclusion.setAside.key] == 1)
        #expect(r[CleanupExclusion.onlyUsableCopy.key] == 1)
    }

    @Test("rows with no stored full hash are 'Not checked yet' — counted, never planned")
    func notCheckedYet() {
        let a = F.row("/Volumes/LaCieWorkspace/a.mov", size: 10, digest: nil)
        let b = F.row("/Volumes/SanDiskWorkspace/a.mov", size: 20, digest: nil)
        let plan = F.plan([a, b])
        #expect(plan.copies.isEmpty)
        #expect(plan.notChecked == CleanupPlan.Tally(files: 2, bytes: 30))
    }

    @Test("two files naming each other: exactly one goes, and its keeper is the other")
    func twoFilesNamingEachOther() {
        let a = F.row("/Volumes/LaCieWorkspace/a.mov")
        let b = F.row("/Volumes/SanDiskWorkspace/b.mov")
        for order in [[a, b], [b, a]] {
            let plan = F.plan(order)
            #expect(plan.copies.count == 1)
            let copy = plan.copies[0]
            #expect(copy.target.id == b.id && copy.keeper.id == a.id)
            #expect(!plan.copies.contains { $0.target.id == copy.keeper.id })
        }
    }

    // MARK: Junk

    @Test("junk you marked: other drives → Junk; FamilyArchive → the tick-box list; archive tree → never")
    func junkLanes() {
        let j1 = F.row("/Volumes/SanDiskWorkspace/j1.mov", digest: nil, junk: true)
        let jFA = F.row("/Volumes/FamilyArchive/Jams/loop.aif", digest: nil, junk: true, protection: .archiveVolume)
        let jTree = F.row("/Volumes/FamilyArchive/Breen_Family_Archive/x.mov", digest: nil, junk: true, protection: .archiveTree)
        let jArch = F.row("/Volumes/SanDiskWorkspace/promoted.mov", digest: nil, junk: true, archived: true)
        let jPair = F.row("/Volumes/SanDiskWorkspace/v.mxf", digest: nil, junk: true, pair: true)
        let jRO = F.row("/Volumes/RO/x.mov", digest: nil, junk: true, protection: .other("read only"))
        // In the archive root folder by NAME, though the gate called it the
        // volume (a spelling that hid it from the tree check): never.
        let jByName = F.row("/Volumes/FamilyArchive 1/Breen_Family_Archive/1990s/y.mov", digest: nil, junk: true,
                            protection: .archiveVolume)
        // …and the same net is case-insensitive, like the volumes (QA P3).
        let jByNameLower = F.row("/Volumes/FamilyArchive 1/breen_family_archive/1990s/z.mov", digest: nil, junk: true,
                                 protection: .archiveVolume)
        #expect(CleanupPathRules.isInArchiveRootFolder(jByNameLower.path))
        #expect(!CleanupPathRules.isInArchiveRootFolder("/Volumes/X/Breen_Family_Archive_old/a.mov"))
        let plan = F.plan([j1, jFA, jTree, jArch, jPair, jRO, jByName, jByNameLower])
        #expect(plan.junk.map(\.id) == [j1.id])
        #expect(plan.archiveJunk.map(\.id) == [jFA.id])
        // codex r1 P3-7: the page's numbers are on the plan, summed once.
        #expect(plan.junkBytes == j1.sizeBytes && plan.archiveJunkBytes == jFA.sizeBytes)
        #expect(plan.leftAloneTotal.files == plan.leftAlone.values.reduce(0) { $0 + $1.files })
        #expect(plan.leftAloneSorted.count == plan.leftAlone.count)
        let r = F.reasons(plan)
        #expect(r[CleanupExclusion.archived.key] == 4)
        #expect(r[CleanupExclusion.pairHalf.key] == 1)
        #expect(plan.leftAlone[.protected("read only")]?.files == 1)
    }

    @Test("a copy group whose content is also marked junk is left alone; the junk row may go")
    func copyGroupWithJunkMember() {
        let junk = F.row("/Volumes/LaCieWorkspace/a/c.mov", junk: true)
        let keep = F.row("/Volumes/LaCieWorkspace/b/c.mov")
        let extra = F.row("/Volumes/SanDiskWorkspace/c/c.mov")
        let plan = F.plan([junk, keep, extra])
        #expect(plan.copies.isEmpty)
        #expect(plan.junk.map(\.id) == [junk.id])
        #expect(F.reasons(plan)[CleanupExclusion.copyIsJunk.key] == 2)
    }

    @Test("a junk row that names a keeper's physical file never goes")
    func junkAliasingAKeeper() {
        let keepStamp = F.stamp(inode: 3, size: 1_000)
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov", digest: "d1")
        let extra = F.row("/Volumes/SanDiskWorkspace/a.mov", digest: "d1")
        let junkAlias = F.row("/Volumes/LaCieWorkspace/A.mov", digest: nil, junk: true)
        let plan = F.plan([keep, extra, junkAlias], facts: [keep.path: .file(keepStamp), junkAlias.path: .file(keepStamp)])
        #expect(plan.copies.map(\.target.id) == [extra.id])
        #expect(plan.junk.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.survivorOfAnother.key] == 1)
    }

    @Test("two junk rows naming one file: neither goes")
    func junkSameFile() {
        let s = F.stamp(inode: 11, size: 1_000)
        let a = F.row("/Volumes/SanDiskWorkspace/x.mov", digest: nil, junk: true)
        let b = F.row("/Volumes/SanDiskWorkspace/X.mov", digest: nil, junk: true)
        let plan = F.plan([a, b], facts: [a.path: .file(s), b.path: .file(s)])
        #expect(plan.junk.isEmpty)
        #expect(F.reasons(plan)[CleanupExclusion.sameFileAsAnotherRow.key] == 2)
    }

    // MARK: The keeper invariant

    @Test("INVARIANT: no keeper — by row or by physical file — is ever in a removal list (2,000 random catalogs)")
    func keeperNeverInRemovalSet() {
        var rng = SeededGenerator(seed: 20_261_012)
        let drives = ["FamilyArchive", "LaCieWorkspace", "SanDiskWorkspace", "Unlisted", "Other"]
        for _ in 0..<2_000 {
            var rows: [CleanupRow] = []
            var facts: [String: CleanupDiskFacts] = [:]
            for i in 0..<Int.random(in: 2...9, using: &rng) {
                let drive = drives.randomElement(using: &rng) ?? "Other"
                let path = "/Volumes/\(drive)/f\(i).mov"
                let digests: [String?] = ["d1", "d2", nil]
                let row = F.row(path, digest: digests[Int.random(in: 0..<digests.count, using: &rng)],
                                junk: Int.random(in: 0..<5, using: &rng) == 0,
                                protection: drive == "FamilyArchive" ? .archiveVolume : nil,
                                marks: Int.random(in: 0..<3, using: &rng) == 0 ? CleanupHandMarks(stars: 1) : .none)
                rows.append(row)
                // A few physical files shared between rows (aliases).
                facts[path] = .file(F.stamp(inode: UInt64(Int.random(in: 0..<6, using: &rng)), size: 1_000))
            }
            let plan = F.plan(rows, facts: facts)
            let keeperIDs = Set(plan.copies.map(\.keeper.id))
            let removal = plan.copies.map(\.target) + plan.junk + plan.archiveJunk
            #expect(removal.allSatisfy { !keeperIDs.contains($0.id) })
            #expect(removal.allSatisfy { !plan.reservedSurvivors.contains(CleanupPhysicalID($0.identity)) })
            #expect(Set(removal.map { CleanupPhysicalID($0.identity) }).count == removal.count, "one physical file, at most one removal")
            let selection = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: true)
            #expect(selection.copies.allSatisfy { !keeperIDs.contains($0.target.id) })
        }
    }

    // MARK: Selection

    @Test("the frozen selection: unticked files and the FamilyArchive list (tick box off) stay out")
    func selection() {
        let keep = F.row("/Volumes/LaCieWorkspace/a.mov")
        let extra = F.row("/Volumes/SanDiskWorkspace/a.mov")
        let j = F.row("/Volumes/SanDiskWorkspace/j.mov", digest: nil, junk: true)
        let jFA = F.row("/Volumes/FamilyArchive/j.mov", digest: nil, junk: true, protection: .archiveVolume)
        let plan = F.plan([keep, extra, j, jFA])
        let off = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        #expect(off.count == 2 && off.archiveJunk.isEmpty)
        let on = CleanupSelection(plan: plan, unticked: [j.id], includeArchiveJunk: true)
        #expect(on.copies.count == 1 && on.junk.isEmpty && on.archiveJunk.map(\.id) == [jFA.id])
        let none = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false, includeCopies: false, includeJunk: false)
        #expect(none.isEmpty)
        #expect(off.bytesToRead == 2 * 1_000, "each copy AND its keeper are read")
    }

    @Test("the selection drops a corrupted plan's keeper-as-target (belt and braces)")
    func selectionRefusesKeeperTargets() {
        let s = F.stamp(inode: 1, size: 10)
        let k = CleanupFile(id: UUID(), path: "/k", filename: "k", volumeName: "", sizeBytes: 10, identity: s)
        let t = CleanupFile(id: UUID(), path: "/t", filename: "t", volumeName: "", sizeBytes: 10, identity: F.stamp(inode: 2, size: 10))
        var plan = CleanupPlan()
        plan.copies = [CleanupPlan.Copy(target: t, keeper: k, digest: "d"), CleanupPlan.Copy(target: k, keeper: t, digest: "d")]
        plan.reservedSurvivors = [CleanupPhysicalID(s)]
        plan.junk = [k]
        let sel = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: true)
        #expect(sel.copies.isEmpty, "both targets are some copy's keeper")
        #expect(sel.junk.isEmpty)
    }

    // MARK: Words

    @Test("words: the button and the tick box")
    func words() {
        #expect(CleanupWords.actionTitle(.init(files: 1, bytes: 1_000_000_000)).hasPrefix("Move 1 file ("))
        #expect(CleanupWords.actionTitle(.init(files: 2, bytes: 0)).hasPrefix("Move 2 files ("))
        #expect(CleanupWords.archiveJunkToggle(3) == "Unlock FamilyArchive for this run — also move these 3 confirmed-junk files")
        #expect(CleanupWords.archiveJunkToggle(1) == "Unlock FamilyArchive for this run — also move this 1 confirmed-junk file")
        #expect(CleanupWords.readNote(0) == nil)
        #expect(CleanupWords.readTime(7_200 * 200_000_000) == "about 2.0 hours")
    }

    // MARK: Scale

    @Test("SCALE: a 100k-row catalog plans within budget", .timeLimit(.minutes(1)))
    func scale100k() {
        var rows: [CleanupRow] = []
        rows.reserveCapacity(100_000)
        for i in 0..<100_000 {
            switch i % 10 {
            case 0..<4:   // 20k pairs of copies
                let drive = i % 2 == 0 ? "LaCieWorkspace" : "SanDiskWorkspace"
                rows.append(F.row("/Volumes/\(drive)/c\(i).mov", digest: "g\(i / 2)"))
            case 4: rows.append(F.row("/Volumes/SanDiskWorkspace/j\(i).mov", digest: nil, junk: true))
            case 5: rows.append(F.row("/Volumes/SanDiskWorkspace/n\(i).mov", digest: nil))
            default: rows.append(F.row("/Volumes/LaCieWorkspace/u\(i).mov", digest: "u\(i)"))
            }
        }
        let policy = F.policy
        let clock = ContinuousClock()
        var plan = CleanupPlan()
        let elapsed = clock.measure {
            var inode: UInt64 = 0
            plan = CleanupPlanner.plan(rows: rows, facts: { _ in inode += 1; return .file(F.stamp(inode: inode, size: 1_000)) },
                                       rank: { policy.volumeRank(forPath: $0) })
        }
        #expect(plan.copies.count == 20_000)
        #expect(plan.junk.count == 10_000)
        #expect(plan.notChecked.files == 10_000)
        #expect(elapsed < .seconds(5), "100k plan took \(elapsed)")
        let sel = CleanupSelection(plan: plan, unticked: [], includeArchiveJunk: false)
        #expect(sel.count == 30_000)
    }
}
