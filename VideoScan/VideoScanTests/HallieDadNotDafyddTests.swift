// HallieDadNotDafyddTests.swift
//
// THE LIVE FAILURE, 2026-09-26 14:14–14:17 ET (session 627FCBEB, Rick, app):
//
//   Rick:   find videos of dad
//   Hallie: "Dafydd ab Einion "Y Giwn Llwyd" was born about 1360, more than
//            five centuries before motion pictures begin in 1888 — no one
//            lives that long, so there can’t be film of him."
//   Rick:   dad breen not someone from 5 centuries ago
//   Hallie: (Richard Harding Breen Sr's biography) — and, in the same turn,
//           "Opening the Family Tree tab focused on Dafydd ab Einion".
//   Rick:   sure
//   Hallie: (Richard Harding Breen Sr's Marine Corps service)
//   Rick:   sure, but I also want videos of dad
//   Hallie: Dafydd ab Einion, word for word, again.
//
// ROOT CAUSE (A). The "videos of X" lineage shape (HallieLineageQuestion,
// before the mode gate and before the translator) resolved "Dad" as a NAME.
// GedcomFamilyGraph.people(matching:) is token-exact over EVERY NAME record
// of every person, and the merged FamilySearch tree's @IB21341@ — Dafydd ab
// Einion "Y Giwn Llwyd", b. about 1360 — carries fifteen NAME records, the
// seventh of which is "Dad ab Giwn". So "Dad" was an EXACT hit on a
// 39,250-person tree, not a fuzzy one, and every rung that guards fuzzy
// recovery (the ≤4-letter rule, the bare-given-name rule) was never
// reached. A kin term is the OWNER's relative: it binds through the People
// tab (Rick's row "child of Dad"), then the owner's own tree record, and
// otherwise declines by name. It is never looked up as a tree name — the
// same rule the person-fact lane adopted for GH #180 and the temporal lane
// on 2026-09-21, now in the ONE resolver every lineage shape shares.
//
// ROOT CAUSE (B). "videos of dad" two turns after Rick corrected to "dad
// breen" re-resolved from scratch; the conversation had already settled who
// "dad" is. ConversationMemory now remembers a kin term the conversation
// resolved ("dad breen" → Richard Harding Breen Sr) and the media shapes
// use that binding before any lookup.
//
// Five dimensions (feature-test checklist):
//   1. Logic     — the live turns, the tree fallback, the honest decline.
//   2. Scale     — n/a: one resolver call over tens of profiles.
//   3. Media     — n/a (no media files opened).
//   4. Isolation — in-memory tree and profiles; a scratch asset root so the
//                  photo answers never read /Volumes/FamilyArchive.
//   5. Sensor    — the fixture tree keeps "Dad ab Giwn" as an alternate NAME
//                  of a 1360 Welshman (the rung that fired), and a People-tab
//                  alias ("Ma") still wins over the kin rule (GH #180).
//
// The GEDCOM fixture is synthetic (2026-08-03 privacy policy); the Dafydd
// record mirrors the shape of the real one because the shape IS the bug.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// `rickHasParents`: with Rick's FAMC row the tree records his father;
/// without it the tree can bind nothing for "dad" and only the People tab
/// (or the conversation) can.
private func fixtureTree(rickHasParents: Bool) -> String {
    var lines = [
        "0 HEAD",
        "0 @I1@ INDI",
        "1 NAME Richard Harding /Breen/ Jr",
        "1 SEX M",
        "1 _FSFTID GVQV-NW3",
        "1 BIRT",
        "2 DATE 4 MAR 1959",
    ]
    if rickHasParents { lines.append("1 FAMC @F1@") }
    lines += [
        "0 @I2@ INDI",
        "1 NAME Richard Harding /Breen/ Sr",
        "1 SEX M",
        "1 _FSFTID G2S4-JF4",
        "1 BIRT",
        "2 DATE 21 FEB 1929",
        "1 DEAT",
        "2 DATE 25 JUN 2008",
        "1 FAMS @F1@",
        "0 @I3@ INDI",
        "1 NAME Eileen /Latta/",
        "1 SEX F",
        "1 _FSFTID G2CR-R4H",
        "1 BIRT",
        "2 DATE 31 AUG 1930",
        "1 DEAT",
        "2 DATE 3 MAR 2023",
        "1 FAMS @F1@",
        // The real @IB21341@, name for name: the seventh NAME is "Dad".
        "0 @I4@ INDI",
        "1 NAME Dafydd /ab Einion \"Y Giwn Llwyd\"/",
        "1 NAME David ap Y Gwin Lloyd",
        "1 NAME David ap Gwion Llwyd",
        "1 NAME David ab y Gwin Lloyd",
        "1 NAME Davd ap Giwn",
        "1 NAME David ab Y Gwion Lloyd Baron of Hendwr",
        "1 NAME Dad ab Giwn",
        "1 NAME David ab Gwido de Hendor",
        "1 NAME David de Hendour",
        "1 NAME Dd ab Gwin",
        "1 NAME Davydd ab Gwion Llwyd",
        "1 SEX M",
        "1 BIRT",
        "2 DATE about 1360",
        "2 PLAC of, Yr Hendwr, Llandrillo-yn-Edeirnion, Merionethshire, Wales",
        "1 _FSFTID PDPK-6VX",
        "0 @F1@ FAM",
        "1 HUSB @I2@",
        "1 WIFE @I3@",
    ]
    if rickHasParents { lines.append("1 CHIL @I1@") }
    lines.append("0 TRLR")
    return lines.joined(separator: "\n")
}

