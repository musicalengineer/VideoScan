// CatalogTrashPairGroupTests.swift
// DECISIONS 2026-11-01: Delete Selected Files… may take a whole recovered
// audio/video pair group at once. A half is refused only when it would be
// orphaned; a group is never split — every half moves or none does.
//
//   LOGIC     — the pure plan: a full group admitted; one half missing →
//               the whole group held with the sibling named; mixed
//               selections (group halves contiguous); a Combine output
//               keeps its refusal; unknown links held; a departed sibling.
//   ISOLATION — real files through the one Trash routine: a sibling offline,
//               changed on disk or re-linked in the catalog between the plan
//               and the move, or on FamilyArchive → the group is held and
//               nothing moves; a Trash failure on the second half is a
//               named SPLIT, never success.
//   TRUTH     — the sheet's words from the plan, the OUTCOME line, the
//               ledger event carrying the pair.
//   MEDIA     — mxf (OP-1a video + OP-Atom audio) and avi (dv + pcm) halves.
//   SCALE     — 100k rows, 5k groups selected whole: the plan in budget.
// The sensor half is CatalogTrashPairGroupSensorTests.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Catalog Delete Selected Files — whole A/V pair groups", .serialized)
@MainActor
struct CatalogTrashPairGroupTests {

    // MARK: Fixtures

    private static let stubID = PairHalfIdentity(device: 1, inode: 1, size: 1, mtimeNs: 1)

    private func rec(_ path: String, _ stream: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = stream.rawValue
        r.sizeBytes = 1_000
        return r
    }

    /// Link `halves` as one group the way the correlator does (first ↔ second).
    @discardableResult
    private func pair(_ halves: VideoRecord...) -> UUID {
        let gid = UUID()
        for h in halves { h.pairGroupID = gid }
        if halves.count == 2 { halves[0].pairedWith = halves[1]; halves[1].pairedWith = halves[0] }
        return gid
    }

    private func plan(_ sel: [VideoRecord], catalog: [VideoRecord],
                      archive: Set<UUID> = [], offline: Set<UUID> = [],
                      unreadable: Set<UUID> = []) -> VideoScanModel.CatalogTrashPlan {
        VideoScanModel.catalogTrashPlan(
            for: sel, catalog: catalog,
            isMasterArchive: { archive.contains($0.id) }, isOffline: { offline.contains($0.id) },
            identity: { unreadable.contains($0.id) ? nil : Self.stubID })
    }

    private struct Disk {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
    }

    private func disk(_ label: String, archive: Bool = false) throws -> Disk {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        if archive { try MasterArchiveTestSupport.initialize(model, in: sb) }
        return Disk(sb: sb, model: model)
    }

    private func file(_ d: Disk, _ name: String, seed: UInt64, _ stream: StreamType, in dir: URL? = nil) throws -> VideoRecord {
        let url = try MasterArchiveTestSupport.writeBlob(at: (dir ?? d.sb.sources).appendingPathComponent(name), bytes: 1024, seed: seed)
        return MasterArchiveTestSupport.makeRecord(path: url.path, streamType: stream)
    }

    private func exists(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }

