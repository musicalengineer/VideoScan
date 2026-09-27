// TreeWalkRealTreeReport.swift
// SENSOR (read-only, opt-in): walk Rick's real merged tree and PRINT the
// numbers for his eyes — counts by line, by birth region, the top checks,
// coverage and timings. Nothing is pinned: the tree changes with every
// FamilySearch refresh. Never writes anything.
//
//   env VS_REAL_GEDCOM=/Volumes/FamilyArchive/…/familysearch-merged-mco-20260917.ged \
//       swift test --package-path VideoScan/VideoScanCore --filter TreeWalkRealTreeReport
//
// The identity rulings beside the .ged are applied, like the app does.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("TreeWalkRealTreeReport")
struct TreeWalkRealTreeReport {
    @Test func reportOnTheRealTree() throws {
        guard let path = ProcessInfo.processInfo.environment["VS_REAL_GEDCOM"] else {
            print("[walk] set VS_REAL_GEDCOM to run the real-tree report")
            return
        }
        let url = URL(fileURLWithPath: path)
        let clock = ContinuousClock()
        let t0 = clock.now
        var graph = try #require(GedcomFamilyGraph(fileURL: url))
        let rulings = FamilyIdentityDecisions.load(from: url.deletingLastPathComponent())
        graph = graph.applyingIdentityRulings(rulings)
        _ = graph.index
        print("[walk] parsed \(graph.people.count) people in \(clock.now - t0); hidden \(graph.suppressedPersonIDs.count)")
        let starts = graph.roots.prefix(2).map(\.id)
        print("[walk] starts: \(graph.roots.prefix(2).map(\.name))")

        var progress = 0
        var sink = TreeWalkLog.Sink(TreeWalkLog(mode: .background, displayNames: ["Rick", "Donna"]))
        var logLines: [String] = []
        let t1 = clock.now
        let result = try TreeWalk.walk(graph, options: .init(starts: starts)) { event in
            if case .progress = event { progress += 1 }
            logLines += sink.lines(for: event)
        }
        let elapsed = clock.now - t1
        logLines += sink.lines(for: .finished(result), savedNote: "decorations not saved (report)")
        let s = result.summary
        print("[walk] walk \(elapsed) (Debug) — phases: walk \(String(format: "%.1f", s.walkMilliseconds)) ms, checks \(String(format: "%.1f", s.checksMilliseconds)) ms, total \(String(format: "%.0f", s.totalMilliseconds)) ms")
        print("[walk] visited \(s.peopleWalked) of \(s.peopleInTree); generations Rick \(s.generationsFromFirst), Donna \(s.generationsFromSecond); progress events \(progress)")
        print("[walk] by line: " + TreeWalk.Line.allCases.map { "\($0.rawValue) \(s.byLine[$0] ?? 0)" }.joined(separator: ", "))
        print("[walk] by region (walked): " + BirthplaceClassifier.BirthRegion.allCases
            .map { "\($0.label) \(s.byRegion[$0] ?? 0)" }.joined(separator: ", "))
        print("[walk] checks \(result.checks.count) (warn \(s.warnCount), info \(s.infoCount)); cycles \(s.cycleCount)")
        for kind in TreeWalk.CheckKind.allCases {
            print("[walk]   \(kind.rawValue): \(s.checksByKind[kind] ?? 0)")
        }
        for c in result.checks where c.kind == .ancestorCycle { print("[walk]   CYCLE: \(c.reason)") }
        print("[walk] --- first 10 warn checks ---")
        for c in result.checks.filter({ $0.severity == .warn }).prefix(10) { print("[walk]   \(c.reason)") }
        print("[walk] coverage (walked): " + s.coverageWalked.map(\.line).joined(separator: "; "))
        print("[walk] estimated ancestor counts: \(s.estimatedAncestorCounts)")
        if let rick = result.decoration(for: starts[0]) {
            print("[walk] Rick: ancestors \(rick.ancestorCount.spoken), dated share \(rick.documentedAncestorFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "-"), descendants \(rick.descendantCount.spoken)")
        }
        // Where Rick's and Donna's lines meet: the nearest shared ancestors.
        let both = result.ids.indices.filter { result.decorations[$0].line == .both }
            .sorted { (result.decorations[$0].generationFromFirst ?? 99) + (result.decorations[$0].generationFromSecond ?? 99)
                    < (result.decorations[$1].generationFromFirst ?? 99) + (result.decorations[$1].generationFromSecond ?? 99) }
        print("[walk] on both lines: \(both.count); nearest shared ancestors:")
        for o in both.prefix(5) {
            let d = result.decorations[o]
            print("[walk]   \(result.names[o]) b.\(d.birthYear.map(String.init) ?? "?") — gen \(d.generationFromFirst ?? -1) from Rick, \(d.generationFromSecond ?? -1) from Donna; \(d.birthRegion.label)")
        }
        let unknownPlaces = Dictionary(grouping: result.ids.indices.filter {
            result.visible[$0] && result.decorations[$0].line != .none && result.decorations[$0].birthRegion == .unknown
        }, by: { graph.people[result.ids[$0]]?.birthPlace.map { BirthplaceClassifier.components(of: $0).last?.trimmingCharacters(in: .whitespaces) ?? "" } ?? "(none)" })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }.prefix(12)
        print("[walk] top unknown-region tails: " + unknownPlaces.map { "\($0.0) \($0.1)" }.joined(separator: " | "))
        print("[walk] --- log sample ---")
        for line in logLines.prefix(6) { print("[walk]   \(line)") }
        if let last = logLines.last { print("[walk]   \(last)") }
    }
}
