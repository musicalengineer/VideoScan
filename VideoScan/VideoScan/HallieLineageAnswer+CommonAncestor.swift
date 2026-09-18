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
        // Rick 2026-09-18: family members will ask this ("how is Bonnie
        // related to Rick?") — name the nearest COUPLE, count separate
        // lines rather than every shared ancestor, speak to the owner as
        // "you", and say what to take with a grain of salt.
        let ownerID: String? = {
            if case .success(let owner, _) = resolveDetailed(nil, context: context, graph: graph) { return owner.id }
            return nil
        }()
        // The owner always comes first ("how are Donna and I related" →
        // "You and Donna Hudson … your 8th-great-grandparents and Donna
        // Hudson's 9th"), including in the marriage aside.
        let ownerSecond = pb.id == ownerID && pa.id != ownerID
        let (x, y) = ownerSecond ? (pb, pa) : (pa, pb)
        let asideTerm = ownerSecond
            ? graph.directRelation(between: x.id, and: y.id).flatMap { affinalKinds.contains($0.kind) ? $0.term : nil }
            : affinalAside?.term
        guard let ancestry = graph.commonAncestry(of: x.id, and: y.id),
              let nearest = ancestry.nearest else {
            let asideSentence = affinalAside.map { " (" + $0.term + ".)" } ?? ""
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
        let prose = commonAncestryProse(ancestry, nearest: nearest, a: x, b: y, ownerID: ownerID,
                                        affinalTerm: asideTerm)
        let z = nearest.ancestors[0]
        return Result(
            route: .graph, outcome: .answered,
            prose: prose,
            basisLine: basis + " Cousin term from the two depths (degree = nearer depth − 1, removed = the difference);"
                + " separate lines = shared ancestors none of whose children are shared.",
            queryDescription: query + " → " + nearest.ancestors.map(\.name).joined(separator: " and "),
            citations: [], catalogPersonName: z.name,
            offeredActions: nearest.ancestors.map { .openFamilyTreePerson(personID: $0.id, personName: $0.name) } + chips)
    }

    /// The answer's words, pure: same tree, same owner, same sentences.
    static func commonAncestryProse(
        _ ancestry: GedcomFamilyGraph.CommonAncestry,
        nearest: GedcomFamilyGraph.AncestralMeeting,
        a: GedcomFamilyGraph.Person, b: GedcomFamilyGraph.Person,
        ownerID: String?, affinalTerm: String?
    ) -> String {
        let aIsOwner = a.id == ownerID, bIsOwner = b.id == ownerID
        func poss(_ p: GedcomFamilyGraph.Person) -> String {
            p.id == ownerID ? "your" : HallieLineageQuestion.possessive(p.name)
        }
        func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
        let pair = aIsOwner ? "You and \(b.name)" : bIsOwner ? "You and \(a.name)" : "\(a.name) and \(b.name)"
        let them = (aIsOwner || bIsOwner) ? "you" : "them"
        let n = ancestry.sharedAncestorCount, lines = ancestry.meetings.count
        let count = n.formatted(.number.grouping(.automatic))
        let through = lines > 1 ? " through \(lines.formatted(.number.grouping(.automatic))) separate lines" : ""
        let couple = nearest.ancestors.count > 1
        let who = nearest.ancestors.map { $0.name + HalliePersonVitals.parenthetical($0, places: true) }
            .joined(separator: " and ")
        func label(_ generations: Int) -> String {
            couple ? GedcomFamilyGraph.generationLabel(generations: generations, sex: "") + "s"
                : GedcomFamilyGraph.generationLabel(generations: generations, sex: nearest.ancestors[0].sex)
        }
        var sentences: [String] = []
        sentences.append("\(pair) share \(count) recorded ancestor\(n == 1 ? "" : "s")\(through); the nearest \(couple ? "are" : "is") \(who) — \(poss(a)) \(label(nearest.depthA)) and \(poss(b)) \(label(nearest.depthB)), making \(them) \(nearest.kinshipTerm).")
        if var term = affinalTerm {
            if let ownerID, let owner = [a, b].first(where: { $0.id == ownerID }) {
                term = term.replacingOccurrences(of: HallieLineageQuestion.possessive(owner.name), with: "your")
            }
            sentences.append(term + " — so this is the blood connection behind the marriage.")
        }
        func line(_ path: [GedcomFamilyGraph.Person], owner: Bool) -> String {
            let head = nearest.ancestors.map(\.name).joined(separator: " and ")
            let rest = path.dropFirst().enumerated().map { i, p in
                owner && i == path.count - 2 ? "you" : p.name
            }
            return ([head] + rest).joined(separator: " → ")
        }
        sentences.append("\(capitalized(poss(a))) line: \(line(nearest.pathA, owner: aIsOwner)). \(capitalized(poss(b))) line: \(line(nearest.pathB, owner: bIsOwner)).")
        if lines > 1 {
            let next = ancestry.meetings[1]
            sentences.append("The next nearest line is through " + next.ancestors.map(\.name).joined(separator: " and ")
                + " — \(next.kinshipTerm).")
        }
        // The grain of salt (Rick: "the info must be taken with a grain of
        // salt, but it is fun"). Far lines always; named doubts when any.
        if max(nearest.depthA, nearest.depthB) >= 5 {
            sentences.append("Take this with a grain of salt: lines this far back are only as good as the family tree they came from, and I haven’t checked them against original records.")
        }
        func named(_ people: [GedcomFamilyGraph.Person]) -> String {
            let shown = people.prefix(3).map(\.name)
            let more = people.count - shown.count
            return HallieNameQualifier.joined(Array(shown) + (more > 0 ? ["\(more) more"] : []), conjunction: "and")
        }
        if !ancestry.undatedLinks.isEmpty {
            sentences.append("On these lines, \(named(ancestry.undatedLinks)) \(ancestry.undatedLinks.count == 1 ? "has" : "have") no recorded birth date.")
        }
        if !ancestry.disputedParentLinks.isEmpty {
            sentences.append("The tree records more than one set of parents for \(named(ancestry.disputedParentLinks)).")
        }
        return sentences.joined(separator: " ")
    }
}
