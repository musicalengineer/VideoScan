// HallieTurnExecutor.swift
// Shared, UI-neutral deterministic execution for one QueryAST-v2 turn.

import Foundation
import VideoScanCore

enum HallieTurnExecutor {
    enum Route: Sendable, Equatable {
        case presence
        case temporal
        case aggregate
        case graph
        /// Person + spoken/visible terms ANDed; runs on the presence
        /// executor with every basis cited (2026-08-17: "show timmy as a
        /// baby saying peekaboo").
        case cross
        /// ONE catalog record — the selected row or a named file — and its
        /// people / date / dossier (ArchivistRecordExecutor, 2026-09-02).
        case record
        case unsupportedEvent
        /// A model-free turn about the previous answer: play/reveal/show a
        /// cited item, paging, an elliptical refinement, or an honest
        /// "ask me for something first".
        case followUp
        /// A model-free honest answer about what Hallie can and cannot do.
        case capability
        /// The deterministic help card ("help", "?", "what can you do").
        case help
        /// A one-line friendly reply ("thanks", "hi", "good morning").
        case smalltalk
        /// Bounded ordinary conversation that receives no archive evidence.
        case conversation
        /// A family member telling Hallie about someone (HallieTellingMode):
        /// she listens, asks, and records attributed testimony. No AST.
        case telling
        /// "start over" — conversation memory cleared.
        case reset
    }

    enum Outcome: Sendable, Equatable {
        case answered
        case declined
        case unsupported
        case needsClarification
        /// Hallie tried to DO something the turn asked for (a save) and it
        /// did not happen. Never dressed up as an answer (codex #700).
        case failed
        /// A conversation-repair turn ("that's wrong", "you gave me people
        /// from the 1300s"): the previous answer was acknowledged and
        /// restated, nothing was searched (HallieRepairTurn, 2026-08-29).
        case repaired
    }

    enum IdentitySource: Sendable, Equatable {
        case peopleProfile
        case gedcom
        case cyberBrain
    }

    enum CandidateID: Sendable, Equatable {
        case profileStableID(String)
        case gedcomPersonID(String)
        case cyberBrainPersonID(String)

        var source: IdentitySource {
            switch self {
            case .profileStableID: return .peopleProfile
            case .gedcomPersonID: return .gedcom
            case .cyberBrainPersonID: return .cyberBrain
            }
        }
    }

    struct Candidate: Sendable, Equatable {
        let id: CandidateID
        let canonicalName: String
        let label: String
        let source: IdentitySource
        /// Facts a typed which-one reply may discriminate by beyond the
        /// label's years — places and the names of parents and spouses
        /// ("the one from Sudbury", "Matthew Rice's wife"). Normalized
        /// (PersonResolver.normalize); never shown. Empty for People-tab
        /// and CyberBrain choices.
        let discriminators: [String]

        init(id: CandidateID, canonicalName: String, label: String,
             discriminators: [String] = []) {
            self.id = id
            self.canonicalName = canonicalName
            self.label = label
            self.source = id.source
            self.discriminators = discriminators
        }
    }

    /// One family-tree person as a which-one choice: the shared
    /// birth/death label plus the discriminating facts a reply may name.
    static func gedcomCandidate(
        _ person: GedcomFamilyGraph.Person,
        graph: GedcomFamilyGraph
    ) -> Candidate {
        var facts: [String] = []
        if let place = person.birthPlace { facts.append(place) }
        if let place = person.deathPlace { facts.append(place) }
        facts += graph.relatives(.parents, of: person).map(\.name)
        facts += graph.marriages(of: person).compactMap { $0.spouse?.name }
        return Candidate(
            id: .gedcomPersonID(person.id),
            canonicalName: person.name,
            label: ArchivistBiographyPolicy.disambiguationCandidate(for: person).label,
            discriminators: facts.map(PersonResolver.normalize))
    }

    enum ClarificationStage: Sendable, Equatable {
        case profileIdentity
        case gedcomPerson
        case cyberBrainPerson
        /// "Did you mean…?" offers the closest names from BOTH the tree
        /// and the People tab in one list; every chip must be actionable
        /// (codex #663 — the stage used to be taken from the first choice,
        /// so a People chip under a GEDCOM first choice was refused).
        case suggestedIdentity

        func accepts(_ source: IdentitySource) -> Bool {
            switch (self, source) {
            case (.profileIdentity, .peopleProfile), (.gedcomPerson, .gedcom),
                 (.cyberBrainPerson, .cyberBrain),
                 (.suggestedIdentity, .peopleProfile), (.suggestedIdentity, .gedcom):
                return true
            default:
                return false
            }
        }
    }

    /// The original interaction intent survives every continuation. In
    /// particular, a clarification chip must not lose a pending play request.
    struct Intent: Sendable, Equatable {
        let originalQuestion: String
        let ast: ArchivistQueryAST
        let playAfterAnswer: Bool
        /// Paging: proven matches to skip before citing ("show more").
        let citationOffset: Int
        /// Set when the AST came from a follow-up refinement of the previous
        /// question rather than a fresh translation; quoted in the basis line
        /// so the answer says so ("refining: rick + guitar · around 2005").
        let refinementNote: String?
        /// The cumulative chain after this refinement, remembered for the
        /// next fragment. Nil for fresh questions and paging.
        let refinementChain: ArchivistFollowUpResolver.Chain?
        /// The answer's lead for a refined turn ("Narrowed to Westford,
        /// around 2005"); the executor appends the count.
        let refinementChange: String?
        /// How "I"/"you" in a graph people list were bound for this turn
        /// (owner / archivist). Set once, before identity resolution, and
        /// carried through clarifications so a chip never re-reads a
        /// pronoun differently. Echoed in the basis line.
        let speakerBindings: [SpeakerBinding]
        /// For a two-person `relationship` question whose FIRST slot was
        /// already disambiguated by a chip: slot index → chosen identity,
        /// so the second slot's clarification does not lose it.
        let pinnedGraphSubjects: [Int: CandidateID]
        /// "and the newest?" / "the second oldest one" (2026-09-02): re-run
        /// `ast` as a list sorted by date and pick one. Nil for every other
        /// turn; the presence route reads it (+DateOrdered).
        let dateOrder: DateOrderRequest?

        init(
            originalQuestion: String,
            ast: ArchivistQueryAST,
            playAfterAnswer: Bool = false,
            citationOffset: Int = 0,
            refinementNote: String? = nil,
            refinementChain: ArchivistFollowUpResolver.Chain? = nil,
            refinementChange: String? = nil,
            speakerBindings: [SpeakerBinding] = [],
            pinnedGraphSubjects: [Int: CandidateID] = [:],
            dateOrder: DateOrderRequest? = nil
        ) {
            self.originalQuestion = originalQuestion
            self.ast = ast
            self.playAfterAnswer = playAfterAnswer
            self.citationOffset = max(0, citationOffset)
            self.refinementNote = refinementNote
            self.refinementChain = refinementChain
            self.refinementChange = refinementChange
            self.speakerBindings = speakerBindings
            self.pinnedGraphSubjects = pinnedGraphSubjects
            self.dateOrder = dateOrder
        }

        /// The same intent with a rewritten graph AST and/or extra pins.
        func replacing(
            ast newAST: ArchivistQueryAST? = nil,
            speakerBindings newBindings: [SpeakerBinding]? = nil,
            pinnedGraphSubjects newPins: [Int: CandidateID]? = nil
        ) -> Intent {
            Intent(
                originalQuestion: originalQuestion,
                ast: newAST ?? ast,
                playAfterAnswer: playAfterAnswer,
                citationOffset: citationOffset,
                refinementNote: refinementNote,
                refinementChain: refinementChain,
                refinementChange: refinementChange,
                speakerBindings: newBindings ?? speakerBindings,
                pinnedGraphSubjects: newPins ?? pinnedGraphSubjects,
                dateOrder: dateOrder)
        }
    }

    /// A list query that a NON-list answer still carries — the count it
    /// counted, the person an age was about — so "and the newest?" has
    /// something to sort (2026-09-02, eval cc007 / cs015 / tm009).
    enum RefinableQuery: Sendable, Equatable {
        /// Re-run this presence/cross AST. `anyOfPeople`: the people were
        /// the joint subject of an age answer ("the boys"), so a video with
        /// ANY of them counts — the presence executor's own reading of
        /// several names is all-of-them.
        case list(ArchivistQueryAST, anyOfPeople: Bool)
        /// A catalog-wide count ("how many videos do you have", "what years
        /// does the footage cover"): every dated record.
        case wholeCatalog
    }

    /// "the newest" / "the second oldest one": which end, which position.
    struct DateOrderRequest: Sendable, Equatable {
        enum Order: Sendable, Equatable {
            case newestFirst
            case oldestFirst
        }
        let order: Order
        /// 1-based: "the newest" = 1, "the second newest" = 2.
        let ordinal: Int
        let scope: RefinableQuery
    }

