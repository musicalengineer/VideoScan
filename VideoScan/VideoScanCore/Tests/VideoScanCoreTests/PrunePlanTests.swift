// PrunePlanTests.swift
// LOGIC + SCALE for the simple prune plan (docs/design/pruneplan_simple_2026-10-21.md).
// Rick's rule: offer byte-identical copies of a verified archive file; for
// everything else say "no obvious choices" and why.
//
//   * R1 — only a copy whose digest equals a VERIFIED archive digest is offered;
//   * R2–R5 — a hold the app captured is the row's reason, never offered;
//   * every "no obvious choices" reason, in the doc's words;
//   * I6 — a version or a name-alike is never offered, whatever else is true;
//   * missing / network asked only of offered rows (off-main in the app);
//   * the 200-row cap: offered rows first, the rest counted, never offered;
//   * advice: "N files will exist only in the Master Archive", naming those
//     with no cloud / off-site "yes";
//   * SCALE: 100k snapshots built under a time budget.

import XCTest
@testable import VideoScanCore

final class PrunePlanTests: XCTestCase {

    private let digest = String(repeating: "a", count: 64)
    private let other = String(repeating: "b", count: 64)

    private func archive(_ name: String = "tape.mov", digest: String?, source: UUID? = nil,
                         id: UUID = UUID(), attestations: [BackupAttestation] = []) -> PruneSnapshot {
        PruneSnapshot(id: id, filename: name, fullPath: "/Volumes/FamilyArchive/Archive/\(name)",
                      volumeName: "FamilyArchive", sizeBytes: 1_000, digest: digest, isArchive: true,
                      derivedFrom: source, attestations: attestations)
    }

    private func copy(_ name: String = "tape.mov", vol: String = "LaCie", digest: String?, id: UUID = UUID(),
                      derivedFrom: UUID? = nil, hold: PruneReason? = nil,
                      attestations: [BackupAttestation] = []) -> PruneSnapshot {
        PruneSnapshot(id: id, filename: name, fullPath: "/Volumes/\(vol)/\(name)", volumeName: vol,
                      sizeBytes: 1_000, digest: digest, derivedFrom: derivedFrom, hold: hold, attestations: attestations)
    }

    private func reason(_ plan: PrunePlan, _ id: UUID) -> PruneReason?? {
        plan.items.flatMap(\.rows).first { $0.id == id }.map(\.reason)
    }

    // MARK: Words

    func testTheReasonWordsAreTheDesignTable() {
        XCTAssertEqual(PruneReason.allCases.map(\.text), [
            "not in the Master Archive yet",
            "the archive copy hasn't been verified yet",
            "a version, not the same bytes",
            "same name, different footage",
            "not hashed yet",
            "drive not connected",
            "drive is protected",
            "part of a recovered A/V pair",
            "not found where the catalog says",
            "not the same bytes as the archive copy — kept",
        ])
    }

    // MARK: R1

