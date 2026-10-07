import Foundation

enum ArchivistGraphConclusion: Sendable, Equatable {
    case answered
    case missingFact
    case personNotFound
    case personAmbiguous
    case profileAmbiguous
    case conflictingProfileStableID(String)
    case invalidPerson
    case unsupportedPeopleCount(Int)
    case missingRelation
    case unexpectedRelation
}

/// Where the Family Tree tab should land if the user takes the offered
/// action. Presentation hint only; it carries a display name, never a claim.
enum ArchivistFamilyTreeFocus: Sendable, Equatable {
    case person(name: String)
    case surname(String)
}

/// Exact GEDCOM values used to compose an answer. This value stays on the
/// deterministic side of the translator boundary and must never be sent to an
/// LLM. IDs make each displayed fact auditable even when names are repeated.
struct ArchivistGraphEvidence: Sendable, Equatable {
    struct IdentityBridge: Sendable, Equatable {
        let requestedName: String
        let profileCanonicalName: String
        let effectiveGEDCOMPersonID: String
        let effectiveGEDCOMName: String
    }

    struct RelatedPerson: Sendable, Equatable {
        let id: String
        let name: String
    }

    struct Relationship: Sendable, Equatable {
        let relation: GedcomFamilyGraph.Relation
        let people: [RelatedPerson]
    }

    /// One multi-hop route ("Donna → mother Elaine → her mother Ann").
    struct KinshipPath: Sendable, Equatable {
        struct Hop: Sendable, Equatable {
            let label: String
            let person: RelatedPerson
        }
        let hops: [Hop]
    }

    let subjectID: String
    let subjectName: String
    let birthDate: String?
    let deathDate: String?
    let relationships: [Relationship]
    let identityBridge: IdentityBridge?
    let kinshipPaths: [KinshipPath]
    /// The second person of a `relationship` answer (B), also when no path
    /// was found — so offered actions can still name both people.
    let counterpart: RelatedPerson?

    init(
        subjectID: String,
        subjectName: String,
        birthDate: String?,
        deathDate: String?,
        relationships: [Relationship],
        identityBridge: IdentityBridge?,
        kinshipPaths: [KinshipPath] = [],
        counterpart: RelatedPerson? = nil
    ) {
        self.subjectID = subjectID
        self.subjectName = subjectName
        self.birthDate = birthDate
        self.deathDate = deathDate
        self.relationships = relationships
        self.identityBridge = identityBridge
        self.kinshipPaths = kinshipPaths
        self.counterpart = counterpart
    }
}

struct ArchivistGraphResult: Sendable, Equatable {
    let conclusion: ArchivistGraphConclusion
    let prose: String
    let basisLine: String
    let evidence: ArchivistGraphEvidence?
    let candidates: [ArchivistBiographyAnswer.Candidate]
    let profileCandidates: [String]
    let ambiguityCandidates: [ArchivistGraphAmbiguityCandidate]
    let catalogPersonName: String?
    let familyTreeFocus: ArchivistFamilyTreeFocus?
    /// For a two-person `relationship` query: which people-list slot the
    /// ambiguity / not-found conclusion is about (0 or 1). Nil otherwise.
    let subjectIndex: Int?
    /// The claim-per-sentence plan behind `prose` when the executor built
    /// one (the person card, 2026-08-29): the composer phrases these
    /// claims, each cited to its GEDCOM pointers, instead of re-splitting
    /// the prose. Nil = derive the plan from the prose as before.
    let answerPlan: HallieAnswerPlan?
    /// A duplicated parent the card flagged (live miss #16): the person
    /// whose record shows both parents, for the "Show possible duplicate
    /// in Family Tree" chip. Nil when the card raised no flag.
    let possibleDuplicate: PossibleDuplicate?
    /// Living or passed on for the person the answer is about (LifeStatus,
    /// 2026-09-01), so the composer keeps the template's tense. Nil when
    /// the result has no single subject (declines, ambiguity, no person).
    let subjectLifeStatus: LifeStatus?
    /// The People-tab profile the BIOGRAPHY subject is bridged to
    /// (2026-09-04). Only the id travels — the profile's free-text note
    /// stays outside graph execution, exactly as before; the turn
    /// executor, which already holds the profiles, looks the note up and
    /// quotes it with the People tab's own attribution. Nil for an
    /// unbridged subject or any other operation.
    let peopleTabProfileStableID: String?

