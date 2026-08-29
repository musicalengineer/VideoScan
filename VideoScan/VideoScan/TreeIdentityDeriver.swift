// TreeIdentityDeriver.swift
// "The app knows my identity — can't it auto-derive that from the family
// tree?" (Rick, 2026-08-29). Ranks the evidence that a People-tab profile
// IS one family-tree record and answers with one of three verdicts:
//
//   .certain(person, reason)   — one record, and the reason is strong enough
//                                to act on (some reasons auto-pin, the rest
//                                pin on "Show in Family Tree" with an Undo);
//   .ambiguous([candidates])   — the tree offers several; ask which one;
//   .none                      — nothing on the tree could be them (the
//                                contemporaries FamilySearch never carries).
//
// Evidence, in rank order (the first rule that speaks wins):
//   1. owner profile   — the ONE profile spelled like Hallie's owner setting
//                        → the owner's FamilySearch ID pin, when the tree has it
//   2. tree root       — exactly one root (Rick, Donna in a merged tree)
//                        spelled like the profile's name / an alias
//   3. name match      — the existing FamilyTreeIdentityResolver (canonical
//                        name + aliases, most specific spelling first), then
//                        tie-broken by birth year, sex, the profile's typed
//                        kinship rows against already-PINNED profiles ("child
//                        of Dad" ⇒ must be a child of Dad's tree record), and
//                        root / spouse-of-root
//   4. suggestions     — FamilyKinshipOverlay.suggestedTreeMatches, review only
//
// Every candidate must be COMPATIBLE: sex agrees when both sides know it,
// the profile's birth year lies inside the record's birth interval, and the
// record did not die before the profile was born. A record another profile
// is already pinned to is never offered (one profile per tree person).
//
// Pure and injected: graph + subjects + the two owner strings. No defaults,
// no disk, nothing @MainActor. Cost per profile: a handful of indexed name
// lookups on the tree (≤ ms on 39k people); the whole People tab is one pass.
//
// C++ readers: `enum … { case certain(…) }` is a tagged union (std::variant)
// — every `switch` over it must handle all arms; `struct` is a value type.

import Foundation
import VideoScanCore

/// One tree record offered as a profile's identity. Carries what the UI
/// shows ("Richard Harding Breen Jr (b. 1929, Albany) · GVQV-NW3") so no
/// view has to reach back into the graph.
struct TreeIdentityCandidate: Hashable, Sendable, Identifiable {
    let personID: String
    let name: String
    let familySearchID: String?
    let birthDate: String?
    let birthPlace: String?
    let sex: String

    var id: String { personID }

    init(_ person: GedcomFamilyGraph.Person) {
        personID = person.id
        name = person.name.isEmpty ? "(unnamed)" : person.name
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        familySearchID = (fsid?.isEmpty ?? true) ? nil : fsid
        birthDate = person.birthDate
        birthPlace = person.birthPlace
        sex = person.sex
    }

    var birthYear: Int? { GedcomFamilyGraph.year(in: birthDate) }

    /// "GVQV-NW3", or the file-local pointer for exports without FSIDs.
    var code: String { familySearchID ?? personID }

    /// "Richard Harding Breen Jr (b. 1929)".
    var label: String {
        birthYear.map { "\(name) (b. \($0))" } ?? name
    }

    /// "b. 1929, Albany, New York" — the which-one sheet's second line.
    var detail: String {
        var parts: [String] = []
        if let birthDate, !birthDate.isEmpty { parts.append("b. \(birthDate)") }
        if let birthPlace, !birthPlace.isEmpty { parts.append(birthPlace) }
        return parts.joined(separator: ", ")
    }

    /// The durable pin for this record: the FamilySearch ID when it has one,
    /// else the export-local pointer bound to the tree's fingerprint.
    func identity(fingerprint: String?) -> TreeIdentity {
        if let familySearchID { return .familySearchID(familySearchID) }
        return .pointer(pointer: personID, sourceFingerprint: fingerprint ?? "")
    }
}