@Suite("Hallie — 'find videos of dad' is Dad Breen, never a Welshman named Dad", .serialized)
struct HallieDadNotDafyddTests {
    typealias Exec = HallieTurnExecutor
    typealias Answer = HallieLineageAnswer

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private static let dadUUID = UUID(uuidString: "FF6C5474-EBB4-4D32-A9EF-B2D38647A146")!
    private static let rickUUID = UUID(uuidString: "71393E0E-0000-4000-8000-000000000001")!
    private static let maUUID = UUID(uuidString: "11892D85-0000-4000-8000-000000000002")!

    /// Rick's People tab as it stands (POI/*/profile.json): TWO profiles
    /// named "Richard"; the aliases and the relationship rows tell them
    /// apart. `rows: false` drops every relationship row, which is what a
    /// family member who never filled the Relationships card would have.
    private static func profiles(rows: Bool) -> [Exec.ProfileSnapshot] {
        [
            .init(stableID: "dad", canonicalName: "Richard",
                  aliases: ["Dad Breen", "Grampa Breen", "Dick"],
                  birthdate: date(1929, 2, 21),
                  kinships: rows ? [Kinship(relation: .parent, relativeTo: .profile(id: rickUUID))] : [],
                  sex: .male, uuid: dadUUID,
                  treeIdentity: .familySearchID("G2S4-JF4"),
                  deathdate: date(2008, 6, 25),
                  surname: "Breen", middleName: "Harding", suffix: "Sr"),
            .init(stableID: "rick", canonicalName: "Richard",
                  aliases: ["Dicky", "Rick"],
                  birthdate: date(1959, 3, 4),
                  kinships: rows ? [
                    Kinship(relation: .child, relativeTo: .profile(id: dadUUID)),
                    Kinship(relation: .child, relativeTo: .profile(id: maUUID)),
                  ] : [],
                  sex: .male, uuid: rickUUID,
                  treeIdentity: .familySearchID("GVQV-NW3"),
                  surname: "Breen", middleName: "Harding", suffix: "Jr"),
            .init(stableID: "ma", canonicalName: "Eileen",
                  aliases: ["Ma", "Ma Breen", "Gramma Breen"],
                  birthdate: date(1930, 8, 31),
                  kinships: rows ? [Kinship(relation: .parent, relativeTo: .profile(id: rickUUID))] : [],
                  sex: .female, uuid: maUUID,
                  treeIdentity: .familySearchID("G2CR-R4H"),
                  deathdate: date(2023, 3, 3),
                  surname: "Breen", maidenName: "Latta", middleName: "Marie"),
        ]
    }

