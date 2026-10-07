import Foundation

/// A continuation selects identity by an opaque stable ID, never by feeding a
/// displayed name back through the alias resolver.
enum ArchivistGraphSubjectSelection: Sendable, Equatable {
    case unresolved
    case profileStableID(String)
    case gedcomPersonID(String)
}

struct ArchivistGraphAmbiguityCandidate: Sendable, Equatable {
    enum ID: Sendable, Equatable {
        case profileStableID(String)
        case gedcomPersonID(String)
    }

    let id: ID
    let canonicalName: String
    let label: String
}

/// Immutable projection copied from the decoded wire AST before execution.
/// The executor deliberately cannot receive the translator-owned AST itself;
/// only these bounded value fields cross into the factual graph layer.
struct ArchivistGraphQuery: Sendable, Equatable {
    enum Operation: String, Sendable, Equatable {
        case biography, birth, death, kinship, familyTree
        /// "where was X born / did X die" — the PLACE, not the date
        /// (Rick, 2026-08-31). See ArchivistQueryAST.Graph.Operation.
        case birthPlace = "birth-place"
        case deathPlace = "death-place"
        /// "how is A related to B" — `people` is exactly two (2026-08-18).
        case relationship
    }

    /// Who a people-list slot is in Hallie's voice, when the caller bound a
    /// pronoun: the owner is "you"/"your", the archivist herself is "I"/"my".
    /// Presentation only — identity still resolves through the same path.
    enum Voice: String, Sendable, Equatable {
        case owner
        case archivist
    }

    /// Mirrors the wire vocabulary by raw value. One-hop relations answer
    /// through `GedcomFamilyGraph.relatives`; the rest through the multi-hop
    /// path resolver (`ExtendedRelation`).
    enum Relation: String, Sendable, Equatable, CaseIterable {
        case father, mother, parents
        case brother, sister, siblings
        case son, daughter, children
        case husband, wife, spouse
        case grandfather, grandmother, grandparents
        case greatGrandfather = "great-grandfather"
        case greatGrandmother = "great-grandmother"
        case greatGrandparents = "great-grandparents"
        case greatGreatGrandfather = "great-great-grandfather"
        case greatGreatGrandmother = "great-great-grandmother"
        case greatGreatGrandparents = "great-great-grandparents"
        case uncle, aunt
        case auntsAndUncles = "aunts-and-uncles"
        case cousin, cousins
        case nephew, niece
        case niecesAndNephews = "nieces-and-nephews"
        case fatherInLaw = "father-in-law"
        case motherInLaw = "mother-in-law"
        case parentsInLaw = "parents-in-law"
        case brotherInLaw = "brother-in-law"
        case sisterInLaw = "sister-in-law"
        case sonInLaw = "son-in-law"
        case daughterInLaw = "daughter-in-law"

        var singleHop: GedcomFamilyGraph.Relation? {
            GedcomFamilyGraph.Relation(rawValue: rawValue)
        }

        var extended: GedcomFamilyGraph.ExtendedRelation? {
            GedcomFamilyGraph.ExtendedRelation(rawValue: rawValue)
        }
    }

    enum Side: String, Sendable, Equatable {
        case maternal, paternal

        var graphSide: GedcomFamilyGraph.KinshipSide {
            self == .maternal ? .maternal : .paternal
        }
    }

    let people: [String]
    let operation: Operation
    let relation: Relation?
    let side: Side?
    let surname: String?
    /// People-list index → voice, for slots that were bound pronouns.
    let voices: [Int: Voice]

    init(
        people: [String],
        operation: Operation,
        relation: Relation? = nil,
        side: Side? = nil,
        surname: String? = nil,
        voices: [Int: Voice] = [:]
    ) {
        self.people = people
        self.operation = operation
        self.relation = relation
        self.side = side
        self.surname = surname
        self.voices = voices
    }

    // The field guards (asksForAPlace, asksForRelation, asksForABiography, …)
    // live in ArchivistGraphQuery+FieldGuards.swift.

