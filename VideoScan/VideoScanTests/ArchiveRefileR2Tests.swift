// ArchiveRefileR2Tests.swift
// Pins for the codex review of Refile (docs/codex-review-refile-2026-09-27.md),
// one suite per finding, each written RED before its fix. Sandbox archives
// only (`test_*` fixtures under the process temp dir).

import Foundation
import Testing
@testable import VideoScan

// MARK: - Finding 2: a publisher that writes and then throws

@Suite("Archive Refile r2 — publish-then-throw is restored", .serialized)
@MainActor
struct ArchiveRefileR2PublishThrowTests {

    @Test("publish-then-throw on the first and on the second index file → every index file byte-identical, file back",
          arguments: [1, 2])
    func publishThenThrow(onCall: Int) async throws {
        let a = try await RefileFixture.make("r2pt\(onCall)")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let manifest = RefileFixture.data(a.sb.manifestURL)
        let journal = RefileFixture.data(a.journalURL)
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let c = Counter()
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { data, url in
            let n: Int = c.lock.withLock { c.n += 1; return c.n }
            try ArchiveIndexRename.livePublish(data, to: url)          // the bytes land…
            if n == onCall { throw CocoaError(.fileWriteUnknown) }     // …and then it throws
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(RefileFixture.data(a.sb.manifestURL) == manifest, "manifest restored byte-for-byte")
        #expect(RefileFixture.data(a.journalURL) == journal, "journal restored byte-for-byte")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(a.copy.fullPath == a.absPath)
    }
}

// MARK: - Finding 4: the move back's folder flush must be checked

@Suite("Archive Refile r2 — rollback durability", .serialized)
@MainActor
struct ArchiveRefileR2RollbackDurabilityTests {

    /// The two ways into a rollback: the read-back at (c) and the index publish at (d).
    enum Failure: String, CaseIterable, Sendable { case verify, index }

    @Test("rollback folder flush fails → incompleteRecovery, backup RETAINED, file at the original path",
          arguments: Failure.allCases)
    func rollbackFlushFailure(at failure: Failure) async throws {
        let a = try await RefileFixture.make("r2rb_\(failure.rawValue)")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let from = a.relPath
        var seams = ArchiveRefileEngine.Seams.live
        seams.directoryFsync = { fd, phase in phase == .afterMoveBack ? -1 : ArchivePromoteEngine.barriers.fsync(fd) }
        switch failure {
        case .verify:
            seams.hashFile = { root, rel in
                rel == from ? try ArchivePromoteEngine.sha256(root: root, relativePath: rel) : String(repeating: "0", count: 64)
            }
        case .index:
            seams.indexPublisher = { _, _ in throw CocoaError(.fileWriteUnknown) }
        }
        let backups = a.sb.archiveRoot.appendingPathComponent("00_Index/.rename_backups")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])

        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .incompleteRecovery, "\(r.kind): \(r.message)")
        #expect(r.message.localizedCaseInsensitiveContains("not confirmed"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath), "the rename back itself succeeded")
        #expect(a.copy.fullPath == a.absPath)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
        #expect(after.subtracting(before).count == 1, "the backup of this refile is kept, never removed")
    }
}

// MARK: - Finding 3: a failed move back is reconciled by IDENTITY

@Suite("Archive Refile r2 — failed move back reconciled by identity", .serialized)
@MainActor
struct ArchiveRefileR2MoveBackIdentityTests {

    @Test("a foreign file appears at the old path during the read-back → mixedState naming both paths; the record follows the ORIGINAL; both files kept")
    func blockerAtOldPath() async throws {
        let a = try await RefileFixture.make("r2id")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let from = a.relPath
        let to = p.target(hint: p.initialHint, name: p.initialName)
        let blocker = a.absPath
        let backups = a.sb.archiveRoot.appendingPathComponent("00_Index/\(ArchiveIndexRename.backupFolder)")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
        var seams = ArchiveRefileEngine.Seams.live
        seams.hashFile = { root, rel in
            if rel == from { return try ArchivePromoteEngine.sha256(root: root, relativePath: rel) }
            // While the moved file is being read back, another writer puts a
            // DIFFERENT file at the old name; then the read-back "mismatches".
            try Data("a different file".utf8).write(to: URL(fileURLWithPath: blocker))
            return String(repeating: "0", count: 64)
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .mixedState, "\(r.kind): \(r.message)")
        #expect(r.message.contains(from) && r.message.contains(to), "both paths named: \(r.message)")
        let newAbs = a.sb.archiveRoot.appendingPathComponent(to).path
        #expect(MasterArchiveTestSupport.sha256(ofFile: newAbs) == a.sha, "the archived original is at the new path, untouched")
        #expect(String(decoding: RefileFixture.data(URL(fileURLWithPath: blocker)), as: UTF8.self) == "a different file",
                "the foreign file is preserved")
        #expect(a.copy.fullPath == newAbs, "the record points at the ORIGINAL, never at the foreign file")
        // r3 #1: an unconfirmed recovery KEEPS its index backup, marker incomplete.
        let added = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).subtracting(before)
        #expect(added.count == 1, "the mixed-state backup survives: \(added)")
        if let dir = added.first {
            let marker = ArchiveIndexRename.readMarker(in: backups.appendingPathComponent(dir))
            #expect(marker != nil && marker?.complete == false, "incomplete marker — never counted, never pruned")
        }
    }
}

