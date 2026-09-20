// PrunePlanTests.swift
// LOGIC for the dry-run prune plan (promote-and-prune stage 2, Rick
// 2026-09-12): the importance bar (levels, defaults, settings loader), the
// family grouping, the scrubbable-copy rule's every negative, keeper
// election (most free space, new device first, user override), the
// "not covered by the bar" outcome, the counts the sheet shows, and a
// SCALE pin (100k snapshots / 5k families under budget).
//
// v3 (Rick's ruling 2026-09-20 — "allow me to delete any copy or all
// copies on any drive EXCEPT FamilyArchive … many are subsets or
// improvements or trimmed"): a VERSION joins its original's family by
// provenance (≤ 4 hops) and is checkable, unchecked by default; a copy
// with a note is checkable; the archive copies are never rows; only an
// offline copy, a pair half and a family without a verified archive copy
// are refused; "n/a for these" satisfies the bar's cloud-or-off-site
// want; name-related records outside the family are "might be copies"
// until a hash says.

import XCTest
@testable import VideoScanCore

final class PrunePlanTests: XCTestCase {

    private let at = Date(timeIntervalSince1970: 1_757_700_000)

    private func copy(_ name: String, vol: String, key: String = "h:v1:k", size: Int64 = 1_000,
                      archive: Bool = false, verified: Bool = false, inside: Bool = false, online: Bool = true,
                      pair: Bool = false, version: Bool = false, note: Bool = false, stars: Int = 0,
                      disposition: MediaDisposition = .unreviewed, attestations: [BackupAttestation] = [],
                      working: Bool = true, free: Int64? = 100, promotedFrom: UUID? = nil, id: UUID = UUID(),
                      derivedFrom: UUID? = nil, kind: String? = nil) -> ArchiveCopySnapshot {
        ArchiveCopySnapshot(id: id, filename: name, fullPath: "/Volumes/\(vol)/\(name)", volumeName: vol, sizeBytes: size,
                            contentKey: key, promotedFromID: promotedFrom, isArchiveCopy: archive,
                            fixityVerified: verified, isInsideArchiveRoot: inside, isOnline: online,
                            isPairMember: pair, isVersion: version, hasHumanNote: note, starRating: stars,
                            disposition: disposition, attestations: attestations,
                            volumeIsConnectedWorking: working, volumeFreeBytes: free,
                            derivedFrom: derivedFrom, derivationKind: kind)
    }

    private func archiveCopy(key: String = "h:v1:k", verified: Bool = true, stars: Int = 3, promotedFrom: UUID? = nil) -> ArchiveCopySnapshot {
        copy("archived.mov", vol: "FamilyArchive", key: key, archive: true, verified: verified, stars: stars,
             disposition: .important, working: false, free: nil, promotedFrom: promotedFrom)
    }

    private func plan(_ family: [ArchiveCopySnapshot], keepOne: Bool = true, keeper: String? = nil,
                      bar: ImportanceBar = .defaults) -> PrunePlan.Family {
        PrunePlan.compute(families: [family], options: .init(keepOne: keepOne, keeperVolume: keeper, bar: bar)).families[0]
    }