enum TreeIdentityDerivation: Equatable, Sendable {
    enum Reason: String, Sendable, CaseIterable {
        case ownerSetting = "owner setting"
        case treeRoot = "tree root"
        case nameAndBirth = "name + birth year"
        case uniqueFullName = "unique full name"
        case nameAndKinship = "name + relationship"
        case nameAndRoot = "name + tree root"

        /// Only the two identity SOURCES the app already trusts elsewhere
        /// (Hallie's owner pin; a merged tree's recorded home people) are
        /// pinned without asking. Name evidence waits for "Show in Family
        /// Tree", where the pin is announced with an Undo.
        var isAutoAcceptable: Bool {
            switch self {
            case .ownerSetting, .treeRoot: return true
            default: return false
            }
        }

        /// The attestation written on the profile.
        var attestation: String { "derived: \(rawValue)" }
    }

    case certain(TreeIdentityCandidate, reason: Reason)
    case ambiguous([TreeIdentityCandidate])
    case none

    var certainCandidate: TreeIdentityCandidate? {
        if case .certain(let c, _) = self { return c }
        return nil
    }

    var isAutoAcceptable: Bool {
        if case .certain(_, let reason) = self { return reason.isAutoAcceptable }
        return false
    }
}

/// The slice of a profile the deriver reads — built from a POIProfile (People
/// tab) or a Hallie ProfileSnapshot (chat turn), so both paths derive the
/// same answer from the same evidence.
struct TreeIdentitySubject: Equatable, Sendable {
    let stableID: String
    let name: String
    let aliases: [String]
    let sex: PersonSex?
    let birthdate: Date?
    let deathdate: Date?
    let kinships: [Kinship]
    let uuid: UUID?
    let treeIdentity: TreeIdentity?
    let treeIdentityUnreadable: Bool
    let notInFamilyTree: Bool

    init(stableID: String, name: String, aliases: [String] = [], sex: PersonSex? = nil,
         birthdate: Date? = nil, deathdate: Date? = nil, kinships: [Kinship] = [],
         uuid: UUID? = nil, treeIdentity: TreeIdentity? = nil,
         treeIdentityUnreadable: Bool = false, notInFamilyTree: Bool = false) {
        self.stableID = stableID
        self.name = name
        self.aliases = aliases
        self.sex = sex
        self.birthdate = birthdate
        self.deathdate = deathdate
        self.kinships = kinships
        self.uuid = uuid
        self.treeIdentity = treeIdentity
        self.treeIdentityUnreadable = treeIdentityUnreadable
        self.notInFamilyTree = notInFamilyTree
    }

    init(_ profile: POIProfile) {
        self.init(stableID: profile.id, name: profile.name, aliases: profile.aliases,
                  sex: profile.sex, birthdate: profile.birthdate, deathdate: profile.deathdate,
                  kinships: profile.kinships, uuid: profile.uuid,
                  treeIdentity: profile.treeIdentity,
                  treeIdentityUnreadable: profile.treeIdentityQuarantined != nil,
                  notInFamilyTree: profile.notInFamilyTree)
    }

    init(_ snapshot: HallieTurnExecutor.ProfileSnapshot) {
        self.init(stableID: snapshot.stableID, name: snapshot.canonicalName, aliases: snapshot.aliases,
                  sex: snapshot.sex, birthdate: snapshot.birthdate, kinships: snapshot.kinships,
                  uuid: snapshot.uuid, treeIdentity: snapshot.treeIdentity)
    }

    /// Birth year in UTC — the same calendar BirthKnowledge uses, so a
    /// midnight-local birthdate never slips a year.
    var birthYear: Int? {
        birthdate.map { TreeIdentityDeriver.utcCalendar.component(.year, from: $0) }
    }
}

struct TreeIdentityDeriver: Sendable {
    let graph: GedcomFamilyGraph
    let subjects: [TreeIdentitySubject]
    let ownerName: String?
    let ownerFamilySearchID: String?

