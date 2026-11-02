// CatalogTrashPairGroupLiveCatalogTests.swift
// Delete Selected Files, recovered A/V pairs — the pair as one unit and the
// LIVE catalog deciding membership (Codex #195 / #197 / #201) and the
// DECISIONS 2026-11-01 contract: a change during a unit's off-main disk
// work is reported in words, never as success; the routine acts on the
// catalog's row only. Fixtures: CatalogTrashPairGroupFixtures.swift.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Catalog Delete Selected Files — pair groups: live catalog and the unit contract", .serialized)
@MainActor
struct CatalogTrashPairGroupLiveCatalogTests: PairGroupFixtures {

    // MARK: Codex #195 — fourth-pass regressions (red first)

    @Test("codex #195 F1: a half linked only from its sibling (reverse-only) never moves outside the pair gate")
    func reverseOnlySiblingNeverMoves() async throws {
        let d = try disk("pgrev")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_ro1.V.mxf", seed: 101, .videoOnly), a = try file(d, "test_ro1.A.mxf", seed: 102, .audioOnly)
        a.pairedWith = v              // A still points at V …
        a.pairGroupID = UUID()        // … V carries no pair field at all
        d.model.records = [v, a]
        let both = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        #expect(both.toTrash.isEmpty, "\(both.refused)")
        let result = await d.model.trashSelectedRecords([v, a], confirmed: both)
        #expect(result.succeeded == 0 && exists(v) && exists(a))
        let alone = d.model.catalogTrashPlan(for: [v], isOffline: { _ in false })
        #expect(alone.toTrash.isEmpty, "V alone is held while A links to it: \(alone.refused)")
        let r2 = await d.model.trashSelectedRecords([v], confirmed: alone)
        #expect(r2.succeeded == 0 && exists(v))
    }