    func testR1AnIdenticalCopyOfAVerifiedArchiveFileIsOffered() {
        let a = archive(digest: digest)
        let c = copy(digest: digest)
        let plan = PrunePlan.build([a, c])
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.offeredIDs, [c.id])
        XCTAssertEqual(plan.items[0].offered.first?.isIdentical, true)
        XCTAssertFalse(plan.items[0].rows.contains { $0.id == a.id }, "the archive file is never a row")
    }

    func testR1AnUnverifiedArchiveFileOffersNothing() {
        let source = UUID()
        let a = archive(digest: nil, source: source)
        let src = copy(digest: digest, id: source)
        let same = copy("tape.mov", vol: "Crucial", digest: digest)
        let plan = PrunePlan.build([a, src, same], batch: [source])
        XCTAssertTrue(plan.offeredIDs.isEmpty)
        XCTAssertEqual(reason(plan, src.id), .some(.archiveUnverified))
        XCTAssertEqual(reason(plan, same.id), .some(.archiveUnverified), "same name, but the archive has no verified digest")
        XCTAssertEqual(plan.items.first?.archive.reason, .archiveUnverified)
    }

    func testR1ADifferentDigestIsNeverIdentical() {
        let a = archive(digest: digest)
        let c = copy(digest: other)
        let plan = PrunePlan.build([a, c], batch: [c.id])
        XCTAssertTrue(plan.offeredIDs.isEmpty)
        XCTAssertEqual(plan.unarchived.map(\.id), [c.id], "a same-name copy with other bytes in a batch is not archived")
        let catalog = PrunePlan.build([a, c])
        XCTAssertTrue(catalog.items.isEmpty, "catalog-wide, an item with no identical copy is not listed")
    }

    // MARK: R2–R5 — the hold the app captured is the reason

    func testR2toR5AHeldIdenticalCopyIsListedWithItsReasonAndNeverOffered() {
        for hold in [PruneReason.driveOffline, .driveProtected, .pairHalf, .missing] {
            let a = archive(digest: digest)
            let c = copy(digest: digest, hold: hold)
            let plan = PrunePlan.build([a, c])
            XCTAssertTrue(plan.offeredIDs.isEmpty, "\(hold)")
            XCTAssertEqual(reason(plan, c.id), .some(hold))
            XCTAssertEqual(plan.items.first?.rows.first?.isIdentical, true, "still the same bytes — \(hold)")
        }
    }

    // MARK: No obvious choices

    func testVersionsNameAlikesAndUnhashedCopiesAreNamedNotOffered() {
        let source = UUID()
        let a = archive(digest: digest, source: source)
        let src = copy("tape.mov", vol: "M4drive", digest: other, id: source)       // promoted from, other bytes (a transcode)
        let trim = copy("tape_trimmed.mov", digest: other, derivedFrom: source)     // cut from the source
        let trimUnhashed = copy("tape_t2.mov", digest: nil, derivedFrom: a.id)      // cut from the archive file
        let sameName = copy("TAPE.MOV", vol: "Crucial", digest: other)
        let sameNameUnhashed = copy("tape.mov", vol: "Projects", digest: nil)
        let plan = PrunePlan.build([a, src, trim, trimUnhashed, sameName, sameNameUnhashed], batch: [source])
        XCTAssertTrue(plan.offeredIDs.isEmpty)
        XCTAssertEqual(reason(plan, src.id), .some(.version))
        XCTAssertEqual(reason(plan, trim.id), .some(.version))
        XCTAssertEqual(reason(plan, trimUnhashed.id), .some(.notHashed))
        XCTAssertEqual(reason(plan, sameName.id), .some(.sameNameDifferentFootage))
        XCTAssertEqual(reason(plan, sameNameUnhashed.id), .some(.notHashed))
    }

    func testABatchRecordWithNoArchiveFileIsNotPromotedYet() {
        let lone = copy("other.mov", digest: other)
        let plan = PrunePlan.build([archive(digest: digest), lone], batch: [lone.id])
        XCTAssertEqual(plan.unarchived.map(\.reason), [.notPromoted])
        XCTAssertTrue(plan.items.isEmpty)
    }

    /// I6: whatever a related copy's other facts are, it is never offered;
    /// every offered row carries its item's verified digest.
    func testI6OnlyTheArchiveDigestEverReachesTheOfferedList() {
        let source = UUID()
        let a = archive(digest: digest, source: source)
        var snaps = [a]
        for i in 0..<50 {
            let d: String? = [nil, other, digest][i % 3]
            snaps.append(copy(i % 2 == 0 ? "tape.mov" : "x\(i).mov", vol: "V\(i)", digest: d,
                              derivedFrom: i % 5 == 0 ? source : nil))
        }
        let plan = PrunePlan.build(snaps)
        let byID = Dictionary(uniqueKeysWithValues: snaps.map { ($0.id, $0) })
        for item in plan.items {
            for row in item.offered {
                XCTAssertEqual(byID[row.id]?.digest, item.digest, "an offered row is byte-identical by digest")
                XCTAssertNotNil(item.digest)
            }
        }
        XCTAssertEqual(plan.offeredCount, snaps.filter { $0.digest == digest && !$0.isArchive }.count)
    }

    // MARK: Disk facts (asked off-main by the app)

    func testMissingAndNetworkAreAskedOnlyOfOfferedRows() {
        let a = archive(digest: digest)
        let gone = copy(vol: "M4drive", digest: digest)
        let share = copy(vol: "NAS", digest: digest)
        let fine = copy(vol: "LaCie", digest: digest)
        let offline = copy(vol: "Offline", digest: digest, hold: .driveOffline)
        var asked: [String] = []
        let plan = PrunePlan.build([a, gone, share, fine, offline])
            .confirmingOnDisk(isMissing: { asked.append($0); return $0 == gone.fullPath },
                              isNetwork: { $0 == share.fullPath })
        XCTAssertEqual(reason(plan, gone.id), .some(.missing))
        XCTAssertEqual(reason(plan, share.id), .some(.driveProtected))
        XCTAssertEqual(plan.offeredIDs, [fine.id])
        XCTAssertFalse(asked.contains(offline.fullPath), "a held row is never stat'ed")
    }

    // MARK: Scope

    func testBatchScopeListsTheBatchsItemsCatalogScopeListsItemsWithACopy() {
        let s1 = UUID(), s2 = UUID()
        let a1 = archive("one.mov", digest: digest, source: s1)
        let a2 = archive("two.mov", digest: other, source: s2)
        let c1 = copy("one.mov", digest: digest, id: s1)
        let c2 = copy("two.mov", digest: other, id: s2)
        let batch = PrunePlan.build([a1, a2, c1, c2], batch: [s1])
        XCTAssertEqual(batch.items.map(\.id), [a1.id])
        let all = PrunePlan.build([a1, a2, c1, c2])
        XCTAssertEqual(Set(all.items.map(\.id)), [a1.id, a2.id])
        let lonely = PrunePlan.build([archive("solo.mov", digest: digest, source: s1)], batch: [s1])
        XCTAssertEqual(lonely.items.first?.rows.isEmpty, true, "a promoted file with no other copy: nothing to prune")
    }

    // MARK: The 200-row cap

    func testTheCapListsOfferedRowsFirstAndNeverOffersAHiddenRow() {
        var snaps: [PruneSnapshot] = []
        for i in 0..<150 {          // 150 items with only a held copy each
            let d = String(format: "%064x", i + 1)
            snaps.append(archive("h\(i).mov", digest: d))
            snaps.append(copy("h\(i).mov", digest: d, hold: .driveOffline))
        }
        for i in 0..<120 {          // then 120 items with an offered copy each
            let d = String(format: "%064x", 10_000 + i)
            snaps.append(archive("o\(i).mov", digest: d))
            snaps.append(copy("o\(i).mov", digest: d))
        }
        let full = PrunePlan.build(snaps)
        let shown = full.shown(maxRows: 200)
        XCTAssertEqual(shown.rowCount, 200)
        XCTAssertEqual(shown.hiddenRowCount, 70)
        XCTAssertEqual(shown.offeredCount, 120, "every offered row fits before a held one is listed")
        XCTAssertTrue(shown.offeredIDs.isSubset(of: full.offeredIDs))
        let tiny = full.shown(maxRows: 10)
        XCTAssertEqual(tiny.offeredCount, 10)
        XCTAssertEqual(tiny.hiddenRowCount, full.rowCount - 10)
    }

    // MARK: Advice (attestations advise, never gate)

    func testTheAdviceSentenceNamesArchiveOnlyFilesWithoutACloudOrOffsiteYes() {
        let yes = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: Date(), by: "rick")
        let s1 = UUID(), s2 = UUID()
        let a1 = archive("christmas.mov", digest: digest, source: s1, attestations: [yes])
        let a2 = archive("wedding.mov", digest: other, source: s2)
        let c1 = copy("christmas.mov", digest: digest)
        let c2 = copy("wedding.mov", digest: other)
        let offline2 = copy("wedding.mov", vol: "Shelf", digest: other, hold: .driveOffline)
        let plan = PrunePlan.build([a1, a2, c1, c2, offline2])
        XCTAssertEqual(plan.offeredIDs, [c1.id, c2.id])
        XCTAssertEqual(plan.adviceSentence(after: [c1.id, c2.id]),
                       "1 file will exist only in the Master Archive after this.",
                       "wedding keeps its offline copy; christmas has a cloud yes")
        let bare = PrunePlan.build([a1, a2, c1, c2])
        XCTAssertEqual(bare.adviceSentence(after: [c1.id, c2.id]),
                       "2 files will exist only in the Master Archive after this. No cloud or off-site copy is recorded for wedding.mov.")
        XCTAssertNil(bare.adviceSentence(after: []), "nothing checked, nothing to say")
        XCTAssertNil(bare.adviceSentence(after: [UUID()]), "an id that is not an offered row changes nothing")
    }

    func testAMissingCopyDoesNotCountAsRemaining() {
        let a = archive(digest: digest)
        let c = copy(digest: digest)
        let gone = copy(vol: "M4drive", digest: digest, hold: .missing)
        let plan = PrunePlan.build([a, c, gone])
        XCTAssertTrue(plan.items[0].leavesArchiveOnly(after: [c.id]))
    }

    func testTheProtectionLineCountsTheArchiveAndTheIdenticalCopies() {
        let source = UUID()
        let a = archive(digest: digest, source: source)
        let src = copy(vol: "M4drive", digest: digest, id: source)
        let off = copy(vol: "Shelf", digest: digest, hold: .driveOffline)
        let trim = copy("t.mov", digest: other, derivedFrom: source)
        let p = PrunePlan.build([a, src, off, trim], batch: [source]).protection
        XCTAssertEqual(p.archive, .verified)
        XCTAssertEqual(p.workingCopyCount, 2, "a version is not a copy")
        XCTAssertEqual(p.workingVolumesOnline, ["M4drive"])
        XCTAssertEqual(p.workingVolumesOffline, ["Shelf"])
    }

    func testTheLogLineSaysWhatIsOfferedAndWhy() {
        let a = archive("x.mov", digest: digest)
        let plan = PrunePlan.build([a, copy("x.mov", digest: digest), copy("x.mov", vol: "S", digest: digest, hold: .driveOffline)])
        XCTAssertEqual(plan.items[0].logLine, "what-next: x.mov — archive ✓ · 1 offered · held: 1 drive not connected")
    }

    // MARK: SCALE

    /// 100k snapshots (1k archive files, 99k copies, a tenth identical) build
    /// well inside the budget — the app runs this off the main actor.
    func testScale100kSnapshotsBuildUnderBudget() {
        var snaps: [PruneSnapshot] = []
        snaps.reserveCapacity(100_000)
        for i in 0..<1_000 { snaps.append(archive("a\(i).mov", digest: String(format: "%064x", i))) }
        for i in 0..<99_000 {
            let d = i % 10 == 0 ? String(format: "%064x", i % 1_000) : String(format: "%064x", 1_000_000 + i)
            snaps.append(copy("c\(i).mov", vol: "V\(i % 7)", digest: d))
        }
        let started = Date()
        let plan = PrunePlan.build(snaps).confirmingOnDisk(isMissing: { _ in false }, isNetwork: { _ in false }).shown()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(plan.rowCount, PrunePlan.maxRows)
        XCTAssertLessThan(elapsed, 5.0, "100k snapshots took \(elapsed)s")
    }
}