    /// Most candidates an `.ambiguous` verdict carries — a one-word name on
    /// a 39k-person tree can match hundreds; the sheet has a search field.
    static let ambiguityCap = 12

    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    /// Tree records other subjects are ALREADY pinned to (pin resolved
    /// against this tree; a stale pin claims nothing), keyed by person id,
    /// valued by the claimant's stable id. Computed once per deriver.
    private let claimed: [String: String]
    private let fingerprint: String?
    private let ownerSubjectID: String?
    private let resolver: FamilyTreeIdentityResolver

    init(graph: GedcomFamilyGraph, subjects: [TreeIdentitySubject],
         ownerName: String?, ownerFamilySearchID: String?) {
        self.graph = graph
        self.subjects = subjects
        self.ownerName = ownerName
        self.ownerFamilySearchID = ownerFamilySearchID?.trimmingCharacters(in: .whitespacesAndNewlines)
        // The content fingerprint (a SHA over every name) is only needed to
        // honour export-local pointer pins; skipped when no subject has one.
        let needsFingerprint = subjects.contains {
            if case .pointer? = $0.treeIdentity { return true }
            return false
        }
        let fp = needsFingerprint ? FamilyKinshipOverlay.fingerprint(of: graph) : nil
        fingerprint = fp
        var claims: [String: String] = [:]
        for subject in subjects {
            if let person = Self.pinnedPerson(subject.treeIdentity, graph: graph, fingerprint: fp) {
                claims[person.id] = subject.stableID
            }
        }
        claimed = claims
        // Rule 1 applies to exactly ONE profile: if two profiles are both
        // spelled like the owner ("Rick" and a "Richard Breen" alias on
        // Dad), neither gets the owner pin by name.
        let ownerLike = subjects.filter { Self.isOwnerSubject($0, ownerName: ownerName) }
        ownerSubjectID = ownerLike.count == 1 ? ownerLike[0].stableID : nil
        resolver = FamilyTreeIdentityResolver(
            graph: graph,
            profiles: subjects.map { POIProfile(name: $0.name, referencePath: "", aliases: $0.aliases) })
    }

    init(graph: GedcomFamilyGraph, profiles: [POIProfile],
         ownerName: String?, ownerFamilySearchID: String?) {
        self.init(graph: graph, subjects: profiles.map(TreeIdentitySubject.init),
                  ownerName: ownerName, ownerFamilySearchID: ownerFamilySearchID)
    }

    // MARK: Batch

    /// Verdicts for every subject that has no usable pin (unpinned, not
    /// quarantined, not marked "not in the tree"), keyed by stable id.
    func deriveAll() -> [String: TreeIdentityDerivation] {
        var out: [String: TreeIdentityDerivation] = [:]
        for subject in subjects where subject.treeIdentity == nil
            && !subject.treeIdentityUnreadable && !subject.notInFamilyTree {
            out[subject.stableID] = derive(subject)
        }
        return out
    }

    // MARK: One subject

