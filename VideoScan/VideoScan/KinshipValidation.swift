// KinshipValidation.swift
// Save-time sanity checks for one candidate relationship row (design:
// docs/kinship_inference_design.md §1 + amendment 8 after codex review,
// 2026-08-29). Deterministic; every rule is one helper with a unit test.
//
// Errors block the save and say why; warnings are shown once and the save
// proceeds. The caller builds the FamilyKinshipInference from the profiles
// AS THEY ARE NOW (the candidate row not yet added) and passes the rows
// already on the subject's profile.
//
// Only the four primitives may be entered (parent, child, spouse,
// sibling); a derived kind (grandparent, cousin, in-law…) is an error
// "derived, not entered" — the editor stops offering them in the next
// phase, this is the backstop. Relations are neutral (no gendered word is
// stored), so there is no sex-consistency rule.
//
// Cycle checks canonicalize the row to (parent, child) and ask the engine
// whether the would-be child is already above the would-be parent — rows
// hop by hop, tree ancestry via one memoised ancestor index per pinned
// vertex (never a whole-tree walk in the save path).
//
// Pure: no I/O, no defaults, nothing to mock.

import Foundation
import VideoScanCore

enum KinshipValidation {

    enum Severity: String, Sendable { case error, warning }

    enum Rule: String, Sendable, CaseIterable {
        case derivedNotEntered
        case unresolvedAnchor
        case treePinProblem
        case selfRelation
        case spouseOfSelf
        case duplicateRow
        case conflictingRelation
        case parentChildCycle
        case tooManyParents
        case siblingOfLineal
        case parentNotOlder
        case spouseAgeGap
        case siblingWithParentsRecorded
    }

    struct Finding: Equatable, Sendable {
        let severity: Severity
        let rule: Rule
        let message: String

        var isError: Bool { severity == .error }
    }

    /// Spouses provably born more than this many years apart get a warning.
    static let spouseAgeGapYears = 40

    typealias Node = FamilyKinshipInference.Node

    /// Everything one rule needs.
    private struct Context {
        let candidate: Kinship
        let subject: Node
        let anchor: Node
        let existingRows: [Kinship]
        let inference: FamilyKinshipInference
        var subjectName: String { inference.name(of: subject) }
        var anchorName: String { inference.name(of: anchor) }
        var word: String { candidate.relation.term(sex: inference.sex(of: subject)) }
        /// The row canonicalized to (parent, child) for lineal rules.
        var lineal: (parent: Node, child: Node)? {
            switch candidate.relation {
            case .parent: return (subject, anchor)
            case .child:  return (anchor, subject)
            default:      return nil
            }
        }
    }

    /// Validate "`subject` is `candidate.relation` of `candidate.relativeTo`".
    /// `existingRows` = rows already on the subject's profile.
    static func validate(
        candidate: Kinship,
        subjectProfileStableID: String,
        existingRows: [Kinship],
        inference: FamilyKinshipInference
    ) -> [Finding] {
        guard FamilyKinshipInference.primitives.contains(candidate.relation) else {
            return [Finding(severity: .error, rule: .derivedNotEntered,
                            message: "“\(candidate.relation.label)” is derived, not entered — record the parent, child, spouse or sibling links it comes from and it will be worked out.")]
        }
        let overlay = inference.overlay
        guard let subject = overlay.node(profileStableID: subjectProfileStableID) else {
            return [Finding(severity: .error, rule: .unresolvedAnchor,
                            message: "This profile is not in the relationship graph yet — save it first.")]
        }
        if let problem = overlay.pinProblem(forProfileStableID: subjectProfileStableID) {
            return [Finding(severity: .error, rule: .treePinProblem, message: problem)]
        }
        guard let anchor = overlay.node(for: candidate.relativeTo), !overlay.isPlaceholder(anchor) else {
            return [Finding(severity: .error, rule: .unresolvedAnchor,
                            message: "The person this row points at could not be found (removed profile, or not in the installed family tree) — pick them again.")]
        }
        if let anchorProfile = overlay.member(anchor)?.profileStableID,
           let problem = overlay.pinProblem(forProfileStableID: anchorProfile) {
            return [Finding(severity: .error, rule: .treePinProblem, message: problem)]
        }
        let ctx = Context(candidate: candidate, subject: subject, anchor: anchor,
                          existingRows: existingRows, inference: inference)
        if let selfFinding = checkSelf(ctx) { return [selfFinding] }
        var findings: [Finding] = []
        findings += checkDuplicate(ctx)
        findings += checkConflict(ctx)
        findings += checkCycle(ctx)
        findings += checkParentCount(ctx)
        findings += checkSiblingOfLineal(ctx)
        findings += checkParentOlder(ctx)
        findings += checkSpouseGap(ctx)
        findings += checkSiblingWithParents(ctx)
        return findings
    }

    // MARK: Errors

    private static func checkSelf(_ c: Context) -> Finding? {
        guard c.anchor == c.subject else { return nil }
        let rule: Rule = c.candidate.relation == .spouse ? .spouseOfSelf : .selfRelation
        return Finding(severity: .error, rule: rule, message: "\(c.subjectName) can't be their own \(c.word).")
    }