    struct Request: Sendable, Equatable {
        let intent: Intent
        /// Readable by the executor's extension files; only `continue` (this
        /// file) can construct a Request that carries one.
        let selectedIdentity: CandidateID?

        init(intent: Intent) {
            self.intent = intent
            self.selectedIdentity = nil
        }

        fileprivate init(intent: Intent, selectedIdentity: CandidateID) {
            self.intent = intent
            self.selectedIdentity = selectedIdentity
        }
    }

    struct Clarification: Sendable, Equatable {
        let intent: Intent
        let stage: ClarificationStage
        let candidates: [Candidate]
        fileprivate let continuationToken: UUID

        fileprivate init(
            intent: Intent,
            stage: ClarificationStage,
            candidates: [Candidate],
            continuationToken: UUID
        ) {
            self.intent = intent
            self.stage = stage
            self.candidates = candidates
            self.continuationToken = continuationToken
        }

        /// The same pending question over a subset of its choices ("two of
        /// them were born in 1520 — which?"). The subset must come from
        /// this clarification's own candidates; anything else is refused
        /// (nil) so a client cannot widen or forge the list.
        func narrowed(to subset: [Candidate]) -> Clarification? {
            guard !subset.isEmpty,
                  subset.allSatisfy({ chosen in candidates.contains { $0.id == chosen.id } })
            else { return nil }
            return Clarification(
                intent: intent, stage: stage, candidates: subset,
                continuationToken: continuationToken)
        }
    }

    /// Factory for the executor's extension files. The initializer and the
    /// context token stay fileprivate so no client can forge a continuation;
    /// only executor code holding a live Context can mint one.
    static func makeClarification(
        intent: Intent,
        stage: ClarificationStage,
        candidates: [Candidate],
        context: Context
    ) -> Clarification {
        Clarification(
            intent: intent, stage: stage, candidates: candidates,
            continuationToken: context.continuationToken)
    }

    /// The only People-gallery values admitted to factual execution. Photos,
    /// notes, recognition settings, and profile filesystem paths stay outside.
    struct ProfileSnapshot: Sendable, Equatable {
        let stableID: String
        let canonicalName: String
        let aliases: [String]
        let birthdate: Date?
        /// The free-text note on the profile. Never a fact: the only reader
        /// (PeopleTab) quotes it with attribution, and nothing matches on it.
        let note: String
        /// Typed local relationships + sex (2026-08-27) for the kinship
        /// overlay. Additive; default "none".
        let kinships: [Kinship]
        let sex: PersonSex?
        let uuid: UUID?
        /// The profile's family-tree pin (2026-08-29): the ONLY way a Hallie
        /// profile becomes a tree vertex in the kinship overlay. Seam for
        /// Phase B (engine-backed answers); carried, not yet reasoned over.
        let treeIdentity: TreeIdentity?
        /// The profile's recorded death (LifeStatus, 2026-09-01): what makes
        /// a People-tab person "passed on" in Hallie's tense. Additive.
        let deathdate: Date?

        init(
            stableID: String,
            canonicalName: String,
            aliases: [String] = [],
            birthdate: Date? = nil,
            note: String = "",
            kinships: [Kinship] = [],
            sex: PersonSex? = nil,
            uuid: UUID? = nil,
            treeIdentity: TreeIdentity? = nil,
            deathdate: Date? = nil
        ) {
            self.stableID = stableID
            self.canonicalName = canonicalName
            self.aliases = aliases
            self.birthdate = birthdate
            self.note = note
            self.kinships = kinships
            self.sex = sex
            self.uuid = uuid
            self.treeIdentity = treeIdentity
            self.deathdate = deathdate
        }
    }

    /// Immutable values captured by the caller before shared execution. This
    /// deliberately contains no model, media, photo, or filesystem adapters.
    struct Context: Sendable {
        let presenceRecords: [ArchivistPresenceRecordSnapshot]
        let aggregateRecords: [ArchivistAggregateRecordSnapshot]
        /// `nil` means profile evidence could not be read. An empty array is
        /// a successful read proving that no profiles currently exist.
        let profiles: [ProfileSnapshot]?
        let graph: GedcomFamilyGraph?
        /// Live miss #8 (2026-08-29): when `graph` is nil because the loader
        /// REFUSED a multi-pull compiled generation after a codec/schema
        /// bump (FamilyGraphFileLoader.Outcome.needsRecompile), these are
        /// its source files, still on disk. Non-empty ⇒ there IS a family
        /// tree; every "no tree" decline must say "needs recompiling" and
        /// offer `.recompileFamilyTree` instead. Empty = genuinely no tree.
        let needsRecompile: [URL]
        let cyberBrain: CyberBrainIndex?
        let selectedTemporalDate: ArchivistTemporalSelectionDateSnapshot?
        /// The ONE record a `record` question is about, resolved by the
        /// client before execution (+Record, 2026-09-02). `.noSelection`
        /// for every other route.
        let recordScope: RecordScope
        /// Who "I" and "you" are (2026-08-18). `.none` = pronouns cannot be
        /// bound and the executor says so.
        let speakers: Speakers
        /// Profile → tree bridges this turn ASSUMED from a derivable-but-
        /// unconfirmed identity (TreeIdentityDeriver, 2026-08-29), keyed by
        /// tree person id, valued "Rick as Richard Harding Breen Jr". An
        /// answer that leans on one says so in a "(taking …)" aside.
        let assumedTreeBridges: [String: String]
        /// An opaque capture identity. Copying Context preserves it; invoking
        /// the initializer creates a new capture that cannot continue an old
        /// clarification even if visible stable IDs and names are unchanged.
        fileprivate let continuationToken: UUID

        init(
            presenceRecords: [ArchivistPresenceRecordSnapshot] = [],
            aggregateRecords: [ArchivistAggregateRecordSnapshot] = [],
            profiles: [ProfileSnapshot]? = [],
            graph: GedcomFamilyGraph? = nil,
            needsRecompile: [URL] = [],
            cyberBrain: CyberBrainIndex? = nil,
            selectedTemporalDate: ArchivistTemporalSelectionDateSnapshot? = nil,
            recordScope: RecordScope = .noSelection,
            speakers: Speakers = .none,
            assumedTreeBridges: [String: String] = [:]
        ) {
            self.presenceRecords = presenceRecords
            self.aggregateRecords = aggregateRecords
            self.profiles = profiles
            self.graph = graph
            // A loaded graph is never "waiting on a recompile".
            self.needsRecompile = graph == nil ? needsRecompile : []
            self.cyberBrain = cyberBrain
            self.selectedTemporalDate = selectedTemporalDate
            self.recordScope = recordScope
            self.speakers = speakers
            self.assumedTreeBridges = assumedTreeBridges
            self.continuationToken = UUID()
        }
    }

    struct Citation: Sendable, Equatable {
        let recordID: UUID
        let fullPath: String
        let filename: String
        let playbackSeconds: Double?
        let bases: [ArchivistEvidenceBasis]
    }

