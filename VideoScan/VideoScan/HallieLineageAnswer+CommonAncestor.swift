// HallieLineageAnswer+CommonAncestor.swift
// "how am I related to X" / "who is our common ancestor" — owner binding,
// the which-one clarification, the cousin-term arithmetic and the chain prose.
// Moved out of HallieLineageQuestion.swift unchanged on 2026-09-07 night
// (codex #1182); its one private helper (commonAncestorWhichOne) moves with
// it, so nothing is widened.
import Foundation
import VideoScanCore

extension HallieLineageAnswer {
    // MARK: Common ancestor

    /// "How are Rick and Donna related?" Both names go through the same
    /// resolver as every lineage shape; the graph does the intersection.
    /// Honest on both empty sides: no parents attached → "that side isn't
    /// in the tree yet" with the Get Family Tree chip; nothing shared →
    /// say how far each side was walked.
    static func commonAncestor(_ typedA: String?, _ typedB: String?,
                               context: HallieTurnExecutor.Context) -> Result? {
        let intent = HallieTurnExecutor.Intent(
            originalQuestion: "",
            ast: .graph(.init(people: [typedA ?? "me", typedB ?? "me"], operation: .commonAncestor)))
        return commonAncestor(typedA, typedB,
                              request: HallieTurnExecutor.Request(intent: intent), context: context)
    }

