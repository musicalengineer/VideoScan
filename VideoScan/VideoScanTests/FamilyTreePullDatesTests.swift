// FamilyTreePullDatesTests.swift
// The "<Surname> GEDCOM <date>" lines under the Family Tree title (Rick,
// 2026-10-30), through the tab's real load path. The parsing, hashing and
// grouping are proven in VideoScanCore (GedcomPullFactsTests); this suite is
// the app-side SENSOR: a tab load installs the lines and logs one
// `[family-tree] gedcom pull` line per source per load, with the compiled
// generation's id and ingest date — never per redraw.
//
// Isolation: temp GEDCOM folder + temp compiled store; synthetic
// /Testsurname/ names only; never App Support or the archive.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Family Tree — GEDCOM pull dates under the title")
@MainActor
struct FamilyTreePullDatesTests {

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    nonisolated static let pull = """
    0 HEAD
    1 SOUR getmyancestors
    2 VERS 1.2.0
    2 DATE 1 JAN 1999
    1 DATE 26 Aug 2026
    2 TIME 05:07:30
    1 GEDC
    2 VERS 5.5.1
    0 @I1@ INDI
    1 NAME Pat Example /Testsurname/ Jr
    1 SEX M
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Sam /Spousesurname/
    1 SEX F
    1 FAMS @F1@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    0 TRLR

    """

    struct Sandbox {
        let root: URL
        let gedcom: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent("FTPullDates-\(UUID().uuidString)")
            gedcom = root.appendingPathComponent("GEDCOM", isDirectory: true)
            try FileManager.default.createDirectory(at: gedcom, withIntermediateDirectories: true)
            try FamilyTreePullDatesTests.pull.write(to: gedcom.appendingPathComponent("test-pull.ged"),
                                                    atomically: true, encoding: .utf8)
        }
        func store() -> FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: root.appendingPathComponent("compiled"))
            store.log = { _ in }
            return store
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private func waitForPullLog(_ log: LogCapture, count: Int) async {
        for _ in 0..<200 where log.all.filter({ $0.contains("[family-tree] gedcom pull") }).count < count {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("A tab load shows the pull's line and logs it once, with the generation it came from")
    func loadShowsAndLogs() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let store = box.store()
        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store)
        let log = LogCapture()
        model.pullDates.log = { log.append($0) }

        await model.loadFromDisk()
        #expect(model.isLive)
        await waitForPullLog(log, count: 1)
        let pullLines = log.all.filter { $0.contains("[family-tree] gedcom pull") }
        print(pullLines.joined(separator: "\n"))
        #expect(pullLines.count == 1)
        let generation = try #require(store.readPointer()?.current)
        let line = try #require(pullLines.first)
        #expect(line.contains("label=Testsurname header=26 Aug 2026 05:07:30 file=test-pull.ged"))
        #expect(line.contains("generation=\(generation)"))
        #expect(!line.contains("ingest=unknown"))
        #expect(model.pullDates.lines.map(\.text) == ["Testsurname GEDCOM 26 Aug 2026"])
        #expect(model.pullDates.lines.first?.help.contains("test-pull.ged") == true)
        #expect(model.pullDates.lines.first?.help.hasPrefix("Ingested into this tree") == true)

        // A second load logs once more (once per load, not per redraw) and
        // shows the same line.
        await model.loadFromDisk()
        await waitForPullLog(log, count: 2)
        #expect(log.all.filter { $0.contains("[family-tree] gedcom pull") }.count == 2)
        #expect(model.pullDates.lines.map(\.text) == ["Testsurname GEDCOM 26 Aug 2026"])
    }

    @Test("No tree → no lines (nothing stale left under the title)")
    func noTreeClears() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let pulls = FamilyTreePullDates()
        pulls.log = { _ in }
        let graph = try #require(GedcomFamilyGraph(fileURL: box.gedcom.appendingPathComponent("test-pull.ged")))
        await pulls.refresh(graph: graph, store: nil, gedcomDirectory: box.gedcom)
        #expect(pulls.lines.map(\.text) == ["Testsurname GEDCOM 26 Aug 2026"])
        await pulls.refresh(graph: nil, store: nil, gedcomDirectory: box.gedcom)
        #expect(pulls.lines.isEmpty)
    }

    @Test("The file changed since the tree was built → no line, logged NOT ON DISK")
    func changedFileIsNotDescribed() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let url = box.gedcom.appendingPathComponent("test-pull.ged")
        let graph = try #require(GedcomFamilyGraph(fileURL: url))
        try (Self.pull + "0 @N1@ NOTE edited\n").write(to: url, atomically: true, encoding: .utf8)
        let result = FamilyTreePullDates.describe(graph: graph, store: nil, gedcomDirectory: box.gedcom,
                                                  cache: GedcomPullHashCache())
        #expect(result.lines.isEmpty)
        #expect(result.log.count == 1 && result.log[0].contains("NOT ON DISK file=test-pull.ged"))
        #expect(result.log[0].contains("generation=unknown"))
    }
}