    struct KnowledgeCitation: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let attribution: String?
        let locator: String?
    }

    /// A media action the user asked for on ALREADY-CITED items ("play the
    /// first one"). The executor never opens media; the client performs it
    /// (app: player/Finder/Catalog row; shell: its media-action seam).
    struct MediaActionRequest: Sendable, Equatable {
        enum Kind: String, Sendable, Equatable {
            case play
            case reveal
            case show
        }
        let kind: Kind
        let citations: [Citation]
    }

    /// Something the client may offer as a next step (a chip in the app, a
    /// line in the shell). Never performed automatically — unless the
    /// result says so with `performsFirstOfferedAction` (a navigation ask
    /// such as "center the tree on Martha Lamson", 2026-08-29).
    enum OfferedAction: Sendable, Equatable {
        /// Open the Family Tree tab focused on this person.
        case openFamilyTree(personName: String)
        /// Focus an exact file-local GEDCOM pointer (duplicate names safe).
        case openFamilyTreePerson(personID: String, personName: String)
        /// Open the Family Tree tab filtered to this surname.
        case openFamilyTreeSurname(String)
        /// Open the Family Tree tab's "Get Family Tree" sheet (the
        /// getmyancestors GEDCOM pull, Rick 2026-08-25).
        case getFamilyTree
        /// Ask this question next (label is what the chip shows).
        case ask(question: String, label: String)
        /// Rebuild the compiled family tree from the pulls on disk (live
        /// miss #8, 2026-08-29). Offered with `performsFirstOfferedAction`
        /// so the app runs FamilyTreeLiveModel.recompile() itself and then
        /// re-asks the question; the shell and web list it as prose.
        case recompileFamilyTree
        /// Open the People tab (relationships overview, live miss #12).
        case openPeopleTab
        /// Open one of the main app tabs. Explicit navigation asks carry
        /// `performsFirstOfferedAction`; the same case also backs the chip.
        case openAppDestination(HallieAppNavigation.Destination)
        /// Focus the Family Tree on the person whose record shows two
        /// mothers / fathers (live miss #16), so the duplicate can be seen
        /// and merged upstream on FamilySearch.
        case showPossibleDuplicate(personID: String, personName: String)
    }

    struct Result: Sendable, Equatable {
        let route: Route
        let outcome: Outcome
        let prose: String
        let basisLine: String
        let queryDescription: String?
        let citations: [Citation]
        let knowledgeCitations: [KnowledgeCitation]
        let catalogPersonName: String?
        let clarification: Clarification?
        /// Exact match count for list answers (presence/cross), independent
        /// of the bounded citation page; nil for other routes.
        let matchCount: Int?
        let mediaAction: MediaActionRequest?
        let offeredActions: [OfferedAction]
        /// The typed facts behind `prose`, when the route builds one itself
        /// (presence lists, CyberBrain biographies). Nil = derive from the
        /// templated prose (see HallieAnswerPlan.derive).
        let answerPlan: HallieAnswerPlan?
        /// Who wrote `prose`: the deterministic template (always, until a
        /// client applies a verified composition) or the local model.
        let composedBy: HallieComposedBy
        /// The transcript-log text: the composed prose WITH its claim tags
        /// so the log shows which claim each sentence rests on. Nil = log
        /// `prose` as is.
        let transcriptText: String?
        /// Things to LOOK at alongside the prose — a photo, a crest, a
        /// lineage or tree card (2026-08-22). Presentation only: never part
        /// of the fact basis, never shown to the translator or composer.
        let attachments: [HallieAttachment]
        /// The user ASKED for the first offered action ("center the tree
        /// on X"): a client with that surface performs it without a tap;
        /// a client without one (shell, web) just lists it. Off by default.
        ///
        /// This Boolean is retained for source compatibility. Compound
        /// answers may reorder/concatenate offers, so clients must execute
        /// `immediateOfferedAction`, not assume array element zero is still
        /// the action the user requested.
        let performsFirstOfferedAction: Bool
        /// The exact offered action the user directly requested. Keeping its
        /// identity separate from `offeredActions` makes compound turns safe:
        /// an unrelated chip can precede this action without being run.
        let immediateOfferedAction: OfferedAction?
        /// Living or passed on for the person the answer is about
        /// (LifeStatus, 2026-09-01). Read by HallieAnswerPlan.derive when
        /// the route built no plan of its own, so the composer is told the
        /// tense for a templated kinship answer too. Nil = no verdict.
        let subjectLifeStatus: LifeStatus?
        /// The list this non-list answer still carries (a count, an age)
        /// for "and the newest?" — conversation memory keeps it. Nil = the
        /// memory derives it (list answers) or forgets it (2026-09-02).
        let refinableQuery: RefinableQuery?

        init(
            route: Route,
            outcome: Outcome,
            prose: String,
            basisLine: String,
            queryDescription: String?,
            citations: [Citation],
            knowledgeCitations: [KnowledgeCitation] = [],
            catalogPersonName: String?,
            clarification: Clarification? = nil,
            matchCount: Int? = nil,
            mediaAction: MediaActionRequest? = nil,
            offeredActions: [OfferedAction] = [],
            answerPlan: HallieAnswerPlan? = nil,
            composedBy: HallieComposedBy = .template,
            transcriptText: String? = nil,
            attachments: [HallieAttachment] = [],
            performsFirstOfferedAction: Bool = false,
            immediateOfferedAction: OfferedAction? = nil,
            subjectLifeStatus: LifeStatus? = nil,
            refinableQuery: RefinableQuery? = nil
        ) {
            self.route = route
            self.outcome = outcome
            self.prose = prose
            self.basisLine = basisLine
            self.queryDescription = queryDescription
            self.citations = citations
            self.knowledgeCitations = knowledgeCitations
            self.catalogPersonName = catalogPersonName
            self.clarification = clarification
            self.matchCount = matchCount
            self.mediaAction = mediaAction
            self.offeredActions = offeredActions
            self.answerPlan = answerPlan
            self.composedBy = composedBy
            self.transcriptText = transcriptText
            self.attachments = attachments
            let immediate = immediateOfferedAction
                ?? (performsFirstOfferedAction ? offeredActions.first : nil)
            self.immediateOfferedAction = immediate
            self.performsFirstOfferedAction = immediate != nil
            self.subjectLifeStatus = subjectLifeStatus
            self.refinableQuery = refinableQuery
        }

        /// The same answer with extra things to look at. Facts untouched.
        func adding(attachments extra: [HallieAttachment]) -> Result {
            guard !extra.isEmpty else { return self }
            return Result(
                route: route, outcome: outcome, prose: prose, basisLine: basisLine,
                queryDescription: queryDescription, citations: citations,
                knowledgeCitations: knowledgeCitations, catalogPersonName: catalogPersonName,
                clarification: clarification, matchCount: matchCount, mediaAction: mediaAction,
                offeredActions: offeredActions, answerPlan: answerPlan, composedBy: composedBy,
                transcriptText: transcriptText, attachments: attachments + extra,
                performsFirstOfferedAction: performsFirstOfferedAction,
                immediateOfferedAction: immediateOfferedAction,
                subjectLifeStatus: subjectLifeStatus,
                refinableQuery: refinableQuery)
        }

        /// The same answer carrying a PROVENANCE note — how Hallie read the
        /// question, not something she asserts about the family. The note is
        /// appended to the prose (what a template answer shows) and carried
        /// on the answer plan (so a model-phrased answer keeps it too, see
        /// HallieGroundedComposer). A route that built no plan of its own
        /// gets its derived plan pinned here, so the note can never end up
        /// inside a claim and be checked as if it were a fact.
        func carryingProvenance(_ note: String) -> Result {
            // Idempotent: the plan remembers the note it already carries,
            // so an answer wrapped twice never says the assumption twice.
            guard !note.isEmpty, answerPlan?.provenanceNote != note else { return self }
            let plan = (answerPlan ?? HallieAnswerPlan.derive(from: self))
                .carrying(provenance: note)
            return Result(
                route: route,
                outcome: outcome,
                prose: prose + note,
                basisLine: basisLine,
                queryDescription: queryDescription,
                citations: citations,
                knowledgeCitations: knowledgeCitations,
                catalogPersonName: catalogPersonName,
                clarification: clarification,
                matchCount: matchCount,
                mediaAction: mediaAction,
                offeredActions: offeredActions,
                answerPlan: plan,
                composedBy: composedBy,
                transcriptText: transcriptText,
                attachments: attachments,
                performsFirstOfferedAction: performsFirstOfferedAction,
                immediateOfferedAction: immediateOfferedAction,
                subjectLifeStatus: subjectLifeStatus,
                refinableQuery: refinableQuery)
        }

        /// The same answer with its prose replaced by a verified composition.
        /// Basis line, citations, chips, and every other field are untouched:
        /// only the wording changes, never the facts or their provenance.
        func applying(_ composition: HallieGroundedComposer.Outcome) -> Result {
            Result(
                route: route,
                outcome: outcome,
                prose: composition.displayText,
                basisLine: basisLine,
                queryDescription: queryDescription,
                citations: citations,
                knowledgeCitations: knowledgeCitations,
                catalogPersonName: catalogPersonName,
                clarification: clarification,
                matchCount: matchCount,
                mediaAction: mediaAction,
                offeredActions: offeredActions,
                answerPlan: answerPlan,
                composedBy: composition.composedBy,
                transcriptText: composition.composedBy == .model
                    ? composition.transcriptText : nil,
                attachments: attachments,
                performsFirstOfferedAction: performsFirstOfferedAction,
                immediateOfferedAction: immediateOfferedAction,
                subjectLifeStatus: subjectLifeStatus,
                refinableQuery: refinableQuery)
        }
    }

    struct Dependencies: Sendable {
        let executePresence: @Sendable (
            ArchivistPresenceQuery,
            [ArchivistPresenceRecordSnapshot]
        ) -> ArchivistPresenceResult
        let executeTemporal: @Sendable (
            ArchivistQueryAST.Temporal,
            ArchivistTemporalSubjectResolution,
            ArchivistTemporalSelectionDateSnapshot?
        ) -> ArchivistTemporalResult
        let executeAggregate: @Sendable (
            ArchivistAggregateQuery,
            [ArchivistAggregateRecordSnapshot],
            ArchivistAggregateIdentityCatalog
        ) -> ArchivistAggregateResult
        let executeGraph: @Sendable (
            ArchivistGraphQuery,
            ArchivistGraphInputs,
            ArchivistGraphSubjectSelection
        ) -> ArchivistGraphResult
        /// Two-person relationship: per-slot selections (already resolved
        /// to GEDCOM pointers by the identity flow) plus a floating one.
        let executeRelationship: @Sendable (
            ArchivistGraphQuery,
            ArchivistGraphInputs,
            [ArchivistGraphSubjectSelection],
            ArchivistGraphSubjectSelection
        ) -> ArchivistGraphResult

        init(
            executePresence: @escaping @Sendable (
                ArchivistPresenceQuery,
                [ArchivistPresenceRecordSnapshot]
            ) -> ArchivistPresenceResult,
            executeTemporal: @escaping @Sendable (
                ArchivistQueryAST.Temporal,
                ArchivistTemporalSubjectResolution,
                ArchivistTemporalSelectionDateSnapshot?
            ) -> ArchivistTemporalResult,
            executeAggregate: @escaping @Sendable (
                ArchivistAggregateQuery,
                [ArchivistAggregateRecordSnapshot],
                ArchivistAggregateIdentityCatalog
            ) -> ArchivistAggregateResult,
            executeGraph: @escaping @Sendable (
                ArchivistGraphQuery,
                ArchivistGraphInputs,
                ArchivistGraphSubjectSelection
            ) -> ArchivistGraphResult,
            executeRelationship: @escaping @Sendable (
                ArchivistGraphQuery,
                ArchivistGraphInputs,
                [ArchivistGraphSubjectSelection],
                ArchivistGraphSubjectSelection
            ) -> ArchivistGraphResult = { query, inputs, subjects, floating in
                ArchivistGraphExecutor.executeRelationship(
                    query, inputs: inputs, subjects: subjects,
                    floatingSelection: floating)
            }
        ) {
            self.executePresence = executePresence
            self.executeTemporal = executeTemporal
            self.executeAggregate = executeAggregate
            self.executeGraph = executeGraph
            self.executeRelationship = executeRelationship
        }

        static let production = Dependencies(
            executePresence: ArchivistPresenceExecutor.execute,
            executeTemporal: ArchivistTemporalExecutor.execute,
            executeAggregate: ArchivistAggregateExecutor.execute,
            executeGraph: { query, inputs, subject in
                ArchivistGraphExecutor.execute(
                    query, inputs: inputs, subject: subject)
            })
    }

    static func route(_ ast: ArchivistQueryAST) -> Route {
        switch ast {
        case .presence: return .presence
        case .temporal: return .temporal
        case .aggregate: return .aggregate
        case .graph: return .graph
        case .event: return .unsupportedEvent
        case .cross: return .cross
        case .record: return .record
        }
    }

    static func description(of ast: ArchivistQueryAST) -> String {
        switch route(ast) {
        case .presence: return "shape=presence"
        case .temporal: return "shape=temporal"
        case .aggregate: return "shape=aggregate"
        case .graph: return "shape=graph"
        case .cross: return "shape=cross"
        case .record: return "shape=record"
        case .unsupportedEvent: return "shape=event (unsupported)"
        case .followUp: return "follow-up"
        case .capability: return "capability"
        case .help: return "help"
        case .smalltalk: return "smalltalk"
        case .conversation: return "conversation"
        case .telling: return "telling"
        case .reset: return "reset"
        }
    }

    /// Transcript-log / UI label for a route. One spelling, shared by the app
    /// window and the shell so the log never drifts between clients.
    static func label(_ route: Route) -> String {
        switch route {
        case .presence: return "presence"
        case .temporal: return "temporal"
        case .aggregate: return "aggregate"
        case .graph: return "graph"
        case .cross: return "cross"
        case .record: return "record"
        case .unsupportedEvent: return "unsupported-event"
        case .followUp: return "follow-up"
        case .capability: return "capability"
        case .help: return "help"
        case .smalltalk: return "smalltalk"
        case .conversation: return "conversation"
        case .telling: return "telling"
        case .reset: return "reset"
        }
    }

    static func label(_ outcome: Outcome) -> String {
        switch outcome {
        case .answered: return "answered"
        case .declined: return "declined"
        case .unsupported: return "unsupported"
        case .needsClarification: return "needs-clarification"
        case .failed: return "failed"
        case .repaired: return "repaired"
        }
    }

    /// Executes exactly one validated AST. Detached work receives only
    /// immutable Sendable projections and bounded executor closures.
    static func execute(
        _ ast: ArchivistQueryAST,
        context: Context
    ) async throws -> Result {
        try await execute(
            Request(intent: Intent(
                originalQuestion: "", ast: ast, playAfterAnswer: false)),
            context: context,
            dependencies: .production)
    }

    static func execute(
        _ ast: ArchivistQueryAST,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        try await execute(
            Request(intent: Intent(
                originalQuestion: "", ast: ast, playAfterAnswer: false)),
            context: context,
            dependencies: dependencies)
    }

    static func execute(
        _ request: Request,
        context: Context
    ) async throws -> Result {
        try await execute(request, context: context, dependencies: .production)
    }

    static func `continue`(
        pending: Clarification,
        selecting selectedID: CandidateID,
        context: Context
    ) async throws -> Result {
        guard pending.continuationToken == context.continuationToken,
              let candidate = pending.candidates.first(where: {
                  $0.id == selectedID
              }),
              pending.stage.accepts(selectedID.source),
              selectionIsCurrent(candidate, context: context) else {
            return invalidContinuationResult(for: pending.intent.ast)
        }
        return try await execute(
            Request(intent: pending.intent, selectedIdentity: selectedID),
            context: context)
    }

    static func execute(
        _ request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        try Task.checkCancellation()
        let ast = request.intent.ast
        switch ast {
        case .presence(let payload):
            // "photos of X" about a family-tree person: portrait /
            // photography floor / which-one chips, never a catalog search
            // (+PhotoAsk). Nil = not a photo ask about a tree person.
            if let photo = photoAsk(payload, request: request, context: context) {
                return photo
            }
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            return try await executePresenceLike(
                payload, route: .presence, request: request,
                context: context, dependencies: dependencies)

        case .cross(let payload):
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            // Spoken terms and visible/topic terms are both keyword
            // constraints on the presence executor: every keyword must be
            // proven by SOME field (transcript, caption, filename, …) and
            // the basis names which. Nothing is coerced or widened.
            let merged = ArchivistQueryAST.Presence(
                people: payload.people,
                yearStart: payload.yearStart,
                yearEnd: payload.yearEnd,
                mediaKind: payload.mediaKind,
                keywords: (payload.keywords ?? []) + (payload.transcript ?? []))
            return try await executePresenceLike(
                merged, route: .cross, request: request,
                context: context, dependencies: dependencies)

        case .temporal(let payload):
            guard let profiles = context.profiles else {
                return unavailableProfilesResult(route: .temporal)
            }
            let question = request.intent.originalQuestion
            let ask = ArchivistTemporalExecutor.detectAsk(in: question)
            // "the boys" / "my dad" → People profiles through the People-tab
            // relationships (+TemporalSubjects). Fresh turns only: a
            // which-one chip already carries the chosen profile id.
            if request.selectedIdentity == nil {
                switch TemporalSubjects.resolve(
                    question: question, subject: payload.subject, context: context) {
                case .declined(let prose, let basis):
                    return Result(
                        route: .temporal, outcome: .declined,
                        prose: prose, basisLine: basis,
                        queryDescription: "shape=temporal operation=age subject=\(payload.subject)",
                        citations: [], catalogPersonName: nil)
                case .resolved(let group):
                    return groupTemporalResult(
                        group, payload: payload, ask: ask, question: question, context: context)
                case .notApplicable:
                    break
                }
            }
            let resolution = temporalResolution(
                payload.subject, profiles: profiles,
                selectedIdentity: request.selectedIdentity)
            // A born-yet / would-have-been ask, or a person who had passed
            // on before the record was made, is phrased by the group
            // composer even for one person ("Dad would have been 58 in
            // 1994 — he passed on in 1977"); a plain age keeps its wording.
            if case .resolved(_, let subject) = resolution,
               ask != .age || passedOnBeforeReference(subject, payload.reference, context: context) {
                return groupTemporalResult(
                    TemporalSubjects.Resolved(
                        phrase: subject.canonicalName, subjects: [subject], note: ""),
                    payload: payload, ask: ask, question: question, context: context)
            }
            if case .ambiguous(_, let candidates) = resolution {
                let choices = profileCandidates(candidates)
                let clarification = Clarification(
                    intent: request.intent,
                    stage: .profileIdentity,
                    candidates: choices,
                    continuationToken: context.continuationToken)
                return Result(
                    route: .temporal,
                    outcome: .needsClarification,
                    prose: "Which \(payload.subject) do you mean?",
                    basisLine: "Basis: subject resolution matched multiple People profiles.",
                    queryDescription:
                        "shape=temporal operation=age subject=\(payload.subject)",
                    citations: [],
                    catalogPersonName: nil,
                    clarification: clarification)
            }
            // "how old is Donna" with NOTHING selected (eval ft022,
            // 2026-09-01): present tense means today, from the profile
            // birthdate (or "about N" from a tree birth year) — or the age
            // at death for someone who has passed on. Past tense and "in
            // this video" keep asking for a dated video or a year.
            let result: ArchivistTemporalResult
            if payload.reference == .currentSelection,
               context.selectedTemporalDate == nil,
               ArchivistTemporalExecutor.isPresentTenseAge(request.intent.originalQuestion) {
                let approximate = birthYear(of: payload.subject, context: context).map {
                    ArchivistTemporalExecutor.ApproximateBirthYear(year: $0.year, source: $0.source)
                }
                result = ArchivistTemporalExecutor.executePresentAge(
                    payload, subject: resolution, approximateBirthYear: approximate)
            } else {
                result = dependencies.executeTemporal(
                    payload, resolution, context.selectedTemporalDate)
            }
            // An answered age still carries "videos of that person" for
            // "and the most recent one?" (conversation memory).
            var refinable: RefinableQuery?
            if result.value != nil, case .resolved(_, let subject) = resolution {
                refinable = .list(
                    .presence(.init(people: [subject.canonicalName], mediaKind: .video)),
                    anyOfPeople: false)
            }
            return Result(
                route: .temporal,
                outcome: result.value == nil ? .declined : .answered,
                prose: result.prose,
                basisLine: result.basisLine,
                queryDescription:
                    "shape=temporal operation=age subject=\(payload.subject)",
                citations: [],
                catalogPersonName: nil,
                refinableQuery: refinable)

        case .aggregate(let payload):
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            guard let profiles = context.profiles else {
                return unavailableProfilesResult(route: .aggregate)
            }
            let query = ArchivistAggregateQuery(payload)
            let records = context.aggregateRecords
            let identities = aggregateIdentities(profiles: profiles)
            let execute = dependencies.executeAggregate
            let result = try await detached {
                execute(query, records, identities)
            }
            let answer = result.factualAnswer
            let citations = answer.rankings.flatMap(\.sampleCitations)
                .prefix(25)
                .map { normalize($0) }
            return Result(
                route: .aggregate,
                outcome: result.conclusion == .ranked ? .answered : .declined,
                prose: answer.prose,
                basisLine: answer.basisLine,
                queryDescription: result.interpretedQuery,
                citations: citations,
                catalogPersonName: nil)

        case .graph(let rawPayload):
            // The lineage common-ancestor shape resolves both names through
            // the lineage chain (owner pin, CyberBrain alias, tree index) —
            // not the graph preflight — and carries which-one chips that
            // resume it (2026-08-29).
            if rawPayload.operation == .commonAncestor {
                let names = rawPayload.people.map { name -> String? in
                    HallieLineageAnswer.isFirstPerson(name) ? nil : name
                }
                guard names.count == 2 else {
                    return invalidContinuationResult(for: ast)
                }
                return HallieLineageAnswer.commonAncestor(
                    names[0], names[1], request: request, context: context)
                    ?? invalidContinuationResult(for: ast)
            }
            // Everything that must happen BEFORE a family-tree lookup on a
            // fresh turn — wedding-date guard, bare-pronoun guard, "my dad"
            // rebinding, "I"/"you" binding — lives in +GraphPreflight; a
            // continuation's intent already carries bound names.
            if request.selectedIdentity == nil, request.intent.speakerBindings.isEmpty,
               let handled = try await graphPreflight(
                   rawPayload, request: request, context: context, dependencies: dependencies) {
                return handled
            }
            let result = try await executeGraphCase(
                rawPayload, request: request, context: context,
                dependencies: dependencies)
            // The binding is evidence: say what "you" and "I" meant.
            if let note = bindingNote(request.intent.speakerBindings) {
                return result.prefixingBasis(note)
            }
            return result

        case .record(let payload):
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            return executeRecord(payload, request: request, context: context)

        case .event:
            guard request.selectedIdentity == nil else {
                return invalidContinuationResult(for: ast)
            }
            return Result(
                route: .unsupportedEvent,
                outcome: .unsupported,
                prose: "Event queries are not supported yet; I did not run a broader search.",
                basisLine: "Basis: QueryAST shape=event has no deterministic executor.",
                queryDescription: nil,
                citations: [],
                catalogPersonName: nil)
        }
    }

    /// True when the subject's recorded death is before the reference the
    /// question points at (a selected record's date or an explicit year).
    private static func passedOnBeforeReference(
        _ subject: ArchivistTemporalSubjectSnapshot,
        _ reference: ArchivistQueryAST.Temporal.Reference,
        context: Context
    ) -> Bool {
        guard let death = subject.deathdate else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let deathYear = utc.component(.year, from: death)
        switch reference {
        case .explicitYear(let year):
            return year > deathYear
        case .currentSelection:
            guard let selection = context.selectedTemporalDate else { return false }
            if selection.precision == .year {
                return utc.component(.year, from: selection.date) > deathYear
            }
            return selection.date > death
        }
    }

    /// Ages / born-yet / would-have-been for one or several resolved
    /// people, against the selected record, an explicit year, or today.
    private static func groupTemporalResult(
        _ group: TemporalSubjects.Resolved,
        payload: ArchivistQueryAST.Temporal,
        ask: ArchivistTemporalExecutor.Ask,
        question: String,
        context: Context
    ) -> Result {
        let names = group.subjects.map(\.canonicalName)
        let description = "shape=temporal operation=age subject=\(payload.subject)"
            + " resolved=\(names.joined(separator: ","))"
        let reference: ArchivistTemporalExecutor.GroupReference
        switch payload.reference {
        case .explicitYear(let year):
            reference = .explicitYear(year)
        case .currentSelection:
            if let selection = context.selectedTemporalDate {
                reference = .selection(selection)
            } else if ask != .bornYet, ArchivistTemporalExecutor.isPresentTenseAge(question) {
                // "how old are the boys now" with nothing selected: today.
                reference = .today(Date())
            } else {
                let example = names.count == 1
                    ? "how old was \(names[0]) in 1995?"
                    : "how old were \(group.phrase.replacingOccurrences(of: "'", with: "")) in 1995?"
                var basis = "Basis: the selected catalog record has no dated evidence."
                if !group.note.isEmpty { basis = "Basis: \(group.note); " + basis.dropFirst("Basis: ".count) }
                return Result(
                    route: .temporal, outcome: .declined,
                    prose: "I need a dated video to count from — select one in the Catalog and ask again, or give me a year (“\(example)”).",
                    basisLine: basis, queryDescription: description,
                    citations: [], catalogPersonName: nil)
            }
        }
        let result = ArchivistTemporalExecutor.executeGroup(
            subjects: group.subjects, phrase: group.phrase, ask: ask, reference: reference)
        var basis = result.basisLine
        if !group.note.isEmpty {
            basis = "Basis: \(group.note); " + basis.dropFirst("Basis: ".count)
        }
        let answered = result.value != nil
        return Result(
            route: .temporal,
            outcome: answered ? .answered : .declined,
            prose: result.prose,
            basisLine: basis,
            queryDescription: description,
            citations: [],
            catalogPersonName: names.count == 1 ? names[0] : nil,
            refinableQuery: answered
                ? .list(.presence(.init(people: names, mediaKind: .video)), anyOfPeople: names.count > 1)
                : nil)
    }

    /// The graph route proper, after pronoun binding. Split out so the
    /// binding note can be prefixed on whichever of the several returns
    /// answers (CyberBrain biography, bridged kinship, plain GEDCOM,
    /// relationship).
    private static func executeGraphCase(
        _ rawPayload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        let ast = request.intent.ast
        // "show ricks family tree": a possessive typed without its
        // apostrophe. When nobody knows "ricks" but someone knows "rick",
        // read it that way — visibly, in the basis line — instead of
        // declaring the person unknown.
        let (payload, singularNote) = singularizedGraphPayload(
            rawPayload, request: request, context: context)
        if let singularNote {
            let inner = try await executeGraphCase(
                payload,
                request: Request(intent: request.intent.replacing(ast: .graph(payload))),
                context: context, dependencies: dependencies)
            return inner.prefixingBasis(singularNote)
        }
        if payload.operation == .relationship {
            return try await executeRelationship(
                payload: payload, request: request, context: context,
                dependencies: dependencies)
        }
        // The model read "rick's grandma muriel" as TWO people (live
        // 2026-08-26). A kinship with two names is one person named twice:
        // the second name filters the relation set. Same answerer as the
        // model-free parse; never the executor's people-count guard.
        if payload.operation == .kinship, payload.people.count == 2,
           let relation = payload.relation,
           let kin = HallieKinshipApposition.Kin(astRelation: relation, side: payload.side) {
            let owner = payload.people[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let isPronoun = ["me", "i", "my", "myself", "you"].contains(owner.lowercased())
            let apposition = HallieKinshipApposition(
                possessor: isPronoun ? nil : HallieLineageQuestion.capitalizedName(owner), kin: kin,
                relationWord: (payload.side.map { "\($0.rawValue) " } ?? "") + relation.rawValue.replacingOccurrences(of: "-", with: " "),
                name: payload.people[1].trimmingCharacters(in: .whitespacesAndNewlines))
            return HallieLineageAnswer.kinshipApposition(apposition, context: context)
        }
        // CyberBrain answers only when it knows the requested identity.
        // A `nil` here means CyberBrain has no opinion, and the turn
        // continues on the pre-existing profiles + GEDCOM path exactly
        // as it would with no CyberBrain installed.
        if payload.operation == .biography,
           let cyberBrain = context.cyberBrain,
           let result = try await executeCyberBrainBiography(
               payload: payload,
               request: request,
               context: context,
               index: cyberBrain) {
            return result
        }
        // Kinship / birth / death get the SAME alias bridge as biography:
        // a CyberBrain nickname ("rick") resolves to its GEDCOM pointer,
        // ambiguity yields the same distinct-label chips, and the typed
        // continuation lands here again. `nil` = CyberBrain has no
        // opinion; fall through to the profiles + GEDCOM path.
        if payload.operation != .biography,
           let cyberBrain = context.cyberBrain,
           let result = try await executeCyberBrainBridgedGraph(
               payload: payload,
               request: request,
               context: context,
               index: cyberBrain,
               dependencies: dependencies) {
            return result
        }
        // The tree is on disk but the compiled generation was refused by
        // this version (live miss #8): say so and offer the recompile —
        // never "I don't have a tree", and not the People-tab fallback
        // either, since the re-ask after the recompile answers properly.
        if let recompile = HallieLineageAnswer.needsRecompileResult(context, queryDescription: "shape=graph") {
            return recompile
        }
        // No tree at all, but the People tab knows the name: answer from
        // the profile (see +PeopleTab) rather than "I don't have a tree" —
        // or ask which one when several profiles claim the spelling.
        if context.graph == nil, let typed = payload.people.first,
           let result = peopleTabResult(
               typed: typed, payload: payload, request: request, context: context,
               queryDescription: graphQueryDescription(payload)) {
            return result
        }
        guard let graph = context.graph else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I don't have an imported family tree, so I can't answer that reliably.",
                basisLine: "Basis: no readable GEDCOM was available.",
                queryDescription: "shape=graph",
                citations: [],
                catalogPersonName: nil)
        }
        let query = ArchivistGraphQuery(payload)
        let queryDescription = graphQueryDescription(payload)
        let inputs = ArchivistGraphInputs(
            graph: graph,
            profiles: (context.profiles ?? []).map {
                ArchivistGraphProfileSnapshot(
                    stableID: $0.stableID,
                    canonicalName: $0.canonicalName,
                    aliases: $0.aliases,
                    kinships: $0.kinships,
                    sex: $0.sex,
                    birthdate: $0.birthdate,
                    deathdate: $0.deathdate,
                    uuid: $0.uuid,
                    treeIdentity: $0.treeIdentity)
            },
            ownerName: context.speakers.ownerName)
        let selection: ArchivistGraphSubjectSelection
        // Step 0 of the owner chain (2026-08-26): a configured FamilySearch
        // ID pins the owner's own spelling to one record before any name
        // matching — never applied to anyone else's name.
        var ownerNote: String?
        switch request.selectedIdentity {
        case nil:
            if let typed = payload.people.first,
               HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName),
               let pinned = graph.person(familySearchID: context.speakers.ownerFamilySearchID) {
                selection = .gedcomPersonID(pinned.id)
                ownerNote = "“you” = \(pinned.name) (FamilySearch ID \(pinned.familySearchID ?? ""))."
            } else {
                selection = .unresolved
            }
        case .profileStableID(let id): selection = .profileStableID(id)
        case .gedcomPersonID(let id): selection = .gedcomPersonID(id)
        case .cyberBrainPersonID:
            return invalidContinuationResult(for: ast)
        }
        let execute = dependencies.executeGraph
        var result = try await detached {
            execute(query, inputs, selection)
        }
        // The owner chain (2026-08-26): the subject is one of the owner's
        // own spellings ("rick", "Rick Breen") and the tree could not settle
        // on one record — several Richards, or none under that spelling —
        // so pin the owner's record (root tie-break) and run again. Said in
        // the basis line; never applied to anyone else's name.
        if request.selectedIdentity == nil, ownerNote == nil,
           result.conclusion == .personNotFound || !result.ambiguityCandidates.isEmpty,
           let typed = payload.people.first,
           HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName),
           case .one(let owner, let note) = HallieOwnerResolver.resolve(
               typed, graph: graph, familySearchID: context.speakers.ownerFamilySearchID) {
            result = try await detached {
                execute(query, inputs, .gedcomPersonID(owner.id))
            }
            ownerNote = note.replacingOccurrences(of: "Basis: ", with: "")
        }
        // The pinned owner ID is stale (codex #707): say so in the basis
        // line rather than letting the name/root chain guess at "me".
        if request.selectedIdentity == nil, ownerNote == nil,
           let typed = payload.people.first,
           HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName),
           let stale = HallieOwnerResolver.stalePinLine(
               familySearchID: context.speakers.ownerFamilySearchID, graph: graph) {
            ownerNote = stale
        }
        // LIVE MISS #11 (2026-08-29): "pa oc'connor" — the SURNAME is in
        // the tree (by spelling recovery) and the given token is a family
        // nickname. An alias bridges it to one person, a member's own name
        // answers or asks which one, and otherwise the surname roster is
        // offered below — never the bare decline. See +SurnameRoster.
        var rosterNote: String?
        var rosterReply: Result?
        if request.selectedIdentity == nil, ownerNote == nil,
           result.conclusion == .personNotFound,
           let typed = payload.people.first,
           let step = surnameRosterStep(
               typed: typed, request: request, context: context,
               graph: graph, queryDescription: queryDescription) {
            switch step {
            case .resolved(let selection, let note):
                result = try await detached {
                    execute(query, inputs, selection)
                }
                rosterNote = note
            case .replyNow(let reply):
                return reply
            case .roster(let reply):
                rosterReply = reply
            }
        }
        func withOwnerNote(_ r: Result) -> Result {
            var out = r
            if let rosterNote { out = out.prefixingBasis(rosterNote) }
            if let ownerNote { out = out.prefixingBasis(ownerNote) }
            return out
        }
        if !result.ambiguityCandidates.isEmpty {
            let choices = result.ambiguityCandidates.map { candidate in
                switch candidate.id {
                case .profileStableID(let id):
                    return Candidate(
                        id: .profileStableID(id),
                        canonicalName: candidate.canonicalName,
                        label: candidate.label)
                case .gedcomPersonID(let id):
                    return Candidate(
                        id: .gedcomPersonID(id),
                        canonicalName: candidate.canonicalName,
                        label: candidate.label)
                }
            }
            let stage: ClarificationStage = choices[0].source == .peopleProfile
                ? .profileIdentity : .gedcomPerson
            // Family-tree namesakes: anchors first, capped, or the ask for
            // a surname/year (HallieWhichOne, 2026-08-29) — the same rule
            // as the two-person route.
            if stage == .gedcomPerson, let typed = payload.people.first {
                let people = choices.compactMap { choice -> GedcomFamilyGraph.Person? in
                    if case .gedcomPersonID(let id) = choice.id { return graph.people[id] }
                    return nil
                }
                let arrangement = HallieWhichOne.arrange(
                    people, graph: graph,
                    ownerFamilySearchID: context.speakers.ownerFamilySearchID)
                let shown = arrangement.shown.map { person in
                    Candidate(
                        id: .gedcomPersonID(person.id),
                        canonicalName: person.name,
                        label: ArchivistBiographyPolicy.disambiguationCandidate(for: person).label)
                }
                return withOwnerNote(Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: HallieWhichOne.prose(
                        typed: typed, arrangement: arrangement, labels: shown.map(\.label)),
                    basisLine: HallieWhichOne.basis(typed: typed, arrangement: arrangement),
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: arrangement.offersChips
                        ? Clarification(
                            intent: request.intent, stage: stage, candidates: shown,
                            continuationToken: context.continuationToken)
                        : nil))
            }
            let clarification = Clarification(
                intent: request.intent,
                stage: stage,
                candidates: choices,
                continuationToken: context.continuationToken)
            return Result(
                route: .graph,
                outcome: .needsClarification,
                prose: result.prose,
                basisLine: result.basisLine,
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil,
                clarification: clarification)
        }
        // An assumed bridge is ALWAYS said out loud, in the answer itself.
        //
        // It used to be moved to the basis whenever the route carried a
        // claim plan, on the theory that an aside in the prose would be
        // lost to the composer. That made the aside disappear from "who is
        // Rick's dad?" the day the overlay kinship route gained a plan
        // (35336f98). It is provenance, not a claim: `carryingProvenance`
        // appends it to the prose and pins it on the plan, so the composer
        // re-attaches it and the verifier is never asked to prove it.
        let taken = assumedBridges(result, context: context)
        let aside = taken.isEmpty ? "" : " (taking \(taken.joined(separator: "; ")))"
        let base = Result(
            route: .graph,
            outcome: result.conclusion == .answered ? .answered : .declined,
            prose: result.prose,
            basisLine: result.basisLine,
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: result.catalogPersonName,
            offeredActions: graphOffers(result),
            answerPlan: result.answerPlan,
            subjectLifeStatus: result.subjectLifeStatus)
            .carryingProvenance(aside)
        // Where the tree falls short, say how far it reaches and what the
        // family has told Hallie (quoted, attributed) — see +FamilyKnowledge.
        if result.conclusion == .personNotFound, let typed = payload.people.first {
            // Not in the tree — but is it someone from the People tab? Then
            // the profile answers (name, alternate names, birth date, tags);
            // a chip chosen after "which one?" names the profile directly.
            if let result = peopleTabResult(
                typed: typed, payload: payload, request: request, context: context,
                queryDescription: queryDescription) {
                return result
            }
            // A near miss ("Jusson Lambe") → "Did you mean Judson Lamb?" as a
            // clarification with the real people as choices — the existing
            // chip/typed-reply continuation finishes the turn. Never a
            // silent substitution (Rick 2026-08-24).
            let suggestions = HallieNameSuggestion.suggest(
                typed, graph: graph,
                profiles: (context.profiles ?? []).map {
                    (stableID: $0.stableID, name: $0.canonicalName, aliases: $0.aliases)
                })
            if !suggestions.isEmpty {
                let choices = suggestions.map { suggestion -> Candidate in
                    switch suggestion.identity {
                    case .gedcom(let id):
                        return Candidate(id: .gedcomPersonID(id),
                                         canonicalName: suggestion.name, label: suggestion.label)
                    case .profile(let stableID):
                        return Candidate(id: .profileStableID(stableID),
                                         canonicalName: suggestion.name, label: suggestion.label)
                    }
                }
                let prose = choices.count == 1
                    ? "I don't find \u{201C}\(typed)\u{201D} — did you mean \(choices[0].canonicalName)?"
                    : "I don't find \u{201C}\(typed)\u{201D} — did you mean one of these?"
                return Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: prose,
                    basisLine: "Basis: no exact match in the family tree or People tab; the closest recorded names are offered, nothing was assumed.",
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: Clarification(
                        intent: request.intent,
                        stage: .suggestedIdentity,
                        candidates: choices,
                        continuationToken: context.continuationToken))
            }
            // The surname roster (LIVE MISS #11) — after the People tab and
            // the near-miss suggestion, before the bare decline.
            if let rosterReply { return rosterReply }
            return FamilyKnowledgeSupplement.notFoundOffer(base, typed: typed, graph: graph)
        }
        return withOwnerNote(FamilyKnowledgeSupplement.apply(
            to: base, payload: payload, graphResult: result,
            graph: graph, context: context))
    }

    /// The privacy ceiling the app grants its own Family Archivist. Every
    /// planner call names it explicitly so the boundary is visible here, not
    /// buried in a Core default.
    static let appPrivacyCeiling: CyberBrainItem.Privacy = .private

    /// Returns `nil` when CyberBrain does not know the requested identity so
    /// the caller falls through to the profiles + GEDCOM path. That path owns
    /// nickname → profile → GEDCOM bridging, profile ambiguity/conflict
    /// handling, and `.profileStableID` / `.gedcomPersonID` continuations;
    /// CyberBrain must not shadow it with a weaker name-only GEDCOM lookup.
    private static func executeCyberBrainBiography(
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        index: CyberBrainIndex
    ) async throws -> Result? {
        guard let requestedName = payload.people.first else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I need a person's name before I can build a biography.",
                basisLine: "Basis: no biography subject was supplied.",
                queryDescription: "shape=graph operation=biography",
                citations: [],
                catalogPersonName: nil)
        }
        let graph = context.graph
        let privacyCeiling = appPrivacyCeiling
        let cyberBrainKnowsName: Bool
        if case .notFound = index.resolve(requestedName) {
            cyberBrainKnowsName = false
        } else {
            cyberBrainKnowsName = true
        }
        let plan: CyberBrainAnswerPlan
        switch request.selectedIdentity {
        case nil:
            guard cyberBrainKnowsName else { return nil }
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    personName: requestedName,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .cyberBrainPersonID(let personID):
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    personID: personID,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .gedcomPersonID(let personID):
            // A GEDCOM chip offered by the profiles + GEDCOM path continues
            // there. If CyberBrain does know the name (a chip from another
            // origin), the typed pointer is honored directly — never
            // re-resolved through display text.
            guard cyberBrainKnowsName else { return nil }
            plan = try await detached {
                CyberBrainBiographyPlanner.plan(
                    gedcomPersonID: personID,
                    index: index,
                    graph: graph,
                    privacyCeiling: privacyCeiling)
            }
        case .profileStableID:
            return nil
        }

        let queryDescription =
            "shape=graph operation=biography person=\(requestedName)"
        let knowledgeCitations = plan.sourceCitations.map {
            KnowledgeCitation(
                id: $0.id,
                title: $0.title,
                attribution: $0.attribution,
                locator: $0.locator)
        }
        if plan.answerState == .ambiguous {
            let choices = plan.ambiguityCandidates.map { candidate -> Candidate in
                if candidate.source == .gedcom {
                    // Same-name family-tree people (Sr./Jr.) need labels the
                    // user can tell apart; mirror the graph path's
                    // birth/death or pointer suffix.
                    if let graph, let person = graph.people[candidate.id] {
                        return gedcomCandidate(person, graph: graph)
                    }
                    return Candidate(
                        id: .gedcomPersonID(candidate.id),
                        canonicalName: candidate.canonicalName,
                        label: "\(candidate.canonicalName) (\(candidate.id))")
                }
                return Candidate(
                    id: .cyberBrainPersonID(candidate.id),
                    canonicalName: candidate.canonicalName,
                    label: cyberBrainLabel(candidate, plan: plan,
                                           index: index, graph: graph))
            }
            let stage: ClarificationStage = choices.first?.source == .gedcom
                ? .gedcomPerson : .cyberBrainPerson
            return Result(
                route: .graph,
                outcome: .needsClarification,
                prose: CyberBrainDeterministicComposer.compose(plan),
                basisLine: "Basis: identity was not resolved; no biography claims were selected.",
                queryDescription: queryDescription,
                citations: [],
                knowledgeCitations: knowledgeCitations,
                catalogPersonName: nil,
                clarification: Clarification(
                    intent: request.intent,
                    stage: stage,
                    candidates: choices,
                    continuationToken: context.continuationToken))
        }

        let answered = plan.answerState == .answered
            || plan.answerState == .disputed
        let prose = CyberBrainDeterministicComposer.compose(plan)
        let life = cyberBrainSubjectLifeStatus(
            subject: plan.subject, requestedName: requestedName, index: index, context: context)
        return Result(
            route: .graph,
            outcome: answered ? .answered : .declined,
            prose: prose,
            basisLine: knowledgeCitations.isEmpty
                ? "Basis: Breen Family CyberBrain; no supporting source was selected."
                : "Basis: Breen Family CyberBrain; \(knowledgeCitations.count) supporting source\(knowledgeCitations.count == 1 ? "" : "s").",
            queryDescription: queryDescription,
            citations: [],
            knowledgeCitations: knowledgeCitations,
            catalogPersonName: answered ? plan.subject : nil,
            // The approved CyberBrain claims, verbatim, are the only thing a
            // model may rephrase for this answer (docs/cyberbrain_design.md §9).
            answerPlan: answered
                ? HallieAnswerPlan.biography(plan, fallbackText: prose, subjectLifeStatus: life)
                : nil,
            subjectLifeStatus: answered ? life : nil)
    }

    /// Living or passed on for a CyberBrain biography subject (LifeStatus,
    /// 2026-09-01): the tree record CyberBrain links the person to, and a
    /// death the People-tab profile of the same name records. Nil when the
    /// subject has neither a tree record nor a profile — then nothing about
    /// tense is said to the composer.
    static func cyberBrainSubjectLifeStatus(
        subject: String,
        requestedName: String,
        index: CyberBrainIndex,
        context: Context
    ) -> LifeStatus? {
        var treePerson: GedcomFamilyGraph.Person?
        for name in [subject, requestedName] where treePerson == nil {
            if case .resolved(let person) = index.resolve(name),
               let gedcomID = person.gedcomPersonID {
                treePerson = context.graph?.people[gedcomID]
            }
        }
        // The profile that claims the name outright; two claimants = none.
        let wanted = Set([subject, requestedName].map(PersonResolver.normalize))
        let claimants = (context.profiles ?? []).filter { snapshot in
            ([snapshot.canonicalName] + snapshot.aliases)
                .contains { wanted.contains(PersonResolver.normalize($0)) }
        }
        let profile = claimants.count == 1 ? claimants[0] : nil
        guard treePerson != nil || profile != nil else { return nil }
        return LifeStatus.ofProfile(
            deathdate: profile?.deathdate, bridged: treePerson, in: context.graph)
    }

    /// Non-biography graph operations (kinship, birth, death) routed through
    /// CyberBrain identity resolution and then answered by the deterministic
    /// GEDCOM executor by pointer. Returns `nil` when CyberBrain does not know
    /// the name (or knows it but has no family-tree link), so the caller
    /// continues on the profiles + GEDCOM path unchanged.
    private static func executeCyberBrainBridgedGraph(
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        index: CyberBrainIndex,
        dependencies: Dependencies
    ) async throws -> Result? {
        // Multi-subject and empty-name validation belongs to the graph
        // executor; only a single, non-blank name is bridged here.
        guard payload.people.count == 1,
              let requestedName = payload.people.first?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !requestedName.isEmpty,
              let graph = context.graph else {
            return nil
        }
        let queryDescription = graphQueryDescription(payload)

        let person: CyberBrainPerson
        switch request.selectedIdentity {
        case nil:
            switch index.resolve(requestedName) {
            case .notFound:
                return nil
            case .resolved(let resolved):
                guard resolved.gedcomPersonID.flatMap({ graph.people[$0] })
                        != nil else {
                    return nil
                }
                person = resolved
            case .ambiguous(let people):
                let linked = people.filter {
                    $0.gedcomPersonID.flatMap { graph.people[$0] } != nil
                }
                guard !linked.isEmpty else { return nil }
                let choices = linked.map { candidate in
                    Candidate(
                        id: .cyberBrainPersonID(candidate.id),
                        canonicalName: candidate.canonicalName,
                        label: bridgedLabel(candidate, among: linked,
                                            graph: graph))
                }
                return Result(
                    route: .graph,
                    outcome: .needsClarification,
                    prose: "Which \(requestedName) do you mean?",
                    basisLine: "Basis: Breen Family CyberBrain knows more than one person by that name; no family fact was selected.",
                    queryDescription: queryDescription,
                    citations: [],
                    catalogPersonName: nil,
                    clarification: Clarification(
                        intent: request.intent,
                        stage: .cyberBrainPerson,
                        candidates: choices,
                        continuationToken: context.continuationToken))
            }
        case .cyberBrainPersonID(let personID):
            guard let selected = index.person(id: personID) else {
                return invalidContinuationResult(for: request.intent.ast)
            }
            person = selected
        case .gedcomPersonID, .profileStableID:
            return nil
        }

        guard let gedcomID = person.gedcomPersonID,
              let gedcomPerson = graph.people[gedcomID] else {
            return Result(
                route: .graph,
                outcome: .declined,
                prose: "I know \(person.canonicalName) from the family archive, but they aren't linked to the imported family tree, so I can't answer that reliably.",
                basisLine: "Basis: Breen Family CyberBrain identity without a GEDCOM link; family tree not consulted.",
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil)
        }

        let query = ArchivistGraphQuery(payload)
        let inputs = ArchivistGraphInputs(
            graph: graph, profiles: [] as [ArchivistGraphProfileSnapshot])
        let execute = dependencies.executeGraph
        let result = try await detached {
            execute(query, inputs, .gedcomPersonID(gedcomID))
        }
        // Prepend the identity bridge to the executor's own basis line so the
        // answer states how "rick" became a GEDCOM person, mirroring the
        // profile-bridge wording on the profiles + GEDCOM path.
        let bridge = "Breen Family CyberBrain identity “"
            + requestedName + "” → “" + person.canonicalName + "” → GEDCOM “"
            + gedcomPerson.name + "”; "
        var basis = result.basisLine
        for prefix in ["Basis: ", "Checked: "] where basis.hasPrefix(prefix) {
            basis = prefix + bridge + basis.dropFirst(prefix.count)
            break
        }
        let base = Result(
            route: .graph,
            outcome: result.conclusion == .answered ? .answered : .declined,
            prose: result.prose,
            basisLine: basis,
            queryDescription: queryDescription,
            citations: [],
            catalogPersonName: result.catalogPersonName,
            offeredActions: graphOffers(result),
            answerPlan: result.answerPlan,
            subjectLifeStatus: result.subjectLifeStatus)
        // "who are Rick's sons" arrives here (CyberBrain knows "rick"); the
        // tree stops in 1959, but the family has told Hallie about the sons.
        return FamilyKnowledgeSupplement.apply(
            to: base, payload: payload, graphResult: result,
            graph: graph, context: context)
    }

    /// The People tab's identity verdict is PersonResolver's (#778): the
    /// one owner of a spelling answers from its profile; several owners ask
    /// "which one?" with People chips — never a silent canonical-name pick.
    /// `nil` = nobody in the People tab goes by it; the caller carries on.
    private static func peopleTabResult(
        typed: String,
        payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context,
        queryDescription: String
    ) -> Result? {
        switch PeopleTab.claim(typed, selected: request.selectedIdentity,
                               in: context.profiles ?? []) {
        case .one(let profile):
            return PeopleTab.answer(profile: profile, payload: payload, context: context,
                                    queryDescription: queryDescription)
        case .ambiguous(let profiles):
            return Result(
                route: .graph,
                outcome: .needsClarification,
                prose: "Which \(typed) do you mean?",
                basisLine: "Checked: People profiles — more than one goes by “\(typed)”; no person was selected.",
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: nil,
                clarification: Clarification(
                    intent: request.intent,
                    stage: .profileIdentity,
                    candidates: PeopleTab.candidates(profiles),
                    continuationToken: context.continuationToken))
        case .none:
            return nil
        }
    }

    static func graphQueryDescription(_ payload: ArchivistQueryAST.Graph) -> String {
        var parts = ["shape=graph operation=\(payload.operation.rawValue)"]
        if !payload.people.isEmpty {
            parts.append("person=\(payload.people.joined(separator: ","))")
        }
        if let relation = payload.relation { parts.append("relation=\(relation.rawValue)") }
        if let side = payload.side { parts.append("side=\(side.rawValue)") }
        if let surname = payload.surname { parts.append("surname=\(surname)") }
        return parts.joined(separator: " ")
    }

    static func familyTreeOffers(_ focus: ArchivistFamilyTreeFocus?) -> [OfferedAction] {
        switch focus {
        case nil: return []
        case .person(let name): return [.openFamilyTree(personName: name)]
        case .surname(let surname): return [.openFamilyTreeSurname(surname)]
        }
    }

    /// The tree-focus offer plus the duplicate-parent chip when the card
    /// raised one (live miss #16).
    static func graphOffers(_ result: ArchivistGraphResult) -> [OfferedAction] {
        var offers = familyTreeOffers(result.familyTreeFocus)
        if let duplicate = result.possibleDuplicate {
            offers.append(.showPossibleDuplicate(
                personID: duplicate.personID, personName: duplicate.personName))
        }
        return offers
    }

    /// "(taking Dad as Richard Harding Breen Sr)" — every tree person the
    /// answer leaned on through a bridge this turn only ASSUMED (a
    /// derivable-but-unconfirmed identity). Empty when none was.
    static func assumedBridges(_ result: ArchivistGraphResult, context: Context) -> [String] {
        guard !context.assumedTreeBridges.isEmpty, let evidence = result.evidence else { return [] }
        var ids: [String] = [evidence.subjectID]
        ids += evidence.kinshipPaths.flatMap { $0.hops.map(\.person.id) }
        ids += evidence.relationships.flatMap { $0.people.map(\.id) }
        if let counterpart = evidence.counterpart { ids.append(counterpart.id) }
        var seen = Set<String>()
        return ids.compactMap { context.assumedTreeBridges[$0] }.filter { seen.insert($0).inserted }
    }

    /// The whole set of names anybody in the context can vouch for: People
    /// profiles (name + aliases), CyberBrain (name + aliases), GEDCOM (token
    /// match), and — for family-tree requests — GEDCOM surnames.
    static func isKnownPerson(
        _ name: String,
        context: Context,
        acceptSurname: Bool = false
    ) -> Bool {
        let key = PersonResolver.normalize(name)
        guard !key.isEmpty else { return false }
        if let profiles = context.profiles, profiles.contains(where: {
            ([$0.canonicalName] + $0.aliases).contains { PersonResolver.normalize($0) == key }
        }) { return true }
        if let cyberBrain = context.cyberBrain {
            if case .notFound = cyberBrain.resolve(name) {} else { return true }
        }
        if let graph = context.graph {
            if !graph.people(matching: name).isEmpty { return true }
            if acceptSurname, !graph.people(withSurname: name).isEmpty { return true }
        }
        return false
    }

    /// "ricks" → "rick" when only the singular is a known name. Returns the
    /// payload to execute and, when rewritten, the note for the basis line.
    private static func singularizedGraphPayload(
        _ payload: ArchivistQueryAST.Graph,
        request: Request,
        context: Context
    ) -> (ArchivistQueryAST.Graph, String?) {
        guard request.selectedIdentity == nil,
              payload.people.count == 1,
              let typed = payload.people.first?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              typed.count > 2,
              typed.lowercased().hasSuffix("s"),
              !typed.contains("'"), !typed.contains("’"),
              !isKnownPerson(typed, context: context,
                             acceptSurname: payload.operation == .familyTree)
        else { return (payload, nil) }
        let singular = String(typed.dropLast())
        guard isKnownPerson(singular, context: context) else { return (payload, nil) }
        var rewritten = payload
        rewritten.people = [singular]
        return (rewritten, "reading “\(typed)” as “\(singular)’s”")
    }

}
