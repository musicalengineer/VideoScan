// KinshipValidation.swift
// Save-time sanity checks for one candidate relationship row (design:
// docs/kinship_inference_design.md §1, 2026-08-29). Deterministic; every
// rule has a unit test in KinshipInferenceTests.
//
// Errors block the save and say why; warnings are shown once and the save
// proceeds. The caller builds the FamilyKinshipInference from the profiles
// AS THEY ARE NOW (the candidate row not yet added) and passes the rows
// already on the subject's profile.
//
// Only the four primitives may be entered (parent, child, spouse,
// sibling); a derived kind (grandparent, cousin, in-law…) is an error
// "derived, not entered" — the editor stops offering them in the next
// phase, this is the backstop.
//
// Pure: no I/O, no defaults, nothing to mock.

import Foundation
import VideoScanCore

enum KinshipValidation {

    enum Severity: String, Sendable { case error, warning }

    enum Rule: String, Sendable, CaseIterable {
        case derivedNotEntered
        case selfRelation
        case spouseOfSelf
        case duplicateRow
        case parentChildCycle
        case tooManyParents
        case parentNotOlder
        case spouseAgeGap
        case sexMismatch
        case siblingWithParentsRecorded
        case unresolvedAnchor
    }

    struct Finding: Equatable, Sendable {
        let severity: Severity
        let rule: Rule
        let message: String

        var isError: Bool { severity == .error }
    }

    /// Spouses born more than this many years apart get a warning.
    static let spouseAgeGapYears = 40

