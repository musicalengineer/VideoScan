// KinshipExplicitOverInferredTests.swift
// Regression cover for the 2026-09-03 People-tab save blocker.
//
// Rick's log (2026-09-02 18:43:17):
//   [kinship-save] validation result=blocked elapsed_ms=15 rows=1
//                  rules=error:duplicateRow,warning:siblingWithParentsRecorded
//
// He had just saved 11 rows onto his own card (siblings + parents), then
// opened a sibling's card — which stores NO rows of its own — and typed the
// one obvious fact. `checkDuplicate` refused it, because the overlay carries
// the IMPLIED INVERSE of the row stored on the other card and the rule
// treated that inverse as "already recorded on this card".
//
// The rule now distinguishes the two:
//   • the same row already on THIS card            → .error   (still blocks)
//   • the fact known only from ANOTHER card / an
//     inference (the implied inverse, a derived
//     shared-parent edge)                          → .warning (never blocks)
//
// Five dimensions (CLAUDE.md):
//   1. Logic     — the live case, plus every primitive relation
//   2. Scale     — n/a (one row, one overlay; the scale gate lives in
//                  KinshipPerformanceGateTests)
//   3. Media     — n/a
//   4. Isolation — synthetic in-memory profiles only. No POIStorage, no
//                  ~/Library/Application Support, no UserDefaults, no
//                  GEDCOM file; `graph: nil` throughout.
//   5. Sensor    — `explicitRowIsNeverBlockedByKnowledgeHeldElsewhere`
//                  pins "a fact the app worked out, or holds on someone
//                  else's card, never blocks the user from stating it".

import Foundation
import Testing
@testable import VideoScan

struct KinshipExplicitOverInferredTests {

    // MARK: - Synthetic fixture (no real profile is ever read)

    private static func born(_ year: Int) -> Date {
        var dc = DateComponents()
        dc.year = year; dc.month = 6; dc.day = 15; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private static func person(
        _ name: String, sex: PersonSex? = nil, year: Int? = nil, rows: [Kinship] = []
    ) -> POIProfile {
        POIProfile(name: name, referencePath: "/fixture/\(name)",
                   birthdate: year.map(born), sex: sex, kinships: rows)
    }

    private static func row(
        _ relation: KinshipRelation, of name: String, basis: SiblingBasis = .unspecified
    ) -> Kinship {
        Kinship(relation: relation, relativeTo: .profile(name: name), basis: basis)
    }

    /// The shape of Rick's People tab at 18:43 on 2026-09-02, with synthetic
    /// names: ONE card carries every row; the relatives' cards are empty.
    ///   Ada  — sibling of Ben, sibling of Cleo, child of Mira, child of Otto
    ///   Ben, Cleo, Mira, Otto — no rows at all
    private static var oneCardCarriesEverything: [POIProfile] {
        [
            person("Ada", sex: .female, year: 1962, rows: [
                row(.sibling, of: "Ben"), row(.sibling, of: "Cleo"),
                row(.child, of: "Mira"), row(.child, of: "Otto"),
            ]),
            person("Ben", sex: .male, year: 1965),
            person("Cleo", sex: .female, year: 1967),
            person("Mira", sex: .female, year: 1935),
            person("Otto", sex: .male, year: 1931),
        ]
    }

    private func findings(
        subject: String, _ relation: KinshipRelation, of anchor: String,
        in profiles: [POIProfile], basis: SiblingBasis = .unspecified
    ) -> [KinshipValidation.Finding] {
        let existing = profiles.first { $0.name == subject }?.kinships ?? []
        return KinshipValidation.validate(
            candidate: Kinship(relation: relation, relativeTo: .profile(name: anchor), basis: basis),
            subjectProfileStableID: subject.lowercased(),
            existingRows: existing,
            inference: FamilyKinshipInference(profiles: profiles, graph: nil))
    }

    private func rules(_ f: [KinshipValidation.Finding]) -> [KinshipValidation.Rule] { f.map(\.rule) }

    private func severity(
        _ f: [KinshipValidation.Finding], of rule: KinshipValidation.Rule
    ) -> KinshipValidation.Severity? {
        f.first { $0.rule == rule }?.severity
    }

    // MARK: - 1. The exact case from the log

    /// Ben's card is empty; the sibling fact lives only on Ada's card as an
    /// implied inverse. Typing it on Ben's card must SAVE.
    @Test func theBlockedSaveFromTheLogNowSaves() {
        let f = findings(subject: "Ben", .sibling, of: "Ada", in: Self.oneCardCarriesEverything)

        // Both findings still surface — nothing is silenced.
        #expect(rules(f) == [.duplicateRow, .siblingWithParentsRecorded])
        // …but neither blocks any more.
        #expect(severity(f, of: .duplicateRow) == .warning)
        #expect(severity(f, of: .siblingWithParentsRecorded) == .warning)
        #expect(!f.blocksSave)

        // The wording confirms rather than rejects.
        let message = f.first { $0.rule == .duplicateRow }?.message ?? ""
        #expect(message.contains("Ada"))
        #expect(!message.contains("can't"))
    }

    /// End to end through the save gate the sheet uses, including the audit
    /// line: the log now reads `result=warningConfirmationRequired` on the
    /// first press and `result=save` once Rick confirms — never `blocked`.
    @Test func theSaveGateLetsTheRowThrough() {
        var profiles = Self.oneCardCarriesEverything
        let benIndex = profiles.firstIndex { $0.name == "Ben" }!
        var ben = profiles[benIndex]
        ben.kinships = [Self.row(.sibling, of: "Ada")]

        let first = PersonEditSheetKinshipSave.evaluate(
            profile: ben, otherProfiles: profiles, graph: nil,
            currentRows: [], warningsAcknowledged: false)
        #expect(first.decision == .warningConfirmationRequired)

        let confirmed = PersonEditSheetKinshipSave.evaluate(
            profile: ben, otherProfiles: profiles, graph: nil,
            currentRows: [], warningsAcknowledged: true)
        #expect(confirmed.decision == .save)

        // The privacy-safe audit line keeps carrying the rule names.
        let line = PersonEditSheetKinshipSave.resultLine(confirmed, elapsed: .milliseconds(15))
        #expect(line == "[kinship-save] validation result=save elapsed_ms=15 rows=1 "
                + "rules=warning:duplicateRow,warning:siblingWithParentsRecorded")
    }

