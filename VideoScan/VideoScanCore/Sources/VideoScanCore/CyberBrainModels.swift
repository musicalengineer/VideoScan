import Foundation

public struct CyberBrainArchive: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let archiveID: String
    public let displayName: String
    public let people: [CyberBrainPerson]
    public let sources: [CyberBrainSource]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        archiveID: String,
        displayName: String,
        people: [CyberBrainPerson],
        sources: [CyberBrainSource]
    ) {
        self.schemaVersion = schemaVersion
        self.archiveID = archiveID
        self.displayName = displayName
        self.people = people
        self.sources = sources
    }
}

public struct CyberBrainPerson: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let gedcomPersonID: String?
    public let profileStableID: UUID?
    public let canonicalName: String
    public let aliases: [String]
    public let terminology: [String]
    public let biographyPassages: [CyberBrainItem]
    public let anecdotes: [CyberBrainItem]
    public let lifeEvents: [CyberBrainItem]
    public let notes: [CyberBrainItem]
    /// How Hallie's voice should say a word of this person's name
    /// (2026-08-26, "a pronunciation key next to aliases"): name word →
    /// respelling, e.g. "Nathaniel" → "nuh-THAN-yul". Keys are single
    /// words; the speech lexicon is word-based, so an entry applies to that
    /// word wherever it appears in spoken text, not just next to this
    /// person. Optional and omitted when empty: files written before this
    /// field decode unchanged (nil), and a file without pronunciations is
    /// byte-identical to what the older writer produced.
    public let pronunciations: [String: String]?

    public init(
        id: String,
        gedcomPersonID: String? = nil,
        profileStableID: UUID? = nil,
        canonicalName: String,
        aliases: [String] = [],
        terminology: [String] = [],
        biographyPassages: [CyberBrainItem] = [],
        anecdotes: [CyberBrainItem] = [],
        lifeEvents: [CyberBrainItem] = [],
        notes: [CyberBrainItem] = [],
        pronunciations: [String: String]? = nil
    ) {
        self.id = id
        self.gedcomPersonID = gedcomPersonID
        self.profileStableID = profileStableID
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.terminology = terminology
        self.biographyPassages = biographyPassages
        self.anecdotes = anecdotes
        self.lifeEvents = lifeEvents
        self.notes = notes
        self.pronunciations = (pronunciations?.isEmpty ?? true) ? nil : pronunciations
    }

    /// Copy with a different pronunciation table (nil/empty clears it).
    /// Swift structs are values, so "modify" means "make a new one" — the
    /// C++ analogy is a const struct with a builder method.
    public func withPronunciations(_ table: [String: String]?) -> CyberBrainPerson {
        CyberBrainPerson(
            id: id, gedcomPersonID: gedcomPersonID, profileStableID: profileStableID,
            canonicalName: canonicalName, aliases: aliases, terminology: terminology,
            biographyPassages: biographyPassages, anecdotes: anecdotes,
            lifeEvents: lifeEvents, notes: notes, pronunciations: table)
    }

    public var items: [CyberBrainItem] {
        biographyPassages + anecdotes + lifeEvents + notes
    }
}

