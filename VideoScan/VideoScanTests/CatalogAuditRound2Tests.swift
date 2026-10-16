// CatalogAuditRound2Tests.swift
// "Audit Catalog…" tier 0 — codex ROUND 2 (2026-10-16) closures, pinned
// on the real filesystem through the real job / the real apply:
//   D1 (r2 F1) — the expected identity is the LANE ROOT's, never "where the
//                parent is now"; lane "/" has the stub rule (an empty folder
//                or a missing parent under "/" is never proof).
//   D2 (r2 F2) — the proof is bound to a directory handle (open / openat
//                O_NOFOLLOW, fstatfs, fstatat): a link in the path is never
//                provable, so a retargeted parent link cannot mark.
//   D3 (r2 F4) — rollback ownership by `removalRevision`, not by value:
//                equal-value ABA (nil → Trash → Put Back → Restore → nil, or
//                an identical marker reinstated) is a newer write.
//   D4 (r2 F3) — supersession is in the snapshot.
// Helpers (`runAudit`, the ShowAgainSandbox rows / links / lane root) are
// shared from CatalogAuditJobTests.swift.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Audit catalog — codex round 2 (lane-root identity, fd-bound proof, revision ownership, supersession)", .serialized)
@MainActor
struct CatalogAuditRound2Tests {

    // MARK: D1 — the lane root's identity and the "/" stub rule