    /// Validate "`subject` is `candidate.relation` of `candidate.relativeTo`".
    /// - `enteredTerm`: the gendered word the editor showed/typed ("brother"),
    ///   if any, for the sex-consistency warning. The stored row is always
    ///   the ungendered relation.
    /// - `existingRows`: rows already on the subject's profile.
    static func validate(
        candidate: Kinship,
        enteredTerm: String? = nil,
        subjectProfileStableID: String,
        existingRows: [Kinship],
        inference: FamilyKinshipInference
    ) -> [Finding] {
        var findings: [Finding] = []
        let overlay = inference.overlay

        // Gate 1: primitives only.
        guard FamilyKinshipInference.primitives.contains(candidate.relation) else {
            findings.append(Finding(
                severity: .error, rule: .derivedNotEntered,
                message: "“\(candidate.relation.label)” is derived, not entered — record the parent, child, spouse or sibling links it comes from and it will be worked out."))
            return findings
        }

        guard let subject = overlay.node(profileStableID: subjectProfileStableID) else {
            findings.append(Finding(severity: .error, rule: .unresolvedAnchor,
                                    message: "This profile is not in the relationship graph yet — save it first."))
            return findings
        }
        let subjectName = inference.name(of: subject)
        guard let anchor = overlay.node(for: candidate.relativeTo) else {
            findings.append(Finding(severity: .error, rule: .unresolvedAnchor,
                                    message: "The person this row points at could not be found — pick them again."))
            return findings
        }
        let anchorName = inference.name(of: anchor)
        let word = candidate.relation.term(sex: inference.sex(of: subject))

        // Errors.
        if anchor == subject {
            let rule: Rule = candidate.relation == .spouse ? .spouseOfSelf : .selfRelation
            findings.append(Finding(severity: .error, rule: rule,
                                    message: "\(subjectName) can't be their own \(word)."))
            return findings   // nothing below is meaningful for a self row
        }
        let duplicateOnSubject = existingRows.contains {
            $0.relation == candidate.relation && $0.relativeTo.key == candidate.relativeTo.key
        }
        let duplicateInGraph = overlay.edges(from: anchor).contains {
            $0.relation == candidate.relation && $0.to == subject
        }
        if duplicateOnSubject || duplicateInGraph {
            findings.append(Finding(severity: .error, rule: .duplicateRow,
                                    message: "\(subjectName) is already recorded as \(anchorName)'s \(word)."))
        }
        switch candidate.relation {
        case .parent:
            // subject becomes anchor's parent: a cycle if anchor is already above subject.
            if inference.isAncestor(anchor, of: subject) {
                findings.append(Finding(severity: .error, rule: .parentChildCycle,
                                        message: "\(anchorName) is already an ancestor of \(subjectName) — a parent can't also be a descendant."))
            }
            let parents = inference.explicitParents(of: anchor)
            if parents.count >= 2, !parents.contains(subject) {
                findings.append(Finding(severity: .error, rule: .tooManyParents,
                                        message: "\(anchorName) already has two parents recorded (\(parents.map(inference.name(of:)).joined(separator: " and "))) — remove one before adding a third."))
            }
        case .child:
            if inference.isAncestor(subject, of: anchor) {
                findings.append(Finding(severity: .error, rule: .parentChildCycle,
                                        message: "\(subjectName) is already an ancestor of \(anchorName) — a child can't also be an ancestor."))
            }
            let parents = inference.explicitParents(of: subject)
            if parents.count >= 2, !parents.contains(anchor) {
                findings.append(Finding(severity: .error, rule: .tooManyParents,
                                        message: "\(subjectName) already has two parents recorded (\(parents.map(inference.name(of:)).joined(separator: " and "))) — remove one before adding a third."))
            }
        case .spouse, .sibling:
            break
        default:
            break
        }

        // Warnings.
        let subjectYear = inference.birthYear(of: subject)
        let anchorYear = inference.birthYear(of: anchor)
        switch candidate.relation {
        case .parent:
            if let subjectYear, let anchorYear, subjectYear >= anchorYear {
                findings.append(Finding(severity: .warning, rule: .parentNotOlder,
                                        message: "\(subjectName) (born \(subjectYear)) is not older than \(anchorName) (born \(anchorYear)) — check the birthdates."))
            }
        case .child:
            if let subjectYear, let anchorYear, anchorYear >= subjectYear {
                findings.append(Finding(severity: .warning, rule: .parentNotOlder,
                                        message: "\(anchorName) (born \(anchorYear)) is not older than \(subjectName) (born \(subjectYear)) — check the birthdates."))
            }
        case .spouse:
            if let subjectYear, let anchorYear, abs(subjectYear - anchorYear) > spouseAgeGapYears {
                findings.append(Finding(severity: .warning, rule: .spouseAgeGap,
                                        message: "\(subjectName) and \(anchorName) were born \(abs(subjectYear - anchorYear)) years apart — check the birthdates."))
            }
        case .sibling:
            let subjectParents = inference.explicitParents(of: subject)
            let anchorParents = inference.explicitParents(of: anchor)
            if subjectParents.count >= 2 || anchorParents.count >= 2 {
                let owner = subjectParents.count >= 2 ? subjectName : anchorName
                let other = subjectParents.count >= 2 ? anchorName : subjectName
                let names = (subjectParents.count >= 2 ? subjectParents : anchorParents).map(inference.name(of:))
                findings.append(Finding(severity: .warning, rule: .siblingWithParentsRecorded,
                                        message: "\(owner)'s parents are both recorded (\(names.joined(separator: " and "))) — record \(other) as their child instead and the sibling link is derived (convert to shared parents)."))
            }
        default:
            break
        }
        if let enteredTerm, let parsed = KinshipRelation.parse(term: enteredTerm),
           let impliedSex = parsed.sex, let actual = inference.sex(of: subject), impliedSex != actual {
            findings.append(Finding(severity: .warning, rule: .sexMismatch,
                                    message: "You entered “\(enteredTerm)” but \(subjectName)'s profile says \(actual.label.lowercased()) — saving as “\(candidate.relation.label)”."))
        }
        return findings
    }
}

extension Array where Element == KinshipValidation.Finding {
    /// Any error present ⇒ the save must not proceed.
    var blocksSave: Bool { contains { $0.isError } }
}