public struct CyberBrainItem: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case biography, anecdote, event, note
    }

    public enum Confidence: String, Codable, Sendable, CaseIterable {
        case confirmed, probable, uncertain, disputed
    }

    public enum Privacy: String, Codable, Sendable, CaseIterable {
        case `private`, family, `public`

        fileprivate var rank: Int {
            switch self {
            case .public: return 0
            case .family: return 1
            case .private: return 2
            }
        }

        public func isVisible(at ceiling: Privacy) -> Bool {
            rank <= ceiling.rank
        }
    }

    public enum Status: String, Codable, Sendable, CaseIterable {
        case active, superseded, retracted
    }

    public let id: String
    public let kind: Kind
    public let text: String
    public let subjectPersonIDs: [String]
    public let eventDate: CyberBrainQualifiedDate?
    public let place: String?
    public let sourceIDs: [String]
    public let confidence: Confidence
    public let privacy: Privacy
    public let status: Status
    public let supersedesItemID: String?
    /// Explicit counter-claims required when confidence is `disputed`.
    /// IDs keep disagreement inspectable instead of grouping unrelated claims
    /// merely because they share a person.
    public let disputesItemIDs: [String]
    public let createdAt: Date
    public let updatedAt: Date
    /// The structured side of a military-service story (Rick 2026-09-23).
    /// Only on a `lifeEvents` item (kind `event`), whose `text` is the brief
    /// story itself — so a reader that predates this field still has the
    /// story as an ordinary passage. Optional and omitted when nil: files
    /// written before this field decode unchanged and re-encode
    /// byte-identically.
    public let service: CyberBrainServiceRecord?

    public init(
        id: String,
        kind: Kind,
        text: String,
        subjectPersonIDs: [String],
        eventDate: CyberBrainQualifiedDate? = nil,
        place: String? = nil,
        sourceIDs: [String],
        confidence: Confidence,
        privacy: Privacy,
        status: Status = .active,
        supersedesItemID: String? = nil,
        disputesItemIDs: [String] = [],
        createdAt: Date,
        updatedAt: Date,
        service: CyberBrainServiceRecord? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.subjectPersonIDs = subjectPersonIDs
        self.eventDate = eventDate
        self.place = place
        self.sourceIDs = sourceIDs
        self.confidence = confidence
        self.privacy = privacy
        self.status = status
        self.supersedesItemID = supersedesItemID
        self.disputesItemIDs = disputesItemIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.service = service
    }
}

/// One person's military service, as the family knows it (Rick
/// 2026-09-23: "the american revolution, the civil war, world war 1 and
/// world war 2 … brief is good because we're lacking some details").
///
/// Facts only — every field is something the family actually said. What is
/// not known stays nil / empty / `.unknown`; Hallie says "the family doesn't
/// know" rather than filling a gap. The story Hallie tells is the carrying
/// item's `text`; the source line comes from the item's first source.
public struct CyberBrainServiceRecord: Codable, Sendable, Equatable {
    /// Which war. `other` covers peacetime service and wars without a case
    /// of their own; `nil` (absent) means the family doesn't know.
    public enum Conflict: String, Codable, Sendable, CaseIterable {
        case americanRevolution, civilWar, worldWarI, worldWarII, other
    }

    /// Whether the person saw combat, as far as the family knows.
    public enum Combat: String, Codable, Sendable, CaseIterable {
        case yes, no, unknown
    }

    /// How the family knows it — this decides Hallie's source line and her
    /// offer wording ("the family story of …" for tradition).
    public enum Basis: String, Codable, Sendable, CaseIterable {
        /// A family member stated it as fact (e.g. Rick about his father).
        case confirmedByFamily
        /// Handed down; nobody has seen a document yet.
        case familyTradition
        /// A service record, discharge paper or similar was seen.
        case documented
    }

    /// One battle or campaign the family names. Nothing is inferred from
    /// the conflict: an engagement exists only when someone named it.
    public struct Engagement: Codable, Sendable, Equatable {
        public let name: String
        public let date: CyberBrainQualifiedDate?
        public let place: String?

        public init(name: String, date: CyberBrainQualifiedDate? = nil, place: String? = nil) {
            self.name = name
            self.date = date
            self.place = place
        }
    }

    public let conflict: Conflict?
    /// The army / service / side, as the family names it: "United States
    /// Marine Corps", "British Army", "Confederate States Army".
    public let force: String
    /// Any role the family knows ("enlisted man", "officer"); nil = unknown.
    public let roleNote: String?
    /// When they served, qualified; nil = unknown.
    public let serviceDates: CyberBrainQualifiedDate?
    public let engagements: [Engagement]
    public let combat: Combat
    public let basis: Basis

    public init(
        conflict: Conflict?,
        force: String,
        roleNote: String? = nil,
        serviceDates: CyberBrainQualifiedDate? = nil,
        engagements: [Engagement] = [],
        combat: Combat = .unknown,
        basis: Basis
    ) {
        self.conflict = conflict
        self.force = force
        self.roleNote = roleNote
        self.serviceDates = serviceDates
        self.engagements = engagements
        self.combat = combat
        self.basis = basis
    }
}

