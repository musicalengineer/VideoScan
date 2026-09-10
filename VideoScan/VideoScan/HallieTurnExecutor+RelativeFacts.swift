import Foundation
import VideoScanCore

extension HallieTurnExecutor {
    /// A relation names the SUBJECT of a fact, not a replacement for that fact.
    /// Keep birthplace/biography intact while a which-one chip binds its stable ID.
    static func executeRelativeFact(
        payload: ArchivistQueryAST.Graph, request: Request,
        context: Context, dependencies: Dependencies
    ) async throws -> Result? {
        guard request.selectedIdentity == nil, payload.people.count == 1,
              [.biography, .birthPlace, .deathPlace, .birth, .death].contains(payload.operation),
              let relative = RelativeFactSubject.parse(payload.people[0]) else { return nil }

        func unavailable(_ prose: String) -> Result {
            Result(route: .graph, outcome: .declined, prose: prose,
                   basisLine: "Basis: the requested relative could not be resolved reliably.",
                   queryDescription: "shape=graph operation=\(payload.operation.rawValue)",
                   citations: [], catalogPersonName: nil)
        }
        guard let ownerName = context.speakers.ownerName, !ownerName.isEmpty else {
            return unavailable("Set your name in Hallie's settings so I can identify your \(relative.relation.rawValue) in the family tree.")
        }
        guard let graph = context.graph else {
            if let recompile = HallieLineageAnswer.needsRecompileResult(context, queryDescription: "shape=graph") { return recompile }
            return unavailable("I need a readable family tree to identify your \(relative.relation.rawValue).")
        }
        let owner: GedcomFamilyGraph.Person
        let ownerNote: String
        switch HallieOwnerResolver.resolve(ownerName, graph: graph, familySearchID: context.speakers.ownerFamilySearchID) {
        case .one(let person, let note): owner = person; ownerNote = note
        case .many:
            return unavailable("More than one person matches your name. Set your FamilySearch ID in Hallie's settings so I can identify your relatives reliably.")
        case .none(let reason):
            return unavailable(reason ?? "I couldn't identify you in the family tree, so I can't identify your \(relative.relation.rawValue).")
        }

        let side = relative.side ?? payload.side
        var people: [GedcomFamilyGraph.Person] = []
        if let relation = GedcomFamilyGraph.Relation(rawValue: relative.relation.rawValue) {
            people = graph.relatives(relation, of: owner)
        } else if let relation = GedcomFamilyGraph.ExtendedRelation(rawValue: relative.relation.rawValue),
                  case .found(let paths) = graph.relatives(relation, side: side.flatMap { GedcomFamilyGraph.KinshipSide(rawValue: $0.rawValue) }, of: owner) {
            var seen = Set<String>()
            people = paths.map(\.relative).filter { seen.insert($0.id).inserted }
        }
        // Prefer explicit People relationships when every hit has a usable
        // tree identity. A side-qualified or deeper path stays with the graph
        // traversal; the overlay's vocabulary does not express those paths.
        if side == nil, let overlay = kinshipOverlay(context: context),
           let wanted = KinshipRelation.parse(term: relative.relation.rawValue) {
            let ownerNode = overlay.node(gedcomID: owner.id)
            if overlay.knows(ownerNode) {
                let hits = overlay.relatives(of: ownerNode, relation: wanted.relation, sex: wanted.sex)
                let linked = hits.compactMap { $0.member.gedcomID.flatMap { graph.people[$0] } }
                if !hits.isEmpty, linked.count == hits.count { people = linked }
            }
        }
        guard !people.isEmpty else {
            return unavailable("The family tree doesn't record a \(side.map { $0.rawValue + " " } ?? "")\(relative.relation.rawValue) for \(owner.name).")
        }
        // These labels are also typed-reply discriminators. Derive each side
        // from actual paths, never candidate order or the relative's surname.
        var sidesByID: [String: [String]] = [:]
        if let extended = GedcomFamilyGraph.ExtendedRelation(rawValue: relative.relation.rawValue),
           extended.startsAtParents {
            for branch in GedcomFamilyGraph.KinshipSide.allCases {
                if case .found(let paths) = graph.relatives(extended, side: branch, of: owner) {
                    for id in Set(paths.map { $0.relative.id }) {
                        sidesByID[id, default: []].append(branch.rawValue)
                    }
                }
            }
        }
        let candidates = people.map { person in
            let sides = sidesByID[person.id] ?? []
            let prefix = sides.isEmpty ? "" : sides.joined(separator: "/") + " "
                + relative.relation.rawValue.replacingOccurrences(of: "-", with: " ") + ": "
            return Candidate(id: .gedcomPersonID(person.id), canonicalName: person.name,
                             label: prefix + ArchivistBiographyPolicy.disambiguationCandidate(for: person).label)
        }
        let pending = makeClarification(intent: request.intent, stage: .gedcomPerson,
                                        candidates: candidates, context: context)
        if candidates.count == 1 {
            return try await Self.continue(pending: pending, selecting: candidates[0].id,
                                           context: context, dependencies: dependencies)
                .prefixingBasis(ownerNote.replacingOccurrences(of: "Basis: ", with: ""))
        }
        let hasBothSides = people.contains { sidesByID[$0.id] == ["maternal"] }
            && people.contains { sidesByID[$0.id] == ["paternal"] }
        let prompt = relative.relation == .grandmother && side == nil && hasBothSides
            ? "Do you mean your maternal grandmother or your paternal grandmother?"
            : "Which \(relative.relation.rawValue.replacingOccurrences(of: "-", with: " ")) do you mean?"
        return Result(route: .graph, outcome: .needsClarification,
                      prose: prompt + " " + candidates.map(\.label).joined(separator: "; "),
                      basisLine: ownerNote,
                      queryDescription: "shape=graph operation=\(payload.operation.rawValue)",
                      citations: [], catalogPersonName: nil, clarification: pending)
    }

    struct RelativeFactSubject: Equatable {
        let relation: ArchivistQueryAST.Graph.Relation
        let side: ArchivistQueryAST.Graph.Side?

        static func parse(_ text: String) -> Self? {
            var words = text.lowercased().replacingOccurrences(of: "-", with: " ")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.first == "my" || words.first == "our" else { return nil }
            words.removeFirst()
            var side: ArchivistQueryAST.Graph.Side?
            if let first = words.first, let parsed = ArchivistQueryAST.Graph.Side(rawValue: first) {
                side = parsed; words.removeFirst()
            }
            let aliases = ["grandma": "grandmother", "gramma": "grandmother", "granny": "grandmother",
                           "grandpa": "grandfather", "grampa": "grandfather", "mom": "mother", "mum": "mother", "dad": "father"]
            words = words.map { aliases[$0] ?? $0 }
            guard let relation = ArchivistQueryAST.Graph.Relation(rawValue: words.joined(separator: "-")) else { return nil }
            return Self(relation: relation, side: side)
        }
    }
}