    /// An EMPTY scratch archive: the photo answers are decided by the
    /// fixture, never by whether /Volumes/FamilyArchive is mounted.
    private static let scratchAssets: @Sendable () -> FamilyAssetConfiguration = {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-dad-dafydd-isolation", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return FamilyAssetConfiguration(
            roots: .init(assets: base.appendingPathComponent("40_Family_Tree", isDirectory: true),
                         thumbnailCache: base.appendingPathComponent("thumbs", isDirectory: true)),
            access: .readOnly,
            legacyGEDCOMDirectory: nil)
    }

    private func graph(rickHasParents: Bool = true) -> GedcomFamilyGraph {
        GedcomFamilyGraph(gedcomText: fixtureTree(rickHasParents: rickHasParents))
    }

    private func context(rows: Bool = true, rickHasParents: Bool = true) -> Exec.Context {
        Exec.Context(
            profiles: Self.profiles(rows: rows),
            graph: graph(rickHasParents: rickHasParents),
            assetConfiguration: Self.scratchAssets,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                            archivistPersonName: nil, ownerFamilySearchID: "GVQV-NW3"))
    }

    private func pre(_ question: String, context: Exec.Context,
                     memory: Exec.ConversationMemory = .init()) -> Exec.PreTranslation {
        Exec.preTranslation(
            question: question, playAfterAnswer: false, memory: memory,
            isKnownPerson: { _ in false },
            lineageAnswer: { Answer.answer($0, context: context) })
    }

    private static let richardSr = "Richard Harding Breen Sr"

    /// The lineage shape's own resolver — the one every "photo of X",
    /// "videos of X", "X's line", "center on X" shares.
    private func resolved(_ typed: String, context: Exec.Context) -> GedcomFamilyGraph.Person? {
        guard let graph = context.graph,
              case .success(let person, _) = Answer.resolveDetailed(typed, context: context, graph: graph)
        else { return nil }
        return person
    }

    // MARK: - The rung that fired

    /// Not a fuzzy match: the tree has a man whose alternate NAME is "Dad".
    /// This is the sensor for the mechanism — if a future name-index change
    /// stops matching alternate NAME records, this test says so, and the
    /// tests below stop proving anything about the kin rule.
    @Test func theTreeReallyHasAManNamedDad() {
        let hits = graph().people(matching: "Dad")
        #expect(hits.count == 1, Comment(rawValue: hits.map(\.name).joined(separator: " | ")))
        #expect(hits.first?.name.contains("Dafydd") == true, Comment(rawValue: hits.first?.name ?? "nobody"))
    }

    // MARK: - A: a kin term is the owner's relative, never a tree name

    /// THE live turn. Dad Breen died in 2008, well after film, so the
    /// pre-film floor has nothing to say and the question continues as
    /// typed to the presence route. It must never be answered for Dafydd.
    @Test func findVideosOfDadNeverAnswersWithDafydd() {
        let decision = pre("find videos of dad", context: context())
        if case .answer(let r) = decision {
            #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
            #expect(!r.prose.contains("1360"), Comment(rawValue: r.prose))
            #expect(r.queryDescription?.contains("Dafydd") != true, Comment(rawValue: r.queryDescription ?? ""))
            #expect(r.catalogPersonName?.contains("Dafydd") != true)
        }
    }

    /// The fourth live turn, word for word.
    @Test func sureButIAlsoWantVideosOfDadNeverAnswersWithDafydd() {
        let decision = pre("sure, but I also want videos of dad", context: context())
        if case .answer(let r) = decision {
            #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
            #expect(r.queryDescription?.contains("Dafydd") != true, Comment(rawValue: r.queryDescription ?? ""))
        }
    }

    /// "dad", "Dad", "my dad", "our father": the People tab's own row
    /// ("Rick: child of Dad") binds the person, and the resolver says so.
    @Test func bareDadResolvesThroughThePeopleTab() {
        let context = context()
        let graph = context.graph!
        for typed in ["dad", "Dad", "my dad", "our father", "daddy"] {
            switch Answer.resolveDetailed(typed, context: context, graph: graph) {
            case .success(let person, let note):
                #expect(person.id == "@I2@", Comment(rawValue: "\(typed) → \(person.name)"))
                #expect(note?.contains("People tab") == true, Comment(rawValue: "\(typed): \(note ?? "no note")"))
            case .ambiguous(let people):
                Issue.record("\(typed) was ambiguous: \(people.map(\.name))")
            case .failure(let result):
                Issue.record("\(typed) failed: \(result?.prose ?? "nil")")
            }
        }
    }

    /// "show me a photo of dad" is Dad Breen's photo answer (the scratch
    /// archive has none, so the honest "not yet" — about the right man).
    @Test func photosOfDadAreAboutRichardSr() {
        guard case .answer(let r) = pre("show me a photo of dad", context: context()) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.queryDescription == "photo: \(Self.richardSr)", Comment(rawValue: r.queryDescription ?? ""))
        #expect(r.catalogPersonName == Self.richardSr)
        #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
        #expect(!r.prose.contains("photography"), Comment(rawValue: r.prose))
    }

    /// No relationship rows on the People tab: the owner's OWN tree record
    /// (pinned by FamilySearch ID) still names his father. That is a graph
    /// walk from a pinned record, not a name lookup.
    @Test func withoutPeopleTabRowsTheOwnersTreeRecordBindsDad() {
        let context = context(rows: false)
        let person = resolved("dad", context: context)
        #expect(person?.id == "@I2@", Comment(rawValue: person?.name ?? "nobody"))
    }

    /// No rows and no parents in the tree: an honest decline that names the
    /// gap — never the Welshman. SENSOR: this is the case where every name
    /// rung is free to fire, and none may.
    @Test func withNoFatherAnywhereDadIsAnHonestDeclineNeverDafydd() {
        let context = context(rows: false, rickHasParents: false)
        switch Answer.resolveDetailed("dad", context: context, graph: context.graph!) {
        case .failure(let result):
            let prose = result?.prose ?? ""
            #expect(prose.lowercased().contains("father"), Comment(rawValue: prose))
            #expect(!prose.contains("Dafydd"), Comment(rawValue: prose))
        case .success(let person, _):
            Issue.record("bound to \(person.name) with nothing to bind from")
        case .ambiguous(let people):
            Issue.record("ambiguous: \(people.map(\.name))")
        }
        guard case .answer(let r) = pre("show me a photo of dad", context: context) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(r.outcome == .declined)
        #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
    }

    /// GH #180's own rule, kept: a bare kin word that IS a People-tab alias
    /// ("Ma" is Eileen) resolves as that alias, not as the owner's mother
    /// through a walk. Both roads reach Eileen here; the note tells them
    /// apart, and it must be the alias road.
    @Test func aPeopleTabAliasStillWinsOverTheKinRule() {
        let context = context()
        switch Answer.resolveDetailed("ma", context: context, graph: context.graph!) {
        case .success(let person, let note):
            #expect(person.id == "@I3@", Comment(rawValue: person.name))
            #expect(note?.contains("People tab") != true, Comment(rawValue: note ?? "no note"))
        default:
            Issue.record("'ma' did not resolve to Eileen")
        }
    }

    /// A kin term the tree cannot express as one hop ("my great-great-
    /// grandmother") still never becomes a name lookup.
    @Test func aDeepKinTermIsNeverANameLookup() {
        let context = context()
        switch Answer.resolveDetailed("my great-great-grandmother", context: context, graph: context.graph!) {
        case .success(let person, _):
            Issue.record("bound a great-great-grandmother the fixture does not have: \(person.name)")
        case .ambiguous(let people):
            Issue.record("ambiguous: \(people.map(\.name))")
        case .failure(let result):
            // Bound first on purpose: `#expect(!(x ?? "").contains(…))`
            // mis-expands (the macro reports `→ ()` and fails on a true
            // condition, seen on both the red and the green run).
            let prose = result?.prose ?? ""
            #expect(!prose.contains("Dafydd"), Comment(rawValue: prose))
            #expect(prose.contains("great great grandmother"), Comment(rawValue: prose))
        }
    }

    // MARK: - Sibling roads: the graph route's own resolver

    /// The same word on the graph route ("show dad's family tree" is a
    /// `.familyTree` intent for "dad"; "who is dad's mother" a `.kinship`
    /// one): `ArchivistGraphExecutor.resolveSubject` reaches the same
    /// `people(matching:)` rung. These pin whatever the executor does with
    /// a bare kin word there — the person must be Dad Breen or an honest
    /// decline, never the Welshman.
    @Test func showDadsFamilyTreeIsNeverDafydd() async throws {
        let context = context()
        let r = try await Exec.execute(
            .init(intent: .init(originalQuestion: "show dad's family tree",
                                ast: .graph(.init(people: ["dad"], operation: .familyTree)))),
            context: context)
        #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
        #expect(r.catalogPersonName?.contains("Dafydd") != true, Comment(rawValue: r.catalogPersonName ?? "nil"))
        #expect(!r.offeredActions.contains { offer in
            if case .openFamilyTreePerson(_, let name) = offer { return name.contains("Dafydd") }
            return false
        }, Comment(rawValue: r.offeredActions.map(Exec.offerLabel).joined(separator: " | ")))
    }

    @Test func whoIsDadsMotherIsNeverDafydd() async throws {
        let context = context()
        let r = try await Exec.execute(
            .init(intent: .init(originalQuestion: "who is dad's mother",
                                ast: .graph(.init(people: ["dad"], operation: .kinship, relation: .mother)))),
            context: context)
        #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
        #expect(r.catalogPersonName?.contains("Dafydd") != true, Comment(rawValue: r.catalogPersonName ?? "nil"))
    }

    // MARK: - B: the conversation keeps who "dad" is after a correction

    /// The correction turn as the app records it: the translator read "dad
    /// breen" as a biography subject, and the answer settled on Richard
    /// Harding Breen Sr. Then "sure" → the service story, same person.
    private func memoryAfterTheCorrection() -> Exec.ConversationMemory {
        var memory = Exec.ConversationMemory()
        let correction = Exec.Intent(
            originalQuestion: "dad breen not someone from 5 centuries ago",
            ast: .graph(.init(people: ["dad breen"], operation: .biography)))
        memory.record(
            intent: correction,
            result: .init(route: .graph, outcome: .answered,
                          prose: "Here is what the family archive currently supports about Richard Harding Breen Sr.",
                          basisLine: "Basis: fixture.", queryDescription: "shape=graph operation=biography person=dad breen",
                          citations: [], catalogPersonName: Self.richardSr,
                          offeredActions: [.ask(question: "how did Richard Harding Breen Sr serve", label: Self.richardSr)]),
            question: correction.originalQuestion)
        #expect(memory.lastSubject == Self.richardSr)
        memory.record(
            intent: Exec.Intent(
                originalQuestion: "sure",
                ast: .graph(.init(people: [Self.richardSr], operation: .biography))),
            result: .init(route: .graph, outcome: .answered,
                          prose: "Richard Harding Breen Sr served in the United States Marine Corps in the 1940s.",
                          basisLine: "Basis: fixture.", queryDescription: "shape=graph operation=biography topic=military-service",
                          citations: [], catalogPersonName: Self.richardSr),
            question: "sure")
        return memory
    }

    /// THE fourth live turn, with a People tab that cannot bind "dad" on
    /// its own (no rows, no parents in the tree): the conversation already
    /// settled that "dad" is Richard Harding Breen Sr two turns ago.
    @Test func afterTheCorrectionVideosOfDadKeepsRichardSr() {
        let context = context(rows: false, rickHasParents: false)
        let memory = memoryAfterTheCorrection()
        let decision = pre("sure, but I also want videos of dad", context: context, memory: memory)
        if case .answer(let r) = decision {
            #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
            #expect(r.queryDescription?.contains("Dafydd") != true, Comment(rawValue: r.queryDescription ?? ""))
            // Richard Sr died in 2008: the film floor has nothing to say, so
            // a local answer here can only be a decline about HIM.
            #expect(r.catalogPersonName == nil || r.catalogPersonName == Self.richardSr,
                    Comment(rawValue: r.catalogPersonName ?? "nil"))
        }
        // The same binding serves the photo shape, where the person is
        // visible in the answer.
        guard case .answer(let photo) = pre("show me a photo of dad", context: context, memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(photo.queryDescription == "photo: \(Self.richardSr)", Comment(rawValue: photo.queryDescription ?? ""))
        #expect(!photo.prose.contains("Dafydd"), Comment(rawValue: photo.prose))
    }

    /// What memory keeps: the relation word, valued by the settled person —
    /// and only from an ANSWERED graph turn.
    @Test func memoryKeepsTheSettledKinTermByRelation() {
        let memory = memoryAfterTheCorrection()
        #expect(memory.kinBindings == ["father": Self.richardSr], Comment(rawValue: "\(memory.kinBindings)"))
        #expect(memory.boundRelative(for: "dad") == Self.richardSr)
        #expect(memory.boundRelative(for: "Dad") == Self.richardSr)
        #expect(memory.boundRelative(for: "my dad") == Self.richardSr)
        #expect(memory.boundRelative(for: "father") == Self.richardSr)
        #expect(memory.boundRelative(for: "mom") == nil)
        #expect(memory.boundRelative(for: "dad breen") == nil, "a term with a surname resolves itself")
        #expect(memory.boundRelative(for: "Richard") == nil, "a name is not a kin term")
        var reset = memory
        reset.reset()
        #expect(reset.kinBindings.isEmpty)
        // A catalog answer never writes one, even about the right person:
        // its subject can be a contested given name ("Richard").
        var catalog = Exec.ConversationMemory()
        catalog.record(
            intent: Exec.Intent(originalQuestion: "videos of my dad",
                                ast: .presence(.init(people: ["my dad"], mediaKind: .video))),
            result: .init(route: .presence, outcome: .answered, prose: "Here are 3 videos.",
                          basisLine: "Basis: fixture.", queryDescription: "presence",
                          citations: [], catalogPersonName: "Richard"),
            question: "videos of my dad")
        #expect(catalog.kinBindings.isEmpty)
    }

    /// A correction the tree DECLINED leaves nothing behind: "dad" is still
    /// unbound, and the honest decline stands — never a guess.
    @Test func aDeclinedCorrectionBindsNothing() {
        let context = context(rows: false, rickHasParents: false)
        var memory = Exec.ConversationMemory()
        memory.record(
            intent: Exec.Intent(
                originalQuestion: "dad breen not someone from 5 centuries ago",
                ast: .graph(.init(people: ["dad breen"], operation: .biography))),
            result: .init(route: .graph, outcome: .declined,
                          prose: "I don't find “dad breen” in the family tree.",
                          basisLine: "Basis: fixture.", queryDescription: "shape=graph operation=biography",
                          citations: [], catalogPersonName: nil),
            question: "dad breen not someone from 5 centuries ago")
        guard case .answer(let photo) = pre("show me a photo of dad", context: context, memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(photo.outcome == .declined, Comment(rawValue: photo.prose))
        #expect(!photo.prose.contains("Dafydd"), Comment(rawValue: photo.prose))
        #expect(!photo.prose.contains(Self.richardSr), Comment(rawValue: photo.prose))
    }

    /// The binding is per relation: settling "dad" says nothing about "mom".
    @Test func aFatherBindingNeverLeaksToMother() {
        let context = context(rows: false, rickHasParents: false)
        let memory = memoryAfterTheCorrection()
        guard case .answer(let photo) = pre("show me a photo of mom", context: context, memory: memory) else {
            Issue.record("the photo ask went to the translator"); return
        }
        #expect(!photo.prose.contains(Self.richardSr), Comment(rawValue: photo.prose))
        #expect(!photo.prose.contains("Dafydd"), Comment(rawValue: photo.prose))
    }

    // MARK: - The whole exchange, through the real executor

    /// Turn 2 runs through the real graph route (the alias "Dad Breen" on
    /// the People tab); turn 4 then never re-resolves from scratch, and the
    /// memory carries no offer to open the tree on Dafydd (defect C's
    /// memory half: HallieTreeFollowUp's "show me" acts on `tree.lastOffers`).
    @Test func theLiveExchangeEndsOnRichardSr() async throws {
        let context = context()
        var memory = Exec.ConversationMemory()
        // Turn 1 as the app would now record it: the film floor stayed
        // silent, the presence route searched for "dad" and found no tag.
        memory.record(
            intent: Exec.Intent(originalQuestion: "find videos of dad",
                                ast: .presence(.init(people: ["dad"], mediaKind: .video))),
            result: .init(route: .presence, outcome: .declined,
                          prose: "I don't have any videos tagged with Dad yet.",
                          basisLine: "Basis: fixture.", queryDescription: "presence",
                          citations: [], catalogPersonName: nil),
            question: "find videos of dad")
        // Turn 2, for real.
        let correction = Exec.Intent(
            originalQuestion: "dad breen not someone from 5 centuries ago",
            ast: .graph(.init(people: ["dad breen"], operation: .biography)))
        let answered = try await Exec.execute(.init(intent: correction), context: context)
        #expect(answered.outcome == .answered, Comment(rawValue: answered.prose))
        #expect(answered.catalogPersonName == Self.richardSr, Comment(rawValue: answered.catalogPersonName ?? "nil"))
        #expect(!answered.prose.contains("Dafydd"), Comment(rawValue: answered.prose))
        memory.record(intent: correction, result: answered, question: correction.originalQuestion)
        #expect(memory.lastSubject == Self.richardSr)
        #expect(!memory.tree.lastOffers.contains { offer in
            if case .openFamilyTreePerson(_, let name) = offer { return name.contains("Dafydd") }
            return false
        })
        // Turn 4.
        let decision = pre("sure, but I also want videos of dad", context: context, memory: memory)
        if case .answer(let r) = decision {
            #expect(!r.prose.contains("Dafydd"), Comment(rawValue: r.prose))
            #expect(r.queryDescription?.contains("Dafydd") != true, Comment(rawValue: r.queryDescription ?? ""))
        }
    }
}
