// ArchiveAngelCandidateProjectionTests.swift
// VideoRecord → ArchiveAngelCandidate projection (LOGIC) on an ISOLATED
// model (sandboxed catalog store, temp files — never the shared App
// Support), plus the pure name/date helpers the plan entries use.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — record projection")
struct ArchiveAngelCandidateProjectionTests {

    @MainActor
    private func fixture(_ label: String) throws -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        let path = sb.sources.appendingPathComponent("clip_\(label).mov").path
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: 4096, seed: 7)
        let rec = MasterArchiveTestSupport.makeRecord(path: path, inferredDate: Date(timeIntervalSince1970: 700_000_000),
                                                      inferredConfidence: 0.9, starRating: 2)
        rec.durationSeconds = 300
        rec.isPlayable = "Yes"
        rec.videoCodec = "h264"
        rec.audioCodec = "aac"
        model.records.append(rec)
        return (sb, model, rec)
    }

    @Test("a plain record projects eligible with its facts")
    @MainActor
    func plain() throws {
        let (sb, model, rec) = try fixture("plain")
        defer { sb.cleanup() }
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(c.id == rec.id)
        #expect(c.starRating == 2)
        #expect(!c.isPairedHalf)
        #expect(!c.hasArchivedDuplicate)
        #expect(c.isOnlyCopy)
        #expect(!c.formatAtRisk)
        #expect(c.volumeOnline)
        #expect(ArchiveAngelScorer.hardFloor(c) == nil)
    }

    @Test("a correlated pair half is flagged (pairGroupID or pairedWith)")
    @MainActor
    func pairedHalf() throws {
        let (sb, model, rec) = try fixture("pair")
        defer { sb.cleanup() }
        rec.pairGroupID = UUID()
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(c.isPairedHalf)
        #expect(ArchiveAngelScorer.hardFloor(c) == .pairedHalf)
    }

    @Test("an archive copy itself is 'already archived'")
    @MainActor
    func archiveCopy() throws {
        let (sb, model, rec) = try fixture("archived")
        defer { sb.cleanup() }
        rec.derivationKind = ArchivePromotion.derivationKind
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(c.hasArchivedDuplicate)
        #expect(ArchiveAngelScorer.hardFloor(c) == .duplicateArchived)
    }

    @Test("a duplicate-group member is not the only copy")
    @MainActor
    func onlyCopy() throws {
        let (sb, model, rec) = try fixture("dup")
        defer { sb.cleanup() }
        rec.duplicateGroupID = UUID()
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(!c.isOnlyCopy)
    }

    @Test("an at-risk codec projects formatAtRisk")
    @MainActor
    func atRisk() throws {
        let (sb, model, rec) = try fixture("dv")
        defer { sb.cleanup() }
        rec.videoCodec = "dvvideo"
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(c.formatAtRisk)
    }

    @Test("confirmed people carry their names; richness flags follow the fields")
    @MainActor
    func people() throws {
        let (sb, model, rec) = try fixture("people")
        defer { sb.cleanup() }
        rec.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date()), ConfirmedTag(name: "Tim", confirmedAt: Date())]
        rec.detectedPeople = ["Matt"]
        rec.userNotes = "Cape Cod"
        rec.tags = ["vacation"]
        let c = ArchiveAngelCandidate.project(rec, model: model, policy: model.duplicateKeeperPolicy())
        #expect(c.confirmedPeople == ["Donna", "Tim"])
        #expect(c.detectedPeople == ["Matt"])
        #expect(c.hasUserNotes)
        #expect(c.tagCount == 1)
        #expect(!c.hasCaptions)
    }

    @Test("proposedDate strips unknown trailing parts", arguments: [
        ("1992-07-15", "1992-07-15"), ("1992-07-xx", "1992-07"), ("1992-xx-xx", "1992"), ("xxxx-xx-xx", nil),
    ])
    func proposedDate(prefix: String, expected: String?) {
        #expect(ArchiveAngelNaming.proposedDate(fromFilenamePrefix: prefix) == expected)
    }

    @Test("proposedName follows the archive naming rule; a generic stem gets the advisor's title")
    @MainActor
    func proposedName() throws {
        let (sb, model, rec) = try fixture("name")
        defer { sb.cleanup() }
        _ = model
        rec.userDate = "1992-07-15"
        let facts = ArchivePathResolver.facts(for: rec)
        let named = ArchiveAngelNaming.proposedName(facts: facts, people: ["Donna"], tags: [])
        #expect(named.hasPrefix("1992-07-15_"))
        #expect(named.hasSuffix(".mov"))
        #expect(named.contains("clip_name"), "a meaningful stem keeps the filename: \(named)")

        rec.filename = "MVI_0042.mov"
        let generic = ArchiveAngelNaming.proposedName(facts: ArchivePathResolver.facts(for: rec), people: ["Donna"], tags: ["cape cod"])
        #expect(generic.contains("Donna_CapeCod"), Comment(rawValue: generic))
    }

    @Test("T10 H3 at the builder: archiveAngelSweepCandidates() marks a same-folder export with its original (the sweep's candidate producer, not just the scorer)")
    @MainActor
    func builderMarksDerivatives() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel_builder")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        func add(_ name: String, star: Int = 0) throws -> VideoRecord {
            let path = sb.sources.appendingPathComponent(name).path
            try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: path), bytes: 4096, seed: 3)
            let rec = MasterArchiveTestSupport.makeRecord(path: path, starRating: star)
            rec.durationSeconds = 3600
            rec.sizeBytes = 9_000_000_000     // above the proxy-stream bitrate floor
            rec.isPlayable = "Yes"
            rec.videoCodec = "dvvideo"
            model.records.append(rec)
            return rec
        }
        let tape = try add("Tape.mov")
        let export = try add("Tape_balanced.mov")
        let lone = try add("Lonely.vs.edit.mov")
        let out = model.archiveAngelSweepCandidates()
        func by(_ id: UUID) -> ArchiveAngelCandidate? { out.first { $0.id == id } }
        #expect(by(export.id)?.derivativeOfOriginal == "Tape.mov")
        #expect(by(tape.id)?.derivativeOfOriginal == nil)
        #expect(by(lone.id)?.derivativeOfOriginal == nil, "no original in the catalog → left alone")
        #expect(by(export.id).map { ArchiveAngelScorer.hardFloor($0) } == .derivativeOfOriginal)
        #expect(by(tape.id).map { ArchiveAngelScorer.hardFloor($0) } == .some(nil))
    }
}
