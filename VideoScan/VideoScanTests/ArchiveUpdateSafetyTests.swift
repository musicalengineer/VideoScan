// ArchiveUpdateSafetyTests.swift
// The proven safety core of Update… (ported from the Refile review rounds
// r1–r3, docs/codex-review-refile-2026-09-27.md): touched-before-publish
// restore, rollback fsync durability, a failed move back reconciled by
// identity, the one 00_Index lock, no main-actor lock wait, and a move back
// that only ever puts back the ORIGINAL. Sandbox archives only.

import Foundation
import Testing
@testable import VideoScan

@MainActor
private func backups(_ a: UpdateFixture.Archived) -> (URL, Set<String>) {
    let dir = a.sb.archiveRoot.appendingPathComponent("00_Index/\(ArchiveIndexRename.backupFolder)")
    return (dir, Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []))
}

@Suite("Archive Update — safety", .serialized)
@MainActor
struct ArchiveUpdateSafetyTests {

    @Test("a publisher that writes and then throws, on the 1st and on the 2nd index file → every index file byte-identical",
          arguments: [1, 2])
    func publishThenThrow(onCall: Int) async throws {
        let a = try UpdateFixture.make("pt\(onCall)")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let manifest = UpdateFixture.data(a.sb.manifestURL), journal = UpdateFixture.data(a.journalURL)
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let c = Counter()
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { data, url in
            let n: Int = c.lock.withLock { c.n += 1; return c.n }
            try ArchiveIndexRename.livePublish(data, to: url)
            if n == onCall { throw CocoaError(.fileWriteUnknown) }
        }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .rolledBack, "\(r.message)")
        #expect(UpdateFixture.data(a.sb.manifestURL) == manifest && UpdateFixture.data(a.journalURL) == journal)
        #expect(FileManager.default.fileExists(atPath: a.absPath))
    }

    @Test("r2 #1: a RESTORE that writes the original bytes but throws on flush is not a confirmed rollback → incompleteRecovery, backup kept")
    func restoreDurabilityFailureIsNotRollback() async throws {
        let a = try UpdateFixture.make("restoreflush")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let (dir, before) = backups(a)
        final class Counter: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let c = Counter()
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { data, url in
            let n: Int = c.lock.withLock { c.n += 1; return c.n }
            switch n {
            case 1: try ArchiveIndexRename.livePublish(data, to: url)            // manifest published
            case 2: throw CocoaError(.fileWriteUnknown)                          // journal publish fails
            default:                                                             // the manifest RESTORE:
                try ArchiveIndexRename.livePublish(data, to: url)                //   right bytes land…
                throw CocoaError(.fileWriteUnknown)                              //   …flush not confirmed
            }
        }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .incompleteRecovery, "\(r.kind): \(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath))
        #expect(Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).subtracting(before).count == 1, "backup kept")
    }

    enum Failure: String, CaseIterable, Sendable { case verify, index }

    @Test("the move back's folder flush fails → incompleteRecovery, backup kept, file at the original path",
          arguments: Failure.allCases)
    func rollbackFlushFailure(at failure: Failure) async throws {
        let a = try UpdateFixture.make("rb_\(failure.rawValue)")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
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
        let (dir, before) = backups(a)
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        #expect(r.kind == .incompleteRecovery, "\(r.kind): \(r.message)")
        #expect(FileManager.default.fileExists(atPath: a.absPath) && a.copy.fullPath == a.absPath)
        #expect(Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).subtracting(before).count == 1)
    }

    @Test("a foreign file appears at the old path during the read-back → mixedState naming both paths; the record follows the ORIGINAL; both files and the backup kept")
    func blockerAtOldPath() async throws {
        let a = try UpdateFixture.make("blocker")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984)
        let from = a.relPath, to = p.target(hint: h, name: p.currentName), blocker = a.absPath
        let (dir, before) = backups(a)
        var seams = ArchiveRefileEngine.Seams.live
        seams.hashFile = { root, rel in
            if rel == from { return try ArchivePromoteEngine.sha256(root: root, relativePath: rel) }
            try Data("a different file".utf8).write(to: URL(fileURLWithPath: blocker))
            return String(repeating: "0", count: 64)
        }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true, seams: seams)
        #expect(r.kind == .mixedState && r.message.contains(from) && r.message.contains(to), "\(r.message)")
        #expect(MasterArchiveTestSupport.sha256(ofFile: a.url(to).path) == a.sha)
        #expect(String(decoding: UpdateFixture.data(URL(fileURLWithPath: blocker)), as: UTF8.self) == "a different file")
        #expect(a.copy.fullPath == a.url(to).path, "the record points at the ORIGINAL, never at the foreign file")
        let added = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).subtracting(before)
        #expect(added.count == 1)
        if let d = added.first { #expect(ArchiveIndexRename.readMarker(in: dir.appendingPathComponent(d))?.complete == false) }
    }

    @Test("another writer swaps the original out for a stranger at the target → never 'rolled back'; the stranger stays, nothing renamed onto the old path, backup kept")
    func strangerIsNeverPutBack() async throws {
        let a = try UpdateFixture.make("swap")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984)
        let target = a.url(p.target(hint: h, name: p.currentName))
        let aside = a.sb.root.appendingPathComponent("test_relocated_original.mov")
        let (dir, before) = backups(a)
        final class Once: @unchecked Sendable { var done = false; let lock = NSLock() }
        let once = Once()
        var seams = ArchiveRefileEngine.Seams.live
        seams.directoryFsync = { fd, phase in
            let first: Bool = once.lock.withLock { let f = phase == .afterMove && !once.done; if f { once.done = true }; return f }
            if first {
                try? FileManager.default.moveItem(at: target, to: aside)
                try? Data("stranger".utf8).write(to: target)
            }
            return ArchivePromoteEngine.barriers.fsync(fd)
        }
        let r = await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true, seams: seams)
        #expect(r.kind == .mixedState, "\(r.kind): \(r.message)")
        #expect(String(decoding: UpdateFixture.data(target), as: UTF8.self) == "stranger")
        #expect(!FileManager.default.fileExists(atPath: a.absPath))
        #expect(MasterArchiveTestSupport.sha256(ofFile: aside.path) == a.sha)
        #expect(Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).subtracting(before).count == 1)
    }

    @Test("a Promote-style manifest append landing inside the publish window is refused or preserved — never dropped")
    func concurrentAppendNeverDropped() async throws {
        let a = try UpdateFixture.make("lock")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let root = a.root
        let intruder = ArchiveManifestCSV.Row(
            promotedAt: Date(), archiveRelPath: "30_Video/1990-1999/1999/1999-xx-xx_test_intruder.mov",
            sha256: "11", sizeBytes: 1, originalPath: "/Volumes/test_X/intruder.mov", originalVolume: "test_X",
            recordID: UUID(), sourceRecordID: UUID(), recordDate: "1999-xx-xx", dateConfidence: "user-known",
            people: [], starRating: 3)
        final class Box: @unchecked Sendable { var error: Error?; var tried = false; let lock = NSLock() }
        let box = Box()
        var seams = ArchiveRefileEngine.Seams.live
        seams.indexPublisher = { data, url in
            let first: Bool = box.lock.withLock { let f = !box.tried; box.tried = true; return f }
            if first {
                do { try ArchiveManifestCSV.append(intruder, rootPath: root) } catch { box.lock.withLock { box.error = error } }
            }
            try ArchiveIndexRename.livePublish(data, to: url)
        }
        _ = await a.model.updateArchivedFile(p, name: p.currentName, hint: try UpdateFixture.hint(1984), known: true, seams: seams)
        let preserved = MasterArchiveTestSupport.manifestRows(a.sb).contains { $0[1] == intruder.archiveRelPath }
        let refusedAppend = box.lock.withLock { box.error } is ArchiveIndexLock.Busy
        #expect(preserved || refusedAppend, "the other writer's row was silently dropped")
    }

    @Test("the index lock excludes a second holder in the same process; it is released after")
    func lockExcludes() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("upd_lockunit")
        defer { sb.cleanup() }
        try FileManager.default.createDirectory(at: sb.archiveRoot.appendingPathComponent("00_Index"), withIntermediateDirectories: true)
        let root = sb.archiveRoot.path
        try ArchiveIndexLock.withExclusive(root: root, holder: "test outer") {
            #expect(throws: ArchiveIndexLock.Busy.self) {
                try ArchiveIndexLock.withExclusive(root: root, holder: "test inner", wait: .milliseconds(50)) {}
            }
        }
        try ArchiveIndexLock.withExclusive(root: root, holder: "test after") {}
    }

    @Test("contended index lock + an 8-entry Promote finalization: no main-actor gap over 100 ms", .timeLimit(.minutes(1)))
    func finalizationDoesNotStallMain() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("upd_heartbeat")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let root = sb.archiveRoot.path
        let job = PromoteToArchiveJob(plan: try #require(model.buildPromotePlan(recordIDs: [])), model: model)
        job.publishedThisBatch = (0..<8).map { i in
            ArchivePromoteJournal.Entry(sourceRecordID: UUID(), sourcePath: "/Volumes/test_S/\(i).mov",
                                        destRelPath: "30_Video/Undated/xxxx-xx-xx_\(i).mov",
                                        state: .published, sha256: "00", copyRecordID: UUID(), at: Date())
        }
        let ctx = PromoteToArchiveJob.RunContext(root: root, manifestURL: sb.manifestURL, journalURL: sb.journalURL,
                                                 manifestRows: [:], manifestFields: [:])
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? ArchiveIndexLock.withExclusive(root: root, holder: "test holder", wait: .seconds(5)) {
                held.signal(); release.wait()
            }
        }
        held.wait()
        defer { release.signal() }
        final class Beat { var last = ContinuousClock.now; var worst = Duration.zero; var running = true }
        let beat = Beat()
        let ticker = Task { @MainActor in
            while beat.running {
                let now = ContinuousClock.now
                beat.worst = max(beat.worst, now - beat.last); beat.last = now
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await Task.yield()
        beat.last = ContinuousClock.now
        let saved = await job.finalizeBatch(model: model, ctx: ctx)
        beat.worst = max(beat.worst, ContinuousClock.now - beat.last)   // a synchronous stall never lets the ticker run
        beat.running = false
        await ticker.value
        #expect(saved)
        #expect(beat.worst < .milliseconds(100), "main actor stalled for \(beat.worst)")
    }
}
