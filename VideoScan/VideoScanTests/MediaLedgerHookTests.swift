// MediaLedgerHookTests.swift
// The Media Ledger WRITERS at the existing hooks (promote-and-prune stage
// 2, Rick 2026-09-12) — each verb still does exactly what it did, and the
// ledger gains its line:
//
//   PROMOTE     one `archived` line per landed file (batch id = job id,
//               fixity + verified in detail), the ledger MIRRORED into the
//               archive's 00_Index/, the batch protection line on the job,
//               and the "Archived — what next?" offer — ONCE, and only when
//               no file failed (a batch with a failure never offers).
//   ATTESTATION recordAttestation writes its ledger twin AND the stage-1
//               attestation journal still gets its lines (SENSOR: existing
//               journal writers unchanged).
//   TIDY        set-aside (by tidy, original reason) / put-back / Remove
//               from Catalog / restore set-aside.
//   PURGE       Remove (purgeRecords) → "removed-from-catalog"; Restore /
//               Undo → restored.
//   JUNK        Delete Confirmed Junk (permanent, on a temp blob) →
//               copyDeleted with the volume; missing files never get a line.
//   INSPECTOR   noteUserPlaceEdited / noteUserDateEdited → placeSet /
//               dateSet with value + confidence ("" when cleared).
//   HISTORY     the inspector's narrated lines for a promoted record read
//               "Archived to … read back and verified." on top.
//   BACKLOG     Tidy's entry offers the same sheet for the outside-archive
//               copies of verified archive content.
//
// Every model's ledger is pointed at the sandbox (never the shared file).

import Foundation
import Testing
@testable import VideoScan

@Suite("Media Ledger — writers at the hooks", .serialized)
@MainActor
struct MediaLedgerHookTests {

    private func makeModel(_ sb: MasterArchiveTestSupport.Sandbox) throws -> VideoScanModel {
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        return model
    }

