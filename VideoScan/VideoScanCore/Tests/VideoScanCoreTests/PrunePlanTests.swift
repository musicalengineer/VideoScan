// PrunePlanTests.swift
// LOGIC for the dry-run prune plan (promote-and-prune stage 2, Rick
// 2026-09-12): the importance bar (levels, defaults, settings loader), the
// family grouping, the scrubbable-copy rule's every negative, keeper
// election (most free space, new device first, user override), the
// "not covered by the bar" outcome, the counts the sheet shows, and a
// SCALE pin (100k snapshots / 5k families under budget).

import XCTest
@testable import VideoScanCore

final class PrunePlanTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_757_700_000)

    private func copy(_ name: String, vol: String, key: String = "h:v1:k", size: Int64 = 1_000,
                      archive: Bool = false, verified: Bool = false, inside: Bool = false, online: Bool = true,
                      pair: Bool = false, version: Bool = false, note: Bool = false, stars: Int = 0,
                      disposition: MediaDisposition = .unreviewed, attestations: [BackupAttestation] = [],
                      working: Bool = true, free: Int64? = 100, promotedFrom: UUID? = nil, id: UUID = UUID()) -> ArchiveCopySnapshot {
        ArchiveCopySnapshot(id: id, filename: name, fullPath: "/Volumes/\(vol)/\(name)", volumeName: vol, sizeBytes: size,
                            contentKey: key, promotedFromID: promotedFrom, isArchiveCopy: archive,
                            fixityVerified: verified, isInsideArchiveRoot: inside, isOnline: online,
                            isPairMember: pair, isVersion: version, hasHumanNote: note, starRating: stars,
                            disposition: disposition, attestations: attestations,
                            volumeIsConnectedWorking: working, volumeFreeBytes: free)
    }

    private func archiveCopy(key: String = "h:v1:k", verified: Bool = true, stars: Int = 3, promotedFrom: UUID? = nil) -> ArchiveCopySnapshot {
        copy("archived.mov", vol: "FamilyArchive", key: key, archive: true, verified: verified, stars: stars,
             disposition: .important, working: false, free: nil, promotedFrom: promotedFrom)
    }

    private func plan(_ family: [ArchiveCopySnapshot], keepOne: Bool = true, keeper: String? = nil,
                      bar: ImportanceBar = .defaults) -> PrunePlan.Family {
        PrunePlan.compute(families: [family], options: .init(keepOne: keepOne, keeperVolume: keeper, bar: bar)).families[0]
    }

    // MARK: Importance bar

    func testLevelsFollowStarsAndDisposition() {
        XCTAssertEqual(ImportanceBar.level(starRating: 3, disposition: .unreviewed), .important)
        XCTAssertEqual(ImportanceBar.level(starRating: 1, disposition: .important), .important, "Important disposition wins")
        XCTAssertEqual(ImportanceBar.level(starRating: 2, disposition: .unreviewed), .ordinary)
        XCTAssertEqual(ImportanceBar.level(starRating: 0, disposition: .unreviewed), .ordinary)
        XCTAssertEqual(ImportanceBar.level(starRating: 0, disposition: .suspectedJunk), .ordinary)
        XCTAssertEqual(ImportanceBar.level(starRating: 1, disposition: .unreviewed), .low)
        XCTAssertEqual(ImportanceBar.level(starRating: 0, disposition: .recoverable), .low)
    }

    func testDefaultsMatchTheDesignTable() {
        let d = ImportanceBar.defaults
        XCTAssertEqual(d.important, .init(extraDevices: 1, cloudOrOffsite: true))
        XCTAssertEqual(d.ordinary, .init(extraDevices: 1, cloudOrOffsite: false))
        XCTAssertEqual(d.low, .init(extraDevices: 0, cloudOrOffsite: false))
        XCTAssertEqual(ImportanceBar.describe(d.important), "verified archive copy + 1 more device + a cloud or off-site copy")
        XCTAssertEqual(ImportanceBar.describe(d.low), "verified archive copy")
        XCTAssertEqual(ImportanceBar.Requirement(extraDevices: 9, cloudOrOffsite: false).extraDevices, 3, "clamped")
    }

    func testLoaderReadsEditedKeysAndFallsBackPerKey() {
        let stored: [String: Any] = [
            ImportanceBar.Key.importantDevices: 2,
            ImportanceBar.Key.ordinaryCloudOrOffsite: true,
            ImportanceBar.Key.lowDevices: "garbage",
            ImportanceBar.Key.lowCloudOrOffsite: NSNumber(value: true),
        ]
        let bar = ImportanceBar.load { stored[$0] }
        XCTAssertEqual(bar.important, .init(extraDevices: 2, cloudOrOffsite: true))
        XCTAssertEqual(bar.ordinary, .init(extraDevices: 1, cloudOrOffsite: true))
        XCTAssertEqual(bar.low, .init(extraDevices: 0, cloudOrOffsite: true), "malformed devices → default; NSNumber bool reads")
        XCTAssertEqual(ImportanceBar.load { _ in nil }, .defaults)
        // ISOLATION: a suite-private UserDefaults domain, never .standard.
        let suite = UserDefaults(suiteName: "PrunePlanTests.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }
        suite.set(3, forKey: ImportanceBar.Key.ordinaryDevices)
        XCTAssertEqual(ImportanceBar.load(defaults: suite).ordinary.extraDevices, 3)
        XCTAssertEqual(ImportanceBar.Key.all.count, 6)
    }

    // MARK: Families

    func testFamiliesKeyByContentAndArchiveCopyJoinsItsSource() {
        let src = copy("src.mov", vol: "LaCie", key: "")            // never hashed
        let arch = archiveCopy(key: "", promotedFrom: src.id)
        let other = copy("other.mov", vol: "X9", key: "h:v1:z")
        let purged = ArchiveCopySnapshot(id: UUID(), filename: "gone.mov", fullPath: "/Volumes/X9/gone.mov",
                                         volumeName: "X9", sizeBytes: 1, contentKey: "h:v1:z", isPurged: true)
        let fams = ArchiveCopyFamilies.group(batch: [src.id, other.id], snapshots: [other, arch, src, purged])
        XCTAssertEqual(fams.count, 2)
        let bySrc = fams.first { $0.contains { $0.id == src.id } }!
        XCTAssertEqual(Set(bySrc.map(\.id)), [src.id, arch.id], "the promote link joins the unhashed source")
        let byOther = fams.first { $0.contains { $0.id == other.id } }!
        XCTAssertEqual(byOther.map(\.id), [other.id], "purged copies are dropped")
        XCTAssertTrue(ArchiveCopyFamilies.group(batch: [], snapshots: [src]).isEmpty)
        XCTAssertTrue(ArchiveCopyFamilies.group(batch: [UUID()], snapshots: [src]).isEmpty)
        // Protection line from the same families.
        let line = ArchiveCopyFamilies.protection(families: fams).displayLine
        XCTAssertTrue(line.hasPrefix("Archive none"), "one family has no archive copy → the batch is not verified: \(line)")
    }

    // MARK: The scrubbable-copy rule — every negative

    func testNoArchiveCopyOrUnverifiedArchiveKeepsEverything() {
        let a = copy("a.mov", vol: "LaCie", stars: 1), b = copy("b.mov", vol: "X9", stars: 1)
        let none = plan([a, b])
        XCTAssertFalse(none.covered); XCTAssertEqual(none.shortfall, "no archive copy")
        XCTAssertTrue(none.trash.isEmpty); XCTAssertNil(none.keeper)
        XCTAssertEqual(none.extraCount, 2, "extras are counted even when nothing may go")
        XCTAssertEqual(Set(none.kept.map(\.reason)), [.noArchiveCopy])

        let unverified = plan([archiveCopy(verified: false, stars: 1), a, b])
        XCTAssertFalse(unverified.covered); XCTAssertEqual(unverified.shortfall, "archive copy unverified")
        XCTAssertTrue(unverified.kept.contains { $0.reason == .archiveUnverified })
        XCTAssertTrue(unverified.kept.contains { $0.reason == .archiveCopy })
    }

    func testProtectedCopiesAreNeverElectedNorTrashed() {
        // Low bar (★): archive alone is enough → everything scrubbable goes.
        let arch = archiveCopy(stars: 1)
        let offline = copy("off.mov", vol: "MyBook", online: false, stars: 1)
        let pair = copy("pair.mxf", vol: "LaCie", pair: true, stars: 1)
        let version = copy("bal.mov", vol: "LaCie", version: true, stars: 1)
        let noted = copy("noted.mov", vol: "LaCie", note: true, stars: 1)
        let inside = copy("inside.mov", vol: "FamilyArchive", inside: true, stars: 1, working: false)
        let free1 = copy("free1.mov", vol: "LaCie", stars: 1)
        let free2 = copy("free2.mov", vol: "X9", stars: 1)
        let f = plan([arch, offline, pair, version, noted, inside, free1, free2], keepOne: false)
        XCTAssertFalse(f.covered, "default bar: the archive copy is ★★★, which needs an attestation")
        XCTAssertEqual(f.level, .important, "the archive copy is ★★★ / Important, so the family level is important")
        // …which means the important bar applies; use the low bar explicitly:
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let g = plan([arch, offline, pair, version, noted, inside, free1, free2], keepOne: false, bar: bar)
        XCTAssertTrue(g.covered)
        XCTAssertEqual(Set(g.trash.map(\.filename)), ["free1.mov", "free2.mov"])
        let reasons = Dictionary(uniqueKeysWithValues: g.kept.map { ($0.copy.filename, $0.reason) })
        XCTAssertEqual(reasons["off.mov"], .offline)
        XCTAssertEqual(reasons["pair.mxf"], .pairMember)
        XCTAssertEqual(reasons["bal.mov"], .version)
        XCTAssertEqual(reasons["noted.mov"], .humanNote)
        XCTAssertEqual(reasons["inside.mov"], .insideArchiveRoot)
        XCTAssertEqual(reasons["archived.mov"], .archiveCopy)
        XCTAssertEqual(g.extraCount, 2, "offline / pair / version / noted copies are never 'extra'")
        XCTAssertEqual(g.extraBytes, 2_000)
    }

    // MARK: The bar

    func testImportantFamilyNeedsDeviceAndAttestationBeforeAnythingGoes() {
        let arch = archiveCopy()
        let a = copy("a.mov", vol: "LaCie", free: 500), b = copy("b.mov", vol: "Projects", free: 900), c = copy("c.mov", vol: "LaCie", free: 500)
        // No attestation → not covered: everything stays, keeper nil.
        let bare = plan([arch, a, b, c])
        XCTAssertFalse(bare.covered)
        XCTAssertEqual(bare.shortfall, "★★★ / Important — no cloud or off-site copy attested")
        XCTAssertNil(bare.keeper); XCTAssertTrue(bare.trash.isEmpty)
        XCTAssertEqual(bare.kept.filter { $0.reason == .barNotMet }.count, 3)
        XCTAssertEqual(bare.extraCount, 3)
        // A "no" is an answer, not a yes.
        let no = copy("a.mov", vol: "LaCie", attestations: [BackupAttestation(kind: .cloud, answer: .no, attestedAt: at)], free: 500, id: a.id)
        XCTAssertFalse(plan([arch, no, b, c]).covered)
        // A cloud "yes" on any member covers the family; keeper = most free space (Projects), the other two go.
        let yes = copy("c.mov", vol: "LaCie", attestations: [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at)], free: 500, id: c.id)
        let ok = plan([arch, a, b, yes])
        XCTAssertTrue(ok.covered); XCTAssertNil(ok.shortfall)
        XCTAssertEqual(ok.keeper?.filename, "b.mov", "connected working volume with the most free space")
        XCTAssertTrue(ok.keeperRequired, "the bar itself needs one more device")
        XCTAssertEqual(Set(ok.trash.map(\.filename)), ["a.mov", "c.mov"])
        XCTAssertEqual(ok.kept.first { $0.reason == .keeper }?.copy.filename, "b.mov")
        // Off-site "yes" counts the same way.
        let off = copy("c.mov", vol: "LaCie", attestations: [BackupAttestation(kind: .offsite, answer: .yes, attestedAt: at)], free: 500, id: c.id)
        XCTAssertTrue(plan([arch, a, b, off]).covered)
    }

    func testOfflineCopyCountsAsADeviceAndTheOnlyOnlineCopyMayThenGo() {
        // Ordinary (★★): archive + 1 more device. The retired-drive copy is
        // that device; keep-one OFF lets the LaCie copy go.
        let arch = archiveCopy(stars: 2, promotedFrom: nil)
        var bar = ImportanceBar.defaults
        bar.important = bar.ordinary   // the archive copy is ★★★; use the ordinary rule for it
        let offline = copy("off.mov", vol: "MyBook", online: false, stars: 2)
        let online = copy("on.mov", vol: "LaCie", stars: 2)
        let f = plan([arch, offline, online], keepOne: false, bar: bar)
        XCTAssertTrue(f.covered)
        XCTAssertFalse(f.keeperRequired)
        XCTAssertNil(f.keeper)
        XCTAssertEqual(f.trash.map(\.filename), ["on.mov"])
        // keep-one ON keeps it as the working copy instead.
        let g = plan([arch, offline, online], keepOne: true, bar: bar)
        XCTAssertEqual(g.keeper?.filename, "on.mov"); XCTAssertTrue(g.trash.isEmpty)
        // Without the offline copy the bar NEEDS the online one → keeper required, nothing goes.
        let h = plan([arch, online], keepOne: false, bar: bar)
        XCTAssertTrue(h.covered); XCTAssertTrue(h.keeperRequired); XCTAssertEqual(h.keeper?.filename, "on.mov"); XCTAssertTrue(h.trash.isEmpty)
        // Two devices required with only one available → not covered.
        bar.important = .init(extraDevices: 2, cloudOrOffsite: false)
        let i = plan([arch, online], bar: bar)
        XCTAssertFalse(i.covered)
        XCTAssertEqual(i.shortfall, "★★★ / Important — needs 1 more device")
    }

    func testKeeperElectionPrefersNewDeviceThenFreeSpaceThenUserOverride() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 1, cloudOrOffsite: false)
        let arch = archiveCopy()
        let noted = copy("noted.mov", vol: "LaCie", note: true)          // LaCie already "has" a copy
        let lacie = copy("l.mov", vol: "LaCie", free: 9_000)
        let x9 = copy("x.mov", vol: "X9", free: 100)
        let f = plan([arch, noted, lacie, x9], bar: bar)
        XCTAssertEqual(f.keeper?.filename, "l.mov", "the design rule: the connected working volume with the most free space")
        XCTAssertEqual(f.trash.map(\.filename), ["x.mov"])
        XCTAssertFalse(f.keeperRequired, "the noted LaCie copy already satisfies +1 device")
        // Equal free space → a volume the family has no other copy on breaks the tie.
        let lacieSmall = copy("ls.mov", vol: "LaCie", free: 100)
        XCTAssertEqual(plan([arch, noted, lacieSmall, x9], bar: bar).keeper?.filename, "x.mov")
        // A disconnected / retired volume never wins over a working one.
        let bigButRetired = copy("r.mov", vol: "MyBook", working: false, free: 99_999)
        XCTAssertEqual(plan([arch, bigButRetired, x9], bar: bar).keeper?.filename, "x.mov")
        // User override wins outright.
        let g = plan([arch, noted, lacie, x9], keeper: "X9", bar: bar)
        XCTAssertEqual(g.keeper?.filename, "x.mov")
        XCTAssertEqual(g.trash.map(\.filename), ["l.mov"])
        // Ties on free space → the lower path.
        let a = copy("a.mov", vol: "Projects", free: 100), b = copy("b.mov", vol: "X9", free: 100)
        XCTAssertEqual(plan([arch, a, b], bar: bar).keeper?.filename, "a.mov")
    }

    func testVolumeChoicesAndTotalsAcrossFamilies() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 1, cloudOrOffsite: false)
        let fam1 = [archiveCopy(key: "h:1"), copy("a1.mov", vol: "LaCie", key: "h:1", size: 10, free: 500), copy("b1.mov", vol: "Projects", key: "h:1", size: 20, free: 900)]
        let fam2 = [archiveCopy(key: "h:2"), copy("a2.mov", vol: "LaCie", key: "h:2", size: 30, free: 500), copy("c2.mov", vol: "X9", key: "h:2", size: 40, online: false)]
        let fam3 = [archiveCopy(key: "h:3", verified: false), copy("a3.mov", vol: "LaCie", key: "h:3", size: 50, free: 500)]
        let p = PrunePlan.compute(families: [fam1, fam2, fam3], options: .init(bar: bar))
        XCTAssertEqual(p.families.count, 3)
        XCTAssertEqual(p.extraCount, 4); XCTAssertEqual(p.extraBytes, 110)
        XCTAssertEqual(p.trashCount, 1); XCTAssertEqual(p.trashBytes, 10, "fam1: keep Projects, trash a1; fam2: LaCie kept (keep-one); fam3 unverified")
        XCTAssertEqual(p.notCoveredCount, 1)
        XCTAssertEqual(p.keeperRequiredCount, 1, "fam1 needs its keeper for the bar; fam2's offline copy already counts")
        XCTAssertEqual(p.keeperVolumes.map(\.name), ["Projects", "LaCie"], "best free space first")
        XCTAssertEqual(p.keeperVolumes.first { $0.name == "LaCie" }?.familyCount, 3)
        XCTAssertEqual(p.suggestedKeeperVolume, "Projects")
        XCTAssertEqual(p.trashFiles.map(\.filename), ["a1.mov"])
        XCTAssertEqual(p.notCoveredFamilies.map(\.displayName), ["archived.mov"])
        XCTAssertEqual(PrunePlan.compute(families: [], options: .init()), .empty)
    }

    // MARK: The checklist (2026-09-20 — the bar advises, the person decides)

    func testRowsMirrorThePlanAndOnlyCandidatesWithAVerifiedArchiveAreCheckable() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let arch = archiveCopy(stars: 1)
        let offline = copy("off.mov", vol: "MyBook", online: false)
        let pair = copy("pair.mxf", vol: "LaCie", pair: true)
        let version = copy("bal.mov", vol: "LaCie", version: true)
        let noted = copy("noted.mov", vol: "LaCie", note: true)
        let inside = copy("inside.mov", vol: "FamilyArchive", inside: true, working: false)
        let free1 = copy("free1.mov", vol: "LaCie", free: 900)
        let free2 = copy("free2.mov", vol: "X9", free: 100)
        // Working copies first in the family; rows still put the archive copies first.
        let f = plan([free1, offline, pair, version, noted, inside, free2, arch], keepOne: true, bar: bar)
        XCTAssertTrue(f.covered); XCTAssertNil(f.advice)
        XCTAssertEqual(f.rows.map(\.copy.filename),
                       ["inside.mov", "archived.mov", "free1.mov", "off.mov", "pair.mxf", "bal.mov", "noted.mov", "free2.mov"],
                       "archive copies first, then catalog order")
        let byName = Dictionary(uniqueKeysWithValues: f.rows.map { ($0.copy.filename, $0) })
        XCTAssertEqual(byName["archived.mov"]?.role, .archiveCopy)
        XCTAssertEqual(byName["inside.mov"]?.role, .insideArchiveRoot)
        XCTAssertEqual(byName["off.mov"]?.role, .kept(.offline))
        XCTAssertEqual(byName["pair.mxf"]?.role, .kept(.pairMember))
        XCTAssertEqual(byName["bal.mov"]?.role, .kept(.version))
        XCTAssertEqual(byName["noted.mov"]?.role, .kept(.humanNote))
        XCTAssertEqual(byName["noted.mov"]?.reasonText, "has your note")
        XCTAssertEqual(byName["free1.mov"]?.role, .candidate)
        XCTAssertEqual(byName["free1.mov"]?.planKeeps, .keeper, "the elected keeper (most free space)")
        XCTAssertEqual(byName["free1.mov"]?.reasonText, "the plan would keep this one")
        XCTAssertEqual(byName["free1.mov"]?.defaultChecked, false)
        XCTAssertEqual(byName["free2.mov"]?.role, .candidate)
        XCTAssertNil(byName["free2.mov"]?.planKeeps); XCTAssertNil(byName["free2.mov"]?.reasonText)
        XCTAssertEqual(byName["free2.mov"]?.defaultChecked, true)
        XCTAssertEqual(f.candidateCount, 2, "only the two free copies are checkable")
        XCTAssertEqual(f.defaultSelection, Set(f.trash.map(\.id)), "default checks = the trash set")
        XCTAssertEqual(Set(f.rows.filter(\.checkable).map(\.id)), [free1.id, free2.id])
        // keep-one off: both candidates default-checked; the keeper hint is gone.
        let g = plan([arch, free1, free2], keepOne: false, bar: bar)
        XCTAssertEqual(g.defaultSelection, [free1.id, free2.id])
        XCTAssertTrue(g.rows.filter(\.checkable).allSatisfy { $0.planKeeps == nil })
        // Plan-level views.
        let p = PrunePlan.compute(families: [[free1, offline, pair, version, noted, inside, free2, arch]],
                                  options: .init(bar: bar))
        XCTAssertEqual(p.defaultSelection, Set(p.trashFiles.map(\.id)))
        XCTAssertEqual(p.checkableIDs, [free1.id, free2.id])
        XCTAssertEqual(p.checkableCount, 2); XCTAssertEqual(p.rowCount, 8)
    }

    func testAdviceForAnImportantFamilyWithNoAttestationAndTheOverride() {
        let arch = archiveCopy()
        let a = copy("Christmas2008.mov", vol: "LaCie", size: 10, free: 500)
        let b = copy("Christmas2008.mov", vol: "Projects", size: 20, free: 900)
        let c = copy("Christmas2008.mov", vol: "X9", size: 30, free: 100)
        let f = plan([arch, a, b, c])
        XCTAssertFalse(f.covered)
        XCTAssertEqual(f.advice, "★★★ / Important — the bar you set wants a cloud or off-site copy; none attested. You can still choose.")
        XCTAssertEqual(f.requirement, ImportanceBar.defaults.important)
        XCTAssertFalse(f.cloudOrOffsiteAttested)
        // Every working copy is checkable, none checked; the plan's keeper is hinted.
        let working = f.rows.filter { $0.role != .archiveCopy }
        XCTAssertEqual(working.count, 3)
        XCTAssertTrue(working.allSatisfy { $0.checkable && !$0.defaultChecked })
        XCTAssertEqual(working.first { $0.planKeeps == .keeper }?.copy.volumeName, "Projects", "most free space")
        XCTAssertEqual(working.filter { $0.planKeeps == .barNotMet }.count, 2)
        XCTAssertTrue(f.defaultSelection.isEmpty); XCTAssertEqual(f.candidateCount, 3)
        // Nothing chosen → nothing, no override.
        XCTAssertEqual(f.selection([]), .empty)
        // Two chosen → both go against the bar (no attestation), one working copy remains.
        let two = f.selection([a.id, c.id])
        XCTAssertEqual(two.count, 2); XCTAssertEqual(two.bytes, 40)
        XCTAssertEqual(two.overrideCount, 2)
        XCTAssertEqual(two.overrideShortfalls, ["★★★ / Important — no cloud or off-site copy attested"])
        XCTAssertEqual(two.overrideText, "2 copies — ★★★ / Important — no cloud or off-site copy attested")
        XCTAssertEqual(two.overrideSentence, "2 copies go against the bar you set: ★★★ / Important — no cloud or off-site copy attested.")
        XCTAssertTrue(two.archiveOnlyFamilies.isEmpty); XCTAssertNil(two.archiveOnlySentence)
        // All three → only the archive copy is left, and it says so; the
        // device shortfall joins the attestation one.
        let all = f.selection([a.id, b.id, c.id])
        XCTAssertEqual(all.count, 3); XCTAssertEqual(all.overrideCount, 3)
        XCTAssertEqual(all.overrideShortfalls, ["★★★ / Important — needs 1 more device, no cloud or off-site copy attested"])
        XCTAssertEqual(all.archiveOnlyFamilies, ["archived.mov"])
        XCTAssertEqual(all.archiveOnlySentence, "archived.mov will exist only in the Master Archive after this.")
        // A "yes" recomputes the advice away: covered, keeper Projects, a + c default-checked, no override.
        let yes = copy("Christmas2008.mov", vol: "X9", size: 30, attestations: [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at)], free: 100, id: c.id)
        let ok = plan([arch, a, b, yes])
        XCTAssertTrue(ok.covered); XCTAssertNil(ok.advice); XCTAssertTrue(ok.cloudOrOffsiteAttested)
        XCTAssertEqual(ok.defaultSelection, [a.id, c.id])
        let dflt = ok.selection(ok.defaultSelection)
        XCTAssertEqual(dflt.count, 2); XCTAssertEqual(dflt.overrideCount, 0); XCTAssertNil(dflt.overrideText)
        // …but checking the keeper too breaks the device rule: an override, and archive-only.
        let keeperToo = ok.selection([a.id, b.id, c.id])
        XCTAssertEqual(keeperToo.overrideCount, 3)
        XCTAssertEqual(keeperToo.overrideShortfalls, ["★★★ / Important — needs 1 more device"])
        XCTAssertEqual(keeperToo.archiveOnlyFamilies, ["archived.mov"])
        // Ids that are not checkable rows are ignored by the count.
        XCTAssertEqual(ok.selection([arch.id, UUID()]), .empty)
    }

    func testUnverifiedArchiveRowsAreShownButNeverCheckable() {
        let a = copy("a.mov", vol: "LaCie", stars: 1), b = copy("b.mov", vol: "X9", stars: 1)
        let none = plan([a, b])
        XCTAssertEqual(none.rows.map(\.role), [.kept(.noArchiveCopy), .kept(.noArchiveCopy)])
        XCTAssertEqual(none.candidateCount, 0); XCTAssertTrue(none.defaultSelection.isEmpty)
        XCTAssertEqual(none.advice, "No archive copy yet — nothing here can go until one is promoted and verified.")
        XCTAssertEqual(none.selection([a.id, b.id]), .empty, "checking what cannot be checked counts nothing")
        let unverified = plan([archiveCopy(verified: false, stars: 1), a, b])
        XCTAssertEqual(unverified.rows.map(\.role), [.archiveCopy, .kept(.archiveUnverified), .kept(.archiveUnverified)])
        XCTAssertEqual(unverified.rows[1].reasonText, "archive copy unverified")
        XCTAssertEqual(unverified.advice, "The archive copy is not verified yet — nothing here can go until it reads back.")
        XCTAssertEqual(unverified.selection([a.id]), .empty)
    }

    func testSelectionAcrossFamiliesDeduplicatesShortfallsAndNamesEveryArchiveOnlyFile() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 1, cloudOrOffsite: false)
        let f1 = [archiveCopy(key: "h:1"), copy("a1.mov", vol: "LaCie", key: "h:1", size: 10, free: 500)]
        let f2 = [archiveCopy(key: "h:2"), copy("a2.mov", vol: "LaCie", key: "h:2", size: 20, free: 500),
                  copy("b2.mov", vol: "X9", key: "h:2", size: 5, online: false)]
        let f3 = [archiveCopy(key: "h:3", verified: false), copy("a3.mov", vol: "LaCie", key: "h:3", size: 50, free: 500)]
        let p = PrunePlan.compute(families: [f1, f2, f3], options: .init(bar: bar))
        XCTAssertEqual(p.checkableIDs, [f1[1].id, f2[1].id], "f3 has no verified archive copy")
        let s = p.selection([f1[1].id, f2[1].id, f3[1].id])
        XCTAssertEqual(s.count, 2); XCTAssertEqual(s.bytes, 30)
        XCTAssertEqual(s.overrideCount, 1, "f1 loses its only device; f2's offline MyBook-style copy still counts")
        XCTAssertEqual(s.overrideShortfalls, ["★★★ / Important — needs 1 more device"])
        XCTAssertEqual(s.archiveOnlyFamilies, ["archived.mov"], "f2 keeps its offline copy, so only f1 is archive-only")
        XCTAssertEqual(s.overrideText, "1 copy — ★★★ / Important — needs 1 more device")
        XCTAssertEqual(s.overrideSentence, "1 copy goes against the bar you set: ★★★ / Important — needs 1 more device.")
        let both = PrunePlan.compute(families: [f1, f1.map { var c = $0; c.id = UUID(); c.contentKey = "h:9"; c.promotedFromID = nil; return c }],
                                     options: .init(bar: bar))
        let s2 = both.selection(both.checkableIDs)
        XCTAssertEqual(s2.overrideShortfalls.count, 1, "the same shortfall is said once")
        XCTAssertEqual(s2.archiveOnlySentence, "archived.mov and 1 more will exist only in the Master Archive after this.")
    }

    // MARK: Scale

    func testScale100kSnapshotsIn5kFamiliesUnderBudget() {
        let volumes = ["LaCie", "Projects", "MyBook", "X9", "X10", "Movies"]
        var snaps: [ArchiveCopySnapshot] = []
        snaps.reserveCapacity(100_000)
        var batch = Set<UUID>()
        for g in 0..<5_000 {
            var first: UUID?
            for c in 0..<19 {
                let vol = volumes[(g + c) % volumes.count]
                var s = copy("g\(g)_c\(c).mov", vol: vol, key: "h:v1:\(g)", size: 1_000, online: (g + c) % 7 != 0, stars: 2,
                             free: Int64(100 + c))
                if c == 0 {
                    first = s.id; batch.insert(s.id)
                    if g % 3 == 0 { s.attestations = [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at)] }
                }
                snaps.append(s)
            }
            snaps.append(archiveCopy(key: "", promotedFrom: first))
        }
        XCTAssertEqual(snaps.count, 100_000)
        let clock = ContinuousClock()
        var families: [[ArchiveCopySnapshot]] = []
        var p = PrunePlan.empty
        let elapsed = clock.measure {
            families = ArchiveCopyFamilies.group(batch: batch, snapshots: snaps)
            p = PrunePlan.compute(families: families, options: .init())
        }
        XCTAssertEqual(families.count, 5_000)
        XCTAssertEqual(p.families.count, 5_000)
        XCTAssertEqual(p.notCoveredCount, 5_000 - 1_667, "only every third family attested a cloud copy")
        XCTAssertGreaterThan(p.trashCount, 0)
        XCTAssertLessThan(elapsed, .seconds(3), "group + compute took \(elapsed) for 100k snapshots")
        // The checklist views are O(rows): 100k rows, default checks = the
        // trash set, a whole-batch selection judged in well under a second.
        XCTAssertEqual(p.rowCount, 100_000)
        var sel = PrunePlan.Selection.empty
        var dflt = Set<UUID>()
        let selElapsed = clock.measure {
            dflt = p.defaultSelection
            sel = p.selection(p.checkableIDs)
        }
        XCTAssertEqual(dflt, Set(p.trashFiles.map(\.id)))
        XCTAssertEqual(sel.count, p.checkableCount)
        XCTAssertGreaterThan(sel.overrideCount, 0)
        XCTAssertLessThan(selElapsed, .seconds(1), "selection views took \(selElapsed) for 100k rows")
        let protection = ArchiveCopyFamilies.protection(families: families)
        XCTAssertEqual(protection.familyCount, 5_000)
        XCTAssertEqual(protection.archive, .verified)
    }
}
