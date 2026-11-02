// CatalogTrashPairGroupIsolationTests.swift
// Delete Selected Files, recovered A/V pairs — ISOLATION through the one
// Trash routine (offline, changed on disk or in the catalog, FamilyArchive,
// Read only, reservations, SPLIT), and the Codex #191 / #194 regressions.
// Fixtures: CatalogTrashPairGroupFixtures.swift.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Catalog Delete Selected Files — pair groups: isolation and Codex #191/#194", .serialized)
@MainActor
struct CatalogTrashPairGroupIsolationTests: PairGroupFixtures {

    // MARK: ISOLATION — real files through the one routine

    @Test("isolation: a unit member on a drive that is not connected holds the whole unit in the routine — nothing moved")
    func siblingOfflineAtTheTurn() async throws {
        let d = try disk("pgoff")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_off.V.mxf", seed: 11, .videoOnly)
        let a = MasterArchiveTestSupport.makeRecord(path: "/Volumes/TestPGNotMounted/avid/test_off.A.mxf", streamType: .audioOnly)
        d.model.records = [v, a]
        var g = VideoScanModel.JunkDeletionGuard(authorize: { _ in nil }, beforeRemoval: { _ in nil })
        g.units = [[v.id, a.id]]
        let result = await d.model.deleteConfirmedJunk([v, a], mode: .toTrash, reason: .catalogTrash, guard: g)
        #expect(result.succeeded == 0 && exists(v), "\(result.items.map(\.outcome))")
        #expect(result.items.map(\.outcome.kind) == [.held, .offline])
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
        #expect(result.refused.first { $0.record.id == a.id }?.reason.contains("changed or went away on disk") == true,
                "A's own real check refuses it; the unit holds V with it")
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

