// CatalogViewerPublishCornerTests.swift
// Corner-case matrix (Rick, 2026-10-21), the VIEWER-SNAPSHOT publisher:
//
//   Case 6  a catalog writer (an MFO job, or a scan) runs while the publisher
//           ticks — through the MODEL's real source
//           (`viewerSnapshotSource(catalogWriterTitle:)`, the wiring the app
//           uses), not a hand-made closure: every tick is skipped with words
//           said once, nothing is committed first or sealed while the job
//           commits, and the first tick after it ends publishes once, at the
//           job's last generation (GH #350).
//   Case 7  the sealed copy dies part-way (injected at our seam:
//           `sealedCopyBlocking` leaves a partial temp and returns words, or
//           "succeeds" with a torn file): the publish is refused with words,
//           the previously published copy and latch are byte-identical, no
//           partial or temp file is left in viewer-catalog/, `onPublished`
//           (the manifest refresh) is not called.
//
// Five dimensions: LOGIC (above) · SCALE N/A (one copy per tick; the
// throttling is the GH #350 suite's sensor) · MEDIA N/A · ISOLATION
// (CutoverScene sandbox; the "viewer folder" is under it) · SENSOR (the
// SHA-256 and directory listing pins).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Viewer snapshot corners — a running writer holds the publish; an interrupted seal publishes nothing", .serialized)
@MainActor
struct CatalogViewerPublishCornerTests {

    // MARK: - Case 6

    enum Writer: String, CaseIterable, Sendable, CustomStringConvertible {
        case job
        case scan
        var description: String { rawValue }
    }

