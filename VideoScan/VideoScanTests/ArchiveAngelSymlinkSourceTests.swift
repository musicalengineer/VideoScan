// ArchiveAngelSymlinkSourceTests.swift — a symlinked source (~/Movies →
// the Projects volume) must measure the TARGET, not the 62-byte link.
// Rick 2026-09-09: first batch refused "Christmas-1990-something.mov —
// size changed 5.8 GB → 62 bytes".

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — symlinked source identity")
struct ArchiveAngelSymlinkSourceTests {

    @MainActor
    @Test("identity re-check follows the link; a real size change is still caught")
    func symlinkMeasuresTarget() throws {
        let sandbox = try MasterArchiveTestSupport.makeSandbox("symlink")
        defer { sandbox.cleanup() }
        let fm = FileManager.default
        let target = sandbox.root.appendingPathComponent("real.mov")
        try Data(repeating: 0x4D, count: 4096).write(to: target)
        let link = sandbox.root.appendingPathComponent("link.mov")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let model = MasterArchiveTestSupport.makeModel(sandbox)
        let rec = VideoRecord()
        rec.filename = "link.mov"; rec.fullPath = link.path; rec.sizeBytes = 4096
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        model.records.append(rec)

        let entry = ArchiveAngelPlan.Entry(
            id: rec.id, sourcePath: link.path, filename: "link.mov", sizeBytes: 4096,
            durationSeconds: 90, score: 10, evidence: [], proposedName: "link.mov", proposedDate: nil)
        #expect(ArchiveAngelPromoter.identityProblem(for: entry, model: model) == nil)

        try Data(repeating: 0x4D, count: 10).write(to: target)
        #expect(ArchiveAngelPromoter.identityProblem(for: entry, model: model)?.contains("size changed") == true)
    }
}