public struct CyberBrainQualifiedDate: Codable, Sendable, Equatable {
    public enum Precision: String, Codable, Sendable, CaseIterable {
        case day, month, year, decade, unknown
    }

    public enum Qualifier: String, Codable, Sendable, CaseIterable {
        case exact, about, before, after, between
    }

    public let value: String
    public let precision: Precision
    public let qualifier: Qualifier
    public let displayText: String

    public init(value: String, precision: Precision, qualifier: Qualifier,
                displayText: String) {
        self.value = value
        self.precision = precision
        self.qualifier = qualifier
        self.displayText = displayText
    }
}

public struct CyberBrainSource: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case officialRecord
        case gedcom
        case firstPerson
        case familyWitness
        case curatedBiography
        case mediaEvidence
        case profileNote
        case inference
    }

    public let id: String
    public let type: Kind
    public let title: String
    public let attribution: String?
    public let sourceDate: CyberBrainQualifiedDate?
    public let locator: String?
    public let notes: String?

    public init(
        id: String,
        type: Kind,
        title: String,
        attribution: String? = nil,
        sourceDate: CyberBrainQualifiedDate? = nil,
        locator: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.attribution = attribution
        self.sourceDate = sourceDate
        self.locator = locator
        self.notes = notes
    }
}

public enum CyberBrainAnswerState: String, Codable, Sendable, Equatable {
    case answered, ambiguous, noEvidence, disputed
}

public struct CyberBrainAnswerPlan: Codable, Sendable, Equatable {
    public enum PermittedAction: String, Codable, Sendable, Equatable {
        case play, reveal, narrow, showSource
    }

    public enum Constraint: String, Codable, Sendable, Equatable {
        case doNotInferIdentity
        case doNotChooseAmbiguousIdentity
        case doNotAddUnsupportedFacts
        case doNotResolveDispute
    }

    public struct Candidate: Codable, Sendable, Equatable, Identifiable {
        public enum Source: String, Codable, Sendable, Equatable {
            case cyberBrain, gedcom
        }

        public let id: String
        public let canonicalName: String
        public let source: Source

        public init(id: String, canonicalName: String, source: Source) {
            self.id = id
            self.canonicalName = canonicalName
            self.source = source
        }
    }

    public struct Claim: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let text: String
        public let evidenceIDs: [String]
        public let confidence: CyberBrainItem.Confidence

        public init(id: String, text: String, evidenceIDs: [String],
                    confidence: CyberBrainItem.Confidence) {
            self.id = id
            self.text = text
            self.evidenceIDs = evidenceIDs
            self.confidence = confidence
        }
    }

    public struct Citation: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let attribution: String?
        public let locator: String?

        public init(id: String, title: String, attribution: String?,
                    locator: String?) {
            self.id = id
            self.title = title
            self.attribution = attribution
            self.locator = locator
        }
    }

    public let subject: String
    public let answerState: CyberBrainAnswerState
    public let claims: [Claim]
    public let uncertaintyStatements: [String]
    public let sourceCitations: [Citation]
    public let suggestedFollowups: [String]
    public let permittedActions: [PermittedAction]
    public let constraints: [Constraint]
    public let ambiguityCandidates: [Candidate]

    public init(
        subject: String,
        answerState: CyberBrainAnswerState,
        claims: [Claim] = [],
        uncertaintyStatements: [String] = [],
        sourceCitations: [Citation] = [],
        suggestedFollowups: [String] = [],
        permittedActions: [PermittedAction] = [],
        constraints: [Constraint] = [],
        ambiguityCandidates: [Candidate] = []
    ) {
        self.subject = subject
        self.answerState = answerState
        self.claims = claims
        self.uncertaintyStatements = uncertaintyStatements
        self.sourceCitations = sourceCitations
        self.suggestedFollowups = suggestedFollowups
        self.permittedActions = permittedActions
        self.constraints = constraints
        self.ambiguityCandidates = ambiguityCandidates
    }
}