    @Test("r2 F1 / D1: an empty folder under '/' (an unmounted mount point's stub) is 'could not check', never gone")
    func emptyMountPointStubUnderRootIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_stub"); defer { sb.cleanup() }
        let stub = sb.root.appendingPathComponent("media", isDirectory: true)      // a custom mount point, nothing mounted
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        let r = sb.row(at: stub.appendingPathComponent("clip.mov").path)
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "an offline custom mount's file was marked Missing")
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("empty") && detail.contains("mount point"), Comment(rawValue: detail))
        #expect(job.storedCount == 0)
    }

    @Test("r2 D1: a single deleted file in a folder under '/' that still holds something is gone")
    func singleDeletedFileInANonEmptyFolderUnderRootIsGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_one_gone"); defer { sb.cleanup() }
        try sb.live("stays.mov")
        let gone = try sb.live("gone.mov", onDisk: false)
        let job = await runAudit(sb.model)
        #expect(job.totals[.gone] == 1 && job.totals[.present] == 1, Comment(rawValue: job.totals.line))
        #expect(gone.removal?.state == .missing && gone.removal?.reason == .missingAtAudit)
    }

    @Test("r2 D1: a deleted subfolder under '/' is a declared limit — 'could not check', never gone")
    func deletedSubfolderUnderRootIsNotProvable() async throws {
        let sb = try ShowAgainSandbox.make("ca_subgone"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")                                                 // the parent is not empty
        let r = sb.row(at: sb.files.appendingPathComponent("deleted_folder/clip.mov").path)
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil)
    }

    @Test("r2 D1: under a mounted lane root (a sandbox root registered as one) a missing parent folder IS proof, bound to the root's identity")
    func missingParentUnderAMountedLaneRootIsGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_parent_gone"); defer { sb.cleanup() }
        let r = sb.row(at: sb.files.appendingPathComponent("deleted_folder/deeper/clip.mov").path)
        let alone = try sb.live("alone_in_an_empty_folder.mov", onDisk: false)   // files/ holds nothing else on disk
        let job = await runAudit(sb.model, laneRoot: sb.laneRoot)
        #expect(job.totals[.gone] == 2 && job.totals[.couldNotCheck] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal?.reason == .missingAtAudit && alone.removal?.reason == .missingAtAudit)
        #expect(job.lanes.map(\.root) == [sb.files.path])
        // And the plan's item carries the lane root's identity, not a parent's.
        let plan = sb.model.catalogAuditPlan(laneRoot: sb.laneRoot)
        let item = sb.anchored(try #require(plan.lanes.flatMap(\.items).first { $0.id == r.id }))
        #expect(item.expectedMount == CatalogAuditMountIdentity.of(sb.files.path) && item.expectedMount != nil)
    }

    @Test("r2 D1: a /Volumes root that is not a mount point (an unmounted drive's stub folder) anchors to nothing — never provable")
    func volumesStubRootAnchorsToNothing() throws {
        let stub = "/Volumes/CAStub_\(UUID().uuidString.prefix(8))"
        #expect(CatalogAuditMountIdentity.ofLaneRoot(stub) == nil, "a root that is not there")
        let slash = CatalogAuditMountIdentity.ofLaneRoot("/")
        #expect(slash?.mountOn == CatalogAuditMountIdentity.bootDataVolume || slash?.mountOn == "/", "'/' is this Mac's data volume")
        for mounted in VolumeReachability.currentLocalMountedRoots() where mounted.hasPrefix("/Volumes/") {
            #expect(CatalogAuditMountIdentity.ofLaneRoot(mounted)?.mountOn == mounted, Comment(rawValue: mounted))
        }
    }

    // MARK: D2 — the proof is bound to a directory handle

    @Test("r2 F2 / D2: a symlinked parent retargeted between the stat and the mark (same filesystem) can never produce a mark — a link in the path is not provable")
    func symlinkedParentRetargetedIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_parent_link"); defer { sb.cleanup() }
        let clip = try sb.live("clip.mov")                                           // the real file, in files/
        let elsewhere = sb.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: elsewhere.appendingPathComponent("other.mov"))
        let link = try sb.link("media", to: sb.files)
        let r = sb.row(at: link.appendingPathComponent("clip.mov").path)             // cataloged THROUGH the link
        let files = sb.files
        let job = await runAudit(sb.model) { j in
            j.statPaths = { paths in
                try? FileManager.default.removeItem(at: link)                        // the link now points at a folder without the file…
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)
                return paths.map { _ in .gone }
            }
        }
        // …and back: the file is at the cataloged path again.
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files)
        #expect(FileManager.default.fileExists(atPath: r.fullPath) && FileManager.default.fileExists(atPath: clip.fullPath))
        #expect(job.totals[.gone] == 0 && job.totals[.couldNotCheck] == 1, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "a present file was marked Missing through a retargeted link")
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("link"), Comment(rawValue: detail))
    }

    @Test("r2 D2: a symlink in the remainder of the path (below the nearest existing folder) is 'could not check'")
    func symlinkInTheRemainderIsNotProvable() async throws {
        let sb = try ShowAgainSandbox.make("ca_link_remainder"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let link = try sb.link("linked", to: sb.files)
        let r = sb.row(at: link.appendingPathComponent("sub/clip.mov").path)        // linked → files; files/sub is not there
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil)
    }

    @Test("r2 D2: the walk itself — folders below the root; a '..' component is refused; a link where a file was is 'not a regular file'")
    func directoryWalkValues() throws {
        #expect(CatalogAuditDirectoryWalk.folders(of: "/Volumes/X/a/b", below: "/Volumes/X") == ["a", "b"])
        #expect(CatalogAuditDirectoryWalk.folders(of: "/Volumes/X", below: "/Volumes/X") == [])
        #expect(CatalogAuditDirectoryWalk.folders(of: "/Users/rick/Movies", below: "/") == ["Users", "rick", "Movies"])
        #expect(CatalogAuditDirectoryWalk.folders(of: "/Volumes/Y/a", below: "/Volumes/X") == nil, "off the lane root")
        #expect(CatalogAuditDirectoryWalk.folders(of: "/Volumes/X/../Y", below: "/Volumes/X") == nil, "never steps out")
        let sb = try ShowAgainSandbox.make("ca_walk"); defer { sb.cleanup() }
        let real = try sb.live("real.mov")
        try FileManager.default.createSymbolicLink(at: sb.files.appendingPathComponent("alias.mov"),
                                                   withDestinationURL: URL(fileURLWithPath: real.fullPath))
        #expect(CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "real.mov", root: "/", readParentEntries: true)
                == .found(.file(size: 2_000)))
        #expect(CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "alias.mov", root: "/", readParentEntries: true)
                == .found(.notAFile), "a link is never followed at the mark")
        if case .gone(let on, let missing, let entries) = CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "nope.mov",
                                                                                            root: "/", readParentEntries: true) {
            #expect(on == CatalogAuditMountIdentity.of(sb.files.path) && missing == 0 && entries == true)
        } else { Issue.record("expected gone") }
        if case .gone(_, let missing, let entries) = CatalogAuditDirectoryWalk.prove(directory: sb.files.appendingPathComponent("a/b").path,
                                                                                      filename: "nope.mov", root: "/", readParentEntries: true) {
            #expect(missing == 2 && entries == nil, "two folders missing; the parent is not listed")
        } else { Issue.record("expected gone") }
    }

    // MARK: D4 — supersession in the snapshot

    @Test("r2 F3 / D4: a row superseded after planning is dropped as 'record changed', never marked")
    func supersededAfterPlanningIsDropped() throws {
        let sb = try ShowAgainSandbox.make("ca_superseded"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let r = try sb.live("old.mov", onDisk: false)
        let plan = sb.model.catalogAuditPlan()
        let item = sb.anchored(try #require(plan.lanes.flatMap(\.items).first { $0.id == r.id }))
        r.supersededByID = UUID()                                                    // Repair replaced it meanwhile
        let (apply, mark) = sb.model.applyCatalogAudit(.gone, to: item)
        #expect(apply.result == .recordChanged && mark == nil, "\(apply.result): \(apply.detail)")
        #expect(r.removal == nil, "a superseded row was marked")
    }

    // MARK: D3 — rollback ownership by revision

    @Test("r2 F4 / D3: equal-value ABA on nil — Trash → Put Back → Restore during the save — is a NEWER write; rollback leaves it alone")
    func rollbackLeavesANewerEqualNilMarkerAlone() async throws {
        let sb = try ShowAgainSandbox.make("ca_aba_nil"); defer { sb.cleanup() }
        let r = try sb.missingRow("aba.mov", onDisk: true)                           // the audit will restore it (wrote = nil)
        let model = sb.model
        let job = await runAudit(sb.model) { j in
            j.chunkSize = 1; j.checkpointRows = 100
            j.saveCatalogForTesting = {
                VideoScanModel.stampRemoval(r, .inTrash(movedAt: Date(), trashPath: nil, reason: .catalogTrash))   // another door: Trash
                #expect(model.clearRemoval(r) == nil)                                                             // Put Back + Restore → nil again
                return false
            }
        }
        #expect(job.saveFailed)
        #expect(r.removal == nil, "the other door's restore was overwritten by the audit's rollback: \(String(describing: r.removal))")
        #expect(sb.catalogLogText().contains("0 of 1 mark(s) undone"), Comment(rawValue: sb.catalogLogText()))
    }

    @Test("r2 F4 / D3: an identical non-nil marker reinstated by another door during the save is NOT the audit's; rollback leaves it")
    func rollbackLeavesAnIdenticalMarkerReinstatedByAnotherDoorAlone() async throws {
        let sb = try ShowAgainSandbox.make("ca_aba_same"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let r = try sb.live("same.mov", onDisk: false)
        let job = await runAudit(sb.model) { j in
            j.chunkSize = 1; j.checkpointRows = 100
            j.saveCatalogForTesting = {
                guard let audits = r.removal else { return false }                                               // the audit's Missing marker
                VideoScanModel.stampRemoval(r, .removedFromCatalog(at: Date(), reason: .userRemoved))             // another door…
                VideoScanModel.stampRemoval(r, audits)                                                            // …then an equal marker again
                return false
            }
        }
        #expect(job.saveFailed)
        #expect(r.removal?.state == .missing && r.removal?.reason == .missingAtAudit, "the newer, equal marker was cleared: \(String(describing: r.removal))")
        #expect(sb.catalogLogText().contains("0 of 1 mark(s) undone"), Comment(rawValue: sb.catalogLogText()))
    }

    @Test("r2 D3: the ordinary rollback still works — the audit's own unsaved mark, untouched since, is undone")
    func ordinaryRollbackStillWorks() async throws {
        let sb = try ShowAgainSandbox.make("ca_plain_undo"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let gone = try sb.live("gone.mov", onDisk: false)
        let back = try sb.missingRow("back.mov", onDisk: true)
        let job = await runAudit(sb.model) { j in j.chunkSize = 1; j.checkpointRows = 100; j.saveCatalogForTesting = { false } }
        #expect(job.saveFailed)
        #expect(gone.removal == nil && gone.removalRevision == 2, "stamped (1), reverted (2)")
        #expect(back.removal?.reason == .missingOnDisk && back.removalRevision == 3, "stamped by the test (1), restored (2), reverted (3)")
        #expect(sb.catalogLogText().contains("2 of 2 mark(s) undone"))
    }

    @Test("r2 D3: the engine bumps the revision on every change of the marker and nowhere else; an identical re-stamp is not a change; the revision round-trips and an old JSON reads 0")
    func removalRevisionIsTheEngineWriteCounter() throws {
        let r = VideoRecord(); r.fullPath = "/x/a.mov"; r.filename = "a.mov"
        #expect(r.removalRevision == 0)
        let m = RemovalMarker.missing(noticedAt: Date(timeIntervalSince1970: 1_700_000_000), lastSeen: nil, reason: .missingAtAudit)
        VideoScanModel.stampRemoval(r, m);  #expect(r.removalRevision == 1)
        VideoScanModel.stampRemoval(r, m);  #expect(r.removalRevision == 1, "an identical marker is not a change")
        VideoScanModel.stampRemoval(r, .removedFromCatalog(at: Date(), reason: .userRemoved)); #expect(r.removalRevision == 2)
        let sb = try ShowAgainSandbox.make("ca_rev"); defer { sb.cleanup() }
        let live = try sb.live("rev.mov")
        VideoScanModel.stampRemoval(live, .removedFromCatalog(at: Date(), reason: .userRemoved)); #expect(live.removalRevision == 1)
        #expect(sb.model.clearRemoval(live) == nil && live.removalRevision == 2, "Restore is a change")
        #expect(sb.model.clearRemoval(live) == nil && live.removalRevision == 2, "Restore of a live row changes nothing")
        // revertRemoval: value + revision, then bumps again; a wrong revision is refused.
        VideoScanModel.stampRemoval(live, m)                                                      // revision 3
        let mirrors = RemovalMirrors.of(live)
        #expect(!VideoScanModel.revertRemoval(live, wrote: m, previous: nil, revision: 2, mirrorsBefore: mirrors, mirrorsAfter: mirrors))
        #expect(live.removal == m && live.removalRevision == 3)
        #expect(VideoScanModel.revertRemoval(live, wrote: m, previous: nil, revision: 3, mirrorsBefore: mirrors, mirrorsAfter: mirrors))
        #expect(live.removal == nil && live.removalRevision == 4)
        // Codable (the DTO is the one encoder): round-trips; written only when non-zero; an old JSON (no key) reads 0; clone carries it.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let back = try decoder.decode(VideoRecord.self, from: try encoder.encode(VideoRecordDTO(live)))
        #expect(back.removalRevision == 4)
        let marked = String(bytes: try encoder.encode(VideoRecordDTO(r)), encoding: .utf8) ?? ""
        #expect(marked.contains("\"removalRevision\":2"), Comment(rawValue: marked))
        let fresh = String(bytes: try encoder.encode(VideoRecordDTO(VideoRecord())), encoding: .utf8) ?? ""
        #expect(!fresh.contains("removalRevision"), "a never-marked row writes no key")
        let old = try decoder.decode(VideoRecord.self, from: Data(#"{"id":"5A0B7B2E-5C8D-4D9E-9E0F-1A2B3C4D5E6F","filename":"old.mov","purgedAt":1700000000}"#.utf8))
        #expect(old.removalRevision == 0 && old.removal != nil)
        #expect(live.snapshotClone().removalRevision == 4)
    }
}
