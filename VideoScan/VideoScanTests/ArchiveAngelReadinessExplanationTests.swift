// ArchiveAngelReadinessExplanationTests.swift
// "Archive Readiness" (Rick 2026-09-24): the informational sheet explains in
// plain sentences why the Angel chose a file, what it still needs and what
// to do about each, whether it is worth archiving, and the facts (duration,
// date, people, copies, where it lives). The internal score appears ONLY in
// the small grey footer.

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — Archive Readiness explanation")
struct ArchiveAngelReadinessExplanationTests {

    /// A score no sentence could contain by accident.
    static let score = 4242

    private func facts(_ kind: ArchiveAngelRecommendationClass = .ready) -> ArchiveAngelRowFacts {
        var f = ArchiveAngelRowFacts(id: UUID(), filename: "Tape 12.mov", fullPath: "/Volumes/LaCie/Tapes/Tape 12.mov", kind: kind)
        f.durationSeconds = 3_725
        f.score = Self.score
        f.audio = .verifiedOK
        f.audioVerifyStatus = "ok"
        f.dateLabel = "July 1994"
        f.confirmedPeople = ["Donna", "Tim"]
        f.otherPeople = ["Ellen"]
        f.volumeName = "LaCie"
        f.evidenceLines = [
            "You rated it best (★★★)",
            "Donna, Tim (confirmed)",
            "Runs 1 h 2 min — likely a whole tape",
        ]
        f.reasons = ["marked Important", "Archive Angel grade A (\(Self.score))"]
        return f
    }

    // MARK: Evidence lines → sentences, one per kind the scorer prints

    static let evidenceTable: [(line: String, mustContain: String)] = [
        ("You rated it best (★★★)", "three stars"),
        ("You rated it better (★★)", "two stars"),
        ("You rated it good (★)", "one star"),
        ("Donna, Tim (confirmed)", "Donna, Tim"),
        ("Looks like Ellen, Beth (machine)", "not yet confirmed"),
        ("Played once", "played once"),
        ("Played 14 times, last on 2026-05-01", "14 times"),
        ("Has notes, 2 tags, captions", "notes, 2 tags, captions"),
        ("Dated 1994-07-12 (yours)", "You dated it 1994-07-12"),
        ("Dated 1994-07-12 (consensus 0.91)", "1994-07-12"),
        ("Date uncertain — 1994-07-12 (0.42)", "guess"),
        ("Dated by the camera", "camera"),
        ("Runs 1 h 2 min — likely a whole tape", "whole tape"),
        ("At-risk format — archive sooner", "sooner"),
        ("This is the only copy", "only copy"),
        ("Lives on MyBook (no role assigned)", "MyBook"),
        ("Audio: silent audio — will balance", "silent audio"),
        ("Looks like a download or rip — h264 at 900 kbit/s for 1 h 40 min, no star, person or note; capped at candidate grade", "download"),
        ("You skipped it twice, last on 2026-09-01 — score × 0.25", "passed on it"),
        ("New to you — never proposed", "not shown it to you"),
    ]

    @Test func everyEvidenceKindBecomesASentence() {
        for (line, needle) in Self.evidenceTable {
            let s = ArchiveAngelReadinessExplanation.sentence(forEvidenceLine: line)
            #expect(s != nil, "no sentence for \(line)")
            guard let s else { continue }
            #expect(s.contains(needle), "\(line) → \(s)")
            #expect(s.hasSuffix("."), "a sentence ends with a period: \(s)")
            #expect(s.first?.isUppercase == true, "a sentence starts with a capital: \(s)")
        }
    }

    @Test func fatigueAndConfidenceNumbersAreNotShown() {
        let fatigue = ArchiveAngelReadinessExplanation.sentence(forEvidenceLine: "You skipped it twice — score × 0.25") ?? ""
        #expect(!fatigue.contains("×") && !fatigue.contains("0.25"))
        let dated = ArchiveAngelReadinessExplanation.sentence(forEvidenceLine: "Dated 1994-07-12 (consensus 0.91)") ?? ""
        #expect(!dated.contains("0.91"))
    }

    @Test func unknownPolicyLinesPassThroughAsSentences() {
        #expect(ArchiveAngelReadinessExplanation.sentence(forEvidenceLine: "from the Cape trip folder") == "From the Cape trip folder.")
    }

    // MARK: Classifier reasons