// MARK: - Finding 1: ONE archive-index write exclusion

@Suite("Archive Refile r2 — one index-write lock", .serialized)
@MainActor
struct ArchiveRefileR2IndexLockTests {

    @Test("a Promote-style manifest append landing inside the publish window is refused or preserved — never dropped")
    func concurrentAppendNeverDropped() async throws {
        let a = try await RefileFixture.make("r2lock")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let root = a.root
        let intruder = ArchiveManifestCSV.Row(
            promotedAt: Date(), archiveRelPath: "30_Video/1990-1999/1999/1999-xx-xx_test_intruder.mov",
            sha256: "11", sizeBytes: 1, originalPath: "/Volumes/test_X/intruder.mov", originalVolume: "test_X",
            recordID: UUID(), sourceRecordID: UUID(), recordDate: "1999-xx-xx", dateConfidence: "user-known",
            people: [], starRating: 3)
        final class Box: @unchecked Sendable { var appendError: Error?; var tried = false; let lock = NSLock() }
        let box = Box()
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { data, url in
            let first: Bool = box.lock.withLock { let f = !box.tried; box.tried = true; return f }
            if first {
                // Another writer (Promote) appends right before our publish.
                do { try ArchiveManifestCSV.append(intruder, rootPath: root) } catch {
                    box.lock.withLock { box.appendError = error }
                }
            }
            try ArchiveIndexRename.livePublish(data, to: url)
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        let rows = MasterArchiveTestSupport.manifestRows(a.sb)
        let preserved = rows.contains { $0[1] == intruder.archiveRelPath }
        let refused = box.lock.withLock { box.appendError != nil }
        #expect(preserved || refused, "the other writer's row was silently dropped (refile: \(r.kind))")
        if refused {
            #expect(box.lock.withLock { box.appendError } is ArchiveIndexLock.Busy)
        }
    }

    @Test("the lock excludes a second holder in the same process; it is released after")
    func lockExcludes() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r2lockunit")
        defer { sb.cleanup() }
        let index = sb.archiveRoot.appendingPathComponent("00_Index")
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        let root = sb.archiveRoot.path
        try ArchiveIndexLock.withExclusive(root: root, holder: "test outer") {
            #expect(throws: ArchiveIndexLock.Busy.self) {
                try ArchiveIndexLock.withExclusive(root: root, holder: "test inner", wait: .milliseconds(50)) {}
            }
        }
        try ArchiveIndexLock.withExclusive(root: root, holder: "test after") {}
    }
}

// MARK: - Finding 5: step (e) failures are not a silent success

@Suite("Archive Refile r2 — step (e) persistence", .serialized)
@MainActor
struct ArchiveRefileR2StepEPersistenceTests {

    private func pendingURL(_ a: RefileFixture.Archived) -> URL {
        a.model.mediaLedger.directory.appendingPathComponent(VideoScanModel.pendingRefilesFilename)
    }

    @Test("catalog save fails → completedWithWarnings, durable pending entry; replay at launch persists it and clears the entry")
    func catalogSaveFails() async throws {
        let a = try await RefileFixture.make("r2cat")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        var persistence = ArchiveRefilePersistence.live
        persistence.saveCatalog = { _ in false }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, persistence: persistence)
        #expect(r.kind == .completedWithWarnings, "\(r.kind): \(r.message)")
        #expect(r.message.contains("catalog"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: pendingURL(a).path), "a durable retry is on disk")
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(a.model.mediaLedger.events(forRecordID: a.source.id).contains { $0.event == .refiled })