    @Test("codex #195 F2: a later half whose only survivor is a hard link to itself holds the first half too")
    func laterHalfAliasSurvivorHoldsThePair() async throws {
        let d = try disk("pgalias")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_al.V.mxf", seed: 103, .videoOnly)
        let aBytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 19 &+ 11) })
        let aURL = d.sb.sources.appendingPathComponent("test_al.A.mxf")
        try aBytes.write(to: aURL)
        let cURL = d.sb.sources.appendingPathComponent("test_al.A link.mxf")
        try FileManager.default.linkItem(at: aURL, to: cURL)      // the alias exists before A's fixity
        let a = try fileWithFixity(d, "test_al.A.mxf", bytes: aBytes, .audioOnly)
        let c = MasterArchiveTestSupport.makeRecord(path: cURL.path, streamType: .audioOnly)
        c.sizeBytes = Int64(aBytes.count)
        let digest = SHA256.hash(data: aBytes).map { String(format: "%02x", $0) }.joined()
        c.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: Int64(aBytes.count))
        pair(v, a)
        d.model.records = [v, a, c]
        let confirmed = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(confirmed.onlyCopy == [v.id], "fixture: A's alias counts as its copy in the catalog")
        let result = await d.model.trashSelectedRecords([v, a], confirmed: confirmed)
        #expect(result.succeeded == 0 && exists(v) && exists(a), "never split: \(result.items.map(\.outcome))")
    }

    @Test("codex #195 F3: later halves never vouch for each other — the outside copy gone holds the whole group")
    func laterHalvesNeverVouchForEachOther() async throws {
        let d = try disk("pgvouch")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_vc.V.mxf", seed: 104, .videoOnly)
        let bytes = Data((0..<2_048).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 13) })
        let a1 = try fileWithFixity(d, "test_vc.A1.mxf", bytes: bytes, .audioOnly)
        let a2 = try fileWithFixity(d, "test_vc.A2.mxf", bytes: bytes, .audioOnly)
        let outside = try fileWithFixity(d, "test_vc.A copy.mxf", bytes: bytes, .audioOnly)
        pair(v, a1, a2)
        d.model.records = [v, a1, a2, outside]
        let confirmed = d.model.catalogTrashPlan(for: [v, a1, a2], isOffline: { _ in false })
        try #require(confirmed.toTrash == [v.id, a1.id, a2.id] && confirmed.onlyCopy == [v.id])
        outside.purgedAt = Date()       // the outside copy left while the alert was up
        let result = await d.model.trashSelectedRecords([v, a1, a2], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a1) && exists(a2))
    }

    @Test("codex #195 F4: a departed sibling's lingering link never refuses the admitted remainder")
    func departedSiblingRemainderMoves() async throws {
        let d = try disk("pgdep")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_dp.V.mxf", seed: 105, .videoOnly), a = try file(d, "test_dp.A.mxf", seed: 106, .audioOnly)
        pair(v, a)
        a.purgedAt = Date()             // removed from the catalog (its link stays on V)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v], isOffline: { _ in false })
        try #require(p.toTrash == [v.id] && p.groups.first?.departed == ["test_dp.A.mxf"])
        let result = await d.model.trashSelectedRecords([v], confirmed: p)
        #expect(result.succeeded == 1 && !exists(v), "\(result.items.map(\.outcome))")
    }

    // MARK: Codex #197 — the live catalog decides membership (red first)

    @Test("codex #197 F1: a stale selected copy of a half with no pair fields never moves outside the pair gate")
    func staleUnpairedSelectionNeverMoves() async throws {
        let d = try disk("pgstale2")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_s2.V.mxf", seed: 111, .videoOnly), a = try file(d, "test_s2.A.mxf", seed: 112, .audioOnly)
        let staleV = v.snapshotClone()            // taken before the pairing
        let gid = UUID()
        v.pairGroupID = gid; a.pairGroupID = gid  // live rows paired by group id only
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [staleV], isOffline: { _ in false })
        #expect(p.toTrash.isEmpty, "\(p.refused)")
        let result = await d.model.trashSelectedRecords([staleV], confirmed: p)
        #expect(result.succeeded == 0 && exists(v) && exists(a))
    }

    @Test("codex #197 F2: clones of BOTH halves selected still meet the live rows' marker-save refusal")
    func bothSelectedClonesHonorMarkerWriteHold() async throws {
        let scene = try CutoverScene.make("pg_marker_both"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let vURL = try MasterArchiveTestSupport.writeBlob(at: scene.folder.appendingPathComponent("test_mb.V.mxf"), bytes: 1024, seed: 113)
        let aURL = try MasterArchiveTestSupport.writeBlob(at: scene.folder.appendingPathComponent("test_mb.A.mxf"), bytes: 1024, seed: 114)
        let v = try scene.freshCopy(of: .healthy, path: vURL.path)
        let a = try scene.freshCopy(of: .healthy, path: aURL.path)
        for (r, st) in [(v, StreamType.videoOnly), (a, StreamType.audioOnly)] {
            r.streamTypeRaw = st.rawValue; r.sizeBytes = 1024; r.ext = "mxf"
        }
        pair(v, a)
        scene.model.records += [v, a]
        #expect(scene.model.saveCatalogNow())
        let vClone = v.snapshotClone(), aClone = a.snapshotClone()
        let confirmed = scene.model.catalogTrashPlan(for: [vClone, aClone], isOffline: { _ in false })
        try #require(confirmed.toTrash == [v.id, a.id], "\(confirmed.refused)")
        await scene.hold()
        defer { scene.release() }
        #expect(CatalogMarkerRelay.saveRefusal(for: v) != nil && CatalogMarkerRelay.saveRefusal(for: a) != nil,
                "fixture: the live rows' marker gates refuse under the hold")
        let result = await scene.model.trashSelectedRecords([vClone, aClone], confirmed: confirmed)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(FileManager.default.fileExists(atPath: vURL.path) && FileManager.default.fileExists(atPath: aURL.path))
    }

    @Test("codex #197 F3: a reverse link added during an earlier turn holds the now-linked file at its turn")
    func reverseLinkAddedBeforeTurnHoldsHalf() async throws {
        let d = try disk("pgrevlate")
        defer { d.sb.cleanup() }
        let o = try file(d, "test_rl2.O.mov", seed: 115, .videoAndAudio)
        let v = try file(d, "test_rl2.V.mxf", seed: 116, .videoOnly), a = try file(d, "test_rl2.A.mxf", seed: 117, .audioOnly)
        d.model.records = [o, v, a]
        let p = d.model.catalogTrashPlan(for: [o, v], isOffline: { _ in false })
        try #require(p.toTrash == [o.id, v.id] && p.groups.isEmpty)
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let oPath = o.fullPath
        let refs = Ref((v: v, a: a))
        let result = await d.model.trashSelectedRecords([o, v], confirmed: p, fileOperation: { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            if url.path == oPath {
                DispatchQueue.main.sync { MainActor.assumeIsolated { refs.value.a.pairedWith = refs.value.v } }
            }
        })
        #expect(result.succeeded == 1 && !exists(o), "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a), "V became a pair half mid-batch; it never moves alone")
    }

    @Test("codex #197 F4: a departed sibling restored mid-batch is a member again — the remainder is held")
    func restoredDepartedSiblingHoldsRemainder() async throws {
        let d = try disk("pgrestore")
        defer { d.sb.cleanup() }
        let o = try file(d, "test_rs2.O.mov", seed: 118, .videoAndAudio)
        let v = try file(d, "test_rs2.V.mxf", seed: 119, .videoOnly), a = try file(d, "test_rs2.A.mxf", seed: 120, .audioOnly)
        pair(v, a)
        a.purgedAt = Date()             // removed from the catalog; its file stays
        d.model.records = [o, v, a]
        let p = d.model.catalogTrashPlan(for: [o, v], isOffline: { _ in false })
        try #require(p.toTrash == [o.id, v.id] && p.groups.first?.departed == ["test_rs2.A.mxf"])
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let oPath = o.fullPath
        let model = Ref(d.model), aRef = Ref(a)
        let result = await d.model.trashSelectedRecords([o, v], confirmed: p, fileOperation: { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
            if url.path == oPath {
                DispatchQueue.main.sync { MainActor.assumeIsolated { _ = model.value.clearRemoval(aRef.value) } }
            }
        })
        #expect(!a.isPurged, "fixture: A is restored")
        #expect(result.succeeded == 1 && !exists(o), "\(result.items.map(\.outcome))")
        #expect(exists(v) && exists(a))
        #expect(!result.groupNotes.contains { $0.contains("1 moved whole") }, "\(result.groupNotes)")
    }

    // MARK: DECISIONS 2026-11-01 contract — the off-main residual is reported; live rows only

    @Test("contract: a sibling linked while the pair's disk work runs is reported in words, never as plain success")
    func lateLinkedSiblingIsReported() async throws {
        let d = try disk("pglatelink")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_ll.V.mxf", seed: 121, .videoOnly), a = try file(d, "test_ll.A.mxf", seed: 122, .audioOnly)
        let x = try file(d, "test_ll.X.mxf", seed: 123, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, x]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.groups.count == 1)
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vPath = v.fullPath
        let refs = Ref((v: v, x: x))
        // The hook: phase 1 is done (every half gated and reserved); the
        // first move has not happened — the off-main window of the contract.
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            if url.path == vPath {
                DispatchQueue.main.sync { MainActor.assumeIsolated { refs.value.x.pairedWith = refs.value.v } }
            }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        })
        #expect(result.succeeded == 2, "the accepted residual: the unit was decided at its turn")
        #expect(result.groupNotes.contains { $0.contains("test_ll.X.mxf") && $0.contains("was linked during the move") },
                "\(result.groupNotes)")
        #expect(!result.groupNotes.contains { $0.contains("1 moved whole") }, "never plain success: \(result.groupNotes)")
        #expect(await consoleLine(d.model, containing: "changed during the move 1") != nil)
        #expect(exists(x), "the late sibling keeps its file and its pair protection")
        // Codex #201 F3: the presenter surfaces the warning though every file moved.
        let report = JunkDeletionReport(result)
        #expect(report.hasNotes, "the alert is shown")
        #expect(report.headline == "Move to Trash \u{2014} the catalog changed during the move", "\(report.headline)")
        #expect(report.summary.contains { $0.contains("test_ll.X.mxf was linked during the move") }, "\(report.summary)")
    }

    @Test("codex #201 F1: an OUTWARD link from a moved half to a row with no pair fields is reported")
    func outwardLinkToUnpairedRowIsReported() async throws {
        let d = try disk("pgoutward")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_ow.V.mxf", seed: 131, .videoOnly), a = try file(d, "test_ow.A.mxf", seed: 132, .audioOnly)
        let x = try file(d, "test_ow.X.mxf", seed: 133, .audioOnly)
        pair(v, a)
        d.model.records = [v, a, x]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.groups.count == 1)
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vPath = v.fullPath
        let refs = Ref((v: v, x: x))
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            if url.path == vPath {
                DispatchQueue.main.sync { MainActor.assumeIsolated { refs.value.v.pendingPairedWithID = refs.value.x.id } }
            }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        })
        #expect(result.succeeded == 2)
        #expect(result.groupNotes.contains { $0.contains("test_ow.X.mxf") }, "\(result.groupNotes)")
        #expect(!result.groupNotes.contains { $0.contains("1 moved whole") }, "\(result.groupNotes)")
        #expect(JunkDeletionReport(result).hasNotes)
    }

    @Test("codex #201 F2: the confirmed halves themselves unpaired during the move is reported, never success")
    func unpairedDuringMoveIsReported() async throws {
        let d = try disk("pgunpair")
        defer { d.sb.cleanup() }
        let v = try file(d, "test_up.V.mxf", seed: 134, .videoOnly), a = try file(d, "test_up.A.mxf", seed: 135, .audioOnly)
        pair(v, a)
        d.model.records = [v, a]
        let p = d.model.catalogTrashPlan(for: [v, a], isOffline: { _ in false })
        try #require(p.groups.count == 1)
        let bin = d.sb.root.appendingPathComponent("seam-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let vPath = v.fullPath
        let refs = Ref((v: v, a: a))
        let result = await d.model.trashSelectedRecords([v, a], confirmed: p, fileOperation: { url in
            if url.path == vPath {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        for r in [refs.value.v, refs.value.a] { r.pairGroupID = nil; r.pairedWith = nil; r.pendingPairedWithID = nil }
                    }
                }
            }
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        })
        #expect(result.succeeded == 2, "the accepted residual: both files moved")
        #expect(result.groupNotes.contains { $0.contains("changed during the move") }, "\(result.groupNotes)")
        #expect(!result.groupNotes.contains { $0.contains("1 moved whole") }, "\(result.groupNotes)")
        #expect(JunkDeletionReport(result).hasNotes)
    }

    @Test("contract: the live pair index never goes stale on a decoded reload of the rows (no field write, same count)")
    func liveIndexFollowsADecodedReload() throws {
        let v = rec("/Volumes/X9/avid/test_rl3.V.mxf", .videoOnly), x = rec("/Volumes/X9/avid/test_rl3.X.mxf", .audioOnly)
        let m = VideoScanModel()
        m.records = [v, x]
        let turns = CatalogTrashGroupTurns(groups: [])
        #expect(!turns.isLiveGroupMember(v.id, model: m))
        // A reload: the same rows decoded afresh (no didSet runs in a decoder),
        // X now carrying a decoded link to V.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        func decoded(_ r: VideoRecord, linkTo: UUID?) throws -> VideoRecord {
            var o = try #require(try JSONSerialization.jsonObject(with: encoder.encode(VideoRecordDTO(r))) as? [String: Any])
            if let linkTo { o["pairedWithID"] = linkTo.uuidString }
            return try decoder.decode(VideoRecord.self, from: JSONSerialization.data(withJSONObject: o))
        }
        let pairGen = VideoRecord.pairLinkGeneration, idGen = VideoRecord.identityGeneration
        let reloaded = [try decoded(v, linkTo: nil), try decoded(x, linkTo: v.id)]
        #expect(reloaded[1].pendingPairedWithID == v.id, "fixture: the decoded link")
        #expect(VideoRecord.pairLinkGeneration == pairGen && VideoRecord.identityGeneration == idGen,
                "fixture: decoding wrote no field through a setter")
        m.records = reloaded
        #expect(turns.isLiveGroupMember(v.id, model: m), "the reload is seen: V is linked now")
    }

    @Test("contract: a stale ordinary copy pointing at another path is held, never moved — the routine acts on the catalog's row")
    func staleOrdinaryCopyIsHeld() async throws {
        let d = try disk("pgstaleord")
        defer { d.sb.cleanup() }
        let o = try file(d, "test_so.O.mov", seed: 124, .videoAndAudio)
        let old = try MasterArchiveTestSupport.writeBlob(at: d.sb.sources.appendingPathComponent("test_so_old.O.mov"), bytes: 1024, seed: 125)
        let staleO = o.snapshotClone()
        staleO.fullPath = old.path
        staleO.filename = old.lastPathComponent
        d.model.records = [o]
        let p = d.model.catalogTrashPlan(for: [staleO], isOffline: { _ in false })
        #expect(p.toTrash.isEmpty, "\(p.refused)")
        let result = await d.model.trashSelectedRecords([staleO], confirmed: p)
        #expect(result.succeeded == 0, "\(result.items.map(\.outcome))")
        #expect(exists(o) && FileManager.default.fileExists(atPath: old.path))
    }
}
