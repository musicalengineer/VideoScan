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