    /// "me" / "I" / "myself" in a common-ancestor intent stands for the
    /// signed-in owner (the lineage resolver's nil).
    static func isFirstPerson(_ name: String) -> Bool {
        ["me", "i", "myself", "my", "us", "we"].contains(
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    enum OwnerSpouse { case spouse(GedcomFamilyGraph.Person, note: String?), ask(Result) }

    /// The owner's spouse from the tree (first recorded family unit with a
    /// spouse), for "our" with nobody in focus. `.ask` when the owner does
    /// not resolve to one record or has no spouse recorded.
    static func ownerSpouse(context: HallieTurnExecutor.Context, graph: GedcomFamilyGraph) -> OwnerSpouse {
        switch resolveDetailed(nil, context: context, graph: graph) {
        case .success(let owner, let note):
            if let spouse = graph.familyUnits(of: owner).compactMap(\.spouse).first {
                return .spouse(spouse, note: note)
            }
            return .ask(betweenYouAndWhom(reason: "the tree records no spouse for \(owner.name)"))
        case .ambiguous, .failure:
            return .ask(betweenYouAndWhom(reason: "the owner is not pinned to one tree record"))
        }
    }

    /// "Between you and whom?" — the ask for an "our" question with nobody
    /// in focus and no spouse to fall back on. No clarification object:
    /// the next sentence is a fresh ask.
    static func betweenYouAndWhom(reason: String) -> Result {
        Result(
            route: .graph, outcome: .needsClarification,
            prose: "Between you and whom? Name the other person — for example, “nearest common ancestor of me and Donna”.",
            basisLine: "Basis: “our” names the owner and one more person, but nobody was in focus and \(reason); nothing was looked up.",
            queryDescription: "common ancestor: our (between you and whom)",
            citations: [], catalogPersonName: nil)
    }

    /// The which-one for one side, with a chip per namesake that RESUMES
    /// this ask (2026-08-29: "donna 1959" after "Which Donna do you mean…"
    /// used to become a catalog search because the answer carried no
    /// continuation). `pinned` keeps the other side's earlier choice.
    private static func commonAncestorWhichOne(
        _ typed: String, among people: [GedcomFamilyGraph.Person],
        request: HallieTurnExecutor.Request, pinned: [Int: HallieTurnExecutor.CandidateID],
        context: HallieTurnExecutor.Context, graph: GedcomFamilyGraph
    ) -> Result {
        let ownerFamilySearchID = context.speakers.ownerFamilySearchID
        let asked = whichOne(typed, among: people, graph: graph, ownerFamilySearchID: ownerFamilySearchID)
        // The chips are exactly the people the sentence names, in its
        // order (roots first, capped — HallieWhichOne, miss #2).
        let shown = HallieWhichOne.arrange(people, graph: graph, ownerFamilySearchID: ownerFamilySearchID).shown
        return Result(
            route: .graph, outcome: .needsClarification,
            prose: asked.prose, basisLine: asked.basisLine,
            queryDescription: asked.queryDescription, citations: [], catalogPersonName: nil,
            clarification: HallieTurnExecutor.makeClarification(
                intent: request.intent.replacing(pinnedGraphSubjects: pinned),
                stage: .gedcomPerson,
                candidates: shown.map { HallieTurnExecutor.gedcomCandidate($0, graph: graph) },
                context: context))
    }

    /// The executor's entry: identity for both slots through the lineage
    /// chain, honouring a chip choice (`request.selectedIdentity`) for the
    /// first ambiguous slot and earlier choices (`pinnedGraphSubjects`),
    /// then the pure answer. Nil = neither side is a person the tree
    /// knows (the question goes on as typed).
    static func commonAncestor(_ typedA: String?, _ typedB: String?,
                               request: HallieTurnExecutor.Request,
                               context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return noTree(context) }
        var notes: [String] = []
        var pinned = request.intent.pinnedGraphSubjects
        var floating = request.selectedIdentity
        // "our nearest common ancestor" with no one in conversation focus
        // (live miss #9): the owner and the owner's spouse from the tree,
        // pinned by record so a namesake never asks which-one. With no
        // spouse recorded either, ask — never "me and myself".
        if typedA == nil, typedB == nil, pinned[1] == nil {
            switch ownerSpouse(context: context, graph: graph) {
            case .spouse(let spouse, let note):
                pinned[1] = .gedcomPersonID(spouse.id)
                notes.append("“Our” = you and your spouse \(spouse.name), from the tree." + (note.map { " " + $0 } ?? ""))
            case .ask(let result):
                return result
            }
        }
        // C++ readers: a two-case enum instead of std::variant — the
        // resolved person, or the answer that stops the question.
        enum Side { case ok(GedcomFamilyGraph.Person), stop(Result) }
        func person(_ typed: String?, slot: Int) -> Side {
            if let choice = pinned[slot] {
                guard case .gedcomPersonID(let id) = choice, let p = graph.people[id] else {
                    return .stop(HallieTurnExecutor.invalidContinuationResult(for: request.intent.ast))
                }
                return .ok(p)
            }
            switch resolveDetailed(typed, context: context, graph: graph) {
            case .success(let p, let note):
                if let note { notes.append(note) }
                return .ok(p)
            case .ambiguous(let people):
                // The one chip choice we were handed belongs to the first
                // slot that turns out ambiguous; consume it here.
                if let choice = floating, case .gedcomPersonID(let id) = choice,
                   let p = people.first(where: { $0.id == id }) {
                    pinned[slot] = choice
                    floating = nil
                    return .ok(p)
                }
                return .stop(commonAncestorWhichOne(
                    typed ?? context.speakers.ownerName ?? "", among: people,
                    request: request, pinned: pinned, context: context, graph: graph))
            case .failure(let r):
                return .stop(r ?? Result(
                    route: .graph, outcome: .declined,
                    prose: "I don’t find \(typed ?? "you") in the family tree.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis,
                    queryDescription: "common ancestor: resolve \(typed ?? "owner")",
                    citations: [], catalogPersonName: nil))
            }
        }
        let sideA = person(typedA, slot: 0), sideB = person(typedB, slot: 1)
        // Neither side is a person the tree knows ("how are astronomy and
        // philosophy related", codex #776): not ours — the question goes
        // on as typed instead of a graph decline.
        if case .stop(let ra) = sideA, case .stop(let rb) = sideB,
           ra.outcome != .needsClarification, rb.outcome != .needsClarification {
            return nil
        }
        let pa: GedcomFamilyGraph.Person, pb: GedcomFamilyGraph.Person
        switch sideA { case .stop(let r): return r; case .ok(let p): pa = p }
        switch sideB { case .stop(let r): return r; case .ok(let p): pb = p }
        // A chip choice nobody needed means the continuation is stale.
        if floating != nil {
            return HallieTurnExecutor.invalidContinuationResult(for: request.intent.ast)
        }
        let basis = ArchivistBiographyPolicy.gedcomBasis
            + " Ancestor sets of both people intersected; nearest by total generations first."
            + (notes.isEmpty ? "" : " " + notes.joined(separator: " "))
        let query = "common ancestor: \(pa.name) & \(pb.name)"
        let chips: [HallieTurnExecutor.OfferedAction] = [
            .openFamilyTreePerson(personID: pa.id, personName: pa.name),
            .openFamilyTreePerson(personID: pb.id, personName: pb.name),
        ]
        // Direct kin first (codex #776): parent/child, spouses, siblings,
        // grandparents and the rest are named as such — never as cousins
        // through a shared grandparent.
        // …but a marriage or in-law link is NOT an answer to "common
        // ancestor" (Rick 2026-08-28: "closest common ancestor of rick and
        // donna" → "Donna Hudson is Rick's wife"). Blood kinds short-circuit;
        // affinal kinds are mentioned as an aside after the blood answer,
        // and only stand alone when the ancestor walk finds nothing.
        let direct = graph.directRelation(between: pa.id, and: pb.id)
        let affinalKinds: Set<GedcomFamilyGraph.DirectRelation.Kind> = [.spouses, .parentInLaw, .siblingInLaw]
        let affinalAside = direct.flatMap { affinalKinds.contains($0.kind) ? $0 : nil }
        if let direct, affinalAside == nil {
            let line = direct.path.count > 2 ? " Line: " + direct.path.map(\.name).joined(separator: " → ") + "." : ""
            return Result(route: .graph, outcome: .answered,
                          prose: direct.term + "." + line,
                          basisLine: basis.replacingOccurrences(of: "Ancestor sets of both people intersected; nearest by total generations first.",
                                                                with: "Direct relation from the recorded parent/spouse links (\(direct.kind.rawValue)); no cousin math needed."),
                          queryDescription: query + " → \(direct.kind.rawValue)", citations: [],
                          catalogPersonName: pb.name,
                          offeredActions: pa.id == pb.id ? [chips[0]] : chips)
        }
        let hits = graph.commonAncestors(of: pa.id, and: pb.id)
        let possA = HallieLineageQuestion.possessive(pa.name)
        let possB = HallieLineageQuestion.possessive(pb.name)
        let asideSentence = affinalAside.map { " (" + $0.term + ".)" } ?? ""
        if hits.isEmpty {
            let dA = graph.ancestorDepth(of: pa.id), dB = graph.ancestorDepth(of: pb.id)
            let missing = [(pa, dA), (pb, dB)].filter { $0.1 == 0 }.map(\.0)
            if !missing.isEmpty {
                let sides = HallieNameQualifier.joined(missing.map { HallieLineageQuestion.possessive($0.name) + " side" }, conjunction: "and")
                let verb = missing.count == 1 ? "isn’t" : "aren’t"
                let records = HallieNameQualifier.joined(missing.map(\.name), conjunction: "or")
                return Result(
                    route: .graph, outcome: .declined,
                    prose: "\(sides) \(verb) in the tree yet — it records no parents for \(records), so there is no shared ancestor to find.\(asideSentence) Get Family Tree can pull that ancestry from FamilySearch and add it to the current tree by FamilySearch ID.",
                    basisLine: basis, queryDescription: query, citations: [], catalogPersonName: nil,
                    offeredActions: chips + [.getFamilyTree])
            }
            return Result(
                route: .graph, outcome: .declined,
                prose: "\(pa.name) and \(pb.name) share no recorded ancestor: I walked \(dA) generation\(dA == 1 ? "" : "s") above \(pa.name) and \(dB) above \(pb.name) without meeting.\(asideSentence) A deeper pull on either side could still connect them.",
                basisLine: basis, queryDescription: query, citations: [], catalogPersonName: nil,
                offeredActions: chips)
        }
        let nearest = hits[0]
        let z = nearest.person
        // Rick 2026-08-28: the record's critical info on the nearest —
        // "(b. 1633 – d. after 1717, Sudbury, Middlesex, Massachusetts Bay
        // Colony)": year with qualifier as recorded, places when recorded.
        let born = HalliePersonVitals.parenthetical(z, places: true)
        let labelA = GedcomFamilyGraph.generationLabel(generations: nearest.depthA, sex: z.sex)
        let labelB = GedcomFamilyGraph.generationLabel(generations: nearest.depthB, sex: z.sex)
        var sentences: [String] = []
        let n = hits.count
        sentences.append("\(pa.name) and \(pb.name) share \(n) recorded ancestor\(n == 1 ? "" : "s"); the nearest is \(z.name)\(born) — \(possA) \(labelA) and \(possB) \(labelB), making them \(nearest.kinshipTerm).")
        func line(_ path: [GedcomFamilyGraph.Person]) -> String {
            path.map(\.name).joined(separator: " → ")
        }
        if let affinalAside { sentences.append(affinalAside.term + " — so this is the blood connection behind the marriage.") }
        sentences.append("\(possA) line: \(line(nearest.pathA)). \(possB) line: \(line(nearest.pathB)).")
        if n > 1 {
            let others = hits.dropFirst().prefix(3).map { h in
                h.person.name + HalliePersonVitals.parenthetical(h.person, places: false) + " (\(h.depthA)/\(h.depthB) generations up)"
            }
            sentences.append("Also shared: " + others.joined(separator: "; ") + (n - 1 > others.count ? "; and \(n - 1 - others.count) more." : "."))
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: basis + " Cousin term from the two depths (degree = nearer depth − 1, removed = the difference).",
            queryDescription: query + " → \(z.name)",
            citations: [], catalogPersonName: z.name,
            offeredActions: [.openFamilyTreePerson(personID: z.id, personName: z.name)] + chips)
    }
}
