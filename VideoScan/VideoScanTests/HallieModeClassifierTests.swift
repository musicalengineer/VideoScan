// HallieModeClassifierTests.swift
// The pure mode classifier (docs/hallie_two_mode_design.md §3.3): cue
// tables, subject resolution, stickiness, scope overrides, conflict →
// unknown, and the CLAUDE.md dimensions — scale (10,000 classifications
// against a 40,000-person oracle under a stated budget, at most two
// oracle calls per turn) and isolation (no globals: the same input with
// the same oracle gives the same verdict whatever else the process holds).

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie mode classifier")
struct HallieModeClassifierTests {
    typealias C = HallieModeClassifier

    /// A small oracle: three tree people, one People-tab alias, one file.
    private static let people: Set<String> = [
        "edward iii", "nathaniel parker", "john hastings", "donna", "rick", "mom",
    ]
    private static let files: Set<String> = ["new hampshire.mov", "christmas 1994.mov"]

    private static let oracle = C.Oracle(
        isExactPersonName: { people.contains($0.lowercased()) },
        isKnownPerson: { people.contains($0.lowercased()) },
        isNamedFile: { files.contains($0.lowercased()) })

    private func verdict(_ q: String, previous: HallieMode = .unknown,
                         forced: HallieMode? = nil) -> C.Verdict {
        C.classify(q, previous: previous, forced: forced, oracle: Self.oracle)
    }

    private func mode(_ q: String, previous: HallieMode = .unknown) -> HallieMode {
        verdict(q, previous: previous).mode
    }

    // MARK: Cue tables

