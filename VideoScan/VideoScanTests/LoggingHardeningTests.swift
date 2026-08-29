// LoggingHardeningTests.swift
// Privacy and action/result sensors for kinship save and family-tree focus.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Logging hardening")
struct LoggingHardeningTests {
    private static func date(_ year: Int) -> Date {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(secondsFromGMT: 0)
        parts.year = year
        parts.month = 6
        parts.day = 15
        return parts.date ?? .distantPast
    }

    @Test("overlay warnings are pure and de-duplicated")
    func overlayWarningDeduplication() {
        let first = POIProfile(name: "Private Person", referencePath: "/fixture/one",
                               aliases: ["Dad"])
        let second = POIProfile(name: "Private Person", referencePath: "/fixture/two",
                                aliases: ["Dad"])
        let overlay = FamilyKinshipOverlay(profiles: [first, second], graph: nil)

        #expect(overlay.warnings.count == 1)
        #expect(overlay.warnings[0].contains("Private Person")) // UI prose remains useful.
    }

    @Test("blocking relationship batch cannot reach the save command")
    func blockingBatchDoesNotSave() {
        let anchor = POIProfile(name: "Anchor", referencePath: "/fixture/anchor")
        var subject = POIProfile(name: "Subject", referencePath: "/fixture/subject")
        let row = Kinship(relation: .spouse, relativeTo: .profile(id: anchor.uuid))
        subject.kinships = [row, row]

        let evaluation = PersonEditSheetKinshipSave.evaluate(
            profile: subject, otherProfiles: [anchor], graph: nil,
            currentRows: [], warningsAcknowledged: false)

        #expect(evaluation.decision == .blocked)
        #expect(evaluation.findings.contains { $0.rule == .duplicateRow && $0.severity == .error })
        var saveCount = 0
        if evaluation.decision == .save { saveCount += 1 }
        #expect(saveCount == 0)
    }

    @Test("a warning requires a second Save")
    func warningRequiresSecondSave() {
        let older = POIProfile(name: "Older", referencePath: "/fixture/older",
                               birthdate: Self.date(1900))
        var younger = POIProfile(name: "Younger", referencePath: "/fixture/younger",
                                 birthdate: Self.date(2000))
        younger.kinships = [Kinship(relation: .spouse, relativeTo: .profile(id: older.uuid))]

        let first = PersonEditSheetKinshipSave.evaluate(
            profile: younger, otherProfiles: [older], graph: nil,
            currentRows: [], warningsAcknowledged: false)
        let second = PersonEditSheetKinshipSave.evaluate(
            profile: younger, otherProfiles: [older], graph: nil,
            currentRows: [], warningsAcknowledged: true)

        #expect(first.findings.map(\.rule).contains(.spouseAgeGap))
        #expect(first.decision == .warningConfirmationRequired)
        #expect(second.decision == .save)
    }

    @Test("sibling basis and existing note survive the save path")
    func siblingBasisAndNoteSurvive() {
        let anchor = POIProfile(name: "Anchor", referencePath: "/fixture/anchor")
        let old = Kinship(relation: .sibling, relativeTo: .profile(id: anchor.uuid),
                          note: "private family lore")
        let edited = Kinship(relation: .sibling, relativeTo: .profile(id: anchor.uuid),
                             basis: .attestedFull)
        let merged = PersonEditSheetKinshipSave.preservingNotes(in: [edited], from: [old])

        #expect(merged[0].basis == .attestedFull)
        #expect(merged[0].note == "private family lore")

        var subject = POIProfile(name: "Subject", referencePath: "/fixture/subject")
        subject.kinships = merged
        let evaluation = PersonEditSheetKinshipSave.evaluate(
            profile: subject, otherProfiles: [anchor], graph: nil,
            currentRows: [], warningsAcknowledged: false)
        #expect(evaluation.decision == .save)
        #expect(evaluation.profile.kinships[0].basis == .attestedFull)
        #expect(evaluation.profile.kinships[0].note == "private family lore")
    }

    @Test("kinship audit includes rules but never finding prose")
    func kinshipAuditIsPrivacySafe() {
        let secret = "Private Person born 1875"
        let finding = KinshipValidation.Finding(
            severity: .warning, rule: .spouseAgeGap, message: secret)
        let profile = POIProfile(name: "Private Person", referencePath: "/fixture/private")
        let evaluation = PersonEditSheetKinshipSave.Evaluation(
            profile: profile, findings: [finding], decision: .warningConfirmationRequired)

        let line = PersonEditSheetKinshipSave.resultLine(
            evaluation, elapsed: .milliseconds(12))
        #expect(line == "[kinship-save] validation result=warningConfirmationRequired elapsed_ms=12 rows=0 rules=warning:spouseAgeGap")
        #expect(!line.contains(secret))
        #expect(!line.contains("Private Person"))
    }

    @Test("focus audit records result and timing without identity")
    @MainActor
    func focusAuditIsPrivacySafe() {
        let line = FamilyTreeLiveModel.focusDiagnosticLine(
            kind: .name, result: .rejectedNoMatch,
            elapsed: .milliseconds(7), people: 39_000)
        #expect(line == "[family-tree] focus kind=name result=rejected-no-match elapsed_ms=7 people=39000")
        #expect(!line.contains("Great Aunt Zelda"))
        #expect(!line.contains("@I999@"))
    }

    @Test("general Hallie diagnostics exclude question and error prose")
    func hallieDiagnosticsArePrivacySafe() {
        struct SensitiveError: LocalizedError {
            let errorDescription: String? = "What did Private Person do in 1875?"
        }
        let recompile = ArchivistDiagnosticLine.recompileStarted(willReask: true)
        let failure = ArchivistDiagnosticLine.failure(.interpretation, error: SensitiveError())

        #expect(recompile == "[family-tree] Hallie recompile started reask=true")
        #expect(!recompile.contains("Private Person"))
        #expect(failure == "[hallie] interpretation failed category=SensitiveError")
        #expect(!failure.contains("1875"))
        #expect(ArchivistDiagnosticLine.focusRequested.contains("focus requested"))
        #expect(!ArchivistDiagnosticLine.focusRequested.contains("centered"))
    }
}
