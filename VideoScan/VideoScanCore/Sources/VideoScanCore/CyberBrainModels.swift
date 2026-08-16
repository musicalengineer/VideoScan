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
        notes: [CyberBrainItem] = []
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
    public let createdAt: Date
    public let updatedAt: Date

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
        createdAt: Date,
        updatedAt: Date
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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

public struct CyberBrainAnswerPlan: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let id: String
        public let canonicalName: String

        public init(id: String, canonicalName: String) {
            self.id = id
            self.canonicalName = canonicalName
        }
    }

    public struct Claim: Sendable, Equatable, Identifiable {
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

    public struct Citation: Sendable, Equatable, Identifiable {
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
    public let permittedActions: [String]
    public let forbiddenClaims: [String]
    public let ambiguityCandidates: [Candidate]

    public init(
        subject: String,
        answerState: CyberBrainAnswerState,
        claims: [Claim] = [],
        uncertaintyStatements: [String] = [],
        sourceCitations: [Citation] = [],
        suggestedFollowups: [String] = [],
        permittedActions: [String] = [],
        forbiddenClaims: [String] = [],
        ambiguityCandidates: [Candidate] = []
    ) {
        self.subject = subject
        self.answerState = answerState
        self.claims = claims
        self.uncertaintyStatements = uncertaintyStatements
        self.sourceCitations = sourceCitations
        self.suggestedFollowups = suggestedFollowups
        self.permittedActions = permittedActions
        self.forbiddenClaims = forbiddenClaims
        self.ambiguityCandidates = ambiguityCandidates
    }
}