    /// Every primitive, entered on the empty card, when the fact is held
    /// only as the inverse on the other card.
    @Test func everyPrimitiveMayBeRestatedOnTheOtherCard() {
        let profiles = Self.oneCardCarriesEverything
        // Ada's "child of Mira" ⇒ Mira's card may say "parent of Ada".
        #expect(!findings(subject: "Mira", .parent, of: "Ada", in: profiles).blocksSave)
        // Ada's "sibling of Cleo" ⇒ Cleo's card may say "sibling of Ada".
        #expect(!findings(subject: "Cleo", .sibling, of: "Ada", in: profiles).blocksSave)

        // …and a spouse pair, the other way round.
        let couple = [
            Self.person("Ida", sex: .female, year: 1959, rows: [Self.row(.spouse, of: "Jon")]),
            Self.person("Jon", sex: .male, year: 1958),
        ]
        let spouse = findings(subject: "Jon", .spouse, of: "Ida", in: couple)
        #expect(rules(spouse) == [.duplicateRow])
        #expect(!spouse.blocksSave)
    }

    // MARK: - 2. The regression risk: a real duplicate STILL blocks

    /// The same row already on THIS card is a genuine duplicate: still an
    /// error, still blocks. This is the case the fix must not weaken.
    @Test func aDuplicateStoredRowOnTheSameCardStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        // Ada's own card already carries "sibling of Ben".
        let f = findings(subject: "Ada", .sibling, of: "Ben", in: profiles)
        #expect(rules(f).contains(.duplicateRow))
        #expect(severity(f, of: .duplicateRow) == .error)
        #expect(f.blocksSave)