    /// Same fact already stored — on this profile, or as the inverse row
    /// on the other profile (the overlay carries both directions).
    private static func checkDuplicate(_ c: Context) -> [Finding] {
        let onSubject = c.existingRows.contains {
            $0.relation == c.candidate.relation && $0.relativeTo.key == c.candidate.relativeTo.key
        }
        let inGraph = c.inference.overlay.edges(from: c.anchor).contains {
            $0.relation == c.candidate.relation && $0.to == c.subject
        }
        guard onSubject || inGraph else { return [] }
        return [Finding(severity: .error, rule: .duplicateRow,
                        message: "\(c.subjectName) is already recorded as \(c.anchorName)'s \(c.word).")]
    }

    /// A different primitive already links the same two people
    /// (parent + sibling, parent + spouse, spouse + child …).
    private static func checkConflict(_ c: Context) -> [Finding] {
        let others = c.inference.overlay.edges(from: c.anchor)
            .filter { $0.to == c.subject && $0.relation != c.candidate.relation
                && FamilyKinshipInference.primitives.contains($0.relation) }
        guard let other = others.first else { return [] }
        let existingWord = other.relation.term(sex: c.inference.sex(of: c.subject))
        return [Finding(severity: .error, rule: .conflictingRelation,
                        message: "\(c.subjectName) is already recorded as \(c.anchorName)'s \(existingWord) — they can't also be their \(c.word).")]
    }

    private static func checkCycle(_ c: Context) -> [Finding] {
        guard let (parent, child) = c.lineal, c.inference.isAncestor(child, of: parent) else { return [] }
        return [Finding(severity: .error, rule: .parentChildCycle,
                        message: "\(c.inference.name(of: child)) is already an ancestor of \(c.inference.name(of: parent)) — a parent can't also be a descendant.")]
    }

    /// > 2 parents after node dedup (a row to "Dad" and the tree's father
    /// are one vertex when Dad is pinned).
    private static func checkParentCount(_ c: Context) -> [Finding] {
        guard let (parent, child) = c.lineal else { return [] }
        let parents = c.inference.explicitParents(of: child)
        guard parents.count >= 2, !parents.contains(parent) else { return [] }
        let names = parents.map(c.inference.name(of:)).joined(separator: " and ")
        return [Finding(severity: .error, rule: .tooManyParents,
                        message: "\(c.inference.name(of: child)) already has two parents recorded (\(names)) — remove one before adding a third.")]
    }

    private static func checkSiblingOfLineal(_ c: Context) -> [Finding] {
        guard c.candidate.relation == .sibling else { return [] }
        let up = c.inference.isAncestor(c.anchor, of: c.subject)
        let down = c.inference.isAncestor(c.subject, of: c.anchor)
        guard up || down else { return [] }
        return [Finding(severity: .error, rule: .siblingOfLineal,
                        message: "\(up ? c.anchorName : c.subjectName) is an ancestor of \(up ? c.subjectName : c.anchorName) — they can't be siblings.")]
    }

    // MARK: Warnings

    /// Only when the child is PROVABLY not younger at the known precision.
    private static func checkParentOlder(_ c: Context) -> [Finding] {
        guard let (parent, child) = c.lineal,
              let parentBirth = c.inference.birth(of: parent), let childBirth = c.inference.birth(of: child),
              !parentBirth.isStrictlyBefore(childBirth),
              childBirth.isStrictlyBefore(parentBirth) || childBirth.years == parentBirth.years
        else { return [] }
        return [Finding(severity: .warning, rule: .parentNotOlder,
                        message: "\(c.inference.name(of: parent)) (born \(parentBirth.spokenYear)) is not older than \(c.inference.name(of: child)) (born \(childBirth.spokenYear)) — check the birthdates.")]
    }

    private static func checkSpouseGap(_ c: Context) -> [Finding] {
        guard c.candidate.relation == .spouse,
              let a = c.inference.birth(of: c.subject), let b = c.inference.birth(of: c.anchor) else { return [] }
        let gap = BirthKnowledge.provableGapYears(a, b)
        guard gap > spouseAgeGapYears else { return [] }
        return [Finding(severity: .warning, rule: .spouseAgeGap,
                        message: "\(c.subjectName) and \(c.anchorName) were born at least \(gap) years apart — check the birthdates.")]
    }

    private static func checkSiblingWithParents(_ c: Context) -> [Finding] {
        guard c.candidate.relation == .sibling else { return [] }
        let subjectParents = c.inference.explicitParents(of: c.subject)
        let anchorParents = c.inference.explicitParents(of: c.anchor)
        guard subjectParents.count >= 2 || anchorParents.count >= 2 else { return [] }
        let subjectHas = subjectParents.count >= 2
        let owner = subjectHas ? c.subjectName : c.anchorName
        let other = subjectHas ? c.anchorName : c.subjectName
        let names = (subjectHas ? subjectParents : anchorParents).map(c.inference.name(of:)).joined(separator: " and ")
        return [Finding(severity: .warning, rule: .siblingWithParentsRecorded,
                        message: "\(owner)'s parents are both recorded (\(names)) — record \(other) as their child instead and the sibling link is derived (convert to shared parents).")]
    }
}

extension Array where Element == KinshipValidation.Finding {
    /// Any error present ⇒ the save must not proceed.
    var blocksSave: Bool { contains { $0.isError } }
}