    init(_ payload: ArchivistQueryAST.Graph, voices: [Int: Voice] = [:],
         question: String? = nil) {
        people = payload.people
        var resolved = Self.operation(for: payload.operation)
        resolved = Self.correctingPlaceOperation(resolved, question: question)
        // A RELATION THE SENTENCE ASKS FOR beats the model's operation, for
        // the same reason the place cue does: it is not a judgement call.
        //
        // ASKS FOR, not merely mentions (codex #1181). "when was his father
        // born?" mentions a father but asks for a DATE: the relative is the
        // subject of a field ask, and forcing `.kinship/.father` answered
        // "who is his father" — the grandfather's name in place of the
        // father's birthday. That is a nested subject this route cannot
        // express, so it is left to the model; only a sentence whose OBJECT
        // is the relative ("who was his father", "tell me about his parents",
        // "whom did he marry") is claimed.
        var resolvedRelation = payload.relation.flatMap { Relation(rawValue: $0.rawValue) }
        if let question, resolvedRelation == nil,
           !Self.asksForAPlace(question),
           !Self.asksForADateOrAge(question),
           let asked = Self.asksForRelation(question, subject: payload.people) {
            resolvedRelation = asked
            switch resolved {
            case .biography, .birth, .death: resolved = .kinship
            default: break
            }
        }
        // A REQUEST FOR THE WHOLE PERSON, last of the three, so the narrower
        // guards above keep their sentences.
        // … and only when the sentence names no FIELD of its own. "tell me
        // about his death" opens like a whole-person request and is a death
        // question; forcing it to biography would answer the life story where
        // the death was asked (devstral:24b bake-off, 2026-09-07 — the one
        // finding of three local models that was real and still open).
        if let question, resolvedRelation == nil,
           !Self.asksForAPlace(question), !Self.mentionsBirth(question), !Self.mentionsDeath(question),
           Self.asksForABiography(question) {
            switch resolved {
            case .birth, .death: resolved = .biography
            default: break
            }
        }
        operation = resolved
        self.voices = voices
        // Raw values are the shared closed vocabulary; a wire relation that
        // has no executor twin becomes nil and fails closed as "missing".
        relation = resolvedRelation
        switch payload.side {
        case .some(.maternal): side = .maternal
        case .some(.paternal): side = .paternal
        case nil: side = nil
        }
        surname = payload.surname
    }

    private static func operation(for operation: ArchivistQueryAST.Graph.Operation) -> Operation {
        switch operation {
        case .biography: return .biography
        case .birth: return .birth
        case .death: return .death
        case .birthPlace: return .birthPlace
        case .deathPlace: return .deathPlace
        case .kinship: return .kinship
        case .familyTree: return .familyTree
        case .relationship, .commonAncestor: return .relationship
        }
    }

    private static func correctingPlaceOperation(_ operation: Operation, question: String?) -> Operation {
        var resolved = operation
        // A PLACE QUESTION GETS THE PLACE OPERATION (Rick, live 2026-09-07).
        // He asked "what country was John Hastings born in?" four times and
        // got the birth DATE every time. The record has the place — `2 PLAC
        // Kenilworth, Warwickshire, England`, and the Family Tree view draws
        // it — and the executor has a `.birthPlace` route whose own comment
        // says handing back the birthday instead "is what 'where was Eileen
        // Latta born' used to do". Nothing was broken downstream: the MODEL
        // chose `birth` for a sentence asking where.
        //
        // The operation is the model's only real judgement call on this
        // route, and this one is decidable from the words. Deterministic
        // correction, applied after the model rather than instead of it, so
        // it holds whatever the model returns and whatever model is loaded.
        if let question, Self.asksForAPlace(question), !Self.namesARelative(question) {
            // WHICH place is decided by the QUESTION, not by the model's
            // birth/death guess (Rick, live 2026-09-07, minutes after the
            // first version of this shipped). "what country was John
            // Hastings born in?" reached here as `.death`, and taking the
            // model's word for it turned a question containing the word
            // "born" into a DEATH answer. Deferring to the model on a point
            // the sentence settles is the exact mistake this guard exists to
            // correct; I made it inside the correction itself.
            //
            // A sentence carrying BOTH cues ("where did he die after being
            // born in France?") is not settled by the words, so it is not
            // overridden at all — the model's reading stands (codex #1181:
            // "born wins" forced birthPlace where deathPlace was asked). And a
            // place question ABOUT A RELATIVE ("where was his father born")
            // is a nested subject this route cannot express; left alone.
            switch (Self.mentionsBirth(question), Self.mentionsDeath(question)) {
            case (true, true):
                break
            case (_, true):
                if [.birth, .death, .biography, .birthPlace].contains(resolved) { resolved = .deathPlace }
            default:
                if [.birth, .death, .biography, .deathPlace].contains(resolved) { resolved = .birthPlace }
            }
        }
        return resolved
    }
}
