import Foundation
import Testing
@testable import VideoScan

struct RecoveryOutcomeContractTests {
    @Test func noPointerAdoptionCreatesLoadablePointer() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let expected = try #require(f.store.readPointer())
        try FileManager.default.moveItem(at: f.store.pointerURL, to: f.root.appendingPathComponent("saved-pointer.json"))
        let outcome = f.loader().loadNewestOutcome()
        #expect(outcome.graph?.people.count == 5)
        #expect(f.store.readPointer()?.current == expected.current)
        #expect(f.store.loadCurrent()?.graph.people.count == 5)
    }

    @Test func movedBrokenBaselineReportsSuperseded() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.breakPointer()
        let selected = try #require(f.store.intactMultiSourceGeneration())
        let winner = try f.promoteLarger()
        let result = f.store.adopt(selected)
        guard case .superseded = result else {
            Issue.record("A promotion after lookup must report superseded, not adopted"); return
        }
        #expect(f.store.readPointer() == winner)
    }

    @Test func currentCandidateStillChecksForInterveningPromotion() throws {
        let f = try Fixture(); defer { f.cleanup() }
        // Keep the named generation, but invalidate the pointer's source binding.
        // This reaches loader recovery even though lookup.current == candidate.
        var mismatched = try #require(f.store.readPointer())
        mismatched.sourceKeys = []
        try JSONEncoder().encode(mismatched).write(to: f.store.pointerURL)
        try #require(f.store.loadCurrent() == nil)
        let selected = try #require(f.store.intactMultiSourceGeneration())
        try #require(f.store.readPointer()?.current == selected.generation)
        let winner = try f.promoteLarger()
        let result = f.store.adopt(selected)
        if case .adopted(let stale) = result {
            Issue.record("Adoption reported success with stale \(stale.people.count)-person graph after a 9-person promotion")
        }
        #expect(f.store.readPointer() == winner, "The newer pointer must also remain intact")
    }

    @Test func supersededLoaderReturnsTheNewerUsableGraph() throws {
        try exerciseLoaderRace(makeWinnerUnavailable: false)
    }

    @Test func supersededLoaderMustNotNarrowWhenWinnerCannotReload() throws {
        try exerciseLoaderRace(makeWinnerUnavailable: true)
    }

    @Test func failedAdoptionLockMustNotReturnASingleSourceTree() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.breakPointer()
        let before = try #require(f.store.readPointer())
        let candidate = try #require(f.store.intactMultiSourceGeneration())
        try #require(candidate.manifest.peopleCount == 5)
        // A directory at the lock pathname deterministically makes open(O_RDWR) fail.
        try FileManager.default.moveItem(at: f.store.lockURL, to: f.root.appendingPathComponent("old-lock"))
        try FileManager.default.createDirectory(at: f.store.lockURL, withIntermediateDirectories: false)
        let outcome = f.loader().loadNewestOutcome()
        print("LOCK_FAILURE_EVIDENCE returned=\(outcome.graph?.people.count ?? -1) pointerChanged=\(f.store.readPointer() != before)")
        #expect(outcome.graph == nil || outcome.graph?.people.count == 5,
                "Failed recovery must fail closed or retain the intact graph; never return only the visible source")
        #expect(f.store.readPointer() == before)
    }

    private func exerciseLoaderRace(makeWinnerUnavailable: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.breakPointer()
        var recovering = f.store
        var injected = false
        var injectionError: Error?
        var winner: FamilyGraphCompiledStore.Pointer?
        // loadCurrent exits on the broken pointer before hashing. The first hash
        // log is inside recovery lookup, after its CAS baseline was captured.
        recovering.log = { line in
            guard !injected, line.contains("hashed") else { return }
            injected = true
            do {
                winner = try f.promoteLarger()
                if makeWinnerUnavailable {
                    try FileManager.default.moveItem(at: f.c, to: f.root.appendingPathComponent("Gamma.unavailable"))
                }
            } catch { injectionError = error }
        }
        let outcome = f.loader(store: recovering).loadNewestOutcome()
        try #require(injected, "The production recovery lookup must reach the interleaving hook")
        try #require(injectionError == nil, "Synthetic competing promotion must succeed: \(String(describing: injectionError))")
        let promoted = try #require(winner)
        print("SUPERSEDED_CALLER_EVIDENCE unavailable=\(makeWinnerUnavailable) returned=\(outcome.graph?.people.count ?? -1) pointerChanged=\(f.store.readPointer() != promoted)")
        #expect(f.store.readPointer() == promoted, "Recovery must preserve the winning promotion even if it cannot be reloaded")
        if makeWinnerUnavailable {
            #expect(outcome.graph == nil || outcome.graph?.people.count == 9,
                    "An unavailable winner cannot authorize a smaller replacement")
        } else {
            #expect(outcome.graph?.people.count == 9)
        }
    }

    private struct Fixture {
        let root: URL
        let originals: URL
        let a: URL
        let b: URL
        let c: URL
        let ab: GedcomFamilyGraph
        let abc: GedcomFamilyGraph
        let store: FamilyGraphCompiledStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryOutcome-\(UUID().uuidString)")
            originals = root.appendingPathComponent("originals")
            let hidden = originals.appendingPathComponent("pulls")
            try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
            func source(_ url: URL, _ label: String, _ count: Int) throws -> GedcomFamilyGraph {
                var lines = ["0 HEAD"]
                for n in 1...count { lines += ["0 @I\(n)@ INDI", "1 NAME \(label)\(n) /Fixture/", "1 _FSFTID \(label)-\(n)"] }
                lines.append("0 TRLR")
                try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                // #require is a fatal fixture assertion, like ASSERT_TRUE in C++.
                return try #require(GedcomFamilyGraph(fileURL: url))
            }
            a = originals.appendingPathComponent("Alpha.ged")
            b = hidden.appendingPathComponent("Beta.ged")
            c = hidden.appendingPathComponent("Gamma.ged")
            let ga = try source(a, "Alpha", 2), gb = try source(b, "Beta", 3), gc = try source(c, "Gamma", 4)
            ab = ga.merged(with: gb); abc = ab.merged(with: gc)
            try #require(ab.people.count == 5 && abc.people.count == 9)
            var s = FamilyGraphCompiledStore(root: root.appendingPathComponent("compiled")); s.log = { _ in }; store = s
            _ = try #require(store.ingest(graph: ab, sources: [a, b]))
        }
        func loader(store override: FamilyGraphCompiledStore? = nil) -> FamilyGraphFileLoader {
            var l = FamilyGraphFileLoader(originalsDirectory: originals)
            l.compiledStore = override ?? store; l.readOnly = false; return l
        }
        func breakPointer() throws {
            var p = try #require(store.readPointer()); p.current = "gen-missing"; p.previous = nil
            try JSONEncoder().encode(p).write(to: store.pointerURL)
        }
        func promoteLarger() throws -> FamilyGraphCompiledStore.Pointer {
            _ = try #require(store.ingest(graph: abc, sources: [a, b, c]))
            return try #require(store.readPointer())
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