        var saves = 0
        var replayPersistence = ArchiveRefilePersistence.live
        replayPersistence.saveCatalog = { m in saves += 1; return m.saveCatalogNow() }
        let replayed = await a.model.replayPendingRefiles(persistence: replayPersistence)
        #expect(replayed == 1)
        #expect(saves == 1)
        #expect(a.model.loadPendingRefiles().isEmpty, "entry cleared")
        #expect(a.model.mediaLedger.events(forRecordID: a.source.id).filter { $0.event == .refiled }.count == 1,
                "the ledger line is not written twice")
    }

    @Test("r3 #2: A→B with a failed catalog save, then B→C succeeds, then a foreign file appears at B → replay never redirects the record; C and the newer dates kept")
    func stalePendingNeverRedirects() async throws {
        let a = try await RefileFixture.make("r3stale")
        defer { a.sb.cleanup() }
        let p1 = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        var failSave = ArchiveRefilePersistence.live
        failSave.saveCatalog = { _ in false }
        let r1 = await a.model.refileArchiveCopy(p1, hint: p1.initialHint, name: p1.initialName, persistence: failSave)
        #expect(r1.kind == .completedWithWarnings, "\(r1.message)")
        let b = a.sb.archiveRoot.appendingPathComponent(p1.target(hint: p1.initialHint, name: p1.initialName)).path

        let p2 = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let hint2 = try #require(ArchiveRefile.hint(year: 1985, month: nil, day: nil))
        let r2 = await a.model.refileArchiveCopy(p2, hint: hint2, name: p2.initialName)
        #expect(r2.kind == .refiled, "\(r2.message)")
        let c = a.sb.archiveRoot.appendingPathComponent(p2.target(hint: hint2, name: p2.initialName)).path
        #expect(a.copy.fullPath == c)

        try Data("someone else's file".utf8).write(to: URL(fileURLWithPath: b))   // B is occupied by a stranger
        _ = await a.model.replayPendingRefiles()
        #expect(a.copy.fullPath == c, "the stale A→B entry must not move the record to the foreign file at B")
        #expect(a.copy.userDate == "1985" && a.source.userDate == "1985", "the newer dates are kept")
        #expect(MasterArchiveTestSupport.sha256(ofFile: c) == a.sha)
        #expect(String(decoding: RefileFixture.data(URL(fileURLWithPath: b)), as: UTF8.self) == "someone else's file")
        #expect(a.model.loadPendingRefiles().isEmpty, "nothing stale left to replay")
    }

    @Test("r4 #1: A→B and B→C both fail to save; relaunch with the ORIGINAL catalog (record at A) → replay follows the chain to C with the latest dates")
    func chainedFailedSavesRecover() async throws {
        let a = try await RefileFixture.make("r4chain")
        defer { a.sb.cleanup() }
        // What the catalog on disk says before either refile (the "relaunch" state).
        let persisted = (path: a.copy.fullPath, copyDate: a.copy.userDate, copyConf: a.copy.userDateConfidence,
                         srcDate: a.source.userDate, srcConf: a.source.userDateConfidence)
        var failSave = ArchiveRefilePersistence.live
        failSave.saveCatalog = { _ in false }
        failSave.scheduleRetrySave = { _ in }            // no debounced persistence either

        let p1 = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let r1 = await a.model.refileArchiveCopy(p1, hint: p1.initialHint, name: p1.initialName, persistence: failSave)
        #expect(r1.kind == .completedWithWarnings, "\(r1.message)")
        let p2 = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let hint2 = try #require(ArchiveRefile.hint(year: 1985, month: nil, day: nil))
        let r2 = await a.model.refileArchiveCopy(p2, hint: hint2, name: p2.initialName, persistence: failSave)
        #expect(r2.kind == .completedWithWarnings, "\(r2.message)")
        let c = a.sb.archiveRoot.appendingPathComponent(p2.target(hint: hint2, name: p2.initialName)).path

        // Relaunch: the records say what the catalog on disk says — neither save landed.
        a.copy.fullPath = persisted.path
        a.copy.filename = (persisted.path as NSString).lastPathComponent
        a.copy.directory = (persisted.path as NSString).deletingLastPathComponent
        a.copy.userDate = persisted.copyDate; a.copy.userDateConfidence = persisted.copyConf
        a.source.userDate = persisted.srcDate; a.source.userDateConfidence = persisted.srcConf

        _ = await a.model.replayPendingRefiles()
        #expect(a.copy.fullPath == c, "replay follows A → B → C")
        #expect(a.copy.userDate == "1985" && a.source.userDate == "1985", "the latest dates")
        #expect(a.model.loadPendingRefiles().isEmpty)
    }

    @Test("r3 #3: a ledger write that lands only its FIRST line, then throws → replay yields every intended event exactly once")
    func partialLedgerAppend() async throws {
        let a = try await RefileFixture.make("r3partial")
        defer { a.sb.cleanup() }
        let dir = a.model.mediaLedger.directory
        struct PartialFailure: Error {}
        a.model.mediaLedger = MediaLedger(directory: dir, writer: { data, url in
            if let nl = data.firstIndex(of: 0x0A) {
                try MediaLedger.appendDurable(Data(data[data.startIndex...nl]), to: url)   // the prefix lands…
            }
            throw PartialFailure()                                                        // …then it fails
        })
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName)
        #expect(r.kind == .completedWithWarnings, "\(r.message)")

        a.model.mediaLedger = MediaLedger(directory: dir)
        _ = await a.model.replayPendingRefiles()
        await a.model.mediaLedger.waitForPendingWrites()
        let all = a.model.mediaLedger.allEvents()
        #expect(all.filter { $0.event == .refiled && $0.recordID == a.source.id }.count == 1, "refiled exactly once")
        #expect(all.filter { $0.event == .dateSet && $0.recordID == a.copy.id && $0.detail["date"] == "1984" }.count == 1,
                "the copy's dateSet line — lost after the prefix — is written exactly once")
        #expect(a.model.loadPendingRefiles().isEmpty)
    }

    @Test("ledger append fails → completedWithWarnings, durable pending entry; replay writes the ledger line once")
    func ledgerAppendFails() async throws {
        let a = try await RefileFixture.make("r2led")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        var persistence = ArchiveRefilePersistence.live
        persistence.appendLedger = { _, _ in false }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, persistence: persistence)
        #expect(r.kind == .completedWithWarnings, "\(r.kind): \(r.message)")
        #expect(r.message.contains("ledger"), "\(r.message)")
        #expect(FileManager.default.fileExists(atPath: pendingURL(a).path))
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(!a.model.mediaLedger.events(forRecordID: a.source.id).contains { $0.event == .refiled })

        let replayed = await a.model.replayPendingRefiles()
        #expect(replayed == 1)
        await a.model.mediaLedger.waitForPendingWrites()
        #expect(a.model.mediaLedger.events(forRecordID: a.source.id).filter { $0.event == .refiled }.count == 1)
        #expect(await a.model.replayPendingRefiles() == 0, "nothing left to replay")
    }
}