    @Test("case 6: a writer runs while the publisher ticks (through the model's own source) — skipped with words once, nothing committed or sealed, published once after it ends at the last generation",
          arguments: Writer.allCases)
    func writerHoldsThePublishThenPublishesOnce(_ writer: Writer) async throws {
        let scene = try CutoverScene.make("corner_publish_\(writer)"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(scene.model.saveCatalogNow())
        let live = scene.sandbox.root.appendingPathComponent("master-live", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        var title: String?
        var lines: [String] = []
        var published = 0
        let publisher = CatalogSnapshotPublisher(
            liveDir: live, source: scene.model.viewerSnapshotSource(catalogWriterTitle: { title }),
            log: { lines.append($0) }, onPublished: { published += 1 })

        switch writer {
        case .job: title = "Fill In Full Hashes"
        case .scan: scene.model.isScanning = true
        }
        let commitsBefore = committer.commitCount
        for tick in 0..<3 {
            // The writer commits between ticks.
            try scene.record(.healthy).userNotes = "\(writer) tick \(tick)"
            #expect(scene.model.saveCatalogNow())
            guard case .skipped(let words) = await publisher.publishIfChanged() else {
                Issue.record("\(writer) tick \(tick): not held: \(String(describing: publisher.lastOutcome))"); return
            }
            #expect(words.contains(writer == .job ? "Fill In Full Hashes is running" : "a scan is running"), Comment(rawValue: words))
        }
        #expect(committer.commitCount == commitsBefore + 3, "only the writer's own commits ran — no commit-first while held")
        #expect(published == 0)
        #expect(!FileManager.default.fileExists(atPath: CatalogViewerSnapshot.databaseURL(in: live).path), "nothing sealed while held")
        #expect(lines.filter { $0.contains("published once it ends") }.count == 1, "said once: \(lines)")

        title = nil
        scene.model.isScanning = false
        guard case .published(let after) = await publisher.publishIfChanged() else {
            Issue.record("\(writer): not published after the writer ended: \(String(describing: publisher.lastOutcome))"); return
        }
        #expect(published == 1)
        #expect(after.generation == (await committer.repository.generation), "the copy holds the writer's last commit")
        #expect(await publisher.publishIfChanged() == .unchanged(generation: after.generation))
        #expect(published == 1, "published once, not again")
    }

    // MARK: - Case 7

    enum Interruption: String, CaseIterable, Sendable, CustomStringConvertible {
        /// VACUUM INTO dies part-way: a partial temp is left and the door says why.
        case failsPartWay
        /// The door says "done" but the file is torn (a copy cut short).
        case tornButReported
        var description: String { rawValue }
    }

    @Test("case 7: the sealed copy is interrupted — refused with words; the last published copy and latch byte-identical; no partial or temp file left; no manifest refresh",
          arguments: Interruption.allCases)
    func interruptedSealPublishesNothing(_ interruption: Interruption) async throws {
        let scene = try CutoverScene.make("corner_seal_\(interruption)"); defer { scene.cleanup() }
        try await scene.importCatalog()
        _ = try await scene.sqliteLoad()
        try scene.writeLatch()
        let repository = FaultyRepository(GRDBCatalogRepository(host: "corner-seal"))
        guard case .readWrite = await repository.open(at: scene.databaseURL) else {
            Issue.record("the scene's catalog.sqlite did not open read-write"); return
        }
        let live = scene.sandbox.root.appendingPathComponent("master-live", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        var published = 0
        var lines: [String] = []
        let publisher = CatalogSnapshotPublisher(
            liveDir: live,
            source: .init(store: { CatalogSnapshotPublisher.Store(repository: repository, commitFirst: { nil }) }, latchURL: scene.latchURL),
            log: { lines.append($0) }, onPublished: { published += 1 })

        guard case .published(let good) = await publisher.publishIfChanged() else {
            Issue.record("the first, healthy publish failed: \(String(describing: publisher.lastOutcome))")
            await repository.close(); return
        }
        let snapshot = CatalogViewerSnapshot.databaseURL(in: live)
        let latch = CatalogViewerSnapshot.latchURL(in: live)
        let before = (try CornerFiles.sha256(snapshot), try CornerFiles.sha256(latch))
        let listingBefore = CornerFiles.names(in: CatalogViewerSnapshot.directory(in: live), prefix: "")

        // A new generation, so the next tick tries to publish.
        guard case .committed = await repository.write(as: .ui, { _ in }) else {
            Issue.record("the test commit did not land"); await repository.close(); return
        }
        let inner = repository.inner
        switch interruption {
        case .failsPartWay:
            repository.sealFault = { target in
                try? Data("SQLite format 3\u{0}".utf8 + Data(repeating: 0, count: 4_000)).write(to: target)
                return "VACUUM INTO \(target.lastPathComponent) failed: injected — interrupted part-way"
            }
        case .tornButReported:
            repository.sealFault = { target in
                if let why = inner.sealedCopyBlocking(to: target) { return why }
                guard let handle = try? FileHandle(forUpdating: target) else { return "could not tear" }
                let length = (try? handle.seekToEnd()) ?? 0
                try? handle.truncate(atOffset: length / 3)
                try? handle.close()
                return nil
            }
        }
        let outcome = await publisher.publishIfChanged()
        await repository.close()
        guard case .failed(let words) = outcome else {
            Issue.record("\(interruption): an interrupted seal was not refused: \(outcome)"); return
        }
        print("[corner-publish] \(interruption): \(words)")
        switch interruption {
        case .failsPartWay: #expect(words.contains("interrupted part-way"), Comment(rawValue: words))
        case .tornButReported: #expect(words.contains("did not check out"), Comment(rawValue: words))
        }
        #expect(published == 1, "\(interruption): the manifest refresh ran for a failed publish")
        #expect(publisher.lastPublishedGeneration == good.generation)
        #expect(try CornerFiles.sha256(snapshot) == before.0, "\(interruption): the last published copy changed")
        #expect(try CornerFiles.sha256(latch) == before.1)
        #expect(CornerFiles.names(in: CatalogViewerSnapshot.directory(in: live), prefix: "") == listingBefore,
                "\(interruption): a partial or temp file was left: \(CornerFiles.names(in: CatalogViewerSnapshot.directory(in: live), prefix: ""))")
        #expect(lines.contains { $0.contains("REFUSED publishing catalog.sqlite for viewers") && $0.contains("Viewers keep the last published copy") }, "\(lines)")
    }
}
