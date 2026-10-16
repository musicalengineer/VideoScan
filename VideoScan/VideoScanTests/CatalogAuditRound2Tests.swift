// CatalogAuditRound2Tests.swift
// "Audit Catalog…" tier 0 — codex ROUND 2 and ROUND 3 (2026-10-16)
// closures, pinned on the real filesystem through the real job / the real
// apply:
//   D2 (r2 F2) — the proof is bound to a directory handle (open / openat
//                O_NOFOLLOW, fstatfs, fstatat): a link in the path is never
//                provable, so a retargeted parent link cannot mark.
//   D3 (r2 F4) — rollback ownership by `removalRevision`, not by value:
//                equal-value ABA (nil → Trash → Put Back → Restore → nil, or
//                an identical marker reinstated) is a newer write.
//   D4 (r2 F3) — supersession is in the snapshot.
//   D5 (r3 F1) — THE ONE PROOF RULE: ENOENT is proof only in a folder on
//                the volume the file was LAST SEEN on (`auditSeenOn`, the
//                stamp the audit writes for every file it finds). No stamp
//                → "never seen by an audit", never marked (Fix Links); a
//                different volume (an unmounted nested volume's stub) →
//                could not check. Supersedes r2 D1 (lane-root identity, the
//                "/" stub rule) — those pins are deleted, not kept dead.
//   D6 (r3 F2) — no symlink ANYWHERE in the path (lstat on every existing
//                component), and after the ENOENT the handle must still be
//                the directory its pathname names (a folder replaced under
//                the audit is not provable).
//   D7 (r3 F3) — rescan preservation carries the revision and the stamp.
//   D8 (r4 F1) — the stamp names the PHYSICAL DEVICE too (Delete
//                Duplicates' drive key): the same volume UUID on another
//                drive (a clone, a restored image) is never gone; a stamp
//                without a device (a share) proves by UUID alone.
//   D9 (r4 F2) — stamp acquisition is bound to the pathname like the proof:
//                after the open, the lexical walk again and the handle must
//                name its path, before anything is read through it.
//   D10        — a path change to another folder or volume root clears the
//                stamp in the one `fullPath` setter; a rename keeps it.
// Helpers (`runAudit`, the ShowAgainSandbox rows / links / stamps / lane
// root) are shared from CatalogAuditJobTests.swift. The ROUND 4 pins were
// red on the r3 tree with only the two task-local seams added.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Audit catalog — codex rounds 2–3 (fd-bound proof, revision ownership, supersession, the one proof rule, no link anywhere, rescan carries history)", .serialized)
@MainActor
struct CatalogAuditRound2Tests {

    // MARK: D5 — the one proof rule (r3 F1)