// MARK: - r3 #4: no blocking lock wait on the main actor

@Suite("Archive Refile r3 — index lock never stalls the main actor", .serialized)
@MainActor
struct ArchiveRefileR3MainActorLockTests {

    @Test("contended index lock + an 8-entry Promote finalization: no main-actor gap over 100 ms", .timeLimit(.minutes(1)))
    func finalizationDoesNotStallMain() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r3heartbeat")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let root = sb.archiveRoot.path
        let plan = try #require(model.buildPromotePlan(recordIDs: []))
        let job = PromoteToArchiveJob(plan: plan, model: model)
        job.publishedThisBatch = (0..<8).map { i in
            ArchivePromoteJournal.Entry(sourceRecordID: UUID(), sourcePath: "/Volumes/test_S/\(i).mov",
                                        destRelPath: "30_Video/Undated/xxxx-xx-xx_\(i).mov",
                                        state: .published, sha256: "00", copyRecordID: UUID(), at: Date())
        }
        let ctx = PromoteToArchiveJob.RunContext(root: root, manifestURL: sb.manifestURL, journalURL: sb.journalURL,
                                                 manifestRows: [:], manifestFields: [:])

        // Another writer holds the index lock for the whole finalization.
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? ArchiveIndexLock.withExclusive(root: root, holder: "test holder", wait: .seconds(5)) {
                held.signal(); release.wait()
            }
        }
        held.wait()
        defer { release.signal() }

        // Main-actor heartbeat: the longest gap between ticks while finalizing.
        final class Beat { var last = ContinuousClock.now; var worst = Duration.zero; var running = true }
        let beat = Beat()
        let ticker = Task { @MainActor in
            while beat.running {
                let now = ContinuousClock.now
                beat.worst = max(beat.worst, now - beat.last)
                beat.last = now
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await Task.yield()
        beat.last = ContinuousClock.now
        let saved = await job.finalizeBatch(model: model, ctx: ctx)
        // The gap still open when finalization returns counts too (a
        // synchronous stall never lets the ticker run at all).
        beat.worst = max(beat.worst, ContinuousClock.now - beat.last)
        beat.running = false
        await ticker.value
        #expect(saved, "the catalog save itself landed")
        #expect(beat.worst < .milliseconds(100), "main actor stalled for \(beat.worst) while the index lock was contended")
    }
}

