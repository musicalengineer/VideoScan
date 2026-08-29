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
        case attestationConflict
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
        findings += checkAttestation(ctx)
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

    /// An attested sibling basis must be consistent: a half row's shared
    /// parent must resolve, and the parents the row would inherit (merged
    /// with what the subject already has, including other attested rows)
    /// must not exceed two.
    private static func checkAttestation(_ c: Context) -> [Finding] {
        guard c.candidate.relation == .sibling else { return [] }
        let inherited: [Node]
        switch c.candidate.basis {
        case .unspecified:
            return []
        case .attestedFull:
            inherited = c.inference.explicitParents(of: c.anchor)
        case .attestedHalf(let shared):
            guard let parent = c.inference.overlay.node(for: shared), !c.inference.overlay.isPlaceholder(parent) else {
                return [Finding(severity: .error, rule: .unresolvedAnchor,
                                message: "The shared parent named on this half-sibling row could not be found — pick them again.")]
            }
            inherited = [parent]
        }
        var merged = c.inference.parents(of: c.subject).map(\.node)
        for parent in inherited where !merged.contains(parent) && parent != c.subject { merged.append(parent) }
        guard merged.count > 2 else { return [] }
        let names = merged.map(c.inference.name(of:)).joined(separator: ", ")
        return [Finding(severity: .error, rule: .attestationConflict,
                        message: "Attesting this sibling link would give \(c.subjectName) more than two parents (\(names)) — correct the other rows first.")]
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

// MARK: - Whole-batch validation (codex #835 b)

extension KinshipValidation {

    /// One row of a proposed edit with its findings.
    struct BatchFinding: Equatable, Sendable {
        let row: Kinship
        let findings: [Finding]
    }

    /// Validate the COMPLETE proposed row list for one profile, not a single
    /// candidate against the old graph: each row that is new or changed is
    /// checked against a graph in which the subject carries every OTHER
    /// proposed row (plus everyone else's current rows), so three parents
    /// entered together, a duplicate typed twice, or a cycle that only
    /// closes through two new rows are all caught before anything is saved.
    /// Unchanged rows are not re-validated (they were legal when saved).
    ///
    /// Cost: one overlay build per new row over the profile list —
    /// dozens of profiles × a handful of rows, milliseconds.
    /// `currentRows` = the rows as saved today (defaults to the profile's rows
    /// in `profiles`); the editor passes the original rows when the profile
    /// in `profiles` already carries the edited state.
    static func validate(
        batch proposed: [Kinship],
        subjectProfileStableID stableID: String,
        profiles: [POIProfile],
        graph: GedcomFamilyGraph?,
        currentRows: [Kinship]? = nil
    ) -> [BatchFinding] {
        guard let subjectIndex = profiles.firstIndex(where: { $0.id == stableID }) else {
            return proposed.map {
                BatchFinding(row: $0, findings: [Finding(severity: .error, rule: .unresolvedAnchor,
                                                         message: "This profile is not in the relationship graph yet — save it first.")])
            }
        }
        let current = currentRows ?? profiles[subjectIndex].kinships
        var out: [BatchFinding] = []
        var seenBefore: [Kinship] = []
        for row in proposed {
            defer { seenBefore.append(row) }
            // An unchanged row (present today, not duplicated in the batch) stands.
            if current.contains(row), !seenBefore.contains(row) { continue }
            var hypothetical = profiles
            var others = proposed
            if let i = others.firstIndex(of: row) { others.remove(at: i) }
            hypothetical[subjectIndex].kinships = others
            let inference = FamilyKinshipInference(profiles: hypothetical, graph: graph)
            let findings = validate(candidate: row, subjectProfileStableID: stableID,
                                    existingRows: others, inference: inference)
            out.append(BatchFinding(row: row, findings: findings))
        }
        return out
    }
}

extension Array where Element == KinshipValidation.BatchFinding {
    var blocksSave: Bool { contains { $0.findings.blocksSave } }
}
