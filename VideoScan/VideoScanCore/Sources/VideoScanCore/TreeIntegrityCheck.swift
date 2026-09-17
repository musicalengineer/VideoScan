// TreeIntegrityCheck.swift
//
// "Did the family tree just get smaller, and did anyone notice?"
//
// THE INCIDENT, 2026-09-16. Rick's compiled tree is two FamilySearch pulls
// merged — his 16,383 people and Donna's 31,084, 39,250 together. A Refresh
// rebased onto the newest SINGLE .ged, so the artifact it promoted had
// 16,383 people and ONE source. Donna's entire line, Edward III and their
// shared descent from Martha Lamson included, was gone from the active tree.
//
// Every individual step reported success. The merge said "20 shared + 0
// added". The compile said "promoted (16383 people)". The verify PASSED —
// because the artifact was internally consistent; it was just a smaller
// tree than the one before it. Nothing in the chain compared the new
// generation to the old one and asked whether losing 22,867 people was
// intended.
//
// That comparison is all this type does, and it is deliberately pure: two
// manifests in, findings out. No I/O, no store, no policy. The callers
// decide what an alarm means — the ingest logs it at audit level, and a
// future UI can offer the rollback the store has always had and nothing
// has ever called.
//
// WHY NOT JUST REFUSE. A shrink can be legitimate: "Replace family tree"
// with a smaller pull is a thing a person may mean to do. Refusing it
// outright would trade a silent loss for a silent block. So this reports,
// loudly and specifically, and leaves the decision where it belongs.

import Foundation

public enum TreeIntegrityCheck {

    public struct Finding: Sendable, Equatable {
        public enum Severity: String, Sendable, Equatable, CaseIterable {
            /// Worth recording in the audit trail; nothing is wrong.
            case note
            /// A human should look at this before trusting the tree.
            case warning
            /// The tree lost something it is very unlikely anyone meant to
            /// lose. This is the 2026-09-16 shape.
            case alarm
        }
        public let severity: Severity
        /// One sentence, written to be read months later in a log by
        /// someone who was not here tonight.
        public let message: String

        public init(severity: Severity, message: String) {
            self.severity = severity
            self.message = message
        }
    }

    /// A drop of more than this share of people is an alarm rather than a
    /// warning. 10% is well outside the noise of a re-pull — Rick's
    /// incident lost 58%.
    public static let alarmingPeopleLossFraction = 0.10

    /// Compare a generation about to be promoted against the one it would
    /// replace. `current` nil — the first ever compile — yields a note and
    /// nothing else: there is no previous tree to have lost anything from.
    public static func compare(
        incoming: FamilyGraphCompiledStore.Manifest,
        against current: FamilyGraphCompiledStore.Manifest?
    ) -> [Finding] {
        guard let current else {
            return [Finding(severity: .note,
                            message: "First compiled tree: \(incoming.peopleCount.formatted()) people "
                                + "from \(sourceList(incoming)).")]
        }
        var findings: [Finding] = []

        // 1. SOURCES. The 2026-09-16 shape, and the one that matters most:
        // a tree built from two pulls must not quietly become one.
        let currentNames = Set(current.sources.map(\.fileName))
        let incomingNames = Set(incoming.sources.map(\.fileName))
        let dropped = currentNames.subtracting(incomingNames).sorted()
        if !dropped.isEmpty {
            findings.append(Finding(
                severity: .alarm,
                message: "The new tree DROPS \(dropped.count) source file(s) the current tree was built from: "
                    + "\(dropped.joined(separator: ", ")). "
                    + "Current: \(sourceList(current)). New: \(sourceList(incoming))."))
        }
        let added = incomingNames.subtracting(currentNames).sorted()
        if !added.isEmpty {
            findings.append(Finding(
                severity: .note,
                message: "The new tree adds \(added.count) source file(s): \(added.joined(separator: ", "))."))
        }

        // 2. PEOPLE. A count can fall for good reasons (a deliberate
        // replace, a duplicate merged upstream), so the size of the fall
        // is what separates a warning from an alarm.
        let lost = current.peopleCount - incoming.peopleCount
        if lost > 0 {
            let fraction = current.peopleCount > 0
                ? Double(lost) / Double(current.peopleCount) : 0
            let percent = String(format: "%.1f%%", fraction * 100)
            findings.append(Finding(
                severity: fraction > alarmingPeopleLossFraction ? .alarm : .warning,
                message: "The new tree has \(lost.formatted()) FEWER people than the current one "
                    + "(\(current.peopleCount.formatted()) → \(incoming.peopleCount.formatted()), \(percent) lost)."))
        }

        // 3. FAMILIES. Reported only when people did NOT fall — otherwise
        // it is the same event said twice.
        let familiesLost = current.familyCount - incoming.familyCount
        if familiesLost > 0, lost <= 0 {
            findings.append(Finding(
                severity: .warning,
                message: "The new tree has \(familiesLost.formatted()) fewer families "
                    + "(\(current.familyCount.formatted()) → \(incoming.familyCount.formatted())) "
                    + "while its people count did not fall."))
        }

        if findings.isEmpty {
            findings.append(Finding(
                severity: .note,
                message: "Tree grew or held steady: \(current.peopleCount.formatted()) → "
                    + "\(incoming.peopleCount.formatted()) people, \(sourceList(incoming))."))
        }
        return findings
    }

    /// True when anything here should stop a person in their tracks.
    public static func hasAlarm(_ findings: [Finding]) -> Bool {
        findings.contains { $0.severity == .alarm }
    }

    private static func sourceList(_ m: FamilyGraphCompiledStore.Manifest) -> String {
        let names = m.sources.map(\.fileName).sorted()
        return names.isEmpty ? "no named sources" : "\(names.count) source(s): \(names.joined(separator: ", "))"
    }
}