    /// The Angel's stem rule, in miniature: strip a trailing derivative token.
    private func baseStem(_ stem: String) -> String {
        var s = stem.lowercased()
        for token in ["_trimmed", "_balanced", "_converted", " copy"] where s.hasSuffix(token) {
            s = String(s.dropLast(token.count))
        }
        return s
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

    // MARK: v3 — family = content + provenance

    func testAVersionJoinsItsArchivedOriginalsFamilyAndIsCheckableUncheckedByDefault() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let src = copy("Christmas2008.mov", vol: "LaCie", key: "")                 // never hashed
        let arch = archiveCopy(key: "", promotedFrom: src.id)
        let trimmed = copy("Christmas2008_trimmed.mov", vol: "M4drive", key: "h:v1:t", version: true,
                           derivedFrom: src.id, kind: "trim")
        let balanced = copy("Christmas2008_balanced.mov", vol: "Projects", key: "h:v1:b", version: true,
                            derivedFrom: src.id, kind: "balanceAudio")
        let cleaned = copy("Christmas2008_cleaned.mov", vol: "Projects", key: "h:v1:c", version: true,
                           derivedFrom: trimmed.id, kind: "cleanup")
        let repair = copy("Christmas2008_fixed.mov", vol: "X9", key: "h:v1:r", version: false,
                          derivedFrom: src.id, kind: "rebuildAudio")               // a repair is its own thing
        let fams = ArchiveCopyFamilies.group(batch: [src.id], snapshots: [repair, cleaned, balanced, trimmed, arch, src])
        XCTAssertEqual(fams.count, 1)
        XCTAssertEqual(Set(fams[0].map(\.id)), [src.id, arch.id, trimmed.id, balanced.id, cleaned.id],
                       "versions join by provenance; the repair does not")
        let f = plan(fams[0], keepOne: true, bar: bar)
        XCTAssertTrue(f.covered && f.archiveVerified)
        XCTAssertEqual(f.archive.map(\.filename), ["archived.mov"], "the archive side is the header, never a row")
        XCTAssertEqual(f.rows.map(\.copy.filename),
                       ["Christmas2008_cleaned.mov", "Christmas2008_balanced.mov", "Christmas2008_trimmed.mov", "Christmas2008.mov"],
                       "catalog order, no archive copy")
        let byName = Dictionary(uniqueKeysWithValues: f.rows.map { ($0.copy.filename, $0) })
        for name in ["Christmas2008_trimmed.mov", "Christmas2008_balanced.mov", "Christmas2008_cleaned.mov"] {
            let row = byName[name]!
            XCTAssertTrue(row.checkable, "\(name) is checkable")
            XCTAssertFalse(row.defaultChecked, "\(name) is unchecked by default")
            XCTAssertEqual(row.planKeeps, .version)
            XCTAssertTrue(row.kind.isVersion)
        }
        XCTAssertEqual(byName["Christmas2008_trimmed.mov"]?.kind, .trimmed)
        XCTAssertEqual(byName["Christmas2008_trimmed.mov"]?.reasonText, "a trimmed version — the original is in the archive")
        XCTAssertEqual(byName["Christmas2008_balanced.mov"]?.kind, .balanced)
        XCTAssertEqual(byName["Christmas2008_cleaned.mov"]?.kind, .cleaned)
        XCTAssertEqual(byName["Christmas2008.mov"]?.kind, .original, "the promotion source")
        XCTAssertEqual(byName["Christmas2008.mov"]?.planKeeps, .keeper, "original over versions — the keeper is never a version")
        XCTAssertEqual(f.extraCount, 4, "versions count as extra copies now")
        XCTAssertEqual(f.candidateCount, 4)
        XCTAssertTrue(f.defaultSelection.isEmpty, "keep-one keeps the original; versions are never checked by default")
        let reasons = Dictionary(uniqueKeysWithValues: f.kept.map { ($0.copy.filename, $0.reason) })
        XCTAssertEqual(reasons["Christmas2008_trimmed.mov"], .version)
        XCTAssertEqual(reasons["archived.mov"], .archiveCopy)
        // Checking every version and the original: all four go, archive-only afterwards.
        let all = f.selection(Set(f.checkableIDs))
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all.archiveOnlyFamilies, ["archived.mov"])
        // Without keep-one the original is the default check; versions still are not.
        XCTAssertEqual(plan(fams[0], keepOne: false, bar: bar).defaultSelection, [src.id])
    }

    func testAFourHopProvenanceChainJoinsAFiveHopChainDoesNot() {
        let src = copy("tape.mov", vol: "LaCie", key: "h:v1:orig")
        let arch = archiveCopy(key: "h:v1:orig")
        var chain: [ArchiveCopySnapshot] = []
        var parent = src.id
        for hop in 1...5 {
            let v = copy("tape_v\(hop).mov", vol: "X9", key: "h:v1:h\(hop)", version: true, derivedFrom: parent, kind: "trim")
            chain.append(v)
            parent = v.id
        }
        let fams = ArchiveCopyFamilies.group(batch: [src.id], snapshots: chain.reversed() + [arch, src])
        XCTAssertEqual(fams.count, 1)
        let ids = Set(fams[0].map(\.id))
        XCTAssertTrue(ids.contains(chain[3].id), "4 hops up reaches the original")
        XCTAssertFalse(ids.contains(chain[4].id), "5 hops does not")
        XCTAssertEqual(ids.count, 6, "src + archive + 4 versions")
        // A cycle never loops.
        let a = copy("a.mov", vol: "X9", key: "h:v1:a", version: true, kind: "trim")
        var b = copy("b.mov", vol: "X9", key: "h:v1:b", version: true, derivedFrom: a.id, kind: "trim")
        var aa = a; aa.derivedFrom = b.id
        b.derivedFrom = aa.id
        XCTAssertEqual(ArchiveCopyFamilies.group(batch: [aa.id], snapshots: [aa, b]).count, 1)
    }

    func testNameRelatedRecordsAreMightBeCopiesUntilAHashSays() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let src = copy("Christmas2008.mov", vol: "LaCie", key: "h:v1:x")
        let arch = archiveCopy(key: "h:v1:x", promotedFrom: src.id)
        let unhashed = copy("Christmas2008 copy.mov", vol: "M4drive", key: "")               // never hashed
        let sameName = copy("Christmas2008.mov", vol: "X9", key: "")                          // same filename, unhashed
        let different = copy("Christmas2008_trimmed.mov", vol: "M4drive", key: "h:v1:zzz")   // hashed, differs
        let partial = copy("Christmas2008_converted.mov", vol: "M4drive", key: "p:md5:7")    // only a partial key
        let unrelated = copy("Thanksgiving.mov", vol: "M4drive", key: "")
        let offline = copy("Christmas2008 copy.mov", vol: "MyBook", key: "", online: false, working: false)
        let insideRoot = copy("Christmas2008 copy.mov", vol: "FamilyArchive", key: "", inside: true, working: false)
        let snaps = [unrelated, different, unhashed, partial, sameName, offline, insideRoot, arch, src]
        let fams = ArchiveCopyFamilies.group(batch: [src.id], snapshots: snaps)
        XCTAssertEqual(fams.count, 1)
        XCTAssertEqual(Set(fams[0].map(\.id)), [src.id, arch.id], "nothing joins by name alone")
        let related = ArchiveCopyFamilies.nameRelated(families: fams, snapshots: snaps, baseStem: baseStem)
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual(Set(related[0].members.map(\.id)), [unhashed.id, sameName.id, different.id, partial.id],
                       "name-related, reachable, not in the family; never offline / inside the root / unrelated")
        XCTAssertEqual(related[0].hiddenCount, 0)
        let p = PrunePlan.compute(families: fams, related: related, options: .init(bar: bar))
        let f = p.families[0]
        XCTAssertEqual(f.rows.map(\.copy.filename), ["Christmas2008.mov"], "the related rows are not rows")
        XCTAssertEqual(f.related.count, 4)
        let status = Dictionary(uniqueKeysWithValues: f.related.map { ($0.copy.filename + "@" + $0.copy.volumeName, $0.status) })
        XCTAssertEqual(status["Christmas2008 copy.mov@M4drive"], .needsHash)
        XCTAssertEqual(status["Christmas2008.mov@X9"], .needsHash)
        XCTAssertEqual(status["Christmas2008_trimmed.mov@M4drive"], .differentFootage, "a segmented hash that differs")
        XCTAssertEqual(status["Christmas2008_converted.mov@M4drive"], .needsHash, "a partial key cannot compare with a segmented one")
        XCTAssertTrue(f.unhashedMemberIDs.isEmpty, "every online member already has a segmented hash")
        XCTAssertEqual(f.related.first { $0.status == .needsHash }?.reasonText, "same name — hash to confirm it is a copy")
        XCTAssertEqual(f.related.first { $0.status == .differentFootage }?.reasonText, "different footage — not a copy")
        XCTAssertEqual(p.relatedCount, 4)
        XCTAssertFalse(p.checkableIDs.contains(unhashed.id), "never checkable without a hash match")
        // After a MATCHING hash the copy is a normal candidate on the next plan.
        var joined = unhashed; joined.contentKey = "h:v1:x"
        let snaps2 = snaps.map { $0.id == unhashed.id ? joined : $0 }
        let fams2 = ArchiveCopyFamilies.group(batch: [src.id], snapshots: snaps2)
        XCTAssertTrue(fams2[0].contains { $0.id == unhashed.id })
        let p2 = PrunePlan.compute(families: fams2,
                                   related: ArchiveCopyFamilies.nameRelated(families: fams2, snapshots: snaps2, baseStem: baseStem),
                                   options: .init(keepOne: true, bar: bar))
        let row = p2.families[0].rows.first { $0.id == unhashed.id }
        XCTAssertEqual(row?.role, .candidate)
        XCTAssertEqual(row?.kind, .duplicate)
        XCTAssertEqual(p2.families[0].related.count, 3, "it left the might-be list")
        // After a MISMATCHING hash it stays out, named as different footage.
        var differs = unhashed; differs.contentKey = "h:v1:nope"
        let snaps3 = snaps.map { $0.id == unhashed.id ? differs : $0 }
        let fams3 = ArchiveCopyFamilies.group(batch: [src.id], snapshots: snaps3)
        XCTAssertFalse(fams3[0].contains { $0.id == unhashed.id })
        let p3 = PrunePlan.compute(families: fams3,
                                   related: ArchiveCopyFamilies.nameRelated(families: fams3, snapshots: snaps3, baseStem: baseStem),
                                   options: .init(bar: bar))
        XCTAssertEqual(p3.families[0].related.first { $0.id == unhashed.id }?.status, .differentFootage)
        // An unhashed family member is named so "Hash to confirm" hashes both sides.
        let srcUnhashed = copy("Christmas2008.mov", vol: "LaCie", key: "", id: src.id)
        let archU = archiveCopy(key: "", promotedFrom: src.id)
        let fams4 = ArchiveCopyFamilies.group(batch: [src.id], snapshots: [unhashed, archU, srcUnhashed])
        let p4 = PrunePlan.compute(families: fams4,
                                   related: ArchiveCopyFamilies.nameRelated(families: fams4, snapshots: [unhashed, archU, srcUnhashed], baseStem: baseStem),
                                   options: .init(bar: bar))
        XCTAssertEqual(Set(p4.families[0].unhashedMemberIDs), [src.id, archU.id])
        XCTAssertEqual(p4.families[0].related.first?.status, .needsHash)
        // The per-family cap counts the rest.
        let many = (0..<25).map { copy("Christmas2008 copy.mov", vol: "M4drive", key: "", id: UUID(), derivedFrom: nil).with(path: "/Volumes/M4drive/\($0)/Christmas2008 copy.mov") }
        let capped = ArchiveCopyFamilies.nameRelated(families: fams, snapshots: many + [arch, src], baseStem: baseStem)
        XCTAssertEqual(capped[0].members.count, ArchiveCopyFamilies.maxRelatedPerFamily)
        XCTAssertEqual(capped[0].hiddenCount, 5)
        XCTAssertTrue(ArchiveCopyFamilies.nameRelated(families: [], snapshots: snaps).isEmpty)
    }

    func testNotApplicableAttestationSatisfiesTheAdviceForThisBatch() {
        let arch = archiveCopy()
        let a = copy("a.mov", vol: "LaCie", free: 500), b = copy("b.mov", vol: "Projects", free: 900)
        let na = copy("c.mov", vol: "X9", attestations: [BackupAttestation(kind: .cloud, answer: .notApplicable, attestedAt: at)], free: 100)
        let f = plan([arch, a, b, na])
        XCTAssertTrue(f.covered, "n/a for these counts as met for this batch's advice")
        XCTAssertNil(f.advice)
        XCTAssertFalse(f.cloudOrOffsiteAttested, "the protection line still says none attested")
        XCTAssertTrue(f.cloudOrOffsiteNotApplicable && f.cloudOrOffsiteSatisfied)
        XCTAssertEqual(f.note, "You said cloud and off-site copies don't apply to these — the bar is met on your word.")
        XCTAssertEqual(f.keeper?.filename, "b.mov")
        XCTAssertEqual(Set(f.trash.map(\.filename)), ["a.mov", "c.mov"], "default checks as if attested")
        // The selection judges the same way: no override.
        XCTAssertEqual(f.selection(f.defaultSelection).overrideCount, 0)
        // Off-site n/a counts the same way; a "no" still does not; a "yes" wins over n/a (no note).
        let naOff = copy("c.mov", vol: "X9", attestations: [BackupAttestation(kind: .offsite, answer: .notApplicable, attestedAt: at)], free: 100, id: na.id)
        XCTAssertTrue(plan([arch, a, b, naOff]).covered)
        let no = copy("c.mov", vol: "X9", attestations: [BackupAttestation(kind: .cloud, answer: .no, attestedAt: at)], free: 100, id: na.id)
        XCTAssertFalse(plan([arch, a, b, no]).covered)
        let yes = copy("c.mov", vol: "X9", attestations: [BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: at),
                                                          BackupAttestation(kind: .offsite, answer: .notApplicable, attestedAt: at)], free: 100, id: na.id)
        let y = plan([arch, a, b, yes])
        XCTAssertTrue(y.covered && y.cloudOrOffsiteAttested); XCTAssertNil(y.note)
        // An ordinary family never wanted one — no note either.
        var bar = ImportanceBar.defaults
        bar.important = bar.ordinary
        XCTAssertNil(plan([arch, a, b, na], bar: bar).note)
    }

    func testTheLogLineSaysWhyEachCopyCouldOrCouldNotBeSelected() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let src = copy("Christmas2008.mov", vol: "CrucialX9", key: "h:v1:x")
        let arch = archiveCopy(key: "h:v1:x", promotedFrom: src.id)
        let dup = copy("Christmas2008.mov", vol: "M4drive", key: "h:v1:x")
        let offline = copy("Christmas2008.mov", vol: "LaCieWorkspace", key: "h:v1:x", online: false, working: false)
        let trimmed = copy("Christmas2008_trimmed.mov", vol: "M4drive", key: "h:v1:t", version: true, derivedFrom: src.id, kind: "trim")
        let noted = copy("Christmas2008.mov", vol: "Projects", key: "h:v1:x", note: true)
        let maybe = copy("Christmas2008 copy.mov", vol: "M4drive", key: "")
        let maybe2 = copy("Christmas2008 copy.mov", vol: "Projects", key: "")
        let snaps = [src, arch, dup, offline, trimmed, noted, maybe, maybe2]
        let fams = ArchiveCopyFamilies.group(batch: [src.id], snapshots: snaps)
        let p = PrunePlan.compute(families: fams,
                                  related: ArchiveCopyFamilies.nameRelated(families: fams, snapshots: snaps, baseStem: baseStem),
                                  options: .init(bar: bar))
        XCTAssertEqual(p.families[0].logLine,
                       "what-next: archived.mov — archive ✓ (1) · 5 copies on CrucialX9, M4drive, LaCieWorkspace, Projects (4 checkable, 1 version, 1 noted, 1 offline) · 2 name-related (2 unhashed)")
        // A family with no archive copy says so, with the advice.
        let none = plan([copy("a.mov", vol: "LaCie", stars: 1)])
        XCTAssertEqual(none.logLine,
                       "what-next: a.mov — archive ✗ unverified (0) · 1 copy on LaCie (0 checkable, 1 locked: no archive copy) · advice: No archive copy yet — nothing here can go until one is promoted and verified.")
    }

    // MARK: QA RED (2026-09-20) — the archive copy of a VERSION is not an archive copy of the ORIGINAL

    /// Pins PrunePlan.swift:174-195 (group: pass A → pass B → pass A again)
    /// and :902-905 (plan: `archiveVerified` = ANY archive-side member).
    /// Rick trims tape.mov → tape_trimmed.mov and promotes only the TRIM.
    /// The original was never promoted; the only verified bytes in the
    /// archive are the trimmed ones. The second joinArchiveCopies pass
    /// pulls the trim's archive copy into the ORIGINAL's family, the
    /// family reads "In FamilyArchive, verified (1)", and the full-length
    /// original becomes a plain checkable "duplicate" — default-checked
    /// with keep-one off. "The last verified copy must never go."
    func testQARedAnArchivedVersionNeverMakesTheUnarchivedOriginalCheckable() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let original = copy("tape.mov", vol: "LaCie", key: "h:v1:full", size: 9_000)
        let trimmed = copy("tape_trimmed.mov", vol: "M4drive", key: "h:v1:trim", size: 2_000, version: true,
                           derivedFrom: original.id, kind: "trim")
        let archivedTrim = archiveCopy(key: "h:v1:trim", verified: true, promotedFrom: trimmed.id)
        let snaps = [original, trimmed, archivedTrim]
        let fams = ArchiveCopyFamilies.group(batch: [original.id], snapshots: snaps)
        XCTAssertEqual(fams.count, 1)
        let f = plan(fams[0], keepOne: false, bar: bar)
        let row = f.rows.first { $0.id == original.id }
        XCTAssertNotNil(row, "the original is listed")
        XCTAssertFalse(row?.checkable ?? true,
                       "tape.mov has NO verified archive copy of ITS content — only its trim is archived — yet it is checkable: \(String(describing: row))")
        XCTAssertFalse(f.defaultSelection.contains(original.id),
                       "the full-length original would go to the Trash by default while only the trimmed bytes are in the archive")
        XCTAssertFalse(f.trash.contains { $0.id == original.id })
        // The fix: the trim's archive copy is a header NOTE, never proof.
        XCTAssertTrue(f.archive.isEmpty && !f.archiveVerified && f.verifiedArchive == nil)
        XCTAssertEqual(f.versionArchive.map(\.id), [archivedTrim.id])
        XCTAssertEqual(f.advice, "Only a version of this is archived (archived.mov) — the original must be promoted and verified before anything here can go.")
        XCTAssertTrue(f.logLine.contains("archive ✗ unverified (0) + 1 version archived"), f.logLine)
        XCTAssertEqual(f.candidateCount, 0, "the trimmed row is locked with the rest")
        // Promote the ORIGINAL too and everything is as before: proof by
        // the promote link, the trim checkable on provenance.
        let archivedOriginal = archiveCopy(key: "h:v1:full", verified: true, promotedFrom: original.id)
        let both = plan(ArchiveCopyFamilies.group(batch: [original.id], snapshots: snaps + [archivedOriginal])[0], keepOne: false, bar: bar)
        XCTAssertEqual(both.archive.map(\.id), [archivedOriginal.id]); XCTAssertTrue(both.archiveVerified)
        XCTAssertEqual(both.verifiedArchive?.id, archivedOriginal.id)
        XCTAssertTrue(both.verifiedArchive?.fixityVerified ?? false)
        XCTAssertEqual(both.versionArchive.map(\.id), [archivedTrim.id])
        XCTAssertEqual(both.defaultSelection, [original.id])
        XCTAssertTrue(both.rows.first { $0.id == trimmed.id }?.checkable ?? false)
        // An archive copy that matches a NON-version member by CONTENT is proof
        // even without a promote link; one matching only a version's key is not.
        let byKey = plan([original, trimmed, archiveCopy(key: "h:v1:full", verified: true)], keepOne: false, bar: bar)
        XCTAssertTrue(byKey.archiveVerified && byKey.defaultSelection == [original.id])
        let byTrimKey = plan([original, trimmed, archiveCopy(key: "h:v1:trim", verified: true)], keepOne: false, bar: bar)
        XCTAssertFalse(byTrimKey.archiveVerified); XCTAssertEqual(byTrimKey.candidateCount, 0)
        // The selection counts what will be read byte-for-byte: duplicates only.
        let dup = copy("tape.mov", vol: "X9", key: "h:v1:full", size: 9_000)
        let three = plan([original, trimmed, dup, archivedOriginal], keepOne: false, bar: bar)
        let s = three.selection([original.id, trimmed.id, dup.id])
        XCTAssertEqual(s.count, 3); XCTAssertEqual(s.verifyCount, 1, "the original goes on its promote link, the trim on provenance, the dup must earn it")
        XCTAssertEqual(s.verifySentence, "1 copy will be checked byte-for-byte against the archive before it goes.")
        XCTAssertNil(PrunePlan.Selection.empty.verifySentence)
    }

    // MARK: The scrubbable-copy rule — every negative

    func testNoArchiveCopyOrUnverifiedArchiveKeepsEverything() {
        let a = copy("a.mov", vol: "LaCie", stars: 1), b = copy("b.mov", vol: "X9", stars: 1)
        let none = plan([a, b])
        XCTAssertFalse(none.covered); XCTAssertEqual(none.shortfall, "no archive copy")
        XCTAssertTrue(none.trash.isEmpty); XCTAssertNil(none.keeper)
        XCTAssertEqual(none.extraCount, 2, "extras are counted even when nothing may go")
        XCTAssertEqual(Set(none.kept.map(\.reason)), [.noArchiveCopy])
        XCTAssertTrue(none.archive.isEmpty && !none.archiveVerified)

        let unverified = plan([archiveCopy(verified: false, stars: 1), a, b])
        XCTAssertFalse(unverified.covered); XCTAssertEqual(unverified.shortfall, "archive copy unverified")
        XCTAssertTrue(unverified.kept.contains { $0.reason == .archiveUnverified })
        XCTAssertTrue(unverified.kept.contains { $0.reason == .archiveCopy })
        XCTAssertEqual(unverified.archive.count, 1); XCTAssertFalse(unverified.archiveVerified)
        // A version or a noted copy in such a family is refused like the rest — the
        // last verified copy never goes.
        let v = copy("a_trimmed.mov", vol: "LaCie", version: true, derivedFrom: a.id, kind: "trim")
        let n = copy("n.mov", vol: "X9", note: true)
        let f = plan([archiveCopy(verified: false, stars: 1), a, v, n])
        XCTAssertEqual(f.candidateCount, 0)
        XCTAssertTrue(f.rows.allSatisfy { $0.role == .kept(.archiveUnverified) }, "\(f.rows.map(\.role))")
        XCTAssertEqual(f.kept.filter { $0.reason == .archiveUnverified }.count, 3)
    }

    func testOfflineAndPairCopiesAreNeverElectedNorTrashedVersionsAndNotedCopiesAreCheckable() {
        // Low bar (★): archive alone is enough → everything plain goes.
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
        XCTAssertEqual(Set(g.trash.map(\.filename)), ["free1.mov", "free2.mov"], "versions and noted copies are never trashed by default")
        let reasons = Dictionary(uniqueKeysWithValues: g.kept.map { ($0.copy.filename, $0.reason) })
        XCTAssertEqual(reasons["off.mov"], .offline)
        XCTAssertEqual(reasons["pair.mxf"], .pairMember)
        XCTAssertEqual(reasons["bal.mov"], .version)
        XCTAssertEqual(reasons["noted.mov"], .humanNote)
        XCTAssertEqual(reasons["inside.mov"], .insideArchiveRoot)
        XCTAssertEqual(reasons["archived.mov"], .archiveCopy)
        XCTAssertEqual(g.extraCount, 4, "Rick's ruling: versions and noted copies are extra copies the person may check; offline / pair are not")
        XCTAssertEqual(g.extraBytes, 4_000)
        XCTAssertEqual(Set(g.checkableIDs), [free1.id, free2.id, version.id, noted.id])
        XCTAssertEqual(PrunePlan.KeepReason.offline.displayText, "drive not connected")
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
        XCTAssertEqual(p.checkableBytes, 60, "a1 + b1 + a2 — fam3 has no verified archive copy")
    }

    // MARK: The checklist (2026-09-20 — the bar advises, the person decides)

    func testRowsAreTheWorkingCopiesAndOnlyCandidatesWithAVerifiedArchiveAreCheckable() {
        var bar = ImportanceBar.defaults
        bar.important = .init(extraDevices: 0, cloudOrOffsite: false)
        let arch = archiveCopy(stars: 1)
        let offline = copy("off.mov", vol: "MyBook", online: false)
        let pair = copy("pair.mxf", vol: "LaCie", pair: true)
        let version = copy("bal.mov", vol: "LaCie", version: true, kind: "balanceAudio")
        let noted = copy("noted.mov", vol: "LaCie", note: true)
        let inside = copy("inside.mov", vol: "FamilyArchive", inside: true, working: false)
        let free1 = copy("free1.mov", vol: "LaCie", free: 900)
        let free2 = copy("free2.mov", vol: "X9", free: 100)
        let f = plan([free1, offline, pair, version, noted, inside, free2, arch], keepOne: true, bar: bar)
        XCTAssertTrue(f.covered); XCTAssertNil(f.advice)
        XCTAssertEqual(f.rows.map(\.copy.filename),
                       ["free1.mov", "off.mov", "pair.mxf", "bal.mov", "noted.mov", "free2.mov"],
                       "working copies in catalog order — the archive side is never a row")
        XCTAssertEqual(f.archive.map(\.filename), ["inside.mov", "archived.mov"])
        XCTAssertTrue(f.archiveVerified)
        let byName = Dictionary(uniqueKeysWithValues: f.rows.map { ($0.copy.filename, $0) })
        XCTAssertEqual(byName["off.mov"]?.role, .kept(.offline))
        XCTAssertEqual(byName["off.mov"]?.reasonText, "drive not connected")
        XCTAssertEqual(byName["pair.mxf"]?.role, .kept(.pairMember))
        XCTAssertEqual(byName["bal.mov"]?.role, .candidate)
        XCTAssertEqual(byName["bal.mov"]?.planKeeps, .version)
        XCTAssertEqual(byName["bal.mov"]?.kind, .balanced)
        XCTAssertEqual(byName["bal.mov"]?.defaultChecked, false)
        XCTAssertEqual(byName["noted.mov"]?.role, .candidate)
        XCTAssertEqual(byName["noted.mov"]?.planKeeps, .humanNote)
        XCTAssertEqual(byName["noted.mov"]?.hasNote, true)
        XCTAssertEqual(byName["noted.mov"]?.reasonText, "has your note — it will be carried to the archive copy")
        XCTAssertEqual(byName["noted.mov"]?.defaultChecked, false)
        XCTAssertEqual(byName["free1.mov"]?.role, .candidate)
        XCTAssertEqual(byName["free1.mov"]?.planKeeps, .keeper, "the elected keeper (most free space)")
        XCTAssertEqual(byName["free1.mov"]?.reasonText, "the plan would keep this one")
        XCTAssertEqual(byName["free1.mov"]?.defaultChecked, false)
        XCTAssertEqual(byName["free1.mov"]?.kind, .duplicate, "no promote link in this family — nothing is 'the original'")
        XCTAssertEqual(byName["free2.mov"]?.role, .candidate)
        XCTAssertNil(byName["free2.mov"]?.planKeeps); XCTAssertNil(byName["free2.mov"]?.reasonText)
        XCTAssertEqual(byName["free2.mov"]?.defaultChecked, true)
        XCTAssertEqual(f.candidateCount, 4, "the two free copies, the version and the noted copy")
        XCTAssertEqual(f.defaultSelection, Set(f.trash.map(\.id)), "default checks = the trash set")
        XCTAssertEqual(Set(f.rows.filter(\.checkable).map(\.id)), [free1.id, free2.id, version.id, noted.id])
        // keep-one off: both plain candidates default-checked; the keeper hint is gone.
        let g = plan([arch, free1, free2], keepOne: false, bar: bar)
        XCTAssertEqual(g.defaultSelection, [free1.id, free2.id])
        XCTAssertTrue(g.rows.filter(\.checkable).allSatisfy { $0.planKeeps == nil })
        // Plan-level views.
        let p = PrunePlan.compute(families: [[free1, offline, pair, version, noted, inside, free2, arch]],
                                  options: .init(bar: bar))
        XCTAssertEqual(p.defaultSelection, Set(p.trashFiles.map(\.id)))
        XCTAssertEqual(p.checkableIDs, [free1.id, free2.id, version.id, noted.id])
        XCTAssertEqual(p.checkableCount, 4); XCTAssertEqual(p.rowCount, 6)
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
        let working = f.rows
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
        XCTAssertEqual(unverified.rows.map(\.role), [.kept(.archiveUnverified), .kept(.archiveUnverified)],
                       "the archive copy is the header, not a row")
        XCTAssertEqual(unverified.rows[0].reasonText, "archive copy unverified")
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
        let both = PrunePlan.compute(families: [f1, f1.map { var c = $0; c.id = UUID(); c.contentKey = "h:9"; c.promotedFromID = nil; c.derivedFrom = nil; return c }],
                                     options: .init(bar: bar))
        let s2 = both.selection(both.checkableIDs)
        XCTAssertEqual(s2.overrideShortfalls.count, 1, "the same shortfall is said once")
        XCTAssertEqual(s2.archiveOnlySentence, "archived.mov and 1 more will exist only in the Master Archive after this.")
    }

    // MARK: Scale

    func testScale100kSnapshotsIn5kFamiliesUnderBudget() {
        let volumes = ["LaCie", "Projects", "MyBook", "X9", "X10", "Movies"]
        var snaps: [ArchiveCopySnapshot] = []
        snaps.reserveCapacity(120_000)
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
        // v3: 10k versions (one trim per family, one two-hop cleanup per
        // other family) join by provenance; 10k unhashed name-related
        // records are "might be copies".
        var versions: [ArchiveCopySnapshot] = []
        var maybes: [ArchiveCopySnapshot] = []
        for g in 0..<5_000 {
            let src = snaps[g * 20]
            let t = copy("g\(g)_c0_trimmed.mov", vol: "Projects", key: "h:v1:t\(g)", version: true, derivedFrom: src.id, kind: "trim")
            versions.append(t)
            versions.append(copy("g\(g)_c0_trimmed_balanced.mov", vol: "Projects", key: "h:v1:b\(g)", version: true,
                                 derivedFrom: g % 2 == 0 ? t.id : src.id, kind: "balanceAudio"))
            maybes.append(copy("g\(g)_c0 copy.mov", vol: "X10", key: ""))
            maybes.append(copy("g\(g)_c0.mov", vol: "Movies", key: ""))
        }
        snaps += versions + maybes
        XCTAssertEqual(snaps.count, 120_000)
        let clock = ContinuousClock()
        var families: [[ArchiveCopySnapshot]] = []
        var related: [ArchiveCopyFamilies.RelatedGroup] = []
        var p = PrunePlan.empty
        let elapsed = clock.measure {
            families = ArchiveCopyFamilies.group(batch: batch, snapshots: snaps)
            related = ArchiveCopyFamilies.nameRelated(families: families, snapshots: snaps, baseStem: baseStem)
            p = PrunePlan.compute(families: families, related: related, options: .init())
        }
        XCTAssertEqual(families.count, 5_000)
        XCTAssertEqual(families.reduce(0) { $0 + $1.count }, 110_000, "every version joined its family")
        XCTAssertEqual(p.families.count, 5_000)
        XCTAssertEqual(p.relatedCount, 10_000, "every unhashed name-related record is a might-be row")
        XCTAssertEqual(p.notCoveredCount, 5_000 - 1_667, "only every third family attested a cloud copy")
        XCTAssertGreaterThan(p.trashCount, 0)
        XCTAssertLessThan(elapsed, .seconds(4), "group + related + compute took \(elapsed) for 120k snapshots")
        // The checklist views are O(rows): 105k working rows, default
        // checks = the trash set, a whole-batch selection judged in well
        // under a second.
        XCTAssertEqual(p.rowCount, 105_000, "19 copies + 2 versions per family; archive copies are not rows")
        var sel = PrunePlan.Selection.empty
        var dflt = Set<UUID>()
        let selElapsed = clock.measure {
            dflt = p.defaultSelection
            sel = p.selection(p.checkableIDs)
        }
        XCTAssertEqual(dflt, Set(p.trashFiles.map(\.id)))
        XCTAssertEqual(sel.count, p.checkableCount)
        XCTAssertGreaterThan(sel.overrideCount, 0)
        XCTAssertLessThan(selElapsed, .seconds(1), "selection views took \(selElapsed) for 105k rows")
        var lines = 0
        let logElapsed = clock.measure { for f in p.families { lines += f.logLine.count } }
        XCTAssertGreaterThan(lines, 0)
        XCTAssertLessThan(logElapsed, .seconds(2), "log lines took \(logElapsed) for 5k families")
        let protection = ArchiveCopyFamilies.protection(families: families)
        XCTAssertEqual(protection.familyCount, 5_000)
        XCTAssertEqual(protection.archive, .verified)
    }
}

private extension ArchiveCopySnapshot {
    func with(path: String) -> ArchiveCopySnapshot { var c = self; c.fullPath = path; return c }
}
