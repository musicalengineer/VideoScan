// ArchiveAngelFamilyFactsTests.swift
// The provenance side of the S4 family-facts fix (ArchiveAngelFamilyFacts):
// the plan row names the copy each inherited fact came from, Review says
// so, a date typed in Review wins over the inherited one, the stamp rule is
// the one PlaceInheritanceSensorTests pins (ArchiveAngelFamilyStamp — the
// retired Helper's AssessCopiesFamilyStamp, renamed), and an already-
// archived balanced copy is reused for the access copy but never promoted
// again. Pure / catalog-only (no media).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — family facts: provenance, precedence, Review wins")
@MainActor
struct ArchiveAngelFamilyFactsTests {

    private func rec(_ name: String, hash: String = "v1:x") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/T/\(name)"
        r.contentHash = hash
        return r
    }

    @Test("inherited(for:) names the source copy; own values inherit nothing; a known date beats a more precise guess")
    func inheritedNamesTheSource() {
        let target = rec("tape.mov")
        let guess = rec("guess.mov"); guess.userDate = "1987-06-14"; guess.userDateConfidence = "estimated"
        let known = rec("known.mov"); known.userDate = "1987"; known.userDateConfidence = "known"
        let placed = rec("placed.mov"); placed.userPlace = "Cape Cod"
        let family = [guess, known, placed, target]
        let got = ArchiveAngelFamilyFacts.inherited(for: target, family: family)
        #expect(got.date == .init(value: "1987", confidence: "known", fromRecordID: known.id, fromFilename: "known.mov"))
        #expect(got.place?.value == "Cape Cod" && got.place?.confidence == "estimated" && got.place?.fromFilename == "placed.mov")
        #expect(got.attestationKinds == nil)

        target.userDate = "1990"; target.userPlace = "Montana"
        let own = ArchiveAngelFamilyFacts.inherited(for: target, family: family)
        #expect(own.date == nil && own.place == nil, "a record's own values are never replaced")
    }

    @Test("the Review line says what is inherited and from which copy")
    func reviewLine() {
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/v/a.mov", filename: "a.mov", sizeBytes: 1,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "a.mov", proposedDate: nil)
        #expect(ArchiveAngelFamilyFacts.reviewLine(e).isEmpty)
        e.inheritedDate = .init(value: "1987-06", confidence: "known", fromRecordID: UUID(), fromFilename: "copy.dv")
        e.inheritedAttestationKinds = ["offsite"]
        #expect(ArchiveAngelFamilyFacts.reviewLine(e) == "Inherits date 1987-06 from copy.dv · backup answers (offsite) from its copies")
    }

    @Test("a date typed in Review wins: the inherited date is NOT stamped, and the log says why")
    func reviewDateWins() {
        let original = rec("tape.mov")
        let sibling = rec("copy.mov"); sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        var e = ArchiveAngelPlan.Entry(id: original.id, sourcePath: original.fullPath, filename: "tape.mov", sizeBytes: 1,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "tape.mov",
                                       proposedDate: "1988")
        let lines = ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [], family: [original, sibling])
        #expect(original.userDate == nil)
        #expect(lines.contains { $0.contains("not stamped: Review set 1988") }, "\(lines)")
        e.proposedDate = "1987-06"
        let again = ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [], family: [original, sibling])
        #expect(original.userDate == "1987-06" && original.userDateConfidence == "known")
        #expect(again == ["Archive Angel: tape.mov — date 1987-06 (known) inherited from copy.mov"])
        #expect(ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [], family: [original, sibling]).isEmpty,
                "idempotent: a second promote click writes nothing and logs nothing")
    }

    @Test("companions promoted with the original get the family facts too; each record's own value still wins")
    func companionsToo() {
        let original = rec("tape.mov")
        let access = rec("tape.vs.archive.mov", hash: ""); access.userPlace = "Own place"
        let sibling = rec("copy.mov"); sibling.userPlace = "Cape Cod"; sibling.userPlaceConfidence = "known"
        let e = ArchiveAngelPlan.Entry(id: original.id, sourcePath: original.fullPath, filename: "tape.mov", sizeBytes: 1,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "tape.mov", proposedDate: nil)
        _ = ArchiveAngelFamilyFacts.stamp(entry: e, original: original, companions: [access], family: [original, sibling, access])
        #expect(original.userPlace == "Cape Cod")
        #expect(access.userPlace == "Own place")
    }

    @Test("the stamp's date rule matches the retired Helper's: known › estimated, precise › coarse, then lexicographic")
    func dateRuleIsTheHelpers() {
        func d(_ n: String, _ v: String, _ c: String?) -> VideoRecord { let r = rec(n); r.userDate = v; r.userDateConfidence = c; return r }
        #expect(ArchiveAngelFamilyStamp.bestUserDate(among: [d("a", "1987", "estimated"), d("b", "1987-06", "estimated")])?.date == "1987-06")
        #expect(ArchiveAngelFamilyStamp.bestUserDate(among: [d("a", "1987-06-14", "estimated"), d("b", "1990", "known")])?.date == "1990")
        #expect(ArchiveAngelFamilyStamp.bestUserDate(among: [d("a", "1991", nil), d("b", "1990", nil)])?.date == "1990")
        #expect(ArchiveAngelFamilyStamp.bestUserDate(among: [d("a", "1991", nil)])?.confidence == "estimated", "no confidence = estimated")
    }

    @Test("SENSOR: plan build and promote both call the stamp (the production path, not just the pure rule)")
    func productionPathCallsTheStamp() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveAngel")
        let job = try String(contentsOf: dir.appendingPathComponent("Prepare/ArchiveAngelJob.swift"), encoding: .utf8)
        let promoter = try String(contentsOf: dir.appendingPathComponent("Promote/ArchiveAngelPromoter.swift"), encoding: .utf8)
        let facts = try String(contentsOf: dir.appendingPathComponent("Promote/ArchiveAngelFamilyFacts.swift"), encoding: .utf8)
        #expect(job.contains("ArchiveAngelFamilyFacts.inherited(for:"))
        #expect(promoter.contains("ArchiveAngelFamilyFacts.stamp(entry:"))
        for rule in ["stampDateIfMissing", "stampPlaceIfMissing", "stampAttestationsIfMissing", "announce("] {
            #expect(facts.contains("ArchiveAngelFamilyStamp.\(rule)"), "the promote stamp goes through \(rule)")
        }
    }

    @Test("an existing companion outside the buffer is promotable only while its file is there")
    func existingCompanionPromotable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("test_existing_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tape_balanced.mov")
        try Data([1]).write(to: file)
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/v/tape.mov", filename: "tape.mov", sizeBytes: 1,
                                       durationSeconds: 60, score: 1, evidence: [], proposedName: "tape.mov", proposedDate: nil)
        let i = try #require(e.steps.firstIndex { $0.kind == .balanceAudio })
        e.steps[i].state = .done; e.steps[i].recordID = UUID(); e.steps[i].existingPath = file.path
        let plan = ArchiveAngelPlan(batchDir: dir.appendingPathComponent("batch").path, requestedCount: 1, makeLossless: false, entries: [e])
        #expect(ArchiveAngelPromoter.promotableCompanions(of: e, in: plan).map(\.kind) == [.balanceAudio])
        #expect(e.companionsMade.map(\.kind) == [.balanceAudio])
        try FileManager.default.removeItem(at: file)
        #expect(ArchiveAngelPromoter.promotableCompanions(of: e, in: plan).isEmpty)
    }
}