    private func consoleLine(_ model: VideoScanModel, containing s: String) async -> String? {
        for _ in 0..<200 {
            if let line = model.dashboard.consoleLines.first(where: { $0.contains(s) }) { return line }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    // MARK: LOGIC — the pure plan

    @Test("red probe: every half of a group selected → both halves move to the Trash")
    func fullGroupMoves() async throws {
        let d = try disk("pairgroup")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_pg.V01.mxf", seed: 1, .videoOnly)
        let a = try file(d, "test_pg.A01.mxf", seed: 2, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let plan = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        #expect(plan.toTrash == [v.id, a.id], "\(plan.refused)")
        // The only-copy warning is unchanged for a pair's halves.
        #expect(plan.onlyCopy == [v.id, a.id])
        let sheet = CatalogTrashConfirmation(plan: plan, sizes: [v.id: 1_024, a.id: 1_024])
        #expect(sheet.onlyCopyWarning == "⚠︎ 2 of these are the only copy we know of." && !sheet.moveIsDefault)
        #expect(sheet.title == "Move 2 files · 1 pair group (2 KB) to the Trash?")
        let result = await d.model.trashSelectedRecords([v, a], confirmed: plan)
        #expect(result.succeeded == 2, "\(result.refused.map(\.reason))")
        #expect(!exists(v) && !exists(a))
        #expect(v.isPurged && a.isPurged && v.removal?.state == .inTrash && a.removal?.state == .inTrash)
    }

    @Test("logic: the whole group selected is admitted as one unit")
    func fullGroupAdmitted() {
        let v = rec("/Volumes/X9/avid/test_g.V01.mxf", .videoOnly)
        let a = rec("/Volumes/X9/avid/test_g.A01.mxf", .audioOnly)
        let gid = pair(v, a)
        let other = rec("/Volumes/X9/test_other.mov")
        let p = plan([a, v], catalog: [other, v, a])
        #expect(p.toTrash == [a.id, v.id])
        #expect(p.refused.isEmpty)
        #expect(p.groups.count == 1)
        #expect(p.groups.first?.key == gid)
        #expect(p.groups.first?.members == [a.id, v.id])
        #expect(p.groups.first?.identities == [Self.stubID, Self.stubID])
        #expect(p.heldGroups.isEmpty)
    }

    @Test("logic: one half missing from the selection holds the whole group, naming the sibling")
    func oneMissingHoldsTheGroup() {
        let v = rec("/Volumes/X9/avid/test_g.V01.mxf", .videoOnly)
        let a = rec("/Volumes/X9/avid/test_g.A01.mxf", .audioOnly)
        pair(v, a)
        let p = plan([v], catalog: [v, a])
        #expect(p.toTrash.isEmpty)
        #expect(p.groups.isEmpty)
        #expect(p.refused.map(\.reason) == [.pairMember])
        let note = p.refused.first?.note
        #expect(note?.contains("test_g.A01.mxf") == true, "\(String(describing: note))")
        #expect(note?.hasPrefix("is half of a recovered audio/video pair, which Combine still needs") == true)
        #expect(p.heldGroups == [.init(filenames: ["test_g.V01.mxf"], reason: "its related half test_g.A01.mxf is not selected", ids: [v.id])])
    }

    @Test("logic: a three-half group with one half missing holds both selected halves")
    func threeHalvesOneMissing() {
        let v = rec("/Volumes/X9/avid/test_t.V01.mxf", .videoOnly)
        let a1 = rec("/Volumes/X9/avid/test_t.A01.mxf", .audioOnly)
        let a2 = rec("/Volumes/X9/avid/test_t.A02.mxf", .audioOnly)
        pair(v, a1, a2)
        let p = plan([v, a1], catalog: [v, a1, a2])
        #expect(p.toTrash.isEmpty)
        #expect(p.refused.map(\.reason) == [.pairMember, .pairMember])
        #expect(p.refused.allSatisfy { $0.note?.contains("test_t.A02.mxf") == true })
        let all = plan([a2, v, a1], catalog: [v, a1, a2])
        #expect(all.toTrash == [a2.id, v.id, a1.id])
        #expect(all.groups.first?.relatedCount == 2)
    }

    @Test("logic: mixed selection — ordinary rows keep their order, a group's halves move together, an incomplete group is held")
    func mixedSelection() {
        let o1 = rec("/Volumes/X9/test_o1.mov"), o2 = rec("/Volumes/X9/test_o2.mov")
        let v1 = rec("/Volumes/X9/avid/test_m1.V.mxf", .videoOnly), a1 = rec("/Volumes/X9/avid/test_m1.A.mxf", .audioOnly)
        let v2 = rec("/Volumes/X9/avid/test_m2.V.mxf", .videoOnly), a2 = rec("/Volumes/X9/avid/test_m2.A.mxf", .audioOnly)
        pair(v1, a1); pair(v2, a2)
        let p = plan([o1, v1, o2, a1, v2], catalog: [o1, o2, v1, a1, v2, a2])
        #expect(p.toTrash == [o1.id, v1.id, a1.id, o2.id], "a group's halves follow its first selected half")
        #expect(p.refused.map(\.id) == [v2.id])
        #expect(p.refused.first?.note?.contains("test_m2.A.mxf") == true)
        #expect(p.groups.map(\.members) == [[v1.id, a1.id]])
        #expect(p.heldGroups.count == 1)
    }

    @Test("logic: a Combine output among the halves keeps its refusal and is never a member")
    func combineOutputAmongHalves() {
        let v = rec("/Volumes/X9/avid/test_c.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_c.A.mxf", .audioOnly)
        let gid = pair(v, a)
        let combined = rec("/Volumes/X9/out/test_c_combined.mov")
        combined.combinedFromPairID = gid
        // A Combine output carrying the pair's group id is still not a half.
        combined.pairGroupID = gid
        let p = plan([v, combined, a], catalog: [v, a, combined])
        #expect(p.toTrash == [v.id, a.id])
        #expect(p.refused.map(\.id) == [combined.id])
        #expect(p.refused.first?.reason == .pairMember && p.refused.first?.note == nil, "the existing Combine-output rule")
        #expect(p.groups.first?.members == [v.id, a.id])
        let alone = plan([combined], catalog: [v, a, combined])
        #expect(alone.toTrash.isEmpty && alone.refused.map(\.reason) == [.pairMember])
    }

    @Test("logic: a half with no known sibling, or a link the catalog can't follow, is held")
    func unknownGroupsAreHeld() {
        let lone = rec("/Volumes/X9/avid/test_lone.V.mxf", .videoOnly)
        lone.pairGroupID = UUID()
        let p1 = plan([lone], catalog: [lone])
        #expect(p1.toTrash.isEmpty && p1.refused.map(\.reason) == [.pairMember])
        #expect(p1.refused.first?.note?.contains("can't find every related half") == true)

        let v = rec("/Volumes/X9/avid/test_u.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_u.A.mxf", .audioOnly)
        pair(v, a)
        v.pendingPairedWithID = UUID()   // a decoded reference with no row
        let p2 = plan([v, a], catalog: [v, a])
        #expect(p2.toTrash.isEmpty && p2.refused.count == 2 && p2.groups.isEmpty)

        let x = rec("/Volumes/X9/avid/test_x.V.mxf", .videoOnly), ghost = rec("/Volumes/X9/avid/test_x.A.mxf", .audioOnly)
        x.pairedWith = ghost   // partner object that is not a catalog row
        let p3 = plan([x], catalog: [x])
        #expect(p3.toTrash.isEmpty && p3.refused.map(\.reason) == [.pairMember])
    }

    @Test("logic: a sibling already removed from the catalog no longer holds the rest; the sheet names it")
    func departedSibling() {
        let v = rec("/Volumes/X9/avid/test_d.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_d.A.mxf", .audioOnly)
        pair(v, a)
        a.purgedAt = Date()
        let p = plan([v], catalog: [v, a])
        #expect(p.toTrash == [v.id])
        #expect(p.groups.first?.departed == ["test_d.A.mxf"])
        let c = CatalogTrashConfirmation(plan: p, sizes: [v.id: 1_000])
        #expect(c.groupLines == ["Move this clip to the Trash: test_d.V.mxf (test_d.A.mxf was already removed from the catalog)."])
    }

    @Test("logic: a sibling refused on its own (archive, offline, set aside, unreadable) holds the whole group")
    func siblingRefusedAloneHoldsTheGroup() {
        let v = rec("/Volumes/X9/avid/test_s.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_s.A.mxf", .audioOnly)
        pair(v, a)
        let arch = plan([v, a], catalog: [v, a], archive: [a.id])
        #expect(arch.toTrash.isEmpty)
        #expect(arch.refused.map(\.reason) == [.pairGroupHeld, .masterArchive])
        #expect(arch.refused.first?.note?.contains("test_s.A.mxf") == true)
        let off = plan([v, a], catalog: [v, a], offline: [v.id])
        #expect(off.toTrash.isEmpty && off.refused.map(\.reason) == [.offlineVolume, .pairGroupHeld])
        let unread = plan([v, a], catalog: [v, a], unreadable: [a.id])
        #expect(unread.toTrash.isEmpty && unread.refused.map(\.reason) == [.pairGroupHeld, .pairGroupHeld])
        #expect(unread.refused.allSatisfy { $0.note?.contains("test_s.A.mxf can't be read") == true })
        a.setAsideReason = CatalogScopePolicy.SetAsideReason.unlinkedAudio.rawValue
        let aside = plan([v, a], catalog: [v, a])
        #expect(aside.toTrash.isEmpty && aside.refused.map(\.reason) == [.pairGroupHeld, .notActive])
    }

    @Test("logic: Select Related Halves selects the group's rows on screen and names a hidden one")
    func selectRelatedHalves() {
        let v = rec("/Volumes/X9/avid/test_r.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_r.A.mxf", .audioOnly)
        pair(v, a)
        let other = rec("/Volumes/X9/test_r_other.mov")
        let all = CatalogPairGroups.relatedSelection(of: v, catalog: [other, v, a], shown: { $0 })
        #expect(all.select == [v.id, a.id])
        #expect(all.line == "Select Related Halves: selected 2 halves of test_r.V.mxf's clip — test_r.V.mxf and test_r.A.mxf.")
        let hidden = CatalogPairGroups.relatedSelection(of: v, catalog: [other, v, a], shown: { $0.subtracting([a.id]) })
        #expect(hidden.select == [v.id])
        #expect(hidden.line.contains("selected 1 of 2 halves — test_r.A.mxf is hidden by the current filter or folder view"))
    }

    // MARK: ISOLATION — real files through the one routine

    @Test("isolation: a sibling's drive goes away before the move → the group is held, nothing moved")
    func siblingOfflineAtTheTurn() throws {
        let d = try disk("pgoff")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_off.V.mxf", seed: 11, .videoOnly), a = try file(d, "test_off.A.mxf", seed: 12, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.groups.count == 1)
        let turns = CatalogTrashGroupTurns(groups: p.groups)
        let why = turns.problem(v, model: d.model, isOffline: { $0.id == a.id })
        #expect(why?.contains("the drive of its related half test_off.A.mxf is not connected") == true, "\(String(describing: why))")
        turns.settled(v.id, moved: false)
        #expect(turns.problem(a, model: d.model, isOffline: { _ in false })?.contains("a pair moves whole or not at all") == true,
                "once a group is stopped, its later halves stay too")
        #expect(exists(v) && exists(a))
    }

    @Test("isolation: a sibling rewritten on disk after the confirmation → both halves stay")
    func siblingChangedOnDisk() async throws {
        let d = try disk("pgchg")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_chg.V.mxf", seed: 21, .videoOnly), a = try file(d, "test_chg.A.mxf", seed: 22, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.groups.count == 1)
        // Replaced after the alert: a new file (new inode, new mtime) at the path.
        try Data(repeating: 7, count: 1024).write(to: URL(fileURLWithPath: a.fullPath), options: .atomic)
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a))
        #expect(!v.isPurged && !a.isPurged)
        #expect(result.refused.first { $0.record.id == v.id }?.reason.contains("test_chg.A.mxf changed or went away on disk") == true,
                "\(result.refused.map(\.reason))")
        #expect(result.refused.first { $0.record.id == a.id }?.reason.contains("test_chg.V.mxf did not move") == true)
        #expect(await consoleLine(d.model, containing: "pair groups: moved 0 · held 1 · failed 0 · split 0") != nil)
        await d.model.mediaLedger.waitForPendingWrites()
        #expect(d.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }.isEmpty)
    }

    @Test("isolation: a sibling re-linked or removed in the catalog after the confirmation → both stay")
    func siblingChangedInTheCatalog() async throws {
        let d = try disk("pgcat")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_cat.V.mxf", seed: 31, .videoOnly), a = try file(d, "test_cat.A.mxf", seed: 32, .audioOnly)
        let x = try file(d, "test_cat.X.mxf", seed: 33, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, x]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.groups.count == 1)
        // Re-correlated: v now pairs with x; a is unpaired.
        let gid = UUID()
        v.pairGroupID = gid; x.pairGroupID = gid; v.pairedWith = x; x.pairedWith = v
        a.pairGroupID = nil; a.pairedWith = nil
        let r1 = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(r1.succeeded == 0 && exists(v) && exists(a) && exists(x),
                "the confirmed pair is never split: a, now unpaired, stays with v — \(r1.items.map(\.outcome))")
        // Held up front since Codex #191 F2: the plan sees the pair changed.
        #expect(r1.refused.first { $0.record.id == a.id }?.reason.contains("the pair changed since you confirmed") == true,
                "\(r1.refused.map(\.reason))")

        // Removed: the sibling purged after the alert — the rest is not the pair confirmed.
        let w = try file(d, "test_cat2.V.mxf", seed: 34, .videoOnly), b = try file(d, "test_cat2.A.mxf", seed: 35, .audioOnly)
        pair(w, b)
        d.model.records += [w, b]
        let confirmed2 = d.model.catalogTrashPlan(for: [w, b], isOffline: { _ in false })
        try #require(confirmed2.groups.count == 1)
        b.purgedAt = Date()
        let r2 = await d.model.trashSelectedRecords([w, b], confirmed: confirmed2)
        #expect(r2.succeeded == 0 && exists(w) && exists(b), "\(r2.items.map(\.outcome))")
        #expect(r2.refused.first { $0.record.id == w.id }?.reason.contains("the pair changed since you confirmed") == true,
                "\(r2.refused.map(\.reason))")
    }

    @Test("isolation: a pair the alert did not confirm whole never moves, even when it is whole now")
    func unconfirmedPairNeverMoves() async throws {
        let d = try disk("pgunc")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_unc.V.mxf", seed: 36, .videoOnly), a = try file(d, "test_unc.A.mxf", seed: 37, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let confirmedOnlyV = d.model.catalogTrashPlan(for: [v], isOffline: { _ in false })
        #expect(confirmedOnlyV.toTrash.isEmpty && confirmedOnlyV.groups.isEmpty)
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmedOnlyV)
        #expect(result.succeeded == 0 && exists(v) && exists(a))
        #expect(result.refused.allSatisfy { $0.reason == CatalogTrashGroupTurns.notConfirmedAsGroupNote }, "\(result.refused.map(\.reason))")
        #expect(await consoleLine(d.model, containing: "kept the pair test_unc.V.mxf and test_unc.A.mxf — the pair changed since you confirmed") != nil)
    }

    /// A half with a known copy elsewhere, its row carrying a whole-file
    /// SHA-256 fixity stamped from the file (the only-copy gate's identity).
    private func fileWithFixity(_ d: Disk, _ name: String, bytes: Data, _ stream: StreamType) throws -> VideoRecord {
        let url = d.sb.sources.appendingPathComponent(name)
        try bytes.write(to: url)
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, streamType: stream)
        r.sizeBytes = Int64(bytes.count)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(bytes.count))
        return r
    }

    @Test("isolation: the second half's surviving copy went away in the catalog after the confirmation → the pair is held before the first half moves")
    func laterHalfBecameOnlyCopyHoldsThePair() async throws {
        let d = try disk("pglatecat")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_lc.V.mxf", seed: 71, .videoOnly)
        let aBytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) })
        let a = try fileWithFixity(d, "test_lc.A.mxf", bytes: aBytes, .audioOnly)
        let aCopy = try fileWithFixity(d, "test_lc.A copy.mxf", bytes: aBytes, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, aCopy]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.toTrash == [v.id, a.id])
        try #require(confirmed.onlyCopy == [v.id], "a has a known copy: no warning for it")
        aCopy.purgedAt = Date()   // another door removed the copy while the alert was up
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(result.succeeded == 0 && exists(v) && exists(a), "never split: \(result.items.map(\.outcome))")
        #expect(result.refused.first { $0.record.id == v.id }?.reason.contains("its related half test_lc.A.mxf is now the only copy") == true,
                "\(result.refused.map(\.reason))")
        #expect(result.groupNotes.allSatisfy { !$0.hasPrefix("Split pair") })
    }

    @Test("isolation: the second half's surviving copy was rewritten on disk → the pair is held before the first half moves")
    func laterHalfCopyNotProvenHoldsThePair() async throws {
        let d = try disk("pglatedisk")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_ld.V.mxf", seed: 72, .videoOnly)
        let aBytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) })
        let a = try fileWithFixity(d, "test_ld.A.mxf", bytes: aBytes, .audioOnly)
        let aCopy = try fileWithFixity(d, "test_ld.A copy.mxf", bytes: aBytes, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, aCopy]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.onlyCopy == [v.id])
        // The catalog still claims the copy; the bytes at its path are new.
        try Data(repeating: 9, count: aBytes.count).write(to: URL(fileURLWithPath: aCopy.fullPath), options: .atomic)
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(result.succeeded == 0 && exists(v) && exists(a), "never split: \(result.items.map(\.outcome))")
        #expect(result.refused.first { $0.record.id == v.id }?.reason.contains("test_ld.A.mxf") == true, "\(result.refused.map(\.reason))")
        #expect(result.groupNotes.allSatisfy { !$0.hasPrefix("Split pair") })
    }

    @Test("isolation: a later half's drive marked Read only after the confirmation holds the pair at the first half's turn")
    func laterHalfOnReadOnlyDrive() {
        let v = rec("/Volumes/TestPGRW/avid/test_ro.V.mxf", .videoOnly), a = rec("/Volumes/TestPGRO/avid/test_ro.A.mxf", .audioOnly)
        pair(v, a)
        let m = VideoScanModel()
        m.records = [v, a]
        let p = plan([v, a], catalog: [v, a])
        try? #require(p.groups.count == 1)
        let turns = CatalogTrashGroupTurns(groups: p.groups)
        let args = (confirmed: Set(p.toTrash), warned: Set(p.toTrash))
        #expect(m.catalogTrashLaterHalvesProblem(v, groups: turns, confirmed: args.confirmed, warnedOnlyCopy: args.warned,
                                                 copies: CatalogTrashTurnCopies(batch: [v, a]), proofs: CatalogTrashMoveProofs()) == nil)
        let ro = CatalogScanTarget(searchPath: "/Volumes/TestPGRO")
        ro.role = .workspace
        ro.isReachable = true
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        m.scanTargets = [ro]
        let why = m.catalogTrashLaterHalvesProblem(v, groups: turns, confirmed: args.confirmed, warnedOnlyCopy: args.warned,
                                                   copies: CatalogTrashTurnCopies(batch: [v, a]), proofs: CatalogTrashMoveProofs())
        #expect(why?.contains("its related half test_ro.A.mxf is in the Master Archive or on a protected drive") == true, "\(String(describing: why))")
        turns.settled(v.id, moved: false)
        #expect(turns.problem(a, model: m, isOffline: { _ in false }) != nil, "the stopped pair keeps its later half too")
    }

    @Test("isolation: a sibling on FamilyArchive is refused — nothing of the group moves, the archive file is untouched")
    func siblingOnFamilyArchive() async throws {
        let d = try disk("pgarch", archive: true)
        defer { d.sb.cleanup() }
        let dir = d.sb.archiveRoot.appendingPathComponent("30_Video", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let v = try file(d, "test_fa.V.mxf", seed: 41, .videoOnly)
        let a = try file(d, "test_fa.A.mxf", seed: 42, .audioOnly, in: dir)
        pair(v, a)
        d.model.records = [v, a]
        #expect(d.model.isInsideMasterArchive(path: a.fullPath))
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        #expect(p.toTrash.isEmpty && p.groups.isEmpty)
        #expect(p.refused.map(\.reason) == [.pairGroupHeld, .masterArchive])
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p)
        #expect(result.succeeded == 0 && exists(v) && exists(a))
    }

    @Test("isolation: the Trash refuses the second half after the first moved → reported SPLIT with where each file is, never success")
    func secondHalfFailsIsASplit() async throws {
        let d = try disk("pgsplit")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_sp.V.mxf", seed: 51, .videoOnly), a = try file(d, "test_sp.A.mxf", seed: 52, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.toTrash == [v.id, a.id])
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let aPath = a.fullPath
        struct NoTrash: Error {}
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            if url.path == aPath { throw NoTrash() }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        })
        #expect(result.succeeded == 1 && !exists(v) && exists(a))
        #expect(result.groupNotes.contains { $0.hasPrefix("Split pair: test_sp.V.mxf is in the Trash") && $0.contains("test_sp.A.mxf stayed at \(aPath)") },
                "\(result.groupNotes)")
        #expect(JunkDeletionReport(result).summary.contains { $0.contains("1 SPLIT") })
        #expect(await consoleLine(d.model, containing: "pair groups: moved 0 · held 0 · failed 0 · split 1") != nil)
        #expect(await consoleLine(d.model, containing: "SPLIT PAIR") != nil)
    }

    // MARK: Codex #191 — the seven P1 regressions (red first)

    /// A non-Sendable reference handed into the @Sendable seams. (≈ a C++
    /// raw pointer the test promises to touch only on the main thread.)
    private final class Ref<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    @Test("codex #191 F1: a stale selected sibling (same id, other path) never moves an unchecked file")
    func staleSelectedSiblingNeverMoves() async throws {
        let d = try disk("pgstale")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_st.V.mxf", seed: 81, .videoOnly)
        let liveA = try file(d, "test_st.A.mxf", seed: 82, .audioOnly)
        pair(v, liveA)
        let staleURL = try MasterArchiveTestSupport.writeBlob(at: d.sb.sources.appendingPathComponent("test_st_old.A.mxf"), bytes: 1024, seed: 83)
        let staleA = liveA.snapshotClone()
        staleA.fullPath = staleURL.path
        staleA.filename = staleURL.lastPathComponent
        d.model.records = [v, liveA]
        let confirmed = d.model.catalogTrashPlan(for: [v, staleA], isOffline: { _ in false })
        let result = await d.model.trashSelectedRecords([v, staleA], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(liveA) && FileManager.default.fileExists(atPath: staleURL.path))
    }

    @Test("codex #191 F2: a sibling that joined the pair after the confirmation holds the whole pair")
    func unconfirmedMembershipHoldsTheGroup() async throws {
        let d = try disk("pgjoin")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_jn.V.mxf", seed: 84, .videoOnly), a = try file(d, "test_jn.A.mxf", seed: 85, .audioOnly)
        let x = try file(d, "test_jn.X.mxf", seed: 86, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, x]
        let confirmed = d.model.catalogTrashPlan(for: [v, a, x], isOffline: { _ in false })
        try #require(confirmed.groups.map(\.members) == [[v.id, a.id]])
        x.pairedWith = v   // linked to the pair while the alert was up
        let result = await d.model.trashSelectedRecords([v, a, x], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a) && exists(x))
    }

    @Test("codex #191 F3: a relink after the first half moved never hides the SPLIT")
    func relinkDoesNotHideASplit() async throws {
        let d = try disk("pgrelink")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_rl.V.mxf", seed: 87, .videoOnly), a = try file(d, "test_rl.A.mxf", seed: 88, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.toTrash == [v.id, a.id])
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vPath = v.fullPath, aPath = a.fullPath
        let vRef = Ref(v)
        struct NoTrash: Error {}
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            if url.path == aPath { throw NoTrash() }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            if url.path == vPath {
                DispatchQueue.main.sync { MainActor.assumeIsolated { vRef.value.fullPath = "/Volumes/TestRelinked/test_rl.V.mxf" } }
            }
        })
        #expect(result.succeeded == 1, "\(result.items.map(\.outcome))")
        #expect(result.items.first { $0.record.id == v.id }?.outcome.isMoved == true, "the moved half's outcome is kept")
        #expect(result.groupNotes.contains { $0.hasPrefix("Split pair: test_rl.V.mxf is in the Trash") }, "\(result.groupNotes)")
        #expect(exists(a))
    }

    @Test("codex #191 F4: a later half another job holds reserved holds the first half too")
    func reservedLaterHalfHoldsTheGroup() async throws {
        let d = try disk("pgres")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_rs.V.mxf", seed: 89, .videoOnly), a = try file(d, "test_rs.A.mxf", seed: 90, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.toTrash == [v.id, a.id])
        guard case .reserved(let key) = RemovalReservations.shared.reserve(a.fullPath) else {
            Issue.record("fixture: could not reserve A"); return
        }
        defer { RemovalReservations.shared.release(key) }
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a))
    }

    @Test("codex #191 F5: a pending link on a half that also has an object link is followed in reverse")
    func reversePendingLinkIsFollowed() {
        let v = rec("/Volumes/X9/avid/test_pl.V.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_pl.A.mxf", .audioOnly)
        let x = rec("/Volumes/X9/avid/test_pl.X.mxf", .videoOnly), y = rec("/Volumes/X9/avid/test_pl.Y.mxf", .audioOnly)
        pair(v, a); pair(x, y)
        x.pendingPairedWithID = v.id
        let p = plan([v, a], catalog: [v, a, x, y])
        #expect(p.toTrash.isEmpty && p.groups.isEmpty, "\(p.refused)")
    }

    @Test("codex #191 F6: a sibling missing on disk is no departed sibling — it holds the group")
    func missingSiblingHoldsTheGroup() {
        let v = rec("/Volumes/X9/avid/test_ms.V.mxf", .videoOnly)
        let a1 = rec("/Volumes/X9/avid/test_ms.A1.mxf", .audioOnly), a2 = rec("/Volumes/X9/avid/test_ms.A2.mxf", .audioOnly)
        pair(v, a1, a2)
        VideoScanModel.stampRemoval(a2, .missing(noticedAt: Date(), lastSeen: nil, reason: .missingOnDisk))
        try? #require(a2.isPurged)
        let p = plan([v, a1], catalog: [v, a1, a2])
        #expect(p.toTrash.isEmpty && p.groups.isEmpty, "\(p.refused)")
        #expect(p.refused.allSatisfy { $0.note?.contains("test_ms.A2.mxf") == true }, "\(p.refused.map(\.note))")
    }

    @Test("codex #191 F7: Stop between the halves of a pair never splits it — cancel takes effect between pairs")
    func cancelBetweenHalvesNeverSplits() async throws {
        let d = try disk("pgcancel")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_cn.V.mxf", seed: 91, .videoOnly), a = try file(d, "test_cn.A.mxf", seed: 92, .audioOnly)
        let w = try file(d, "test_cn2.V.mxf", seed: 93, .videoOnly), b = try file(d, "test_cn2.A.mxf", seed: 94, .audioOnly)
        pair(v, a); pair(w, b)
        d.model.records = [v, a, w, b]
        let p = d.model.catalogTrashPlan(for: [v, a, w, b], isOffline: { _ in false })
        try #require(p.toTrash == [v.id, a.id, w.id, b.id])
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vPath = v.fullPath
        let handle = Ref<Task<Int, Never>?>(nil)
        let model = d.model
        let sel = Ref([v, a, w, b])
        let task = Task { @MainActor in
            await model.trashSelectedRecords(sel.value, confirmed: p, fileOperation: { url in
                try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
                if url.path == vPath { handle.value?.cancel() }   // Stop pressed after the first half moved
            }).succeeded
        }
        handle.value = task
        let moved = await task.value
        #expect(moved == 2, "the started pair completes; the next pair is not started")
        #expect(!exists(v) && !exists(a), "never split")
        #expect(exists(w) && exists(b))
    }

    // MARK: TRUTH — the sheet, the OUTCOME line, the ledger

    @Test("truth: the sheet says what the plan admitted — files · pair groups, one line per group, the held reasons")
    func sheetWordsFromThePlan() {
        let v = rec("/Volumes/X9/avid/test_w.V01.mxf", .videoOnly), a = rec("/Volumes/X9/avid/test_w.A01.mxf", .audioOnly)
        let v3 = rec("/Volumes/X9/avid/test_w3.V.mxf", .videoOnly)
        let a31 = rec("/Volumes/X9/avid/test_w3.A1.mxf", .audioOnly), a32 = rec("/Volumes/X9/avid/test_w3.A2.mxf", .audioOnly)
        let lone = rec("/Volumes/X9/avid/test_w4.V.mxf", .videoOnly), sib = rec("/Volumes/X9/avid/test_w4.A.mxf", .audioOnly)
        pair(v, a); pair(v3, a31, a32); pair(lone, sib)
        let sel = [v, a, v3, a31, a32, lone]
        let p = plan(sel, catalog: sel + [sib])
        let c = CatalogTrashConfirmation(plan: p, sizes: Dictionary(uniqueKeysWithValues: sel.map { ($0.id, Int64(1_024)) }))
        #expect(c.title == "Move 5 files · 2 pair groups (5 KB) to the Trash?")
        #expect(c.groupLines == [
            "Move this clip and its related half to the Trash: test_w.V01.mxf + test_w.A01.mxf.",
            "Move this clip and its 2 related halves to the Trash: test_w3.V.mxf + test_w3.A1.mxf + test_w3.A2.mxf.",
        ])
        #expect(c.detail.hasPrefix("They move to the Finder Trash; you can put them back until you empty it.\n"
                                   + "Never touches Master Archive files, files on drives that are not connected, or half of a recovered audio/video pair unless every half is selected. Instant."
                                   + "\n\nMove this clip and its related half to the Trash: test_w.V01.mxf + test_w.A01.mxf."))
        #expect(c.detail.contains("1 will be held back: half of a recovered audio/video pair not selected whole (1)."))
        // No pair: the title is unchanged.
        let o = rec("/Volumes/X9/test_plain.mov")
        let plain = CatalogTrashConfirmation(plan: plan([o], catalog: [o]), sizes: [o.id: 1_024])
        #expect(plain.title == "Move 1 file (1 KB) to the Trash?" && plain.groupLines.isEmpty)
        // More than the cap: "…and N more pair groups."
        var many: [VideoRecord] = []
        for i in 0..<7 {
            let x = rec("/Volumes/X9/avid/test_cap\(i).V.mxf", .videoOnly), y = rec("/Volumes/X9/avid/test_cap\(i).A.mxf", .audioOnly)
            pair(x, y); many += [x, y]
        }
        let capped = CatalogTrashConfirmation(plan: plan(many, catalog: many), sizes: [:])
        #expect(capped.groupLines.count == 6 && capped.groupLines.last == "…and 2 more pair groups.")
    }

    @Test("truth: OUTCOME names the pair groups, and each half's copyTrashed ledger event carries its pair")
    func outcomeAndLedger() async throws {
        let d = try disk("pgtruth")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_tr.V.mxf", seed: 61, .videoOnly), a = try file(d, "test_tr.A.mxf", seed: 62, .audioOnly)
        let w = try file(d, "test_tr2.V.mxf", seed: 63, .videoOnly), b = try file(d, "test_tr2.A.mxf", seed: 64, .audioOnly)
        let gid = pair(v, a); pair(w, b)
        d.model.records = [v, a, w, b]
        let p = d.model.catalogTrashPlan(for: [v, a, w], isOffline: { _ in false })
        let result = await d.model.trashSelectedRecords([v, a, w], confirmed: p)
        #expect(result.succeeded == 2 && !exists(v) && !exists(a) && exists(w) && exists(b))
        let outcome = await consoleLine(d.model, containing: "OUTCOME Move to Trash")
        #expect(outcome?.contains("pair groups: moved 1 · held 1 · failed 0 · split 0") == true, "\(String(describing: outcome))")
        #expect(await consoleLine(d.model, containing: "kept the pair test_tr2.V.mxf — its related half test_tr2.A.mxf is not selected") != nil)
        #expect(result.groupNotes.first == "Recovered A/V pairs: 1 moved whole, 1 kept.")
        await d.model.mediaLedger.waitForPendingWrites()
        let trashed = d.model.mediaLedger.allEvents().filter { $0.event == .copyTrashed }
        #expect(Set(trashed.map(\.recordID)) == [v.id, a.id])
        #expect(trashed.allSatisfy { $0.detail[CatalogTrashGroupTurns.ledgerPairGroup] == gid.uuidString })
        #expect(trashed.allSatisfy { $0.detail[CatalogTrashGroupTurns.ledgerPairFiles] == "test_tr.V.mxf + test_tr.A.mxf" })
        #expect(trashed.allSatisfy { $0.detail[MediaLedgerEvent.Detail.mode] == "trash" && $0.by == .rick })
    }

    // MARK: MEDIA MATRIX — the formats recovered pairs come in

    private static func sha256(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func runPair(_ label: String, video: [String], videoName: String, audio: [String], audioName: String) async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let d = try disk("pgmm_\(label)")
        defer { d.sb.cleanup() }
        let vPath = d.sb.sources.appendingPathComponent(videoName).path
        let aPath = d.sb.sources.appendingPathComponent(audioName).path
        try CleanupTestMedia.runFFmpeg(video, output: vPath)
        try CleanupTestMedia.runFFmpeg(audio, output: aPath)
        let v = MasterArchiveTestSupport.makeRecord(path: vPath, streamType: .videoOnly)
        let a = MasterArchiveTestSupport.makeRecord(path: aPath, streamType: .audioOnly)
        let vSHA = try #require(Self.sha256(vPath)), aSHA = try #require(Self.sha256(aPath))
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        #expect(p.toTrash == [v.id, a.id], "\(label): \(p.refused)")
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p)
        #expect(result.succeeded == 2, "\(label): \(result.items.map(\.outcome))")
        let vTrash = try #require(v.removal?.trashPath), aTrash = try #require(a.removal?.trashPath)
        #expect(Self.sha256(vTrash) == vSHA && Self.sha256(aTrash) == aSHA, "\(label): the Trash holds the original bytes")
        try? FileManager.default.removeItem(atPath: vTrash)   // the test host's Trash, not Rick's
        try? FileManager.default.removeItem(atPath: aTrash)
    }

    @Test("media: mxf — Avid-style video half (mpeg2, OP-1a) + audio half (pcm, OP-Atom)", .timeLimit(.minutes(2)))
    func mxfPair() async throws {
        try await runPair("mxf",
            video: ["-f", "lavfi", "-i", "testsrc=duration=1:size=720x576:rate=25", "-c:v", "mpeg2video", "-g", "15", "-an"],
            videoName: "test_pgmm.V01.mxf",
            audio: ["-f", "lavfi", "-i", "aevalsrc=0.5*sin(440*2*PI*t):s=48000:d=1", "-c:a", "pcm_s16le", "-ac", "1", "-f", "mxf_opatom"],
            audioName: "test_pgmm.A01.mxf")
    }

    @Test("media: avi — dv video half + pcm audio half", .timeLimit(.minutes(2)))
    func aviPair() async throws {
        try await runPair("avi",
            video: ["-f", "lavfi", "-i", "testsrc=duration=1:size=720x480:rate=30000/1001", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-an"],
            videoName: "test_pgmm_v.avi",
            audio: ["-f", "lavfi", "-i", "aevalsrc=0.5*sin(440*2*PI*t):s=48000:d=1", "-c:a", "pcm_s16le"],
            audioName: "test_pgmm_a.avi")
    }

    // MARK: SCALE

    @Test("SCALE: 100k-row catalog, 5k pair groups selected whole — the plan stays within the trash-plan budget")
    func hundredThousandRowsFiveThousandGroups() {
        var all: [VideoRecord] = []
        all.reserveCapacity(100_000)
        var selection: [VideoRecord] = []
        for i in 0..<5_000 {
            let v = rec("/Volumes/S/avid/\(i / 500)/test_\(i).V.mxf", .videoOnly)
            let a = rec("/Volumes/S/avid/\(i / 500)/test_\(i).A.mxf", .audioOnly)
            pair(v, a)
            all += [v, a]; selection += [v, a]
        }
        for i in 10_000..<100_000 { all.append(rec("/Volumes/S/\(i / 1000)/clip_\(i).mov")) }
        let m = VideoScanModel()
        m.records = all
        let t0 = Date()
        let p = m.catalogTrashPlan(for: selection, isOffline: { _ in false }, identity: { _ in Self.stubID })
        let took = -t0.timeIntervalSinceNow
        #expect(p.toTrash.count == 10_000 && p.groups.count == 5_000 && p.refused.isEmpty)
        // The existing trash-plan budget (CatalogTrashOnlyCopyTests): 1 s.
        #expect(took < 1.0, "the pair-group plan over 100k records took \(took) s")
    }
}