    struct PossibleDuplicate: Sendable, Equatable {
        let personID: String
        let personName: String
    }

    init(
        conclusion: ArchivistGraphConclusion,
        prose: String,
        basisLine: String,
        evidence: ArchivistGraphEvidence?,
        candidates: [ArchivistBiographyAnswer.Candidate],
        profileCandidates: [String],
        ambiguityCandidates: [ArchivistGraphAmbiguityCandidate],
        catalogPersonName: String?,
        familyTreeFocus: ArchivistFamilyTreeFocus? = nil,
        subjectIndex: Int? = nil,
        answerPlan: HallieAnswerPlan? = nil,
        possibleDuplicate: PossibleDuplicate? = nil,
        subjectLifeStatus: LifeStatus? = nil,
        peopleTabProfileStableID: String? = nil
    ) {
        self.conclusion = conclusion
        self.prose = prose
        self.basisLine = basisLine
        self.evidence = evidence
        self.candidates = candidates
        self.profileCandidates = profileCandidates
        self.ambiguityCandidates = ambiguityCandidates
        self.catalogPersonName = catalogPersonName
        self.familyTreeFocus = familyTreeFocus
        self.subjectIndex = subjectIndex
        self.answerPlan = answerPlan
        self.possibleDuplicate = possibleDuplicate
        self.subjectLifeStatus = subjectLifeStatus
        self.peopleTabProfileStableID = peopleTabProfileStableID
    }

    /// The same result tagged with the people-list slot it concerns.
    func taggingSubject(_ index: Int) -> ArchivistGraphResult {
        ArchivistGraphResult(
            conclusion: conclusion, prose: prose, basisLine: basisLine,
            evidence: evidence, candidates: candidates,
            profileCandidates: profileCandidates,
            ambiguityCandidates: ambiguityCandidates,
            catalogPersonName: catalogPersonName,
            familyTreeFocus: familyTreeFocus, subjectIndex: index,
            answerPlan: answerPlan, possibleDuplicate: possibleDuplicate,
            subjectLifeStatus: subjectLifeStatus,
            peopleTabProfileStableID: peopleTabProfileStableID)
    }

    /// The same result carrying the subject's life status. Only an answer
    /// or a missing-fact (which still names the person) is tagged; a
    /// decline about nobody in particular stays untagged.
    func withSubjectLifeStatus(_ status: LifeStatus?) -> ArchivistGraphResult {
        guard let status, conclusion == .answered || conclusion == .missingFact else { return self }
        let statusAwarePlan = answerPlan.map { plan in
            HallieAnswerPlan(
                route: plan.route, shape: plan.shape, subject: plan.subject,
                claims: plan.claims, counts: plan.counts,
                fallbackText: plan.fallbackText,
                subjectLifeStatus: status)
        }
        return ArchivistGraphResult(
            conclusion: conclusion, prose: prose, basisLine: basisLine,
            evidence: evidence, candidates: candidates,
            profileCandidates: profileCandidates,
            ambiguityCandidates: ambiguityCandidates,
            catalogPersonName: catalogPersonName,
            familyTreeFocus: familyTreeFocus, subjectIndex: subjectIndex,
            answerPlan: statusAwarePlan, possibleDuplicate: possibleDuplicate,
            subjectLifeStatus: status,
            peopleTabProfileStableID: peopleTabProfileStableID)
    }
}