    func derive(_ subject: TreeIdentitySubject) -> TreeIdentityDerivation {
        // 1. The owner's own pin (Hallie's speaker setting).
        if subject.stableID == ownerSubjectID,
           let owner = graph.person(familySearchID: ownerFamilySearchID),
           isCompatible(owner, subject), !isClaimed(owner, by: subject) {
            return .certain(TreeIdentityCandidate(owner), reason: .ownerSetting)
        }

        let spellings = Self.spellingsMostSpecificFirst(name: subject.name, aliases: subject.aliases)

        // 2. A recorded home person spelled like the profile.
        let roots = graph.roots.filter { isCompatible($0, subject) && !isClaimed($0, by: subject) }
        if !roots.isEmpty {
            var matchingRoots: [GedcomFamilyGraph.Person] = []
            for spelling in spellings {
                let likeIDs = Set(graph.people(namedLike: spelling).map(\.id))
                for root in roots where likeIDs.contains(root.id) && !matchingRoots.contains(root) {
                    matchingRoots.append(root)
                }
            }
            if matchingRoots.count == 1 {
                return .certain(TreeIdentityCandidate(matchingRoots[0]), reason: .treeRoot)
            }
            if matchingRoots.count > 1 {
                return .ambiguous(matchingRoots.map(TreeIdentityCandidate.init))
            }
        }

        // 3. Name / alias match through the shared resolver.
        var matches: [GedcomFamilyGraph.Person]
        switch resolver.resolve(subject.name) {
        case .people(let people):      matches = people
        case .profileAmbiguous:        matches = []
        }
        matches = matches.filter { isCompatible($0, subject) && !isClaimed($0, by: subject) }

        if matches.isEmpty {
            // 4. Review suggestions only.
            let suggested = FamilyKinshipOverlay.suggestedTreeMatches(
                canonicalName: subject.name, aliases: subject.aliases, graph: graph)
                .filter { isCompatible($0, subject) && !isClaimed($0, by: subject) }
            return suggested.isEmpty
                ? .none
                : .ambiguous(Self.capped(suggested).map(TreeIdentityCandidate.init))
        }

        let constraints = kinshipConstraints(for: subject)
        if !constraints.isEmpty {
            // "Child of Dad" ⇒ MUST be a child of Dad's tree record. A name
            // match that violates every typed row is never certain.
            let consistent = matches.filter { person in
                constraints.allSatisfy { $0.contains(person.id) }
            }
            if consistent.count == 1 {
                return .certain(TreeIdentityCandidate(consistent[0]), reason: .nameAndKinship)
            }
            if consistent.isEmpty {
                return .ambiguous(Self.capped(matches).map(TreeIdentityCandidate.init))
            }
            matches = consistent
        }

        if matches.count == 1, let one = matches.first {
            if subject.birthYear != nil, one.birthYearInterval != nil {
                return .certain(TreeIdentityCandidate(one), reason: .nameAndBirth)
            }
            if Self.hasFullNameSpelling(spellings, matching: one) {
                return .certain(TreeIdentityCandidate(one), reason: .uniqueFullName)
            }
            // A lone one-word match ("Nana" → one Nana somewhere on the
            // tree) is offered, never assumed.
            return .ambiguous([TreeIdentityCandidate(one)])
        }

        // Several namesakes: the profile's birth year settles it when only
        // one record carries a compatible birth date.
        if subject.birthYear != nil {
            let dated = matches.filter { $0.birthYearInterval != nil }
            if dated.count == 1 {
                return .certain(TreeIdentityCandidate(dated[0]), reason: .nameAndBirth)
            }
        }
        // Then home people and their spouses.
        let rootIDs = Set(graph.roots.map(\.id))
        let spouseOfRootIDs = Set(graph.roots.flatMap { graph.relatives(.spouse, of: $0) }.map(\.id))
        let preferred = matches.filter { rootIDs.contains($0.id) || spouseOfRootIDs.contains($0.id) }
        if preferred.count == 1 {
            return .certain(TreeIdentityCandidate(preferred[0]), reason: .nameAndRoot)
        }
        return .ambiguous(Self.capped(matches).map(TreeIdentityCandidate.init))
    }

    // MARK: Evidence helpers

    /// Sex agrees when both know it; the profile's birth year lies inside
    /// the record's birth interval; the record did not die before the
    /// profile was born.
    func isCompatible(_ person: GedcomFamilyGraph.Person, _ subject: TreeIdentitySubject) -> Bool {
        if let sex = subject.sex {
            switch (sex, person.sex.uppercased()) {
            case (.male, "F"), (.female, "M"): return false
            default: break
            }
        }
        if let year = subject.birthYear {
            if let interval = person.birthYearInterval,
               interval.isEntirelyBefore(year) || interval.isEntirelyAtOrAfter(year + 1) {
                return false
            }
            if let death = person.deathYearInterval, death.isEntirelyBefore(year) {
                return false
            }
        }
        return true
    }

    private func isClaimed(_ person: GedcomFamilyGraph.Person, by subject: TreeIdentitySubject) -> Bool {
        guard let claimant = claimed[person.id] else { return false }
        return claimant != subject.stableID
    }