        // Same for a lineal row on its own card.
        let lineal = findings(subject: "Ada", .child, of: "Mira", in: profiles)
        #expect(severity(lineal, of: .duplicateRow) == .error)
        #expect(lineal.blocksSave)
    }

    /// Typing one row TWICE in a single edit still blocks — the batch path
    /// sees the first copy as an existing row on this card.
    @Test func theSameRowTypedTwiceInOneEditStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        let twice = [Self.row(.sibling, of: "Ada"), Self.row(.sibling, of: "Ada")]
        let batch = KinshipValidation.validate(
            batch: twice, subjectProfileStableID: "ben", profiles: profiles, graph: nil,
            currentRows: [])
        #expect(batch.blocksSave)
        #expect(batch.contains { $0.findings.contains { $0.rule == .duplicateRow && $0.isError } })
    }

    // MARK: - 3. Genuine contradictions still fail closed

    /// Two STORED facts that contradict each other are still an error.
    @Test func aConflictBetweenStoredFactsStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        // Ada's card says Ben is her sibling; Ben's card may not say he is
        // her parent.
        let f = findings(subject: "Ben", .parent, of: "Ada", in: profiles)
        #expect(rules(f).contains(.conflictingRelation))
        #expect(severity(f, of: .conflictingRelation) == .error)
        #expect(f.blocksSave)
    }

    @Test func aParentChildCycleStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        // Ada is Mira's child; Mira cannot be Ada's child.
        let f = findings(subject: "Mira", .child, of: "Ada", in: profiles)
        #expect(rules(f).contains(.parentChildCycle))
        #expect(f.blocksSave)
    }

    @Test func aThirdParentStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        // Ada already records Mira and Otto as parents.
        let f = findings(subject: "Ada", .child, of: "Cleo", in: profiles)
        #expect(rules(f).contains(.tooManyParents))
        #expect(f.blocksSave)
    }

    @Test func aSiblingOfAnAncestorStillBlocks() {
        let profiles = Self.oneCardCarriesEverything
        let f = findings(subject: "Ada", .sibling, of: "Mira", in: profiles)
        #expect(rules(f).contains(.siblingOfLineal))
        #expect(f.blocksSave)
    }

    @Test func aDerivedRelationIsStillNotEntered() {
        let f = findings(subject: "Ben", .grandparent, of: "Ada", in: Self.oneCardCarriesEverything)
        #expect(rules(f) == [.derivedNotEntered])
        #expect(f.blocksSave)
    }

    // MARK: - 4. The one new state this change makes reachable

    /// Restating the fact from the other card is now allowed, so the two
    /// cards can carry DIFFERENT sibling bases for one pair. That is not a
    /// new hazard: the overlay's documented policy already says a half row
    /// dominates an unspecified one for the same unordered pair, so Rick
    /// correcting "full" to "half" from the other person's card lands
    /// exactly where the policy says — one shared parent, no conflict, no
    /// fail-closed warning.
    @Test func aHalfRowOnTheOtherCardStillDominatesItsPair() {
        let profiles = Self.oneCardCarriesEverything   // Ada: full sibling of Ben
        let half = Kinship(relation: .sibling, relativeTo: .profile(name: "Ada"),
                           basis: .attestedHalf(sharedParent: .profile(name: "Mira")))

        let f = KinshipValidation.validate(
            candidate: half, subjectProfileStableID: "ben", existingRows: [],
            inference: FamilyKinshipInference(profiles: profiles, graph: nil))
        #expect(!f.blocksSave)
        #expect(severity(f, of: .duplicateRow) == .warning)

        // Stored, the pair resolves to the half reading — Ben shares only Mira.
        var stored = profiles
        stored[stored.firstIndex { $0.name == "Ben" }!].kinships = [half]
        let overlay = FamilyKinshipOverlay(profiles: stored, graph: nil)
        let ben = overlay.node(profileStableID: "ben")!
        let derivedParents = overlay.derivedEdges(from: ben)
            .filter { $0.relation == .parent }.map(\.to)
        #expect(derivedParents == [overlay.node(profileStableID: "mira")!])
        #expect(overlay.warnings.isEmpty)   // dominance, not a fail-closed conflict
    }

    // MARK: - 5. Sensor

    /// SENSOR — "explicit outranks worked-out".
    ///
    /// For every primitive relation, a row whose fact the app holds ONLY
    /// because it worked it out (the implied inverse of another card's row,
    /// or a parent derived across sibling rows by the 2026-09-02 "full
    /// siblings share parents" policy) must never block the user from
    /// stating it on the card they are editing. A future change to the
    /// inference — a new derived edge kind, a wider sibling policy — must
    /// not be able to take Rick's own cards away from him again.
    @Test func explicitRowIsNeverBlockedByKnowledgeHeldElsewhere() {
        // Sibling inference ACTIVE: Ada records both parents and three
        // siblings, so Ben and Cleo hold DERIVED parent edges to Mira/Otto
        // even though their own cards are empty.
        let profiles = Self.oneCardCarriesEverything
        let inference = FamilyKinshipInference(profiles: profiles, graph: nil)
        let overlay = inference.overlay
        let ben = overlay.node(profileStableID: "ben")!

        // Guard the premise: the derivation really is producing parent
        // edges for Ben. If this stops being true the sensor below is
        // vacuous, so fail loudly rather than pass quietly.
        #expect(overlay.derivedEdges(from: ben).contains { $0.relation == .parent })
        #expect(inference.explicitParents(of: ben).isEmpty)

        // Ben states, on his own card, the parents the app merely derived.
        for parent in ["Mira", "Otto"] {
            let f = findings(subject: "Ben", .child, of: parent, in: profiles)
            #expect(!f.blocksSave, Comment(rawValue: "Ben → child of \(parent): \(rules(f))"))
        }

        // And the inverse-only restatements, across every primitive.
        let inverseOnly: [(String, KinshipRelation, String)] = [
            ("Ben", .sibling, "Ada"),
            ("Cleo", .sibling, "Ada"),
            ("Mira", .parent, "Ada"),
            ("Otto", .parent, "Ada"),
        ]
        for (subject, relation, anchor) in inverseOnly {
            let f = findings(subject: subject, relation, of: anchor, in: profiles)
            #expect(!f.blocksSave,
                    Comment(rawValue: "\(subject) → \(relation.rawValue) of \(anchor): \(rules(f))"))
            #expect(severity(f, of: .duplicateRow) != .error)
        }
    }
}
