// ArchiveAngelCodex1665Tests.swift
// codex #1665 (2026-09-23) — the residual of #1659: the archive-copy ↔
// promotion-source link lent facts without a stat. A source rewritten at the
// same size after it was promoted (or an archive copy rewritten in place) is
// no longer the bytes Promote verified; the link may lend only while BOTH
// ends' ContentFixity still describes the file now (describesFileNow) —
// otherwise "similar, not applied". Real files, real SHA-256, real stamps.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — codex #1665: the archive link lends only between fresh ends", .serialized)
@MainActor
struct ArchiveAngelCodex1665Tests {

    private struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let source: VideoRecord
        let archiveCopy: VideoRecord
    }

    /// A source and its promoted archive copy, byte-identical, both with a
    /// real captured ContentFixity; the archive copy linked the way Promote
    /// links it (derivedFrom + archivePromotion). NO shared-digest edge is
    /// relied on: the test drops the copy's digest from the fresh set to
    /// isolate the archive link.
    private func fixture(_ label: String) throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_tape.mov"), bytes: 2048, seed: 5)
        let source = MasterArchiveTestSupport.makeRecord(path: file.path)
        let copyURL = sb.archiveVolume.appendingPathComponent("test_1985-xx-xx_tape.mov")
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: copyURL)
        let copy = MasterArchiveTestSupport.makeRecord(path: copyURL.path)
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        try AngelTestFixity.capture(source)
        try AngelTestFixity.capture(copy)
        model.records = [source, copy]
        #expect(model.isArchiveCopy(copy))
        return Fixture(sb: sb, model: model, source: source, archiveCopy: copy)
    }

    private func rewriteInPlace(_ r: VideoRecord) throws {
        Thread.sleep(forTimeInterval: 0.01)                 // a distinct ctime
        var bytes = try Data(contentsOf: URL(fileURLWithPath: r.fullPath))
        bytes[bytes.count / 2] ^= 0xFF
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: r.fullPath))
        try h.write(contentsOf: bytes)
        try h.close()
        #expect(r.contentFixity?.describesFileNow(FileIdentityStamp.capture(path: r.fullPath)) == false)
    }

    private func inherited(_ f: Fixture, for target: VideoRecord) async -> ArchiveAngelFamilyFacts.Inherited {
        let index = ArchiveAngelCopyFamily.Index(active: f.model.records)
        let fresh = await ArchiveAngelFixityCheck.verify(targets: [target], index: index, catalog: f.model)
        let r = ArchiveAngelFamilyFacts.relatives(of: target, index: index, catalog: f.model, fresh: fresh)
        return ArchiveAngelFamilyFacts.inherited(for: target, relatives: r)
    }

    @Test("control: an unchanged source and archive copy — the source's date reaches the copy")
    func freshLinkLends() async throws {
        let f = try fixture("c1665_control"); defer { f.sb.cleanup() }
        f.source.userDate = "1985"; f.source.userDateConfidence = "known"
        #expect(await inherited(f, for: f.archiveCopy).date?.value == "1985")
    }

    @Test("RED: a source rewritten at the same size after promotion never lends to its archive copy")
    func staleSourceDoesNotLend() async throws {
        let f = try fixture("c1665_source"); defer { f.sb.cleanup() }
        try rewriteInPlace(f.source)
        f.source.userDate = "1985"; f.source.userDateConfidence = "known"
        f.source.userPlace = "Worcester"
        let got = await inherited(f, for: f.archiveCopy)
        #expect(got.date == nil, "a rewritten source lent \(got.date?.value ?? "")")
        #expect(got.place == nil)
    }

    @Test("RED: an archive copy rewritten in place never lends to its source")
    func staleArchiveCopyDoesNotLend() async throws {
        let f = try fixture("c1665_copy"); defer { f.sb.cleanup() }
        try rewriteInPlace(f.archiveCopy)
        f.archiveCopy.userDate = "1985"; f.archiveCopy.userDateConfidence = "known"
        let got = await inherited(f, for: f.source)
        #expect(got.date == nil, "a rewritten archive copy lent \(got.date?.value ?? "")")
    }

    @Test("RED: an archive copy with NO usable fixity (unverifiable) never lends through the link")
    func unverifiableArchiveCopyDoesNotLend() async throws {
        let f = try fixture("c1665_nofixity"); defer { f.sb.cleanup() }
        f.archiveCopy.contentFixity = nil
        f.archiveCopy.userDate = "1985"; f.archiveCopy.userDateConfidence = "known"
        let got = await inherited(f, for: f.source)
        #expect(got.date == nil, "an unverifiable archive copy lent \(got.date?.value ?? "")")
    }
}