    /// The tree record a pin points at on THIS tree, or nil (stale pointer,
    /// FSID the tree lacks).
    static func pinnedPerson(_ pin: TreeIdentity?, graph: GedcomFamilyGraph,
                             fingerprint: String?) -> GedcomFamilyGraph.Person? {
        switch pin {
        case .familySearchID(let id)?:
            return graph.person(familySearchID: id)
        case .pointer(let pointer, let source)?:
            guard let fingerprint, source == fingerprint else { return nil }
            return graph.people[pointer]
        case nil:
            return nil
        }
    }

    static func isOwnerSubject(_ subject: TreeIdentitySubject, ownerName: String?) -> Bool {
        guard let ownerName else { return false }
        return ([subject.name] + subject.aliases).contains {
            HallieOwnerResolver.isOwnerSpelling($0, owner: ownerName)
        }
    }

    /// Sets of allowed tree-person ids, one per typed kinship row that
    /// links this subject to an already-PINNED subject (either direction).
    /// Empty when no row reaches a pin — Tim's "sibling of Rick" reaches
    /// Rick's record, but Rick has no siblings on FamilySearch, so the set
    /// is empty and every name match fails it (Tim is never pinned by name).
    private func kinshipConstraints(for subject: TreeIdentitySubject) -> [Set<String>] {
        var out: [Set<String>] = []
        // Rows stored on this subject: "I am R of X".
        for row in subject.kinships where FamilyKinshipInference.primitives.contains(row.relation) {
            guard let other = anchoredPerson(row.relativeTo, from: subject) else { continue }
            out.append(Set(graph.relatives(Self.relation(row.relation, viewedFrom: other), of: other).map(\.id)))
        }
        // Rows stored on pinned subjects that point at this one: "Y is R of me".
        for other in subjects where other.stableID != subject.stableID {
            guard let pinned = Self.pinnedPerson(other.treeIdentity, graph: graph, fingerprint: fingerprint)
            else { continue }
            for row in other.kinships where FamilyKinshipInference.primitives.contains(row.relation)
                && pointsAt(row.relativeTo, subject: subject) {
                // Y is R of me ⇒ I am R.inverse of Y.
                out.append(Set(graph.relatives(Self.relation(row.relation.inverse, viewedFrom: pinned), of: pinned).map(\.id)))
            }
        }
        return out
    }

    /// "subject is `relation` of `other`" → which of `other`'s relatives the
    /// subject must be among.
    private static func relation(_ relation: KinshipRelation, viewedFrom other: GedcomFamilyGraph.Person)
        -> GedcomFamilyGraph.Relation {
        switch relation {
        case .child:  return .children
        case .parent: return .parents
        case .spouse: return .spouse
        default:      return .siblings
        }
    }

    /// The tree record behind an anchor: a pinned subject's record, or a
    /// direct tree anchor on this tree.
    private func anchoredPerson(_ anchor: KinshipAnchor, from subject: TreeIdentitySubject)
        -> GedcomFamilyGraph.Person? {
        switch anchor {
        case .profile(let id):
            guard let target = subjects.first(where: { $0.uuid == id }), target.stableID != subject.stableID
            else { return nil }
            return Self.pinnedPerson(target.treeIdentity, graph: graph, fingerprint: fingerprint)
        case .profileName(let name):
            let key = PersonResolver.normalize(name)
            guard let target = subjects.first(where: { PersonResolver.normalize($0.name) == key }),
                  target.stableID != subject.stableID else { return nil }
            return Self.pinnedPerson(target.treeIdentity, graph: graph, fingerprint: fingerprint)
        case .treePerson(let fsid):
            return graph.person(familySearchID: fsid)
        case .treePointer(let pointer, let source):
            return Self.pinnedPerson(.pointer(pointer: pointer, sourceFingerprint: source),
                                     graph: graph, fingerprint: fingerprint)
        }
    }

