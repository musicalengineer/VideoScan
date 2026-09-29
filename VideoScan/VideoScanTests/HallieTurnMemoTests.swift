import Foundation
import Testing
@testable import VideoScan

/// #567: People and CyberBrain are read once per Hallie turn, fresh on the
/// next turn, and never served stale after Hallie writes during the turn.
@Suite("Hallie turn memo — identity sources read once per turn")
struct HallieTurnMemoTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func concurrentGuardsShareOneRead() async {
        let reads = Counter()
        let memo = TurnMemo<[Int]?> { reads.bump(); Thread.sleep(forTimeInterval: 0.01); return [1] }
        await withTaskGroup(of: [Int]?.self) { group in
            for _ in 0..<16 { group.addTask { memo.value() } }
            for await value in group { #expect(value == [1]) }
        }
        #expect(reads.value == 1)
    }

    @Test func nilIsAnAnswerNotAReasonToLookAgain() {
        let reads = Counter()
        let memo = TurnMemo<CyberBrainIndex?> { reads.bump(); return nil }
        #expect(memo.value() == nil)
        #expect(memo.value() == nil)
        #expect(reads.value == 1)
    }

    @Test func forgetMakesTheNextAskReadAgain() {
        let reads = Counter()
        let memo = TurnMemo<Int> { reads.bump(); return reads.value }
        #expect(memo.value() == 1)
        memo.forget()
        #expect(memo.value() == 2)
        #expect(reads.value == 2)
    }

    private func dependencies(profileReads: Counter, brainReads: Counter,
                              written: Counter) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in .init(ast: .presence(.init(people: ["donna"])), responderHost: "fixture") },
            loadProfiles: { profileReads.bump(); return [.init(stableID: "rick", canonicalName: "Rick")] },
            loadGraph: { nil },
            loadCyberBrain: { brainReads.bump(); return nil },
            recordTestimony: { _ in written.bump() },
            executeRequest: { request, context in try await HallieTurnExecutor.execute(request, context: context) },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
    }

    @Test func eachTurnReadsOnceAndTheNextTurnReadsFresh() {
        let profiles = Counter(), brain = Counter(), written = Counter()
        let base = dependencies(profileReads: profiles, brainReads: brain, written: written)

        let first = base.readingIdentitySourcesOncePerTurn()
        _ = first.loadProfiles(); _ = first.loadProfiles(); _ = first.loadCyberBrain(); _ = first.loadCyberBrain()
        #expect(profiles.value == 1)
        #expect(brain.value == 1)

        let second = base.readingIdentitySourcesOncePerTurn()
        _ = second.loadProfiles(); _ = second.loadCyberBrain()
        #expect(profiles.value == 2, "a People-tab edit between questions must be seen")
        #expect(brain.value == 2)
    }

    @Test func aWriteDuringTheTurnIsNeverAnsweredFromTheOlderRead() throws {
        let profiles = Counter(), brain = Counter(), written = Counter()
        let turn = dependencies(profileReads: profiles, brainReads: brain, written: written)
            .readingIdentitySourcesOncePerTurn()
        _ = turn.loadCyberBrain(); _ = turn.loadProfiles()
        try turn.recordTestimony(.init(subjectName: "Donna", speakerName: "Rick", text: "fixture",
                                       kind: .note, date: Date(timeIntervalSince1970: 0)))
        #expect(written.value == 1)
        _ = turn.loadCyberBrain(); _ = turn.loadProfiles()
        #expect(brain.value == 2)
        #expect(profiles.value == 2)
    }

    @Test func theUnwrappedDependenciesStillReadEveryTime() {
        let profiles = Counter(), brain = Counter(), written = Counter()
        let base = dependencies(profileReads: profiles, brainReads: brain, written: written)
        _ = base.loadProfiles(); _ = base.loadProfiles()
        #expect(profiles.value == 2)
    }
}