    @Test func classifierReasonsBecomeSentencesWithoutTheScore() {
        let a = ArchiveAngelReadinessExplanation.sentence(forReason: "Archive Angel grade A (\(Self.score))") ?? ""
        #expect(!a.isEmpty)
        #expect(!a.contains("\(Self.score)"))
        #expect(!a.contains("grade A"))
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: "marked Important")?.contains("Important") == true)
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: "stage: Ready")?.contains("Ready") == true)
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: "the copy to keep")?.contains("keep") == true)
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: "3 copies — this one")?.contains("3 copies") == true)
        #expect(ArchiveAngelReadinessExplanation.sentence(forReason: "★★") == nil, "stars are said once, from the evidence")
    }

    // MARK: The whole sheet

    @Test func theScoreAppearsOnlyInTheFooter() {
        let e = ArchiveAngelReadinessExplanation.make(facts(), rulesVersion: 11)
        #expect(e.footer == "internal score \(Self.score) (rules v11)")
        let body = [e.statusWords, e.worthIt] + e.whyChosen + e.missing.flatMap { [$0.what, $0.todo] }
            + e.facts.flatMap { [$0.label, $0.value] }
        #expect(!body.isEmpty)
        for s in body { #expect(!s.contains("\(Self.score)"), "score leaked: \(s)") }
    }

    @Test func readyFileExplainsWhyAndNeedsNothing() {
        let e = ArchiveAngelReadinessExplanation.make(facts())
        #expect(e.isReady)
        #expect(e.statusWords == "Ready to archive")
        #expect(e.missing.isEmpty)
        #expect(e.worthIt.hasPrefix("Yes"))
        #expect(e.whyChosen.contains { $0.contains("three stars") })
        #expect(e.whyChosen.contains { $0.contains("Important") })
        // No sentence twice (stars come from evidence and the classifier).
        #expect(Set(e.whyChosen).count == e.whyChosen.count)
    }

    @Test func eachNeedNamesWhatToDo() {
        var f = facts(.worthALook)
        f.audio = .notVerified
        f.audioVerifyStatus = ""
        f.date = .undated
        f.dateLabel = nil
        f.videoVerifyStatus = "broken"
        f.videoVerifyNote = "Broken video — half the frames"
        let e = ArchiveAngelReadinessExplanation.make(f)
        #expect(!e.isReady)
        #expect(e.missing.count == 4, "\(e.missing)")
        for step in e.missing {
            #expect(!step.what.isEmpty && !step.todo.isEmpty)
        }
        #expect(e.missing.contains { $0.what.contains("date") })
        #expect(e.missing.contains { $0.what.lowercased().contains("sound") })
        #expect(e.missing.contains { $0.what.lowercased().contains("picture") && $0.what.contains("half the frames") },
                "the Verify Video note, without its 'Broken video — ' prefix")
        #expect(e.missing.contains { $0.what.contains("look") })
        #expect(e.worthIt.hasPrefix("Maybe"))
    }

    @Test func audioRepairSaysTheVerifyNote() {
        var f = facts()
        f.audioVerifyStatus = "damaged"
        f.audioVerifyNote = "Damaged audio — invalid codec (qdm2)"
        f.audio = .verifiedProblem(f.audioVerifyNote)
        let e = ArchiveAngelReadinessExplanation.make(f)
        #expect(e.missing.count == 1)
        #expect(e.missing.first?.what.contains("invalid codec (qdm2)") == true)
    }

    @Test func factsListDurationDatePeopleCopiesAndWhere() {
        var f = facts()
        f.copies = 3
        f.duplicateCount = 3
        let e = ArchiveAngelReadinessExplanation.make(f)
        let byLabel = Dictionary(uniqueKeysWithValues: e.facts.map { ($0.label, $0.value) })
        #expect(byLabel["Length"] == "1 h 2 min")
        #expect(byLabel["Date"]?.contains("July 1994") == true)
        #expect(byLabel["Date"]?.contains("1990s") == true, "the era, for anyone who thinks in decades")
        #expect(byLabel["People"]?.contains("Donna") == true)
        #expect(byLabel["People"]?.contains("Ellen (not confirmed)") == true)
        #expect(byLabel["Copies"]?.contains("3") == true)
        #expect(byLabel["Where"]?.contains("LaCie") == true)
        #expect(byLabel["Where"]?.contains("/Volumes/LaCie/Tapes/Tape 12.mov") == true)
    }

    @Test func undatedAndUnpeopledSayTheyAreUnknown() {
        var f = facts(.needsDate)
        f.dateLabel = nil
        f.date = .undated
        f.confirmedPeople = []
        f.otherPeople = []
        let e = ArchiveAngelReadinessExplanation.make(f)
        let byLabel = Dictionary(uniqueKeysWithValues: e.facts.map { ($0.label, $0.value) })
        #expect(byLabel["Date"] == "Not known yet")
        #expect(byLabel["People"] == "Nobody tagged yet")
        #expect(e.worthIt.hasPrefix("Yes, once"))
    }
}