    private func pointsAt(_ anchor: KinshipAnchor, subject: TreeIdentitySubject) -> Bool {
        switch anchor {
        case .profile(let id):        return subject.uuid == id
        case .profileName(let name):  return PersonResolver.normalize(name) == PersonResolver.normalize(subject.name)
        default:                      return false
        }
    }

    /// Does any spelling with a given name AND a surname (≥ 2 non-suffix
    /// tokens) fully describe this record? "Eileen Latta" does; "Eileen"
    /// alone does not.
    private static func hasFullNameSpelling(_ spellings: [String], matching person: GedcomFamilyGraph.Person) -> Bool {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        let recordTokens = Set(([person.name] + person.alternateNames)
            .flatMap { FamilyIdentityText.tokens($0) })
        return spellings.contains { spelling in
            let tokens = FamilyIdentityText.tokens(spelling).filter { !suffixes.contains($0) }
            guard tokens.count >= 2 else { return false }
            return tokens.allSatisfy { token in
                recordTokens.contains(token)
                    || (GedcomFamilyGraph.diminutives[token].map { recordTokens.contains($0) } ?? false)
            }
        }
    }

    /// Most specific spelling first (more words, then longer) — the same
    /// order FamilyTreeIdentityResolver and the overlay use.
    static func spellingsMostSpecificFirst(name: String, aliases: [String]) -> [String] {
        var seen = Set<String>()
        return ([name] + aliases)
            .filter { seen.insert(PersonResolver.normalize($0)).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                let lw = lhs.element.split(whereSeparator: \.isWhitespace).count
                let rw = rhs.element.split(whereSeparator: \.isWhitespace).count
                if lw != rw { return lw > rw }
                if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func capped(_ people: [GedcomFamilyGraph.Person]) -> [GedcomFamilyGraph.Person] {
        Array(people.prefix(ambiguityCap))
    }
}

// MARK: - Hallie: derivable-but-unconfirmed bridges

extension TreeIdentityDeriver {

    /// For a Hallie turn: fill each unpinned profile's `treeIdentity` with a
    /// `.certain` derivation so the kinship overlay can bridge it, and say
    /// so. Returns the substituted snapshots plus the phrase per tree
    /// person id ("Rick as Richard Harding Breen Jr") for the answer's
    /// "(taking …)" aside. Pinned, quarantined and stale profiles are left
    /// exactly as they are — fail-closed pins stay fail-closed.
    static func assumingCertainPins(
        snapshots: [HallieTurnExecutor.ProfileSnapshot],
        graph: GedcomFamilyGraph,
        ownerName: String?,
        ownerFamilySearchID: String?
    ) -> (snapshots: [HallieTurnExecutor.ProfileSnapshot], assumed: [String: String]) {
        let deriver = TreeIdentityDeriver(
            graph: graph, subjects: snapshots.map(TreeIdentitySubject.init),
            ownerName: ownerName, ownerFamilySearchID: ownerFamilySearchID)
        let verdicts = deriver.deriveAll()
        var assumed: [String: String] = [:]
        var used: Set<String> = []
        let out = snapshots.map { snapshot -> HallieTurnExecutor.ProfileSnapshot in
            guard snapshot.treeIdentity == nil,
                  let candidate = verdicts[snapshot.stableID]?.certainCandidate,
                  candidate.familySearchID != nil,   // a pointer pin needs the fingerprint; not worth it for one turn
                  used.insert(candidate.personID).inserted else { return snapshot }
            assumed[candidate.personID] = "\(snapshot.canonicalName) as \(candidate.name)"
            return HallieTurnExecutor.ProfileSnapshot(
                stableID: snapshot.stableID, canonicalName: snapshot.canonicalName,
                aliases: snapshot.aliases, birthdate: snapshot.birthdate, note: snapshot.note,
                kinships: snapshot.kinships, sex: snapshot.sex, uuid: snapshot.uuid,
                treeIdentity: candidate.identity(fingerprint: nil))
        }
        return (out, assumed)
    }
}
