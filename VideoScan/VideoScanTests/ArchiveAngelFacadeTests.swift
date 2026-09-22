// ArchiveAngelFacadeTests.swift
// The Archive Angel's front door (ArchiveAngel/Facade/ArchiveAngel.swift):
// `model.archiveAngel` answers exactly what the pieces behind it answer.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel façade — forwards, never re-derives", .serialized)
@MainActor
struct ArchiveAngelFacadeTests {

    private func model() throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-facade")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    @Test("reads through the façade equal the evidence store's own answers (candidate set, evidence, badge)")
    func readsForward() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = UUID(), b = UUID(), c = UUID()
        let now = Date()
        model.archiveAngel.store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, records: [
            a: .init(score: 120, lines: [.init(points: 120, line: "★★★")], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now),
            b: .init(score: 70, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now),
            c: .init(score: 0, lines: [], rejection: .tooShort, useCount: 0, lastUsed: nil, computedAt: now),
        ]))
        let angel = model.archiveAngel
        #expect(angel.candidateIDs == [a, b])
        #expect(angel.candidateIDs == angel.store.candidateIDs)
        #expect(angel.evidence(for: a) == angel.store.record(for: a))
        #expect(angel.evidence(for: c)?.grade == .x)
        #expect(angel.evidence(for: UUID()) == nil)
        #expect(angel.badge(for: a) == ArchiveAngelCatalogBadge.make(for: angel.store.record(for: a)))
        #expect(angel.badge(for: a)?.text == "Promote me")
        #expect(angel.badge(for: b)?.text == "Worth a look")
        #expect(angel.badge(for: c) == nil)
    }

    @Test("one façade per model: the property is stable across reads")
    func stable() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.archiveAngel === model.archiveAngel)
    }
}
