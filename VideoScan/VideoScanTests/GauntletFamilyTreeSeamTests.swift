// GauntletFamilyTreeSeamTests.swift
//
// `-gauntletFamilyTreeDir` (GauntletSeams.familyTreeDirectory) — the seam
// Gauntlet flow 7 uses to give the isolated app a synthetic tree.
//   ISOLATION  outside a test host the seam is nil even when the argument is
//              present: production never reads a fixture tree. Relative and
//              empty values are refused.
//   LOGIC      the fixture folder loads LIVE through the injected
//              `originalsDirectory` init ContentView uses, with the isolation
//              that init promises (no compiled store, no bookmarks folder).
//   TRUTH      every person a walk reaches is placed by the REAL bundled map
//              borders — the map the UI test opens has something to shade.
// Synthetic names and places only (GauntletFamilyTreeFixture).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Gauntlet seam — synthetic family tree folder")
@MainActor
struct GauntletFamilyTreeSeamTests {

    /// Fresh throwaway suite; never UserDefaults.standard (settings-pollution rule).
    private func withSuite<T>(_ value: String?, _ body: (UserDefaults) throws -> T) throws -> T {
        let name = "vs-test-gauntlet-ft-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        if let value { defaults.set(value, forKey: GauntletSeams.familyTreeDirectoryKey) }
        return try body(defaults)
    }

    @Test func productionIgnoresTheArgument() throws {
        let url = try withSuite("/tmp/fixture-tree") {
            GauntletSeams.familyTreeDirectory(isTestHost: false, defaults: $0)
        }
        #expect(url == nil, "outside a test host the seam must never name a tree folder")
    }

    @Test func aTestHostGetsTheStandardizedAbsoluteFolder() throws {
        let url = try withSuite("/tmp/gauntlet/../fixture-tree") {
            GauntletSeams.familyTreeDirectory(isTestHost: true, defaults: $0)
        }
        #expect(url?.path == "/tmp/fixture-tree")
        #expect(url?.hasDirectoryPath == true)
    }

    @Test(arguments: [nil, "", "relative/tree"] as [String?])
    func absentEmptyOrRelativeIsRefused(_ value: String?) throws {
        let url = try withSuite(value) {
            GauntletSeams.familyTreeDirectory(isTestHost: true, defaults: $0)
        }
        #expect(url == nil)
    }

    /// Writes the fixture where the UI test does (a fresh temp folder).
    private func fixtureFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gauntlet-ft-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(GauntletFamilyTreeFixture.gedcom.utf8)
            .write(to: dir.appendingPathComponent(GauntletFamilyTreeFixture.fileName))
        return dir
    }

    @Test func theFixtureFolderLoadsLiveThroughTheInjectedInit() async throws {
        let dir = try fixtureFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FamilyTreeLiveModel(originalsDirectory: dir)
        await model.loadFromDisk()
        #expect(model.loadState == .loaded(live: true))
        #expect(model.isLive)
        #expect(model.peopleCount == GauntletFamilyTreeFixture.peopleCount)
        #expect(model.walkGraph?.rootPersonIDs == [GauntletFamilyTreeFixture.rootID])
        // Nothing beside the fixture was created (no compiled store, no
        // bookmarks, no rulings written into the folder).
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == [GauntletFamilyTreeFixture.fileName])
    }

    @Test func everyWalkedPersonIsPlacedByTheBundledMap() async throws {
        let graph = GedcomFamilyGraph(gedcomText: GauntletFamilyTreeFixture.gedcom)
        let result = try TreeWalk.walk(graph, options: .init(starts: [GauntletFamilyTreeFixture.rootID],
                                                             maxGenerations: 7))
        let layout = await TreeWalkAnimator.prepare(result, size: CGSize(width: 600, height: 600))
        let highlight = await TreeWalkHighlighter.prepare(result: result, graph: graph, layout: layout)
        let inputs = await FamilyMapModel.prepare(result: result, graph: graph, highlight: highlight)
        let units = try await FamilyMapUnitsCache.shared.units()
        let map = FamilyMapModel(inputs: inputs, units: units, displayNames: ["Juniper"])
        map.apply(selection: .init(), yearCeiling: nil)
        for _ in 0..<500 where map.computed.totals.considered != result.visitedCount {
            try await Task.sleep(for: .milliseconds(10))
        }
        let totals = map.computed.totals
        #expect(totals.considered == result.visitedCount)
        #expect(totals.unresolved == 0, "a fixture birthplace the map cannot place: \(totals)")
    }
}