    @Test("r3 F1 / D5: an unmounted NESTED volume under a mounted lane root — its stub folder is on another volume than the file was last seen on — is 'could not check', never gone; under '/' the same")
    func nestedVolumeUnmountedUnderALaneRootIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_nested"); defer { sb.cleanup() }
        let stub = sb.files.appendingPathComponent("nested", isDirectory: true)       // a nested mount point, nothing mounted now
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        let other = "6E6F7420-7468-6973-2D64-7269766521AA"                              // the UUID of the volume that WAS mounted there
        let inStub = sb.row(at: stub.appendingPathComponent("clip.mov").path)
        inStub.auditSeenOn = AuditSeenOn(volumeUUID: other, mountFrom: "/dev/disk9s1", seenAt: Date(timeIntervalSinceNow: -86_400))
        let inGoneFolder = sb.row(at: sb.files.appendingPathComponent("gone_folder/clip.mov").path)
        inGoneFolder.auditSeenOn = inStub.auditSeenOn
        for laneRule in [sb.laneRoot, CatalogAuditPlanner.productionLaneRoot] {
            let job = await runAudit(sb.model, laneRoot: laneRule)
            #expect(job.totals[.couldNotCheck] == 2 && job.totals[.gone] == 0 && job.totals[.neverSeenByAnAudit] == 0, Comment(rawValue: job.totals.line))
            #expect(inStub.removal == nil && inGoneFolder.removal == nil, "an unmounted nested volume's file was marked Missing")
            let detail = job.problems.first { $0.path == inStub.fullPath }?.detail ?? "no detail row"
            #expect(detail.contains("different volume") && detail.contains("drive not connected?") && detail.contains(other), Comment(rawValue: detail))
            #expect(job.storedCount == 0 && job.stampedCount == 0)
        }
    }

    @Test("r3 D5: a gone row no audit has ever seen is 'never seen by an audit' — needs a decision (the Fix Links bucket), counted in the run marker and the Catalog Status facts, never marked")
    func unstampedGoneRowIsNeverSeenByAnAudit() async throws {
        let sb = try ShowAgainSandbox.make("ca_unseen"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let r = try sb.live("never_seen.mov", onDisk: false)
        let archived = try sb.live("arch_never_seen.mov", onDisk: false)
        archived.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 2_000)
        let marker = CatalogAuditRunMarker()
        let job = await runAudit(sb.model, marker: marker)
        #expect(job.totals[.neverSeenByAnAudit] == 2 && job.totals[.gone] == 0 && job.totals[.goneArchived] == 0 && job.totals[.present] == 1,
                Comment(rawValue: job.totals.line))
        #expect(r.removal == nil && archived.removal == nil, "a row no audit had seen was marked Missing")
        #expect(r.auditSeenOn == nil, "nothing was stamped on a file that was not found")
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("no audit has seen it before") && detail.contains("Fix Links"), Comment(rawValue: detail))
        #expect(CatalogAuditResult.neverSeenByAnAudit.needsAPerson && !CatalogAuditResult.neverSeenByAnAudit.isMark)
        #expect(job.storedCount == 0 && job.stampedCount == 1)
        #expect(marker.lastRun?.counts["neverSeenByAnAudit"] == 2)
        #expect(CatalogAuditPresenceFacts.from(marker.lastRun).needsDecision == 2, "the band's red counts them")
        #expect(sb.catalogLogText().contains("2 gone under \(sb.files.path)"), "the OUTCOME still says where they are not")
    }

    @Test("r3 D5: a stamped gone row on the same volume IS gone — a deleted file, and a deleted folder (no stub rule, no lane-root rule any more)")
    func stampedGoneRowOnTheSameVolumeIsGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_seen_gone"); defer { sb.cleanup() }
        let alone = try sb.live("alone_in_an_empty_folder.mov", onDisk: false, seen: true)   // files/ holds nothing else on disk
        let deeper = sb.row(at: sb.files.appendingPathComponent("deleted_folder/deeper/clip.mov").path)
        deeper.auditSeenOn = sb.stamp
        let job = await runAudit(sb.model)                                                  // the production lane rule: "/"
        #expect(job.totals[.gone] == 2 && job.totals[.couldNotCheck] == 0 && job.totals[.neverSeenByAnAudit] == 0, Comment(rawValue: job.totals.line))
        #expect(alone.removal?.reason == .missingAtAudit && deeper.removal?.reason == .missingAtAudit)
        #expect(job.problems.first { $0.path == alone.fullPath }?.detail.contains("on the drive it was last seen on") == true)
        #expect(job.storedCount == 2)
    }

    @Test("r3 D5: every file found gets the stamp (the handle's volume UUID, what is mounted there, when); it round-trips through JSON / the DTO / clone / rescan preservation and the saved catalog; a never-stamped row writes no key")
    func presentRowsAreStampedAndTheStampRoundTrips() async throws {
        let sb = try ShowAgainSandbox.make("ca_stamp"); defer { sb.cleanup() }
        let r = try sb.live("seen.mov")
        #expect(r.auditSeenOn == nil)
        let before = Date()
        let job = await runAudit(sb.model)
        let stamp = try #require(r.auditSeenOn)
        #expect(stamp.volumeUUID == sb.volumeUUID && stamp.volumeUUID == VolumeIdentity.uuid(forPath: r.fullPath),
                "the stamp is the volume's persistent UUID: \(stamp)")
        #expect(stamp.mountFrom?.isEmpty == false && stamp.seenAt >= before && stamp.seenAt <= Date())
        #expect(job.stampedCount == 1 && job.saveCount == 1 && job.storedCount == 0, "stamped, saved once, no mark")
        // JSON through the DTO (the one encoder), clone, rescan preservation.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let json = String(bytes: try encoder.encode(VideoRecordDTO(r)), encoding: .utf8) ?? ""
        #expect(json.contains("\"auditSeenOn\"") && json.contains(stamp.volumeUUID), Comment(rawValue: json))
        #expect(try decoder.decode(VideoRecord.self, from: Data(json.utf8)).auditSeenOn == stamp)
        #expect(!(String(bytes: try encoder.encode(VideoRecordDTO(VideoRecord())), encoding: .utf8) ?? "").contains("auditSeenOn"),
                "a never-stamped row writes no key")
        let old = try decoder.decode(VideoRecord.self, from: Data(#"{"id":"5A0B7B2E-5C8D-4D9E-9E0F-1A2B3C4D5E6F","filename":"old.mov"}"#.utf8))
        #expect(old.auditSeenOn == nil)
        #expect(r.snapshotClone().auditSeenOn == stamp)
        let target = CatalogScanTarget(searchPath: sb.files.path)
        sb.model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = VideoRecord(); fresh.fullPath = r.fullPath; fresh.filename = r.filename; fresh.directory = r.directory
        _ = sb.model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.auditSeenOn == stamp, "a rescan must not make a stamped row 'never seen' again")
        // The saved catalog (catalog.json keeps whole seconds).
        let onDisk = CatalogStore(directory: sb.catalogDir).load().first { $0.id == r.id }?.auditSeenOn
        #expect(onDisk?.volumeUUID == stamp.volumeUUID && onDisk?.mountFrom == stamp.mountFrom
                && abs((onDisk?.seenAt.timeIntervalSince1970 ?? 0) - stamp.seenAt.timeIntervalSince1970) < 1, Comment(rawValue: String(describing: onDisk)))
    }

    @Test("r3 D5: the second run marks what the first could not — the first run stamps a present file; once it is gone the second run proves it; a file never found stays 'never seen'")
    func theSecondRunMarksWhatTheFirstCouldNot() async throws {
        let sb = try ShowAgainSandbox.make("ca_two_runs"); defer { sb.cleanup() }
        let willGo = try sb.live("will_go.mov")
        let neverThere = try sb.live("never_there.mov", onDisk: false)
        let first = await runAudit(sb.model)
        #expect(first.totals[.present] == 1 && first.totals[.neverSeenByAnAudit] == 1 && first.totals[.gone] == 0, Comment(rawValue: first.totals.line))
        #expect(willGo.auditSeenOn != nil && neverThere.auditSeenOn == nil)
        try FileManager.default.removeItem(atPath: willGo.fullPath)
        let second = await runAudit(sb.model)
        #expect(second.totals[.gone] == 1 && second.totals[.neverSeenByAnAudit] == 1, Comment(rawValue: second.totals.line))
        #expect(willGo.removal?.reason == .missingAtAudit && neverThere.removal == nil)
        #expect(willGo.auditSeenOn != nil, "the stamp stays on a Missing row: it says where to look for a return")
    }

    @Test("r3 D5: stamps are flushed on the clock, at lane end and at run end — never a save per 25 rows (10k stamps on the first run are not 400 saves); a failed save just loses them")
    func stampsFlushOnTheClockNotPerRow() async throws {
        let sb = try ShowAgainSandbox.make("ca_stamp_cadence"); defer { sb.cleanup() }
        let rows = try (0..<60).map { try sb.live("p\($0).mov") }
        let job = await runAudit(sb.model) { j in
            j.chunkSize = 7; j.checkpointRows = 25; j.checkpointSeconds = 3_600
            j.saveCatalogForTesting = { true }
        }
        #expect(job.stampedCount == 60 && job.saveCount == 1, "one save at the end (got \(job.saveCount))")
        #expect(rows.allSatisfy { $0.auditSeenOn != nil })

        let sb2 = try ShowAgainSandbox.make("ca_stamp_lost"); defer { sb2.cleanup() }
        let r = try sb2.live("lost.mov")
        let failed = await runAudit(sb2.model) { j in j.saveCatalogForTesting = { false } }
        #expect(failed.saveFailed && failed.stampedCount == 0 && failed.storedCount == 0)
        #expect(r.removal == nil, "nothing to undo for a stamp")
        #expect(sb2.catalogLogText().contains("1 where-seen stamp(s) not saved"), Comment(rawValue: sb2.catalogLogText()))
    }

    // MARK: D6 — no link anywhere; the handle must still name its path (r3 F2)

    @Test("r3 F2 / D6: a symlink in the EXISTING part of the path — an intermediate component, not the one O_NOFOLLOW sees — is 'a link in the path', never provable")
    func linkInTheExistingPartOfThePathIsNeverProvable() async throws {
        let sb = try ShowAgainSandbox.make("ca_midlink"); defer { sb.cleanup() }
        let sub = sb.files.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: sub.appendingPathComponent("neighbour.mov"))
        let link = try sb.link("media", to: sb.files)                                  // media → files; media/sub exists
        let r = sb.row(at: link.appendingPathComponent("sub/clip.mov").path)
        r.auditSeenOn = sb.stamp                                                        // even stamped on the right volume
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "marked Missing through an intermediate link")
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("a link in the path"), Comment(rawValue: detail))
        // And no stamp is ever written through a link: a present file behind one is present, unstamped.
        let present = sb.row(at: link.appendingPathComponent("sub/neighbour.mov").path, bytes: 10)
        let again = await runAudit(sb.model)
        #expect(again.totals[.present] == 1 && present.auditSeenOn == nil && again.stampedCount == 0, Comment(rawValue: again.totals.line))
    }

    @Test("r3 F2 / D6: the file's folder renamed away and a new one created at its path between the open and the lookup — the handle no longer names the path — is 'the folder changed under the audit', never gone (the file is at the cataloged path)")
    func folderReplacedUnderTheAuditIsNeverProvable() async throws {
        let sb = try ShowAgainSandbox.make("ca_replaced"); defer { sb.cleanup() }
        let sub = sb.files.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let r = sb.row(at: sub.appendingPathComponent("clip.mov").path)
        r.auditSeenOn = sb.stamp
        let aside = sb.files.appendingPathComponent("sub.old", isDirectory: true)
        let path = r.fullPath
        let swap: @Sendable () -> Void = {
            // An outside actor, between the handle reaching `sub` and the name being read.
            try? FileManager.default.moveItem(at: sub, to: aside)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try? Data(repeating: 2, count: 2_000).write(to: URL(fileURLWithPath: path))
        }
        let job = await CatalogAuditDirectoryWalk.$beforeTheNameIsReadForTesting.withValue(swap) {
            await runAudit(sb.model)
        }
        #expect(FileManager.default.fileExists(atPath: r.fullPath), "the file IS at the cataloged path")
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil, "a present file was marked Missing through a handle on the old folder")
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("changed under the audit"), Comment(rawValue: detail))
    }

    // MARK: D2 — the proof is bound to a directory handle (r2 F2)

    @Test("r2 F2 / D2: a symlinked parent retargeted between the stat and the mark (same filesystem) can never produce a mark — a link in the path is not provable")
    func symlinkedParentRetargetedIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_parent_link"); defer { sb.cleanup() }
        let clip = try sb.live("clip.mov")                                           // the real file, in files/
        let elsewhere = sb.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: elsewhere.appendingPathComponent("other.mov"))
        let link = try sb.link("media", to: sb.files)
        let r = sb.row(at: link.appendingPathComponent("clip.mov").path)             // cataloged THROUGH the link
        r.auditSeenOn = sb.stamp
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

    @Test("r2 D2: a symlink below the nearest existing folder, or where the walk lands, is 'could not check'")
    func symlinkInTheRemainderIsNotProvable() async throws {
        let sb = try ShowAgainSandbox.make("ca_link_remainder"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let link = try sb.link("linked", to: sb.files)
        let r = sb.row(at: link.appendingPathComponent("sub/clip.mov").path)        // linked → files; files/sub is not there
        r.auditSeenOn = sb.stamp
        let job = await runAudit(sb.model)
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil)
    }

    @Test("r2 D2: the walk itself — folders below the root; a '..' component is refused; a link where a file was is 'not a regular file'; found and gone carry the handle's volume identity")
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
        if case .found(let stat, let on) = CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "real.mov", root: "/") {
            #expect(stat == .file(size: 2_000) && on?.volumeUUID == sb.volumeUUID && on?.mountOn.isEmpty == false)
        } else { Issue.record("expected found") }
        if case .found(let stat, _) = CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "alias.mov", root: "/") {
            #expect(stat == .notAFile, "a link is never followed at the mark")
        } else { Issue.record("expected found") }
        if case .gone(let on) = CatalogAuditDirectoryWalk.prove(directory: sb.files.path, filename: "nope.mov", root: "/") {
            #expect(on.volumeUUID == sb.volumeUUID)
        } else { Issue.record("expected gone") }
        if case .gone(let on) = CatalogAuditDirectoryWalk.prove(directory: sb.files.appendingPathComponent("a/b").path, filename: "nope.mov", root: "/") {
            #expect(on.volumeUUID == sb.volumeUUID, "two folders missing: bound to the nearest existing ancestor's volume")
        } else { Issue.record("expected gone") }
        #expect(CatalogAuditDirectoryWalk.prove(directory: "/var/tmp", filename: "x.mov", root: "/") == .link, "/var is a link: never provable")
        // The first pass's "where is it": the stamp for the names found as files, nil for the rest.
        let seen = CatalogAuditDirectoryWalk.seenOn(directory: sb.files.path, filenames: ["real.mov", "alias.mov", "nope.mov"], root: "/", now: Date())
        #expect(seen[0]?.volumeUUID == sb.volumeUUID && seen[1] == nil && seen[2] == nil)
        #expect(CatalogAuditDirectoryWalk.seenOn(directory: "/var/tmp", filenames: ["x"], root: "/", now: Date()) == [nil])
        #expect(CatalogAuditDirectoryWalk.seenOn(directory: sb.files.appendingPathComponent("a/b").path, filenames: ["x"], root: "/", now: Date()) == [nil])
    }

    // MARK: D4 — supersession in the snapshot

    @Test("r2 F3 / D4: a row superseded after planning is dropped as 'record changed', never marked")
    func supersededAfterPlanningIsDropped() throws {
        let sb = try ShowAgainSandbox.make("ca_superseded"); defer { sb.cleanup() }
        try sb.live("neighbour.mov")
        let r = try sb.live("old.mov", onDisk: false, seen: true)
        let plan = sb.model.catalogAuditPlan()
        let item = try #require(plan.lanes.flatMap(\.items).first { $0.id == r.id })
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
        let r = try sb.live("same.mov", onDisk: false, seen: true)
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
        let gone = try sb.live("gone.mov", onDisk: false, seen: true)
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

    // MARK: D7 — rescan preservation carries the revision (r3 F3)

    @Test("r3 F3 / D7: mark → restore → rescan keeps revision 2 on an otherwise plain row (the rollback ownership check must still see it)")
    func rescanKeepsTheRevision() throws {
        let sb = try ShowAgainSandbox.make("ca_rescan_rev"); defer { sb.cleanup() }
        let r = try sb.live("plain.mov")
        r.userNotes = ""; r.starRating = 0                                           // nothing else worth restoring
        VideoScanModel.stampRemoval(r, .removedFromCatalog(at: Date(), reason: .userRemoved))
        #expect(sb.model.clearRemoval(r) == nil && r.removalRevision == 2 && r.removal == nil)
        let snap = RescanPreservedFields(from: r)
        #expect(!snap.isWorthRestoring && snap.carriesRemovalHistory, "history alone keeps the row in the rescan map")
        let target = CatalogScanTarget(searchPath: sb.files.path)
        sb.model.snapshotPreservedFieldsForRescan(of: target)
        let fresh = VideoRecord(); fresh.fullPath = r.fullPath; fresh.filename = r.filename; fresh.directory = r.directory
        _ = sb.model.applyPreservedFieldsAfterRescan(of: target, onto: [fresh])
        #expect(fresh.removalRevision == 2 && fresh.removal == nil, "the rescan dropped the revision: \(fresh.removalRevision)")
        // A stamp alone keeps the row too.
        let stamped = try sb.live("stamped.mov", seen: true)
        stamped.userNotes = ""; stamped.starRating = 0
        #expect(RescanPreservedFields(from: stamped).carriesRemovalHistory)
        #expect(!RescanPreservedFields(from: VideoRecord()).carriesRemovalHistory, "a plain fresh row carries none")
    }

    // MARK: D8 — the stamp names the physical device too (r4 F1)

    @Test("r4 F1 / D8: a volume with the SAME UUID on a DIFFERENT drive (a clone, a restored image, mounted at the path while the original is disconnected) is 'a clone? not marked' — the stamp names the physical device the file was last seen on and the proof compares it; the same drive again is gone")
    func cloneOnAnotherDriveWithTheSameVolumeUUIDIsNeverGone() async throws {
        let sb = try ShowAgainSandbox.make("ca_clone"); defer { sb.cleanup() }
        let r = try sb.live("on_the_original.mov")
        let driveA: @Sendable (String, UInt64) -> DuplicateDrives.Identity = { _, dev in
            .init(device: dev, kind: .physical, physicalDevice: "IOService:/test/driveA", deviceLabel: "Original")
        }
        let driveB: @Sendable (String, UInt64) -> DuplicateDrives.Identity = { _, dev in
            .init(device: dev, kind: .physical, physicalDevice: "IOService:/test/driveB", deviceLabel: "Clone")
        }
        let first = await DuplicateDrives.$lookupOverride.withValue(driveA) { await runAudit(sb.model) }
        #expect(first.totals[.present] == 1 && r.auditSeenOn != nil, Comment(rawValue: first.totals.line))
        // The original is disconnected; a clone with the same volume UUID, without this file, sits at the path.
        try FileManager.default.removeItem(atPath: r.fullPath)
        let second = await DuplicateDrives.$lookupOverride.withValue(driveB) { await runAudit(sb.model) }
        #expect(second.totals[.couldNotCheck] == 1 && second.totals[.gone] == 0, Comment(rawValue: second.totals.line))
        #expect(r.removal == nil, "a file on the disconnected original was marked Missing through its clone")
        let detail = second.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("a clone?") && detail.contains("different drive"), Comment(rawValue: detail))
        // The same drive: gone.
        let third = await DuplicateDrives.$lookupOverride.withValue(driveA) { await runAudit(sb.model) }
        #expect(third.totals[.gone] == 1 && r.removal?.reason == .missingAtAudit, Comment(rawValue: third.totals.line))
    }

    @Test("r4 D8: the stamp names the physical device (Delete Duplicates' drive key, asked for the handle's mount) and round-trips; an older stamp without one decodes; a stamp WITHOUT a key proves by volume UUID alone (a share's clone is the share); a stamp WITH a key against a drive that cannot be described is not provable")
    func theStampNamesTheDriveAndProvesByTheVolumeAloneWithoutOne() async throws {
        let sb = try ShowAgainSandbox.make("ca_drive_key"); defer { sb.cleanup() }
        let r = try sb.live("keyed.mov")
        _ = await runAudit(sb.model)
        let stamp = try #require(r.auditSeenOn)
        let identity = DuplicateDrives.liveIdentityFresh(forPath: sb.files.path, device: 0)
        let expected = identity.kind == .physical ? DuplicateDrives.key(for: identity) : nil
        #expect(stamp.deviceKey == expected, "the stamp's drive is the one Delete Duplicates sees for this folder: \(stamp) vs \(identity)")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let json = String(bytes: try encoder.encode(VideoRecordDTO(r)), encoding: .utf8) ?? ""
        #expect(json.contains("\"deviceKey\"") == (expected != nil), Comment(rawValue: json))
        #expect(try decoder.decode(VideoRecord.self, from: Data(json.utf8)).auditSeenOn == stamp)
        let older = try decoder.decode(AuditSeenOn.self, from: Data(#"{"volumeUUID":"\#(sb.volumeUUID)","mountFrom":"/dev/disk9s1","seenAt":0}"#.utf8))
        #expect(older.deviceKey == nil && older.volumeUUID == sb.volumeUUID, "an r3 stamp decodes without a drive")
        // A drive DiskArbitration cannot describe: a keyed stamp is not provable; an unkeyed one proves by the volume UUID.
        let unknown: @Sendable (String, UInt64) -> DuplicateDrives.Identity = { _, dev in .init(device: dev, kind: .unknown) }
        try FileManager.default.removeItem(atPath: r.fullPath)
        r.auditSeenOn = AuditSeenOn(volumeUUID: sb.volumeUUID, mountFrom: "sandbox", seenAt: Date(), deviceKey: "disk:0123456789ab")
        let unkeyed = try sb.live("unkeyed.mov", onDisk: false, seen: true)        // `sb.stamp` carries no drive
        let job = await DuplicateDrives.$lookupOverride.withValue(unknown) { await runAudit(sb.model) }
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 1, Comment(rawValue: job.totals.line))
        #expect(r.removal == nil && unkeyed.removal?.reason == .missingAtAudit)
        let detail = job.problems.first { $0.path == r.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("cannot be identified") && detail.contains("a clone?"), Comment(rawValue: detail))
    }

    // MARK: D9 — stamp acquisition is bound to the pathname like the proof (r4 F2)

    /// files/mid/sub/clip.mov on disk, and a same-shaped `elsewhere/sub` beside
    /// the sandbox (with or without a clip.mov). The outside actor renames
    /// `mid` away and puts a LINK to `elsewhere` at its path.
    private func midLinkScene(_ sb: ShowAgainSandbox, elsewhereHasTheFile: Bool) throws
        -> (row: VideoRecord, substitute: @Sendable () -> Void, mid: URL, aside: URL) {
        let mid = sb.files.appendingPathComponent("mid", isDirectory: true)
        let sub = mid.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: sub.appendingPathComponent("clip.mov"))
        let elsewhere = sb.root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        if elsewhereHasTheFile { try Data(repeating: 2, count: 2_000).write(to: elsewhere.appendingPathComponent("sub/clip.mov")) }
        let aside = sb.files.appendingPathComponent("mid.old", isDirectory: true)
        let substitute: @Sendable () -> Void = {
            try? FileManager.default.moveItem(at: mid, to: aside)
            try? FileManager.default.createSymbolicLink(at: mid, withDestinationURL: elsewhere)
        }
        return (sb.row(at: sub.appendingPathComponent("clip.mov").path), substitute, mid, aside)
    }

    @Test("r4 F2 / D9: a link substituted for an INTERMEDIATE folder between the lexical walk and the open — the open follows it; O_NOFOLLOW guards only the last component — writes NO stamp, and the row's old stamp is untouched")
    func linkSubstitutedBetweenTheWalkAndTheOpenWritesNoStamp() async throws {
        let sb = try ShowAgainSandbox.make("ca_acquire_link"); defer { sb.cleanup() }
        let scene = try midLinkScene(sb, elsewhereHasTheFile: true)
        let old = AuditSeenOn(volumeUUID: "6E6F7420-7468-6973-2D64-7269766521AA", mountFrom: "/dev/disk9s1", seenAt: Date(timeIntervalSinceNow: -86_400))
        scene.row.auditSeenOn = old
        let job = await CatalogAuditDirectoryWalk.$betweenTheWalkAndTheOpenForTesting.withValue(scene.substitute) { await runAudit(sb.model) }
        #expect(job.totals[.present] == 1 && job.stampedCount == 0, Comment(rawValue: job.totals.line))
        #expect(scene.row.auditSeenOn == old, "a stamp was written through a link: \(String(describing: scene.row.auditSeenOn))")
    }

    @Test("r4 F2 / D9: the same substitution during the PROOF — the handle opened through the link reads ENOENT in another folder on the same volume, and `lstat(path)` follows the link so the post-ENOENT check agrees with it — is 'a link in the path', never gone")
    func linkSubstitutedBetweenTheWalkAndTheOpenNeverMarks() async throws {
        let sb = try ShowAgainSandbox.make("ca_acquire_link_proof"); defer { sb.cleanup() }
        let scene = try midLinkScene(sb, elsewhereHasTheFile: false)
        scene.row.auditSeenOn = sb.stamp
        let job = await CatalogAuditDirectoryWalk.$betweenTheWalkAndTheOpenForTesting.withValue(scene.substitute) {
            await runAudit(sb.model) { j in j.statPaths = { paths in paths.map { _ in .gone } } }   // a stale first pass
        }
        // The outside actor puts the folder back: the file is at the cataloged path.
        try FileManager.default.removeItem(at: scene.mid)
        try FileManager.default.moveItem(at: scene.aside, to: scene.mid)
        #expect(FileManager.default.fileExists(atPath: scene.row.fullPath))
        #expect(job.totals[.couldNotCheck] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(scene.row.removal == nil, "marked Missing through a link substituted after the lexical walk")
        let detail = job.problems.first { $0.path == scene.row.fullPath }?.detail ?? "no detail row"
        #expect(detail.contains("a link in the path"), Comment(rawValue: detail))
    }

    @Test("r4 F2 / D9: the file's folder replaced between the open and the name read — the handle no longer names the path — writes NO stamp")
    func folderReplacedBetweenTheOpenAndTheNameReadWritesNoStamp() async throws {
        let sb = try ShowAgainSandbox.make("ca_acquire_replaced"); defer { sb.cleanup() }
        let sub = sb.files.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let r = sb.row(at: sub.appendingPathComponent("clip.mov").path)
        try Data(repeating: 1, count: 2_000).write(to: URL(fileURLWithPath: r.fullPath))
        let aside = sb.files.appendingPathComponent("sub.old", isDirectory: true)
        let path = r.fullPath
        let swap: @Sendable () -> Void = {
            try? FileManager.default.moveItem(at: sub, to: aside)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try? Data(repeating: 2, count: 2_000).write(to: URL(fileURLWithPath: path))
        }
        let job = await CatalogAuditDirectoryWalk.$beforeTheNameIsReadForTesting.withValue(swap) { await runAudit(sb.model) }
        #expect(job.totals[.present] == 1 && job.stampedCount == 0, Comment(rawValue: job.totals.line))
        #expect(r.auditSeenOn == nil, "a stamp was written through a handle on a folder that no longer names the path")
    }

    // MARK: D10 — a path change clears the stamp

    @Test("r4 D10: a stamp is 'this path's folder, on this volume' — a move to another folder or volume root (Relocate, a source-side move) clears it in the one setter; a rename within the folder keeps it; the first audit after a move stamps the new place and marks nothing there")
    func aPathChangeClearsTheStamp() async throws {
        let sb = try ShowAgainSandbox.make("ca_path_change"); defer { sb.cleanup() }
        let renamed = try sb.live("renamed.mov", seen: true)
        let renamedPath = sb.files.appendingPathComponent("renamed_2.mov").path
        try FileManager.default.moveItem(atPath: renamed.fullPath, toPath: renamedPath)
        renamed.fullPath = renamedPath
        #expect(renamed.auditSeenOn != nil, "a rename within the folder keeps the stamp")
        let there = sb.files.appendingPathComponent("moved_here", isDirectory: true)
        try FileManager.default.createDirectory(at: there, withIntermediateDirectories: true)
        let moved = try sb.live("moved.mov", seen: true)
        try FileManager.default.moveItem(atPath: moved.fullPath, toPath: there.appendingPathComponent("moved.mov").path)
        moved.fullPath = there.appendingPathComponent("moved.mov").path
        moved.directory = there.path
        #expect(moved.auditSeenOn == nil, "a move to another folder kept the old stamp")
        let lost = try sb.live("lost.mov", seen: true)                           // moved in the catalog to a place the file is not
        lost.fullPath = there.appendingPathComponent("lost.mov").path
        lost.directory = there.path
        let other = try sb.live("other.mov", seen: true)
        other.fullPath = "/Volumes/Other/other.mov"
        #expect(other.auditSeenOn == nil, "a move to another volume root kept the old stamp")
        sb.model.records.removeAll { $0 === other }
        let job = await runAudit(sb.model)
        #expect(job.totals[.present] == 2 && job.totals[.neverSeenByAnAudit] == 1 && job.totals[.gone] == 0, Comment(rawValue: job.totals.line))
        #expect(moved.auditSeenOn != nil && lost.removal == nil, "the first audit after a move stamps the new place and marks nothing there")
    }
}