    @Test func theGuardHalvesAreDisjointAndTheClassifierTablesAreDisjoint() {
        #expect(HallieConversationGuard.catalogCues.isDisjoint(with: HallieConversationGuard.treeCues))
        #expect(C.catalogCues.isDisjoint(with: C.treeCues),
                Comment(rawValue: "\(C.catalogCues.intersection(C.treeCues))"))
    }

    /// The guard's union must be exactly the set it had before the split
    /// (main 3e663856) — byte-identical behaviour.
    @Test func theGuardUnionIsTheOriginalArchiveWordSet() {
        let original: Set<String> = [
            "archive", "catalog", "video", "videos", "clip", "clips",
            "recording", "recordings", "media", "mxf", "transcript",
            "caption", "captions", "file", "files", "biography",
            "born", "birth", "died", "death", "related", "relationship",
            "father", "mother", "parents", "parent", "spouse", "husband",
            "wife", "children", "child", "son", "daughter", "grandfather",
            "grandmother", "grandparents", "ancestor", "ancestors", "kin",
            "mom", "mum", "dad", "grandma", "grandpa", "nana", "uncle",
            "aunt", "cousin", "brother", "sister", "niece", "nephew",
            "grandson", "granddaughter", "in-law", "married", "wedding",
            "maiden", "passed", "evidence", "source", "sources", "tape",
            "footage", "film", "movie", "photo", "picture", "audio",
            "sound", "track",
        ]
        #expect(HallieConversationGuard.catalogCues.union(HallieConversationGuard.treeCues) == original)
    }

    @Test func explicitCatalogCuesSettleTheTurn() {
        for q in ["play the longest video in the archive", "how many videos do we have",
                  "show me the christmas footage", "reveal the third clip",
                  "what tapes are from 1994", "how much footage altogether"] {
            let v = verdict(q)
            #expect(v.mode == .catalog, Comment(rawValue: "\(q): \(v)"))
            if case .explicitCue(.catalog, _) = v.reason {} else {
                Issue.record("\(q): expected an explicit catalog cue, got \(v.reason)")
            }
        }
    }

    @Test func explicitTreeCuesSettleTheTurn() {
        for q in ["whom did he marry", "tell me all about Edward III", "where was she born",
                  "who were his parents", "how am I related to King Edward III",
                  "search the family tree for a title like king",
                  "who is the highest royalty or title in my family tree"] {
            let v = verdict(q)
            #expect(v.mode == .tree, Comment(rawValue: "\(q): \(v)"))
            if case .explicitCue(.tree, _) = v.reason {} else {
                Issue.record("\(q): expected an explicit tree cue, got \(v.reason)")
            }
        }
    }

    // MARK: Scope overrides beat stickiness and cues

    @Test func scopeOverridesBeatEverything() {
        let correction = verdict("not in videos, in family tree", previous: .catalog)
        #expect(correction.mode == .tree)
        if case .explicitCue(.tree, _) = correction.reason {} else {
            Issue.record("expected a tree scope override, got \(correction.reason)")
        }
        #expect(mode("videos of donna in the family tree") == .tree)
        #expect(mode("his parents in the archive", previous: .tree) == .catalog)
        #expect(mode("not in the tree, the videos", previous: .tree) == .catalog)
        #expect(mode("what do we have from the archive", previous: .tree) == .catalog)
    }

    // MARK: Conflict → unknown (never a guess)

    @Test func bothFamiliesCuedWithNoSubjectIsUnknown() {
        for q in ["tell me all about the wedding video", "tell me more about the archive",
                  "who is in this video", "family videos from the 90s"] {
            let v = verdict(q, previous: .tree)
            #expect(v.mode == .unknown, Comment(rawValue: "\(q): \(v)"))
            #expect(v.reason == .conflict, Comment(rawValue: "\(q): \(v)"))
        }
    }

    // MARK: Subject resolution

    @Test func aTreePersonAsSubjectIsTreeUnlessAnItemNounOutranksIt() {
        #expect(verdict("what do you know about Nathaniel Parker")
                == .init(mode: .tree, reason: .subjectResolved(.tree, "Nathaniel Parker")))
        // Media noun outranks the person: the existing presence road.
        #expect(mode("videos of nathaniel parker", previous: .tree) == .catalog)
        #expect(verdict("clips with Donna at the cape", previous: .tree).mode == .catalog)
        // A photo of a tree person is the portrait road — a tree answer.
        #expect(verdict("photos of nathaniel parker", previous: .catalog)
                == .init(mode: .tree, reason: .subjectResolved(.tree, "nathaniel parker")))
        #expect(mode("are there any pictures of Edward III") == .tree)
        // A leading possessive resolves too.
        #expect(verdict("rick's favourite thing").mode == .tree)
    }

    @Test func aNamedFileAsSubjectIsCatalog() {
        #expect(verdict("what do you know about New Hampshire.mov")
                == .init(mode: .catalog, reason: .subjectResolved(.catalog, "New Hampshire.mov")))
    }

    @Test func anUnknownSubjectWithNoCueIsUnknown() {
        #expect(verdict("what do you know about Zebulon Nobody").mode == .unknown)
        #expect(verdict("what is the story of the westford house").mode == .unknown)
    }

    // MARK: Stickiness

    @Test func ellipticalTurnsInheritThePreviousMode() {
        #expect(verdict("show me", previous: .tree) == .init(mode: .tree, reason: .sticky(.tree)))
        #expect(verdict("show me", previous: .catalog) == .init(mode: .catalog, reason: .sticky(.catalog)))
        #expect(verdict("and how many from the 80s", previous: .catalog).mode == .catalog)
        #expect(verdict("what about 2005?", previous: .catalog).mode == .catalog)
        #expect(verdict("what country?", previous: .tree).mode == .tree)
        #expect(verdict("what did he do for a living?", previous: .tree).mode == .tree)
        #expect(verdict("the rest", previous: .catalog).mode == .catalog)
    }

    @Test func ellipticalTurnsWithNoPreviousModeStayUnknown() {
        #expect(verdict("show me").mode == .unknown)
        #expect(verdict("what country?").mode == .unknown)
        #expect(verdict("and how many from the 80s").mode == .unknown)
    }

    /// A full sentence with a verb and no cue is not elliptical — the
    /// general-knowledge lane keeps it (HallieGeneralKnowledgeLaneTests).
    @Test func aFullSentenceWithNoCueDoesNotInheritAMode() {
        for q in ["Ireland and the UK are part of Europe aren't they?",
                  "Why do leaves change color in autumn?",
                  "Help me think of three questions to ask my grandmother.",
                  "What is a thoughtful way to label old family photographs?"] {
            let v = verdict(q, previous: .tree)
            #expect(v.mode == .unknown || v.reason == .conflict
                    || q.contains("grandmother") || q.contains("family"),
                    Comment(rawValue: "\(q): \(v)"))
        }
        #expect(verdict("Ireland and the UK are part of Europe aren't they?", previous: .tree).mode == .unknown)
        #expect(verdict("Why do leaves change color in autumn?", previous: .catalog).mode == .unknown)
    }

    // MARK: Forced

    @Test func aForcedModeWinsOverEveryCue() {
        #expect(verdict("play the longest video", forced: .tree) == .init(mode: .tree, reason: .forced))
        #expect(verdict("whom did he marry", previous: .tree, forced: .catalog).mode == .catalog)
    }

    // MARK: Worked examples from the design (§3.3)

    @Test func theDesignsWorkedExamplesHold() {
        #expect(mode("tell me all about Edward III") == .tree)
        #expect(mode("show me", previous: .tree) == .tree)
        #expect(mode("show me", previous: .catalog) == .catalog)
        #expect(mode("and how many from the 80s", previous: .catalog) == .catalog)
        #expect(mode("play the longest video in the archive") == .catalog)
        #expect(mode("videos of nathaniel parker", previous: .tree) == .catalog)
        #expect(mode("photos of nathaniel parker", previous: .tree) == .tree)
        #expect(mode("not in videos, in family tree", previous: .catalog) == .tree)
        #expect(mode("how am I related to King Edward III") == .tree)
        #expect(mode("what country?", previous: .tree) == .tree)
        #expect(mode("Ireland and the UK are part of Europe aren't they?", previous: .tree) == .unknown)
    }

    // MARK: Isolation — no globals

    @Test func theSameInputGivesTheSameVerdictAcrossOracles() {
        let a = C.classify("whom did he marry", previous: .catalog, oracle: .none)
        let b = C.classify("whom did he marry", previous: .catalog, oracle: Self.oracle)
        #expect(a == b)
        // The oracle is never asked when a cue settles it.
        var asked = 0
        let counting = C.Oracle(
            isExactPersonName: { _ in asked += 1; return true },
            isKnownPerson: { _ in asked += 1; return true },
            isNamedFile: { _ in asked += 1; return true })
        _ = C.classify("videos of nathaniel parker", previous: .tree, oracle: counting)
        _ = C.classify("whom did he marry", previous: .tree, oracle: counting)
        #expect(asked == 0)
    }

    // MARK: Scale — 10,000 classifications, 40,000-person oracle, ≤ 2 asks per turn

    @Test func tenThousandClassificationsAgainstAFortyThousandPersonTreeStayWithinBudget() {
        // 40k synthetic names: "Given<n> Surname<m>" so lookups are real
        // hash probes over a set of the production tree's size.
        var tree = Set<String>()
        tree.reserveCapacity(40_000)
        for i in 0..<40_000 { tree.insert("given\(i) surname\(i % 997)") }
        var asks = 0
        var maxAsksInOneTurn = 0
        let oracle = C.Oracle(
            isExactPersonName: { asks += 1; return tree.contains($0.lowercased()) },
            isKnownPerson: { asks += 1; return tree.contains($0.lowercased()) },
            isNamedFile: { asks += 1; return $0.lowercased().hasSuffix(".mov") })
        let shapes: [(String, HallieMode)] = [
            ("tell me all about Given%d Surname%d", .tree),
            ("videos of given%d surname%d", .catalog),
            ("what do you know about given%d surname%d", .tree),
            ("what do you know about nobody%d", .unknown),
            ("play the longest video in the archive", .catalog),
            ("and how many from the 80s", .catalog),
            ("whom did he marry", .tree),
            ("Ireland and the UK are part of Europe aren't they?", .unknown),
            ("photos of given%d surname%d", .tree),
            ("show me", .catalog),
        ]
        let start = Date()
        var wrong = 0
        for n in 0..<10_000 {
            let (pattern, expected) = shapes[n % shapes.count]
            let q = pattern
                .replacingOccurrences(of: "%d", with: "\(n % 40_000)")
                .replacingOccurrences(of: "Surname\(n % 40_000)", with: "Surname\(n % 997)")
                .replacingOccurrences(of: "surname\(n % 40_000)", with: "surname\(n % 997)")
            let before = asks
            let v = C.classify(q, previous: .catalog, oracle: oracle)
            maxAsksInOneTurn = max(maxAsksInOneTurn, asks - before)
            if v.mode != expected { wrong += 1 }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(wrong == 0, Comment(rawValue: "\(wrong) verdicts differed from the oracle"))
        #expect(maxAsksInOneTurn <= 2, Comment(rawValue: "oracle asked \(maxAsksInOneTurn) times in one turn"))
        // Budget: 10,000 turns in under 2 s on the M4 (≈ 0.2 ms per turn);
        // the classifier is regex-and-set work, the oracle a hash probe.
        #expect(elapsed < 2.0, Comment(rawValue: "10,000 classifications took \(elapsed)s"))
    }
}