// MARK: - r4 #2: a move back must put back the ORIGINAL

@Suite("Archive Refile r4 — move back verifies identity", .serialized)
@MainActor
struct ArchiveRefileR4MoveBackVerifiesIdentityTests {

    @Test("after the move another writer relocates the original and puts a stranger at the target → never 'rolled back'; the stranger stays, nothing is renamed onto the old path, the incomplete backup is kept")
    func strangerIsNeverPutBack() async throws {
        let a = try await RefileFixture.make("r4swap")
        defer { a.sb.cleanup() }
        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        let to = p.target(hint: p.initialHint, name: p.initialName)
        let target = a.sb.archiveRoot.appendingPathComponent(to)
        let aside = a.sb.root.appendingPathComponent("test_relocated_original.mov")
        let backups = a.sb.archiveRoot.appendingPathComponent("00_Index/\(ArchiveIndexRename.backupFolder)")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? [])
        final class Once: @unchecked Sendable { var done = false; let lock = NSLock() }
        let once = Once()
        var seams = ArchiveRefileEngine.Seams.live
        seams.directoryFsync = { fd, phase in
            let first: Bool = once.lock.withLock { let f = phase == .afterMove && !once.done; if f { once.done = true }; return f }
            if first {
                // Between the rename and the identity check, another writer
                // takes the original away and leaves a stranger in its place.
                try? FileManager.default.moveItem(at: target, to: aside)
                try? Data("stranger".utf8).write(to: target)
            }
            return ArchivePromoteEngine.barriers.fsync(fd)
        }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, seams: seams)
        #expect(r.kind == .mixedState, "\(r.kind): \(r.message)")
        #expect(r.message.contains(a.relPath) && r.message.contains(to), "both paths named")
        #expect(String(decoding: RefileFixture.data(target), as: UTF8.self) == "stranger", "the stranger is preserved where it was")
        #expect(!FileManager.default.fileExists(atPath: a.absPath), "the stranger was NOT renamed onto the old path")
        #expect(MasterArchiveTestSupport.sha256(ofFile: aside.path) == a.sha, "the relocated original is untouched")
        let added = Set((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).subtracting(before)
        #expect(added.count == 1, "backup kept")
        if let dir = added.first {
            #expect(ArchiveIndexRename.readMarker(in: backups.appendingPathComponent(dir))?.complete == false)
        }
    }
}

// MARK: - r4 #3: an unreadable pending-refiles file is never overwritten

@Suite("Archive Refile r4 — unreadable pending file preserved", .serialized)
@MainActor
struct ArchiveRefileR4PendingFilePreservedTests {

    @Test("a corrupt or unknown-schema pending file is moved aside, byte-for-byte, and a new entry does not clobber it",
          arguments: ["corrupt", "futureSchema"])
    func unreadablePendingPreserved(kind: String) async throws {
        let a = try await RefileFixture.make("r4pend_\(kind)")
        defer { a.sb.cleanup() }
        let url = a.model.pendingRefilesURL
        let alien = kind == "corrupt"
            ? Data("{ this is not json \u{0}".utf8)
            : Data(#"{"version":99,"entries":[{"somethingNew":true}]}"#.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try alien.write(to: url)

        let p = try #require(try? await a.model.makeRefilePreview(recordID: a.source.id).get())
        var failSave = ArchiveRefilePersistence.live
        failSave.saveCatalog = { _ in false }
        failSave.scheduleRetrySave = { _ in }
        let r = await a.model.refileArchiveCopy(p, hint: p.initialHint, name: p.initialName, persistence: failSave)
        #expect(r.kind == .completedWithWarnings, "\(r.message)")

        let dir = url.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(VideoScanModel.pendingRefilesFilename + ".unreadable-") }
        #expect(aside.count == 1, "set aside: \(aside)")
        if let name = aside.first {
            #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == alien, "preserved byte-for-byte")
        }
        #expect(a.model.loadPendingRefiles().count == 1, "the new entry lives in a fresh file")
        let fresh = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(fresh?["version"] as? Int == 1)
    }
}
