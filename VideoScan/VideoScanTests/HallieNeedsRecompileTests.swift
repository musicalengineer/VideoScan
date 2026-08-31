// HallieNeedsRecompileTests.swift
// Live misses #8 and #9 (Rick, 2026-08-29 13:05, main 392e6118).
//
// #8: after the codec bump the loader correctly refused the two-source
// generation (FamilyGraphFileLoader.Outcome.needsRecompile) and Hallie
// answered "find our nearest common ancestor" with "I don't have an
// imported family tree" — false. The tree is on disk; it needs a
// recompile. Contract: the exact "needs recompiling" sentence, an offered
// `.recompileFamilyTree` marked to be performed, and the recompile
// itself promoting a generation Hallie then answers from. The genuine
// no-GEDCOM wording is unchanged.
//
// #9: "our" / "we" / "us" = the owner + the person in conversation focus,
// else the owner + the owner's spouse from the tree, else "Between you
// and whom?".
//
// Sandbox pattern: FamilyGraphCompiledStoreTests / HallieCompiledGraph-
// WiringTests — a two-pull generation whose pointer is rewritten with an
// older codec. No production path is touched.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// Rick (owner, pinned by FamilySearch ID) married to Donna; Z Common is
// Rick's great-grandfather and Donna's grandfather.
private let coupleTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F1@
1 FAMS @F2@
1 _FSFTID GVQV-NW3
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 FAMC @F5@
1 FAMS @F2@
1 _FSFTID G2CL-86B
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 FAMC @F3@
1 FAMS @F1@
0 @I4@ INDI
1 NAME George /Breen/
1 SEX M
1 FAMC @F4@
1 FAMS @F3@
0 @I5@ INDI
1 NAME Z /Common/
1 SEX M
1 BIRT
2 DATE 1840
1 FAMS @F4@
1 FAMS @F6@
0 @I6@ INDI
1 NAME Walter /Hudson/
1 SEX M
1 FAMC @F6@
1 FAMS @F5@
0 @I7@ INDI
1 NAME Martha /Lamson/
1 SEX F
1 BIRT
2 DATE 1633
0 @F1@ FAM
1 HUSB @I3@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F3@ FAM
1 HUSB @I4@
1 CHIL @I3@
0 @F4@ FAM
1 HUSB @I5@
1 CHIL @I4@
0 @F5@ FAM
1 HUSB @I6@
1 CHIL @I2@
0 @F6@ FAM
1 HUSB @I5@
1 CHIL @I6@
0 TRLR
"""

// Rick alone: no spouse recorded.
private let singleTree = """
0 HEAD
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 BIRT
2 DATE 1959
1 _FSFTID GVQV-NW3
0 @I7@ INDI
1 NAME Martha /Lamson/
1 SEX F
0 TRLR
"""

private let speakers = HallieTurnExecutor.Speakers(
    ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil,
    ownerFamilySearchID: "GVQV-NW3")

private func context(_ graph: GedcomFamilyGraph?, needsRecompile: [URL] = []) -> HallieTurnExecutor.Context {
    HallieTurnExecutor.Context(profiles: [], graph: graph, needsRecompile: needsRecompile, speakers: speakers)
}

private func intent(_ question: String, people: [String],
                    operation: ArchivistQueryAST.Graph.Operation) -> HallieTurnExecutor.Intent {
    HallieTurnExecutor.Intent(originalQuestion: question,
                              ast: .graph(.init(people: people, operation: operation)))
}

/// Memory after an answer about one person (what "our" leans on).
private func memory(focusedOn name: String?) -> HallieTurnExecutor.ConversationMemory {
    var memory = HallieTurnExecutor.ConversationMemory()
    if let name {
        memory.record(
            intent: nil,
            result: HallieTurnExecutor.Result(
                route: .graph, outcome: .answered, prose: "\(name) is …",
                basisLine: "Basis: test", queryDescription: nil, citations: [],
                catalogPersonName: name),
            question: "tell me about \(name)")
    }
    return memory
}

// MARK: - #9 detector

@Suite("Common ancestor — 'our' / 'we' / 'us' (miss #9)")
struct HallieOurCommonAncestorDetectTests {
    typealias Q = HallieLineageQuestion

    @Test func ricksLiveSentenceAndVariants() {
        #expect(Q.detect("find our nearest common ancestor") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("Find our nearest common ancestor.") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("what is our common ancestor") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("who is our closest shared ancestor?") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("nearest common ancestor between us") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("common ancestor of the two of us") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("how are we related") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("are we related?") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("are we related to each other") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("do we share an ancestor") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("do we have any common ancestors?") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("where do our lines meet") == .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("what do we have in common ancestrally") == .commonAncestor(a: nil, b: nil))
    }

    @Test func namedPairsAndNegativesAreUnchanged() {
        #expect(Q.detect("how are rick and donna related") == .commonAncestor(a: "Rick", b: "Donna"))
        #expect(Q.detect("are me and donna related") == .commonAncestor(a: nil, b: "Donna"))
        #expect(Q.detect("are me and myself related") == nil)
        #expect(Q.detect("are they related") == nil)
        #expect(Q.detect("videos of our family") != .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("photos of us at the lake") != .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("our family tree") != .commonAncestor(a: nil, b: nil))
        #expect(Q.detect("we are related to the lattas") != .commonAncestor(a: nil, b: nil))
    }
}

// MARK: - #9 resolution: focus → spouse → ask

@Suite("Common ancestor — 'our' resolves to focus, spouse, or asks (miss #9)")
struct HallieOurCommonAncestorAnswerTests {

    private func turn(_ question: String, memory: HallieTurnExecutor.ConversationMemory,
                      graph: GedcomFamilyGraph) -> (asked: HallieLineageQuestion?, pre: HallieTurnExecutor.PreTranslation) {
        var asked: HallieLineageQuestion?
        let ctx = context(graph)
        let pre = HallieTurnExecutor.preTranslation(
            question: question, playAfterAnswer: false, memory: memory,
            isKnownPerson: { _ in false },
            lineageAnswer: { q in asked = q; return HallieLineageAnswer.answer(q, context: ctx) })
        return (asked, pre)
    }

    @Test func withDonnaInFocusOurMeansOwnerAndDonna() throws {
        let graph = GedcomFamilyGraph(gedcomText: coupleTree)
        let (asked, pre) = turn("find our nearest common ancestor", memory: memory(focusedOn: "Donna Hudson"), graph: graph)
        #expect(asked == .commonAncestor(a: nil, b: "Donna Hudson"))
        guard case .answer(let r) = pre else { Issue.record("expected a local answer, got \(pre)"); return }
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Z Common"), "\(r.prose)")
        #expect(r.prose.contains("Richard Harding Breen Jr") && r.prose.contains("Donna Hudson"), "\(r.prose)")
    }

    @Test func withNoFocusOurFallsBackToTheOwnersSpouse() throws {
        let graph = GedcomFamilyGraph(gedcomText: coupleTree)
        let (asked, pre) = turn("find our nearest common ancestor", memory: memory(focusedOn: nil), graph: graph)
        #expect(asked == .commonAncestor(a: nil, b: nil))
        guard case .answer(let r) = pre else { Issue.record("expected a local answer, got \(pre)"); return }
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Z Common"), "\(r.prose)")
        #expect(r.basisLine.contains("“Our” = you and your spouse Donna Hudson, from the tree."), "\(r.basisLine)")
    }

    @Test func aFocusOnSomeoneElseWinsOverTheSpouse() throws {
        let graph = GedcomFamilyGraph(gedcomText: coupleTree)
        let (asked, pre) = turn("how are we related", memory: memory(focusedOn: "Martha Lamson"), graph: graph)
        #expect(asked == .commonAncestor(a: nil, b: "Martha Lamson"))
        guard case .answer(let r) = pre else { Issue.record("expected a local answer, got \(pre)"); return }
        // Martha has no line to Rick: an honest decline about HER, not the spouse.
        #expect(r.prose.contains("Martha Lamson"), "\(r.prose)")
        #expect(!r.basisLine.contains("your spouse"))
    }

    @Test func withNeitherFocusNorSpouseHallieAsksBetweenYouAndWhom() throws {
        let graph = GedcomFamilyGraph(gedcomText: singleTree)
        let (asked, pre) = turn("find our nearest common ancestor", memory: memory(focusedOn: nil), graph: graph)
        #expect(asked == .commonAncestor(a: nil, b: nil))
        guard case .answer(let r) = pre else { Issue.record("must stay a local answer, never a translator run: \(pre)"); return }
        #expect(r.outcome == .needsClarification)
        #expect(r.clarification == nil, "no which-one object: the next sentence is a fresh ask")
        #expect(r.prose.hasPrefix("Between you and whom?"), "\(r.prose)")
        #expect(r.basisLine.contains("no spouse"), "\(r.basisLine)")
    }

    @Test func theExecutorIntentPathHonoursTheSameFallback() async throws {
        // The which-one chip resume runs the ask as an intent with
        // people ["me", "me"]; the spouse rule must hold there too.
        let graph = GedcomFamilyGraph(gedcomText: coupleTree)
        let r = try await HallieTurnExecutor.execute(
            .init(intent: intent("find our nearest common ancestor", people: ["me", "me"], operation: .commonAncestor)),
            context: context(graph))
        #expect(r.outcome == .answered)
        #expect(r.prose.contains("Z Common"), "\(r.prose)")
    }
}

// MARK: - #8 needs recompile

@Suite("Hallie — tree on disk but needs recompile (miss #8)")
struct HallieNeedsRecompileTests {

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
        func contains(_ needle: String) -> Bool { all.contains { $0.contains(needle) } }
    }

    static let pullNames = ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"]
    static let expectedProse = "The family tree is on disk but needs recompiling after the update (2 pulls: familysearch-tree-20generations.ged, familysearch-donna-20generations.ged). I can do that now — it takes about 10 seconds."

    struct Sandbox {
        let root: URL
        let assets: URL
        let gedcom: URL
        let compiled: URL
        let log = LogCapture()
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent("HallieNeedsRecompile-\(UUID().uuidString)")
            assets = root.appendingPathComponent("assets", isDirectory: true)
            gedcom = assets.appendingPathComponent("GEDCOM", isDirectory: true)
            compiled = root.appendingPathComponent("compiled", isDirectory: true)
            try FileManager.default.createDirectory(at: gedcom, withIntermediateDirectories: true)
        }
        func configuration() -> FamilyAssetConfiguration {
            FamilyAssetConfiguration(
                roots: FamilyAssetStore.Roots(assets: assets,
                                              thumbnailCache: root.appendingPathComponent("cache")),
                access: .readOnly, legacyGEDCOMDirectory: nil)
        }
        func store() -> FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: compiled)
            store.log = { log.append($0) }
            return store
        }
        func write(_ text: String, as name: String) throws -> URL {
            let url = gedcom.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                                  ofItemAtPath: url.path)
            return url
        }
        /// Rick's live state: two pulls compiled into one generation by
        /// an OLDER codec — refused by this build, sources unchanged.
        func promoteTwoPullsWithAnOldCodec() throws -> (store: FamilyGraphCompiledStore, sources: [URL], people: Int) {
            let a = try write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: pullNames[0])
            let b = try write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4)
                                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: pullNames[1])
            let store = store()
            let ga = try #require(GedcomFamilyGraph(fileURL: a)), gb = try #require(GedcomFamilyGraph(fileURL: b))
            let merged = ga.merged(with: gb)
            #expect(store.ingest(graph: merged, sources: [a, b]) != nil)
            var pointer = try #require(store.readPointer())
            pointer.codec = 4
            pointer.index = 1
            try JSONEncoder().encode(pointer).write(to: store.pointerURL)
            #expect(!FamilyGraphCompiledStore.versionsMatch(pointer))
            return (store, [a, b], merged.people.count)
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func theSharedCacheReportsTheRefusedGenerationsPulls() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })
        #expect(cache.graph(for: box.configuration(), store: store) == nil)
        #expect(cache.needsRecompile(for: box.configuration(), store: store).map(\.lastPathComponent) == Self.pullNames)
        #expect(cache.needsRecompile(for: box.configuration(), store: store) == sources)
        #expect(box.log.contains("needs recompile for 2 sources"))
    }

    @Test func everyNoTreePathSaysNeedsRecompileAndOffersThePerformedAction() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (_, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        let ctx = context(nil, needsRecompile: sources)

        func check(_ r: HallieTurnExecutor.Result, _ label: String) {
            #expect(r.prose == Self.expectedProse, "\(label): \(r.prose)")
            #expect(r.outcome == .declined, "\(label)")
            #expect(r.offeredActions == [.recompileFamilyTree], "\(label)")
            #expect(r.performsFirstOfferedAction, "\(label)")
            #expect(r.answerPlan?.shape == .fixed, "\(label): fixed prose, never re-composed")
            #expect(!r.prose.contains("don't have"), "\(label)")
        }
        // Rick's sentence (lineage shape, both forms).
        check(try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: "Donna"), context: ctx)), "lineage common ancestor")
        check(try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: nil), context: ctx)), "lineage 'our'")
        check(try #require(HallieLineageAnswer.answer(.centerTree(person: "Martha Lamson"), context: ctx)), "center tree")
        check(try #require(HallieLineageAnswer.answer(.ancestorLine(person: nil, line: .maternal, generations: 5), context: ctx)), "ancestor line")
        check(HallieLineageAnswer.noTree(ctx), "noTree(context)")
        check(try #require(HallieLineageAnswer.answer(.gedcomAwareness, context: ctx)), "what is gedcom")
        check(try #require(HallieLineageAnswer.answer(.getFamilyTree, context: ctx)), "get family tree")
        // The executor's graph route (preflight + guard).
        check(try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Rick's father", people: ["Rick"], operation: .kinship)), context: ctx), "kinship")
        check(try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Donna", people: ["Donna"], operation: .biography)), context: ctx), "biography")
        check(try await HallieTurnExecutor.execute(
            .init(intent: intent("how are rick and donna related", people: ["Rick", "Donna"], operation: .relationship)), context: ctx), "relationship")
        check(try await HallieTurnExecutor.execute(
            .init(intent: intent("find our nearest common ancestor", people: ["me", "Donna"], operation: .commonAncestor)), context: ctx), "common ancestor intent")
        // Wedding date guard.
        check(try #require(HallieMarriageDate.answer(
            question: "when did rick get married",
            payload: .init(people: ["Rick"], operation: .kinship), context: ctx)), "wedding date")
        // The label every client shows.
        #expect(HallieTurnExecutor.offerLabel(.recompileFamilyTree) == "Recompile the family tree")
    }

    @Test func genuineNoTreeWordingIsUnchanged() async throws {
        let ctx = context(nil)
        let lineage = try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: "Donna"), context: ctx))
        #expect(lineage.prose.hasPrefix("I don’t have a family tree loaded, so I can’t walk the lines yet."), "\(lineage.prose)")
        #expect(lineage.offeredActions.isEmpty)
        #expect(!lineage.performsFirstOfferedAction)
        let kinship = try await HallieTurnExecutor.execute(
            .init(intent: intent("who is Rick's father", people: ["Rick"], operation: .kinship)), context: ctx)
        #expect(kinship.prose == "I don't have an imported family tree, so I can't answer that reliably.")
        let relationship = try await HallieTurnExecutor.execute(
            .init(intent: intent("how are rick and donna related", people: ["Rick", "Donna"], operation: .relationship)), context: ctx)
        #expect(relationship.prose == "I don't have an imported family tree, so I can't work out how two people are related.")
        // A loaded graph never carries a recompile list.
        let loaded = HallieTurnExecutor.Context(graph: GedcomFamilyGraph(gedcomText: coupleTree),
                                                needsRecompile: [URL(fileURLWithPath: "/x.ged")])
        #expect(loaded.needsRecompile.isEmpty)
        #expect(HallieLineageAnswer.needsRecompileResult(loaded, queryDescription: "x") == nil)
    }

    @Test func oneOrThreePullsAreCountedInTheProse() {
        let one = HallieLineageAnswer.needsRecompileProse([URL(fileURLWithPath: "/a.ged")])
        #expect(one.contains("(1 pull: a.ged)"), "\(one)")
        let three = HallieLineageAnswer.needsRecompileProse(["/a.ged", "/b.ged", "/c.ged"].map { URL(fileURLWithPath: $0) })
        #expect(three.contains("(3 pulls: a.ged, b.ged, c.ged)"), "\(three)")
    }

    /// The whole live sequence: refused generation → Hallie's recompile
    /// offer → the app performs it (FamilyTreeRecompileCenter, standalone
    /// path, with progress) → the same ask answers from the promoted tree.
    @Test @MainActor func recompilePromotesAndTheReAskIsAnswered() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, people) = try box.promoteTwoPullsWithAnOldCodec()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })
        let configuration = box.configuration()

        // 1. The turn that hit the refused tree.
        let pending = cache.needsRecompile(for: configuration, store: store)
        #expect(pending == sources)
        let first = try #require(HallieLineageAnswer.answer(.commonAncestor(a: nil, b: nil),
                                                             context: context(nil, needsRecompile: pending)))
        #expect(first.prose == Self.expectedProse)
        #expect(first.performsFirstOfferedAction && first.offeredActions == [.recompileFamilyTree])

        // 2. The app performs the offered action, with progress.
        let phases = LogCapture()
        let center = FamilyTreeRecompileCenter()
        let outcome = await center.recompile(configuration: configuration, store: store, cache: cache,
                                             progress: { phases.append($0) })
        #expect(outcome == .promoted)
        #expect(phases.contains("Reading familysearch-tree-20generations.ged"), "\(phases.all)")
        #expect(phases.contains("Merging familysearch-donna-20generations.ged"), "\(phases.all)")
        let pointer = try #require(store.readPointer())
        #expect(FamilyGraphCompiledStore.versionsMatch(pointer))
        #expect(pointer.codec == GedcomCompiledTree.codecVersion)

        // 3. The re-ask: the promoted generation, no parse, nothing pending.
        let loaded = try #require(cache.load(for: configuration, store: store))
        #expect(loaded.compiled == true)
        #expect(loaded.graph.people.count == people)
        #expect(loaded.graph.rootPersonIDs.count == 2, "the two-root merge survived the recompile")
        #expect(cache.needsRecompile(for: configuration, store: store).isEmpty)
        let after = HallieTurnExecutor.Context(graph: loaded.graph, needsRecompile: pending, speakers: speakers)
        #expect(HallieLineageAnswer.needsRecompileResult(after, queryDescription: "x") == nil)
        let reAsk = try #require(HallieLineageAnswer.answer(.gedcomAwareness, context: after))
        let reAskProse = reAsk.prose
        #expect(reAskProse != Self.expectedProse)
        #expect(!reAskProse.contains("needs recompiling"), "\(reAskProse)")
        #expect(reAskProse.contains("\(people) people and"), "\(reAskProse)")

        // 4. Nothing pending → the center says so without running.
        let again = await center.recompile(configuration: configuration, store: store, cache: cache, progress: { _ in })
        #expect(again == .nothingPending)
    }

    @Test @MainActor func aPullThatNoLongerParsesIsReportedNotHidden() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        let cache = FamilyGraphSharedCache(log: { box.log.append($0) })
        // Sabotage pull b's bytes but keep its size/mtime key so the
        // generation still looks recompilable; the recompile then fails.
        let b = sources[1]
        let mtime = try #require((try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        let size = try #require((try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize)
        try Data(repeating: 0x20, count: size).write(to: b)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: b.path)
        // This is fixture setup, not an optional branch. Returning here
        // used to turn a broken setup (or a changed source-key algorithm)
        // into a green test that exercised no recompile at all.
        let pending = cache.needsRecompile(
            for: box.configuration(), store: store)
        try #require(
            !pending.isEmpty,
            "fixture no longer reaches the needs-recompile state after the source was poisoned")
        let outcome = await FamilyTreeRecompileCenter().recompile(
            configuration: box.configuration(), store: store, cache: cache, progress: { _ in })
        #expect(outcome == .failed)
        #expect(box.log.contains("nothing promoted"))
    }
}