    @Test("isolation: a unit member on a drive marked Read only holds the whole unit — the member's own turn refuses, nothing moved")
    func laterHalfOnReadOnlyDrive() async throws {
        let d = try disk("pgro")
        defer { d.sb.cleanup() }
        let roDir = d.sb.sources.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
        let v = try file(d, "test_ro.V.mxf", seed: 73, .videoOnly)
        let a = try file(d, "test_ro.A.mxf", seed: 74, .audioOnly, in: roDir)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.groups.count == 1)
        let ro = CatalogScanTarget(searchPath: roDir.path)
        ro.role = .workspace
        ro.isReachable = true
        ro.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(), volumeUUID: nil)
        d.model.scanTargets = [ro]                       // marked after the confirmation
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p)
        #expect(result.succeeded == 0 && exists(v) && exists(a), "\(result.items.map(\.outcome))")
    }

    @Test("isolation: reserveAll takes every file of a batch or none — two batches sharing a file never interleave")
    func batchReservationIsAllOrNothing() throws {
        let d = try disk("pgbatch")
        defer { d.sb.cleanup() }
        let x = try file(d, "test_bt.X.mxf", seed: 75, .videoOnly), y = try file(d, "test_bt.Y.mxf", seed: 76, .audioOnly)
        let z = try file(d, "test_bt.Z.mxf", seed: 77, .audioOnly)
        let table = RemovalReservations.shared
        guard case .reserved(let first) = table.reserveAll([x.fullPath, y.fullPath]) else {
            Issue.record("the first batch is taken whole"); return
        }
        defer { first.forEach(table.release) }
        guard case .held(let index, _) = table.reserveAll([z.fullPath, y.fullPath]) else {
            Issue.record("a second batch sharing Y must be held whole"); return
        }
        #expect(index == 1)
        #expect(!table.isReserved(z.fullPath), "nothing of the held batch stays reserved")
        let link = d.sb.sources.appendingPathComponent("test_bt.Z link.mxf")
        try FileManager.default.linkItem(atPath: z.fullPath, toPath: link.path)
        guard case .held = table.reserveAll([z.fullPath, link.path]) else {
            Issue.record("one physical file twice in a batch is held"); return
        }
        #expect(!table.isReserved(z.fullPath))
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

    // MARK: Codex #194 — closing-pass regressions (red first)

    @Test("codex #194 F1: a later half's surviving copy another job is removing holds the first half too")
    func laterHalfReservedSurvivorHoldsThePair() async throws {
        let d = try disk("pgsurv")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_sv.V.mxf", seed: 95, .videoOnly)
        let aBytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 23 &+ 7) })
        let a = try fileWithFixity(d, "test_sv.A.mxf", bytes: aBytes, .audioOnly)
        let aCopy = try fileWithFixity(d, "test_sv.A copy.mxf", bytes: aBytes, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, aCopy]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.onlyCopy == [v.id], "A has a known copy: only V is warned")
        guard case .reserved(let key) = RemovalReservations.shared.reserve(aCopy.fullPath) else {
            Issue.record("fixture: could not reserve A's copy"); return
        }
        defer { RemovalReservations.shared.release(key) }
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(result.succeeded == 0 && exists(v) && exists(a), "never split: \(result.items.map(\.outcome))")
        #expect(result.groupNotes.allSatisfy { !$0.hasPrefix("Split pair") })
    }

    @Test("codex #194 F2: a later half whose removal marker the catalog would refuse holds the first half too")
    func laterHalfMarkerRefusalHoldsTheGroup() async throws {
        let scene = try CutoverScene.make("pg_marker_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let vURL = try MasterArchiveTestSupport.writeBlob(at: scene.folder.appendingPathComponent("test_mk.V.mxf"), bytes: 1024, seed: 96)
        let aURL = try MasterArchiveTestSupport.writeBlob(at: scene.folder.appendingPathComponent("test_mk.A.mxf"), bytes: 1024, seed: 97)
        let v = try scene.freshCopy(of: .healthy, path: vURL.path)
        let a = try scene.freshCopy(of: .healthy, path: aURL.path)
        for (r, st) in [(v, StreamType.videoOnly), (a, StreamType.audioOnly)] {
            r.streamTypeRaw = st.rawValue; r.sizeBytes = 1024; r.ext = "mxf"
        }
        pair(v, a)
        scene.model.records += [v, a]
        #expect(scene.model.saveCatalogNow())
        let vClone = v.snapshotClone()   // same id, path and pair metadata; not the session's live row
        let confirmed = scene.model.catalogTrashPlan(for: [vClone, a], isOffline: { _ in false })
        try #require(confirmed.toTrash == [v.id, a.id], "\(confirmed.refused)")
        await scene.hold()
        defer { scene.release() }
        #expect(CatalogMarkerRelay.saveRefusal(for: vClone) == nil, "fixture: the clone's own marker gate says go")
        #expect(CatalogMarkerRelay.saveRefusal(for: a) != nil, "fixture: live A's marker gate refuses under the hold")
        let result = await scene.model.trashSelectedRecords([vClone, a], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: vURL.path) && FileManager.default.fileExists(atPath: aURL.path))
    }

    @Test("codex #194 F3: a SPLIT names a relinked half's current location, never its obsolete path")
    func relinkedLaterHalfReportsItsCurrentLocation() async throws {
        let d = try disk("pgrelocate")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_rc.V.mxf", seed: 98, .videoOnly), a = try file(d, "test_rc.A.mxf", seed: 99, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.toTrash == [v.id, a.id])
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        let moved = d.sb.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let vPath = v.fullPath, oldA = a.fullPath
        let newA = moved.appendingPathComponent("test_rc.A.mxf").path
        let aRef = Ref(a)
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            if url.path == vPath {
                try FileManager.default.moveItem(atPath: oldA, toPath: newA)
                DispatchQueue.main.sync { MainActor.assumeIsolated { aRef.value.fullPath = newA } }
            }
        })
        let split = try #require(result.groupNotes.first { $0.hasPrefix("Split pair:") }, "\(result.groupNotes)")
        #expect(!FileManager.default.fileExists(atPath: oldA))
        #expect(!split.contains("stayed at \(oldA)"), "\(split)")
        #expect(split.contains(newA) && split.contains("relinked from \(oldA)"), "\(split)")
    }
}