    private func seed(_ sb: MasterArchiveTestSupport.Sandbox, count: Int) throws -> [URL] {
        try (0..<count).map { i in
            try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_led_\(i).mov"),
                                                   bytes: 32 * 1024 + i, seed: UInt64(i + 11))
        }
    }

    private func settled(_ model: VideoScanModel) async -> [MediaLedgerEvent] {
        await model.mediaLedger.waitForPendingWrites()
        return model.mediaLedger.allEvents()
    }

    @Test("PROMOTE: archived lines with the batch id, the mirror in 00_Index, the protection line, and ONE offer; a failed file never offers")
    func promoteWritesArchivedLinesMirrorsAndOffersOnce() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledpromote")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 3)
        let model = try makeModel(sb)
        let recs = files.map { MasterArchiveTestSupport.makeRecord(path: $0.path, userDate: "1992") }
        model.records = recs

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: recs.map(\.id)))
        await job.completionTask?.value
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("Promoted 3"))

        // Ledger lines — one per landed file, on the SOURCE record.
        let events = await settled(model)
        let archived = events.filter { $0.event == .archived }
        #expect(archived.count == 3, "\(events.map(\.event))")
        #expect(Set(archived.map(\.recordID)) == Set(recs.map(\.id)))
        #expect(Set(archived.map(\.batchID)) == [job.id.uuidString])
        #expect(archived.allSatisfy { $0.by == .promote })
        for e in archived {
            #expect(e.detail[MediaLedgerEvent.Detail.verified] == "true")
            #expect(e.detail[MediaLedgerEvent.Detail.fixity]?.count == 64, "sha256 hex")
            #expect(e.detail[MediaLedgerEvent.Detail.relPath]?.hasPrefix("30_Video/") == true, "\(e.detail)")
            #expect(e.detail[MediaLedgerEvent.Detail.archive]?.isEmpty == false)
            #expect(e.contentKey == "", "a synthetic blob record is never hashed → unknown content; found by id / filename: \(e.contentKey)")
        }
        // The manifest row's sha matches the ledger's fixity for each file.
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(Set(rows.map { $0[2] }) == Set(archived.compactMap { $0.detail[MediaLedgerEvent.Detail.fixity] }))

        // Mirror — byte-identical copy inside 00_Index.
        let mirror = MediaLedger.mirrorURL(rootPath: sb.archiveRoot.path)
        #expect(try Data(contentsOf: mirror) == (try Data(contentsOf: model.mediaLedger.fileURL)))

        // Protection line + the one offer.
        #expect(job.protectionLine?.hasPrefix("Archive ✓verified · 3 working copies (") == true, "\(job.protectionLine ?? "nil")")
        let offer = try #require(model.pendingArchivedWhatNext)
        #expect(offer.batchID == job.id.uuidString)
        #expect(Set(offer.recordIDs) == Set(recs.map(\.id)))
        #expect(offer.fileCount == 3)
        #expect(offer.totalBytes == recs.reduce(0) { $0 + $1.sizeBytes })
        #expect(offer.source == .promoteBatch)
        #expect(offer.protection.archive == .verified && offer.protection.familyCount == 3)
        #expect(job.offeredWhatNext)

        // History for a promoted record reads the archived sentence on top.
        let lines = await model.mediaLedger.narrated(recordID: recs[0].id, contentKey: VideoScanModel.ledgerContentKey(for: recs[0]),
                                                     filename: recs[0].filename)
        #expect(lines.first?.hasPrefix("Archived to ") == true && lines.first?.hasSuffix("read back and verified.") == true, "\(lines)")

        // A batch with a failed file: lines for what landed, NO offer.
        model.pendingArchivedWhatNext = nil
        let more = try (3..<5).map { i in
            try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_led_\(i).mov"), bytes: 4096 + i, seed: UInt64(i + 99))
        }
        let good = MasterArchiveTestSupport.makeRecord(path: more[0].path, userDate: "1993")
        let bad = MasterArchiveTestSupport.makeRecord(path: more[1].path, userDate: "1993")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: more[1].path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: more[1].path) }
        model.records.append(contentsOf: [good, bad])
        let second = try #require(await MasterArchiveTestSupport.promote(model, ids: [good.id, bad.id]))
        await second.completionTask?.value
        guard case .finished(let s2) = second.state else { Issue.record("\(second.state)"); return }
        #expect(s2.contains("failed 1"), "\(s2)")
        #expect(model.pendingArchivedWhatNext == nil, "a failed file never offers the sheet")
        #expect(second.protectionLine == nil)
        #expect(!second.offeredWhatNext)
        let after = await settled(model)
        #expect(after.filter { $0.event == .archived }.count == 4, "the landed file still got its line")
        #expect(after.filter { $0.event == .archived && $0.recordID == bad.id }.isEmpty)
    }

    @Test("ATTESTATION: recordAttestation writes the ledger twin; SENSOR — the attestation journal still gets its lines")
    func attestationTwinAndJournalUnchanged() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledattest")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = VideoRecord(); a.filename = "a.mov"; a.fullPath = "/Volumes/T/a.mov"; a.contentHash = "v1:aaa"
        let b = VideoRecord(); b.filename = "b.mov"; b.fullPath = "/Volumes/T/b.mov"
        model.records = [a, b]
        let at = Date(timeIntervalSince1970: 1_757_700_000)
        let write = model.recordAttestation(kind: .cloud, answer: .yes, label: " iCloud ", at: at, for: [a.id, b.id, UUID()], batchID: "batch-7")
        await write.flush?.value
        let events = await settled(model)
        let att = events.filter { $0.event == .attestation }
        #expect(att.count == 2)
        #expect(Set(att.map(\.recordID)) == [a.id, b.id])
        #expect(att.allSatisfy { $0.batchID == "batch-7" && $0.by == .rick && $0.at == at })
        #expect(att.first { $0.recordID == a.id }?.contentKey == "h:v1:aaa")
        #expect(att.first { $0.recordID == b.id }?.contentKey == "", "unhashed, zero-size: unknown content")
        for e in att {
            #expect(e.detail[MediaLedgerEvent.Detail.kind] == "cloud")
            #expect(e.detail[MediaLedgerEvent.Detail.answer] == "yes")
            #expect(e.detail[MediaLedgerEvent.Detail.label] == "iCloud")
        }
        // SENSOR: stage 1's journal is untouched by the ledger.
        let journal = ArchiveAttestationJournal.entries(rootPath: sb.archiveRoot.path)
        #expect(journal.count == 2 && journal.allSatisfy { $0.line == "attestation cloud=yes 'iCloud' by rick" })
        #expect(a.backupAttestations.count == 1, "the record still carries the answer")
        // A "no" is its own line.
        await model.recordAttestation(kind: .offsite, answer: .no, at: at.addingTimeInterval(1), for: [a.id]).flush?.value
        let again = await settled(model).filter { $0.event == .attestation }
        #expect(again.count == 3)
        #expect(again.last?.detail[MediaLedgerEvent.Detail.answer] == "no")
        #expect(again.last?.detail[MediaLedgerEvent.Detail.label] == "")
    }

    @Test("TIDY: set-aside by tidy with the original reason, put back on undo; Remove from Catalog and Put Back by rick")
    func tidyAndRemoveFromCatalog() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledtidy")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let still = VideoRecord(); still.filename = "IMG_0001.jpg"; still.fullPath = "/Volumes/T/IMG_0001.jpg"; still.ext = "jpg"; still.sizeBytes = 10; still.partialMD5 = "m1"
        let music = VideoRecord(); music.filename = "song.mp3"; music.fullPath = "/Volumes/T/song.mp3"; music.ext = "mp3"; music.sizeBytes = 20; music.partialMD5 = "m2"
        let video = VideoRecord(); video.filename = "v.mov"; video.fullPath = "/Volumes/T/v.mov"; video.ext = "mov"; video.sizeBytes = 30
        model.records = [still, music, video]
        let plan = VideoScanModel.TidyCatalogPlan(rows: [
            .init(id: still.id, filename: still.filename, fullPath: still.fullPath, sizeBytes: 10, reason: .stillImage),
            .init(id: music.id, filename: music.filename, fullPath: music.fullPath, sizeBytes: 20, reason: .musicFormat),
        ])
        #expect(model.applyTidyCatalog(plan) == 2)
        var events = await settled(model)
        let setAside = events.filter { $0.event == .setAside }
        #expect(setAside.count == 2)
        #expect(setAside.allSatisfy { $0.by == .tidy && $0.batchID?.hasPrefix("tidy-") == true })
        #expect(setAside.first { $0.recordID == still.id }?.detail[MediaLedgerEvent.Detail.reason] == "still-image")
        #expect(setAside.first { $0.recordID == music.id }?.detail[MediaLedgerEvent.Detail.reason] == "music-format")
        #expect(setAside.first { $0.recordID == still.id }?.contentKey == "p:m1:10")

        #expect(model.undoLastTidyCatalog())
        events = await settled(model)
        let putBack = events.filter { $0.event == .putBack }
        #expect(putBack.count == 2 && putBack.allSatisfy { $0.by == .rick })

        // Remove from Catalog (set aside by rick) then Put Back.
        #expect(model.removeFromCatalog(recordIDs: [video.id]) == 1)
        events = await settled(model)
        let removed = try #require(events.last { $0.event == .setAside })
        #expect(removed.recordID == video.id && removed.by == .rick)
        #expect(removed.detail[MediaLedgerEvent.Detail.reason] == "removed-by-user")
        #expect(model.restoreSetAsideRecords(ids: [video.id]) == 1)
        events = await settled(model)
        #expect(events.last?.event == .putBack && events.last?.recordID == video.id)
        // Narrated: the whole story, newest first.
        let lines = await model.mediaLedger.narrated(recordID: still.id, contentKey: "p:m1:10", filename: still.filename)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("You put it back in the catalog on"), "\(lines)")
        #expect(lines[1].hasPrefix("Tidy set it aside on") && lines[1].hasSuffix("— a photo, not a video."), "\(lines)")
    }

    @Test("PURGE: Remove writes removed-from-catalog; Restore and Undo write restored")
    func purgeAndRestore() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledpurge")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let a = VideoRecord(); a.filename = "a.mov"; a.fullPath = "/Volumes/T/a.mov"
        let b = VideoRecord(); b.filename = "b.mov"; b.fullPath = "/Volumes/T/b.mov"
        model.records = [a, b]
        #expect(model.purgeRecords(ids: [a.id, b.id]) == 2)
        var events = await settled(model)
        let removed = events.filter { $0.event == .setAside }
        #expect(removed.count == 2 && removed.allSatisfy { $0.detail[MediaLedgerEvent.Detail.reason] == "removed-from-catalog" })
        #expect(model.restoreRecord(id: a.id))
        #expect(model.undoLastPurge())
        events = await settled(model)
        let restored = events.filter { $0.event == .restored }
        #expect(restored.map(\.recordID) == [a.id, b.id], "one from Restore, one from Undo (a was already back)")
        let line = await model.mediaLedger.narrated(recordID: a.id, contentKey: "", filename: "a.mov").first
        #expect(line?.hasPrefix("You restored it to the catalog on") == true)
    }

    @Test("JUNK: Delete Confirmed Junk (permanent) writes copyDeleted with the volume; a missing file gets no line")
    func junkDeleteWritesCopyDeleted() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledjunk")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_junk.mov"), bytes: 2048, seed: 5)
        let present = MasterArchiveTestSupport.makeRecord(path: file.path)
        present.mediaDisposition = .confirmedJunk
        let missing = MasterArchiveTestSupport.makeRecord(path: sb.sources.appendingPathComponent("test_gone.mov").path)
        missing.mediaDisposition = .confirmedJunk
        model.records = [present, missing]
        let result = await model.deleteConfirmedJunk([present, missing], mode: .permanent)
        #expect(result.succeeded == 1 && result.alreadyMissing == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let events = await settled(model)
        let deleted = events.filter { $0.event == .copyDeleted }
        #expect(deleted.count == 1)
        #expect(deleted.first?.recordID == present.id)
        #expect(deleted.first?.detail[MediaLedgerEvent.Detail.mode] == "permanent")
        #expect(deleted.first?.detail[MediaLedgerEvent.Detail.volume] == present.volumeName)
        #expect(deleted.first?.batchID?.hasPrefix("junk-") == true)
        #expect(events.filter { $0.recordID == missing.id }.isEmpty, "nothing happened to a file that was already gone")
    }

    @Test("INSPECTOR: place and date edits write placeSet / dateSet with value + confidence; a clear writes an empty value")
    func placeAndDateEdits() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledplace")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let r = VideoRecord(); r.filename = "a.mov"; r.fullPath = "/Volumes/T/a.mov"; r.contentHash = "v1:a"
        model.records = [r]
        r.userPlace = "Cape Cod"; r.userPlaceConfidence = UserPlaceConfidence.known.rawValue
        model.noteUserPlaceEdited(r)
        r.userDate = "1992-07"; r.userDateConfidence = nil
        model.noteUserDateEdited(r)
        r.userPlace = nil; r.userPlaceConfidence = nil
        model.noteUserPlaceEdited(r)
        let events = await settled(model)
        #expect(events.map(\.event) == [.placeSet, .dateSet, .placeSet])
        #expect(events[0].detail == ["place": "Cape Cod", "confidence": "known"])
        #expect(events[1].detail == ["date": "1992-07", "confidence": "estimated"], "nil confidence reads as the default best guess")
        #expect(events[2].detail == ["place": "", "confidence": ""])
        #expect(events.allSatisfy { $0.by == .rick && $0.contentKey == "h:v1:a" })
        let lines = await model.mediaLedger.narrated(recordID: r.id, contentKey: "h:v1:a", filename: "a.mov")
        #expect(lines[0].hasPrefix("You cleared the place on"), "\(lines)")
        #expect(lines[1].contains("set the date to 1992-07 on") && lines[1].hasSuffix("(best guess)."))
        #expect(lines[2].contains("set the place to Cape Cod on") && lines[2].hasSuffix("(you're sure)."))
    }

    @Test("BACKLOG: Tidy's entry offers the sheet for the outside-archive copies of verified archive content")
    func backlogOffer() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("ledbacklog")
        defer { sb.cleanup() }
        let files = try seed(sb, count: 2)
        let model = try makeModel(sb)
        let recs = files.map { MasterArchiveTestSupport.makeRecord(path: $0.path, userDate: "1992") }
        let unrelated = VideoRecord(); unrelated.filename = "u.mov"; unrelated.fullPath = "/Volumes/T/u.mov"; unrelated.contentHash = "v1:u"
        model.records = recs + [unrelated]
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: recs.map(\.id)))
        await job.completionTask?.value
        model.pendingArchivedWhatNext = nil
        await model.offerArchivedWhatNextForBacklog()
        let offer = try #require(model.pendingArchivedWhatNext)
        #expect(offer.source == .tidyBacklog)
        #expect(Set(offer.recordIDs) == Set(recs.map(\.id)), "the sources are the outside-archive copies; the archive copies and the unrelated record are not")
        #expect(offer.protection.archive == .verified)
        #expect(offer.totalBytes == recs.reduce(0) { $0 + $1.sizeBytes })
        // The dry-run plan for that backlog: every family has one working
        // copy (the source) and no attestation → not covered under the
        // default bar (the archive copy is ★★★).
        let plan = await model.prunePlan(for: offer.recordIDs, options: .init())
        #expect(plan.families.count == 2)
        #expect(plan.notCoveredCount == 2)
        #expect(plan.trashCount == 0 && plan.extraCount == 2)
        // Attest a cloud copy → covered; the single working copy is the keeper, nothing goes.
        await model.recordAttestation(kind: .cloud, answer: .yes, label: "iCloud", for: offer.recordIDs).flush?.value
        let covered = await model.prunePlan(for: offer.recordIDs, options: .init())
        #expect(covered.notCoveredCount == 0)
        #expect(covered.keeperRequiredCount == 2 && covered.trashCount == 0)
        #expect(Set(covered.families.compactMap(\.keeper?.id)) == Set(recs.map(\.id)))
    }
}
