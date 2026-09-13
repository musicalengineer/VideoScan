// HallieModeGateTests.swift
// The post-translation mode gate (design §3.4 B), pure: tree mode turns a
// one-person catalog AST into the graph operation the field guards read,
// keeps it when the words name media, declines it when nobody is named;
// catalog mode turns a graph AST into a presence search when a media cue
// is present and otherwise declines with a chip that re-asks under the
// tree; unknown keeps everything.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie mode gate")
struct HallieModeGateTests {
    typealias Gate = HallieModeGate
    private let memory = HallieTurnExecutor.ConversationMemory()

    private func tree(_ ast: ArchivistQueryAST, _ q: String) -> Gate.Outcome {
        Gate.reconcile(ast: ast, mode: .tree, question: q, memory: memory)
    }

    private func catalog(_ ast: ArchivistQueryAST, _ q: String, play: Bool = false) -> Gate.Outcome {
        Gate.reconcile(ast: ast, mode: .catalog, question: q, memory: memory, playAfterAnswer: play)
    }

    // MARK: Tree mode

    @Test func treeModeRewritesAOnePersonPresenceToTheGuardsOperation() {
        let presence = ArchivistQueryAST.presence(.init(people: ["john hastings"], keywords: ["living"]))
        #expect(tree(presence, "what did John Hastings do for a living?")
                == .rewrite(.graph(.init(people: ["john hastings"], operation: .biography)),
                            note: "read “what did John Hastings do for a living?” as a family-tree question about john hastings, not a catalog search"))
        // strict-004 shape: the kin word picks the relation.
        #expect(tree(.presence(.init(people: ["john hastings"], keywords: ["marry"])), "whom did John Hastings marry")
                == .rewrite(.graph(.init(people: ["john hastings"], operation: .kinship, relation: .spouse)),
                            note: "read “whom did John Hastings marry” as a family-tree question about john hastings, not a catalog search"))
        // strict-015 shape.
        if case .rewrite(let ast, _) = tree(.presence(.init(people: ["nathaniel caleb parker"], keywords: ["parents"])),
                                             "tell me about Nathaniel Caleb Parker's parents") {
            #expect(ast == .graph(.init(people: ["nathaniel caleb parker"], operation: .kinship, relation: .parents)))
        } else {
            Issue.record("expected a kinship rewrite")
        }
        // A place, a life event, a biography opener; cross and aggregate too.
        if case .rewrite(let ast, _) = tree(.cross(.init(people: ["edward iii"], keywords: ["born"], transcript: [])),
                                             "where was Edward III born") {
            #expect(ast == .graph(.init(people: ["edward iii"], operation: .birthPlace)))
        } else { Issue.record("expected a birthPlace rewrite") }
        if case .rewrite(let ast, _) = tree(.aggregate(.init(operation: .coOccurrence, anchorPeople: ["edward iii"])),
                                             "when did Edward III die") {
            #expect(ast == .graph(.init(people: ["edward iii"], operation: .death)))
        } else { Issue.record("expected a death rewrite") }
        if case .rewrite(let ast, _) = tree(.presence(.init(people: ["edward iii"], keywords: ["all", "about"])),
                                             "tell me all about Edward III") {
            #expect(ast == .graph(.init(people: ["edward iii"], operation: .biography)))
        } else { Issue.record("expected a biography rewrite") }
    }

    @Test func treeModeKeepsACatalogASTWhenTheWordsNameMedia() {
        let presence = ArchivistQueryAST.presence(.init(people: ["donna"], keywords: ["christmas"]))
        #expect(tree(presence, "the Christmas tape with Donna") == .keep)
        #expect(tree(presence, "videos of donna at christmas") == .keep)
        #expect(tree(presence, "any pictures of donna") == .keep)
        #expect(tree(presence, "is donna in the archive") == .keep)
    }

    @Test func treeModeDeclinesACatalogASTNamingNobody() {
        let outcome = tree(.presence(.init(yearStart: 1990, yearEnd: 1999)), "and in the 90s?")
        guard case .decline(let result) = outcome else {
            Issue.record("expected a decline, got \(outcome)")
            return
        }
        #expect(result.route == .graph)
        #expect(result.outcome == .declined)
        #expect(result.mode == .tree)
        #expect(result.prose == "I read that as a family-tree question, but I couldn't tell who it is about — name the person, "
                + "or say “in the catalog” and I'll search the videos instead.")
        // Two people: still nobody definite.
        if case .decline = tree(.presence(.init(people: ["rick", "donna"])), "how are they related") {} else {
            Issue.record("two people must decline, never guess one")
        }
    }

    @Test func treeModeKeepsGraphTemporalAndRecordASTs() {
        #expect(tree(.graph(.init(people: ["rick"], operation: .biography)), "tell me about rick") == .keep)
        #expect(tree(.temporal(.init(subject: "timmy", operation: .age, reference: .currentSelection)), "how old is timmy") == .keep)
        #expect(tree(.record(.init(reference: .currentSelection, operations: [.people])), "who is in this") == .keep)
    }

    // MARK: Catalog mode

    @Test func catalogModeRewritesAGraphASTToPresenceOnAMediaCue() {
        let graph = ArchivistQueryAST.graph(.init(people: ["donna"], operation: .biography))
        #expect(catalog(graph, "donna at the cape", play: true)
                == .rewrite(.presence(.init(people: ["donna"])),
                            note: "read “donna at the cape” as a catalog search for donna, not a family-tree lookup"))
        #expect(catalog(graph, "videos of donna") == .rewrite(.presence(.init(people: ["donna"])),
                            note: "read “videos of donna” as a catalog search for donna, not a family-tree lookup"))
        #expect(catalog(graph, "reveal donna") == .rewrite(.presence(.init(people: ["donna"])),
                            note: "read “reveal donna” as a catalog search for donna, not a family-tree lookup"))
        // A media cue with nobody named: nothing to search for — keep.
        #expect(catalog(.graph(.init(people: [], operation: .familyTree)), "play the family tree video") == .keep)
    }

    @Test func catalogModeDeclinesAGraphASTWithNoMediaCueAndOffersTheTree() {
        let outcome = catalog(.graph(.init(people: ["rick"], operation: .biography)), "what about rick")
        guard case .decline(let result) = outcome else {
            Issue.record("expected a decline, got \(outcome)")
            return
        }
        #expect(result.route == .followUp)
        #expect(result.outcome == .declined)
        #expect(result.mode == .catalog)
        #expect(result.prose == "I'm looking in the catalog right now — did you mean the family tree?")
        #expect(result.offeredActions == [.ask(question: "in the family tree, what about rick", label: "Ask the family tree")])
        // The chip's question is a scope override for the classifier.
        #expect(HallieModeClassifier.classify("in the family tree, what about rick", previous: .catalog, oracle: .none).mode == .tree)
    }

    @Test func catalogModeKeepsCatalogASTs() {
        #expect(catalog(.presence(.init(people: ["donna"])), "videos of donna") == .keep)
        #expect(catalog(.aggregate(.init(operation: .coOccurrence, anchorPeople: ["archive"])), "the longest video in the archive") == .keep)
    }

    // MARK: Unknown

    @Test func unknownModeKeepsEverything() {
        for ast: ArchivistQueryAST in [
            .presence(.init(people: ["john hastings"], keywords: ["marry"])),
            .graph(.init(people: ["rick"], operation: .biography)),
            .aggregate(.init(operation: .coOccurrence, anchorPeople: ["archive"])),
        ] {
            #expect(Gate.reconcile(ast: ast, mode: .unknown, question: "anything", memory: memory) == .keep)
        }
    }
}
