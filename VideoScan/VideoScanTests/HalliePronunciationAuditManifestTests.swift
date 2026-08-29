import Foundation
import Testing
@testable import VideoScan

/// Pins the checked-in human oracle to Hallie's actual final private TTS
/// input. These tests assert no phonetic spelling beyond corrections already
/// audited in the shipped lexicon; pass-through names remain pass-through.
struct HalliePronunciationAuditManifestTests {
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let cases: [Case]

        struct Case: Decodable {
            let id: String
            let displayedText: String
            let expectedTTSInput: String
            let expectedRecognition: String
            let maximumWordErrorRate: Double
            let auditedCorrections: [Correction]
        }

        struct Correction: Decodable {
            let written: String
            let spoken: String
            let source: String
        }

        var validationProblems: [String] {
            var problems: [String] = schemaVersion == 1
                ? [] : ["unsupported schema version \(schemaVersion)"]
            if cases.isEmpty { problems.append("manifest has no cases") }
            let ids = cases.map(\.id)
            if Set(ids).count != ids.count { problems.append("duplicate case id") }
            for item in cases {
                if item.id.isEmpty || item.displayedText.isEmpty ||
                    item.expectedTTSInput.isEmpty || item.expectedRecognition.isEmpty {
                    problems.append("incomplete case \(item.id)")
                }
                if !(0...1).contains(item.maximumWordErrorRate) {
                    problems.append("invalid threshold \(item.id)")
                }
                if item.auditedCorrections.contains(where: {
                    $0.written.isEmpty || $0.spoken.isEmpty || $0.source.isEmpty
                }) {
                    problems.append("incomplete correction \(item.id)")
                }
            }
            return problems
        }
    }

    private func manifestURL() -> URL {
        URL(fileURLWithPath: #filePath)               // …/VideoScan/VideoScanTests/this.swift
            .deletingLastPathComponent()              // …/VideoScan/VideoScanTests
            .deletingLastPathComponent()              // …/VideoScan
            .deletingLastPathComponent()              // repo root
            .appendingPathComponent("tests/fixtures/pronunciation_audit_cases.json")
    }

    private func loadManifest() throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL()))
    }

    @Test func humanAuditedManifestIsValidAndCoversDemoNames() throws {
        let manifest = try loadManifest()
        #expect(manifest.validationProblems.isEmpty)
        let displayCorpus = manifest.cases.map(\.displayedText).joined(separator: " ")
        for required in [
            "Lamson", "Persis Stowe", "Sewell", "Lovering",
            "O’Connor", "McGill", "Latta", "Thomasine",
        ] {
            #expect(displayCorpus.contains(required), Comment(rawValue: "missing audit name: \(required)"))
        }
        let asserted = Set(manifest.cases.flatMap(\.auditedCorrections).map(\.written))
        #expect(asserted == ["McGill", "Latta"], "do not add a phonetic mapping until a human audits it")
    }

    @Test func manifestPinsTheFinalTTSInputForEveryCase() throws {
        let manifest = try loadManifest()
        for item in manifest.cases {
            let finalInput = HallieSpeaker.sentences(item.displayedText).joined(separator: " ")
            #expect(finalInput == item.expectedTTSInput, Comment(rawValue: item.id))
        }
    }

    @Test func auditedCorrectionsExactlyMatchTheExistingShippedLexicon() throws {
        let manifest = try loadManifest()
        let shipped = Dictionary(uniqueKeysWithValues:
            HalliePronunciationLexicon.shipped.entries.map { ($0.written, $0.spoken) })
        for correction in manifest.cases.flatMap(\.auditedCorrections) {
            #expect(shipped[correction.written] == correction.spoken,
                    Comment(rawValue: correction.written))
        }
    }
}
