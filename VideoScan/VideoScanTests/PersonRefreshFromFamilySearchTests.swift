// PersonRefreshFromFamilySearchTests.swift
// "Refresh from FamilySearch…" for one person (Rick, 2026-09-21) — the app
// half. The pure diff / overlay / store tables live in VideoScanCore
// (PersonFactRefreshTests); these cover the command, the Terminal
// lifecycle, the read path, and the tree-safety sensors.
//
// Five dimensions (CLAUDE.md):
//   LOGIC     PersonRefreshCommandTests, PersonRefreshCoordinatorTests
//   SCALE     PersonRefreshSharedCacheTests.reoverlayOverFortyThousandPeople
//   ISOLATION PersonRefreshIsolationTests (+ every test owns a temp root)
//   SENSOR    PersonRefreshNarrowingSensorTests (the 2026-09-17 incident),
//             PersonRefreshCoordinatorTests.relationshipDifferenceIsNeverApplied
//   MEDIA     n/a (no media files are opened)
//
// No test contacts FamilySearch or runs getmyancestors: the "tool" is a
// planted `exit 0` script, the launcher is silent, and the one-person
// export is written by the test exactly as getmyancestors 1.2.0 writes it.

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

// MARK: - Fixtures

enum PersonRefreshAppFixtures {
    /// A 30-person tree. Walter (WWWW-111) is married to Mae (MMMM-222),
    /// son of Otto + Ida; everyone else is filler with their own FSIDs.
    static func fullTree(people: Int = 30) -> String {
        var lines = ["0 HEAD", "1 GEDC", "2 VERS 5.5.1",
                     "0 @I1@ INDI", "1 NAME Walter James /Dunn/", "1 SEX M",
                     "1 BIRT", "2 DATE 21 Feb 1928", "2 PLAC Boston, Massachusetts",
                     "1 DEAT", "2 DATE 25 Jun 2008",
                     "1 FAMC @F1@", "1 FAMS @F2@", "1 _FSFTID WWWW-111",
                     "0 @I2@ INDI", "1 NAME Mae /Lamb/", "1 SEX F", "1 FAMS @F2@", "1 _FSFTID MMMM-222",
                     "0 @I3@ INDI", "1 NAME Otto /Dunn/", "1 SEX M", "1 FAMS @F1@", "1 _FSFTID OOOO-444",
                     "0 @I4@ INDI", "1 NAME Ida /Roe/", "1 SEX F", "1 FAMS @F1@", "1 _FSFTID IIII-555"]
        for n in 5...people {
            lines += ["0 @I\(n)@ INDI", "1 NAME Filler\(n) /Breen/",
                      String(format: "1 _FSFTID F%03d-%03d", n / 1000, n % 1000)]
        }
        lines += ["0 @F1@ FAM", "1 HUSB @I3@", "1 WIFE @I4@", "1 CHIL @I1@",
                  "0 @F2@ FAM", "1 HUSB @I1@", "1 WIFE @I2@", "1 MARR", "2 DATE 1950",
                  "0 TRLR"]
        return lines.joined(separator: "\n")
    }

    /// getmyancestors `-i WWWW-111 -a 0 -d 0 -m` output shape.
    static func onePerson(fsid: String = "WWWW-111", birth: String = "21 Feb 1929",
                          extraSpouse: Bool = false) -> String {
        var lines = ["0 HEAD", "1 CHAR UTF-8", "1 SOUR getmyancestors", "2 VERS 1.2.0",
                     "0 @SUBM@ SUBM", "1 NAME Someone",
                     "0 @I1@ INDI", "1 NAME Walter James /Dunn/", "1 SEX M",
                     "1 BIRT", "2 DATE \(birth)", "2 PLAC Boston, Massachusetts",
                     "1 DEAT", "2 DATE 25 Jun 2008", "2 PLAC Pittsfield, Massachusetts",
                     "1 FAMS @F1@"]
        if extraSpouse { lines.append("1 FAMS @F2@") }
        lines += ["1 _FSFTID \(fsid)",
                  "0 @I2@ INDI", "1 NAME Mae /Lamb/", "1 SEX F", "1 FAMS @F1@", "1 _FSFTID MMMM-222"]
        if extraSpouse {
            lines += ["0 @I3@ INDI", "1 NAME Vera /Kent/", "1 SEX F", "1 FAMS @F2@", "1 _FSFTID VVVV-777"]
        }
        lines += ["0 @F1@ FAM", "1 HUSB @I1@", "1 WIFE @I2@", "1 MARR", "2 DATE 12 Jun 1950", "1 _FSFTID CCCC-001"]
        if extraSpouse { lines += ["0 @F2@ FAM", "1 HUSB @I1@", "1 WIFE @I3@"] }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n")
    }

    /// A production-shaped layout under one temp base:
    ///   <base>/support/VideoScan/family-tree/{assets/GEDCOM, compiled, person-refresh}
    ///   <base>/support/VideoScan/cyberbrain/cyberbrain.json
    ///   <base>/support/VideoScan/family-tree/assets/People/Walter_WWWW-111/Documents/birth.pdf
    struct Layout {
        let base: URL
        let familyTree: URL
        let assets: URL
        let gedcom: URL
        let compiled: URL
        let refreshRoot: URL
        let bin: URL
        let tool: URL
        var configuration: FamilyAssetConfiguration {
            FamilyAssetConfiguration(
                roots: .init(assets: assets, thumbnailCache: familyTree.appendingPathComponent("thumbs")),
                access: .readWrite, legacyGEDCOMDirectory: familyTree.appendingPathComponent("originals"))
        }
        var store: FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: compiled)
            store.log = { _ in }
            return store
        }
        var overlayStore: PersonFactOverlayStore { PersonFactOverlayStore(directory: refreshRoot) }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    static func layout(people: Int = 30, tag: String = "layout") throws -> Layout {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("fsrefresh-\(tag)-\(UUID().uuidString)", isDirectory: true)
        let support = base.appendingPathComponent("support", isDirectory: true)
        let familyTree = support.appendingPathComponent("VideoScan/family-tree", isDirectory: true)
        let assets = familyTree.appendingPathComponent("assets", isDirectory: true)
        let gedcom = assets.appendingPathComponent("GEDCOM", isDirectory: true)
        let compiled = familyTree.appendingPathComponent("compiled", isDirectory: true)
        let refreshRoot = PersonRefreshPaths.productionRoot(applicationSupport: support)
        let bin = base.appendingPathComponent("bin", isDirectory: true)
        for dir in [gedcom, compiled, refreshRoot, bin] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let tree = gedcom.appendingPathComponent("familysearch-tree.ged")
        try fullTree(people: people).write(to: tree, atomically: true, encoding: .utf8)
        // The pull is from "yesterday", so anything the tests do today is newer.
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: tree.path)
        let tool = bin.appendingPathComponent("getmyancestors")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return Layout(base: base, familyTree: familyTree, assets: assets, gedcom: gedcom, compiled: compiled,
                      refreshRoot: refreshRoot, bin: bin, tool: tool)
    }

    struct SilentLauncher: FamilySearchPullLauncher {
        func open(_ url: URL) {}
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    /// Poll `condition` on the main actor until true or `seconds` elapse.
    @MainActor
    static func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private typealias AF = PersonRefreshAppFixtures

// MARK: - Command (LOGIC)

@Suite("Refresh from FamilySearch — the command")
struct PersonRefreshCommandTests {
    private let tool = URL(fileURLWithPath: "/opt/homebrew/bin/getmyancestors")
    private let output = URL(fileURLWithPath: "/tmp/person refresh/WWWW-111-20260921-120000/person.ged")

    @Test func asksForOnePersonWithSpousesAndNoGenerations() throws {
        let command = try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: " wwww-111 ", outputURL: output)
        let args = command.arguments
        #expect(command.familySearchID == "WWWW-111")
        #expect(Array(args.prefix(7)) == ["-i", "WWWW-111", "-a", "0", "-d", "0", "-m"])
        #expect(args.contains("--no-sources") && args.contains("--no-notes") && args.contains("--no-memories"))
        #expect(Array(args.suffix(2)) == ["-o", output.path])
    }

    @Test func neverCarriesACredential() throws {
        let command = try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: "WWWW-111", outputURL: output)
        #expect(command.arguments.allSatisfy { !FamilySearchPullCommand.forbiddenArguments.contains($0) })
        // Not even the username: getmyancestors prompts for it in Terminal.
        #expect(!command.arguments.contains("-u") && !command.arguments.contains("--username"))
    }

    @Test func rejectsABadIDAndANonGedcomOutput() {
        #expect(throws: FamilySearchPullError.invalidPersonID("LF7T-Y4")) {
            try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: "LF7T-Y4", outputURL: output)
        }
        let txt = URL(fileURLWithPath: "/tmp/person.txt")
        #expect(throws: FamilySearchPullError.outputNotGedcom(txt)) {
            try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: "WWWW-111", outputURL: txt)
        }
    }

    @Test func displayLineQuotesThePathWithASpace() throws {
        let command = try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: "WWWW-111", outputURL: output)
        #expect(command.displayLine.hasSuffix("-o '\(output.path)'"))
    }

    @Test func scriptPausesAndSaysTheToolAsksForTheCredentials() throws {
        let command = try FamilySearchPersonRefreshCommand(toolURL: tool, familySearchID: "WWWW-111", outputURL: output)
        let script = FamilySearchPersonRefreshScript(command: command, personName: "Walter O'Dunn",
                                                     scriptURL: URL(fileURLWithPath: "/tmp/x.command"))
        let text = script.contents
        #expect(text.contains("read -r confirm"))
        #expect(text.contains("username and password"))
        #expect(text.contains(command.displayLine))
        #expect(!text.contains(" -p ") && !text.contains("--password"))
        #expect(text.contains("'\\''"))                    // the apostrophe in the name is quoted
    }

    @Test func stagingFolderIsPerPersonAndStamped() {
        let root = URL(fileURLWithPath: "/tmp/pr", isDirectory: true)
        let folder = PersonRefreshPaths.stagingFolder(root: root, familySearchID: "WWWW-111",
                                                      at: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(folder.deletingLastPathComponent().path == root.path)
        #expect(folder.lastPathComponent.hasPrefix("WWWW-111-2026"))
    }
}

// MARK: - The 2026-09-17 narrowing sensor

@Suite("Refresh from FamilySearch — a one-person .ged never narrows the tree", .serialized)
struct PersonRefreshNarrowingSensorTests {

    /// Plant a one-person export in its staging folder, NEWER than every
    /// file in the tree, and prove every loader shape still loads the full
    /// fixture tree with the same person count.
    private func plantOnePersonExport(in layout: AF.Layout) throws -> URL {
        let folder = PersonRefreshPaths.stagingFolder(root: layout.refreshRoot, familySearchID: "WWWW-111", at: Date())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(PersonRefreshPaths.outputFileName)
        try AF.onePerson().write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3_600)], ofItemAtPath: file.path)
        return file
    }

    @Test func storeAwareLoaderKeepsTheFullTree() throws {
        let layout = try AF.layout(tag: "narrow-store")
        defer { layout.remove() }
        var loader = FamilyGraphFileLoader(originalsDirectory: layout.gedcom)
        loader.compiledStore = layout.store
        loader.readOnly = false
        let before = loader.loadNewestOutcome()
        #expect(before.graph?.people.count == 30)

        let planted = try plantOnePersonExport(in: layout)
        let after = loader.loadNewestOutcome()
        #expect(after.graph?.people.count == 30)
        #expect(after.rejectedURLs.isEmpty)
        let sources = layout.store.loadCurrent()?.manifest.sources.map(\.path) ?? []
        #expect(!sources.contains(planted.path))
        let refreshRoot = layout.refreshRoot.standardizedFileURL.path
        #expect(sources.allSatisfy { !URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(refreshRoot) })
    }

    @Test func storelessNewestFileRuleNeverSeesIt() throws {
        // Rule 4 — "newest valid .ged wins" — is exactly the narrowing path.
        let layout = try AF.layout(tag: "narrow-rule4")
        defer { layout.remove() }
        _ = try plantOnePersonExport(in: layout)
        let outcome = FamilyGraphFileLoader(originalsDirectory: layout.gedcom, compiledStore: nil, readOnly: false)
            .loadNewestOutcome()
        #expect(outcome.graph?.people.count == 30)
        #expect(outcome.candidateCount == 1)
        #expect(outcome.selectedURL?.lastPathComponent == "familysearch-tree.ged")
    }

    @Test func sharedCacheWithTheOverlayKeepsTheFullTree() throws {
        let layout = try AF.layout(tag: "narrow-shared")
        defer { layout.remove() }
        _ = try plantOnePersonExport(in: layout)
        let cache = FamilyGraphSharedCache(overlayStore: layout.overlayStore)
        let graph = cache.graph(for: layout.configuration, store: layout.store)
        #expect(graph?.people.count == 30)
    }

    @Test func theProductionFolderIsInsideNoDiscoveryPath() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        let root = PersonRefreshPaths.productionRoot(applicationSupport: support).standardizedFileURL.path + "/"
        let noArchive = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: nil, masterIsSafelyAvailable: true, readOnly: false, applicationSupportRoot: support)
        let archive = FamilyAssetConfigurationCenter.configuration(
            masterArchiveRoot: URL(fileURLWithPath: "/Volumes/FamilyArchive", isDirectory: true),
            masterIsSafelyAvailable: true, readOnly: false, applicationSupportRoot: support)
        let discovery = [noArchive.roots.assets.appendingPathComponent("GEDCOM"),
                         noArchive.legacyGEDCOMDirectory!,
                         archive.roots.assets.appendingPathComponent("GEDCOM"),
                         FamilyGraphCompiledStore.productionRoot]
        for dir in discovery {
            let d = dir.standardizedFileURL.path + "/"
            #expect(!root.hasPrefix(d), "person-refresh must not be inside \(d)")
            #expect(!d.hasPrefix(root), "\(d) must not be inside person-refresh")
        }
    }
}

// MARK: - Coordinator (LOGIC + SENSOR)

@Suite("Refresh from FamilySearch — the lifecycle", .serialized)
@MainActor
struct PersonRefreshCoordinatorTests {

    @MainActor
    private struct Rig {
        let layout: AF.Layout
        let model: FamilyTreeLiveModel
        let lines = AF.Lines()
        func coordinator(personID: String = "@I1@") -> PersonRefreshCoordinator {
            let target = model.personRefreshTarget(for: personID)!
            let model = self.model
            let lines = self.lines
            return PersonRefreshCoordinator(
                target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
                installedFacts: { model.personFacts(familySearchID: target.familySearchID) },
                locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
                launcher: AF.SilentLauncher(), pollInterval: .milliseconds(20),
                log: { lines.append($0) })
        }
    }

    private func rig(_ tag: String) throws -> Rig {
        let layout = try AF.layout(tag: tag)
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.personRefreshOverlayStore = layout.overlayStore
        model.loadNow()
        return Rig(layout: layout, model: model)
    }

    private func answer(_ coordinator: PersonRefreshCoordinator, with text: String) throws {
        guard case .waiting(let output) = coordinator.phase else {
            Issue.record("not waiting: \(coordinator.phase)")
            return
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
    }

    private func isReady(_ c: PersonRefreshCoordinator) -> Bool { if case .ready = c.phase { true } else { false } }
    private func isRefused(_ c: PersonRefreshCoordinator) -> Bool { if case .refused = c.phase { true } else { false } }

    @Test func refreshDiffApplyAndTheTreeShowsTheNewFacts() async throws {
        let rig = try rig("e2e")
        defer { rig.layout.remove() }
        #expect(rig.model.personFacts(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1928")

        let coordinator = rig.coordinator()
        coordinator.launch()
        guard case .waiting(let output) = coordinator.phase else { Issue.record("\(coordinator.phase)"); return }
        #expect(output.path.hasPrefix(rig.layout.refreshRoot.path))
        #expect(FileManager.default.fileExists(atPath: output.deletingLastPathComponent()
            .appendingPathComponent(PersonRefreshPaths.scriptFileName).path))

        try answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        #expect(diff.changes.map(\.field.key) == ["birthDate", "deathPlace", "marriageDate:MMMM-222"])

        #expect(await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key))))
        #expect(coordinator.phase == .applied(fields: 3))
        #expect(rig.layout.overlayStore.load().entries["WWWW-111"]?.facts.count == 3)

        let journal = PersonRefreshAudit.entries(directory: rig.layout.refreshRoot)
        #expect(journal.count == 1)
        #expect(journal.first?.changes.first { $0.field == "birthDate" }
                == PersonRefreshAudit.FieldChange(field: "birthDate", before: "21 Feb 1928", after: "21 Feb 1929"))

        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
        let facts = rig.model.personFacts(familySearchID: "WWWW-111")
        #expect(facts?.birthDate == "21 Feb 1929")
        #expect(facts?.deathPlace == "Pittsfield, Massachusetts")
        #expect(facts?.spouses.first?.marriageDate == "12 Jun 1950")
        #expect(rig.model.selectedID == "@I1@")
        #expect(rig.model.peopleCount == 30)

        // One log line per step.
        let log = rig.lines.all
        for step in ["[fs-refresh] started", "[fs-refresh] received", "[fs-refresh] diff 3 field(s)",
                     "[fs-refresh] applied 3 field(s) for Walter James Dunn (WWWW-111)"] {
            #expect(log.contains { $0.hasPrefix(step) }, "missing \(step)")
        }

        // A second refresh of the same answer: nothing left to change.
        let again = rig.coordinator()
        again.launch()
        try answer(again, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(again) })
        guard case .ready(let second) = again.phase else { return }
        #expect(second.factsMatch)
    }

    @Test func undoRestoresThePulledFacts() async throws {
        let rig = try rig("undo")
        defer { rig.layout.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        try answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        await coordinator.apply(selectedFieldKeys: ["birthDate"])        // one box ticked
        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
        #expect(rig.model.personFacts(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1929")
        #expect(rig.model.personFacts(familySearchID: "WWWW-111")?.deathPlace == nil)   // unticked
        #expect(diff.changes.count == 3)

        let message = await PersonRefreshCoordinator.undoLast(
            familySearchID: "WWWW-111", personName: "Walter", overlayStore: rig.layout.overlayStore,
            journalDirectory: rig.layout.refreshRoot, log: { rig.lines.append($0) })
        #expect(message.contains("shows the pulled facts again"))
        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
        #expect(rig.model.personFacts(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1928")
        let journal = PersonRefreshAudit.entries(directory: rig.layout.refreshRoot)
        #expect(journal.map(\.action) == [.applied, .undone])
        #expect(journal.last?.changes == [PersonRefreshAudit.FieldChange(field: "birthDate", before: "21 Feb 1929", after: "21 Feb 1928")])
    }

    /// Reflection review F1 (2026-09-21): an unreadable overlay.json used
    /// to load as empty and Apply saved ONE person over it, erasing every
    /// other person's refreshed facts. Now Apply refuses with an honest
    /// sentence, the bytes are set aside intact, and nothing is journaled.
    @Test func applyOverAnUnreadableOverlayRefusesAndKeepsTheFile() async throws {
        let rig = try rig("garbage-apply")
        defer { rig.layout.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        try answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }

        let store = rig.layout.overlayStore
        let original = Data("{ \"entries\": { \"ZZZZ-999\": { \"facts\": ".utf8)
        try original.write(to: store.fileURL)

        #expect(await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key))) == false)
        guard case .failed(let message) = coordinator.phase else {
            Issue.record("expected a refusal, got \(coordinator.phase)"); return
        }
        #expect(message.hasPrefix("The refresh record can't be read, so nothing was changed — it's kept as overlay.json.bad-"))
        let kept = try FileManager.default.contentsOfDirectory(atPath: rig.layout.refreshRoot.path)
            .filter { $0.hasPrefix("overlay.json.bad-") }
        #expect(kept.count == 1)
        if let name = kept.first {
            #expect(message.contains(name))
            #expect(try Data(contentsOf: rig.layout.refreshRoot.appendingPathComponent(name)) == original,
                    "the unreadable overlay must survive byte-identical")
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "nothing was written in its place")
        #expect(PersonRefreshAudit.entries(directory: rig.layout.refreshRoot).isEmpty)
        let refusals = rig.lines.all.filter { $0.hasPrefix("[fs-refresh] refused reason=overlay-unreadable apply for WWWW-111") }
        #expect(refusals.count == 1)
        #expect(!rig.lines.all.contains { $0.hasPrefix("[fs-refresh] applied") })

        // The next refresh starts a fresh record; the set-aside file is untouched.
        let again = rig.coordinator()
        again.launch()
        try answer(again, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(again) })
        guard case .ready(let second) = again.phase else { return }
        #expect(await again.apply(selectedFieldKeys: Set(second.changes.map(\.field.key))))
        #expect(store.load().entries["WWWW-111"]?.facts.count == 3)
        if let name = kept.first {
            #expect(try Data(contentsOf: rig.layout.refreshRoot.appendingPathComponent(name)) == original)
        }
    }

    /// Reflection review F3: corrupt journal lines were dropped by a
    /// silent `try?`. Still skipped (behaviour unchanged) — now counted
    /// and logged in one line.
    @Test func corruptJournalLinesAreCountedAndLogged() throws {
        let layout = try AF.layout(tag: "journal-corrupt")
        defer { layout.remove() }
        let good = PersonRefreshAudit.Entry(
            at: Date(timeIntervalSince1970: 1_000), action: .applied, familySearchID: "WWWW-111", person: "Walter",
            changes: [PersonRefreshAudit.FieldChange(field: "birthDate", before: "1928", after: "1929")], source: nil)
        try PersonRefreshAudit.append(good, directory: layout.refreshRoot)
        let journal = layout.refreshRoot.appendingPathComponent(PersonRefreshPaths.journalFileName)
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ torn line\nnot json either\n".utf8))
        try handle.close()
        var lines: [String] = []
        let entries = PersonRefreshAudit.entries(directory: layout.refreshRoot, log: { lines.append($0) })
        #expect(entries.count == 1)
        #expect(lines.count == 1)
        #expect(lines.first?.contains("skipped 2 unreadable line(s) of 3") == true)
        // A missing journal is quiet.
        var quiet: [String] = []
        #expect(PersonRefreshAudit.entries(directory: layout.bin, log: { quiet.append($0) }).isEmpty)
        #expect(quiet.isEmpty)
    }

    @Test func undoOverAnUnreadableOverlayRefusesAndKeepsTheFile() async throws {
        let rig = try rig("garbage-undo")
        defer { rig.layout.remove() }
        let store = rig.layout.overlayStore
        let original = Data("not json at all".utf8)
        try original.write(to: store.fileURL)
        let message = await PersonRefreshCoordinator.undoLast(
            familySearchID: "WWWW-111", personName: "Walter", overlayStore: store,
            journalDirectory: rig.layout.refreshRoot, log: { rig.lines.append($0) })
        #expect(message.hasPrefix("The refresh record can't be read, so nothing was changed — it's kept as overlay.json.bad-"))
        let kept = try FileManager.default.contentsOfDirectory(atPath: rig.layout.refreshRoot.path)
            .filter { $0.hasPrefix("overlay.json.bad-") }
        #expect(kept.count == 1)
        if let name = kept.first {
            #expect(try Data(contentsOf: rig.layout.refreshRoot.appendingPathComponent(name)) == original)
        }
        #expect(PersonRefreshAudit.entries(directory: rig.layout.refreshRoot).isEmpty)
        #expect(rig.lines.all.filter { $0.hasPrefix("[fs-refresh] refused reason=overlay-unreadable undo for WWWW-111") }.count == 1)
    }

    @Test(arguments: [
        ("merged", "WXYZ-999", "different person, WXYZ-999"),
        ("gone", "", "FamilySearch no longer has WWWW-111"),
        ("garbage", "-", "is not a valid GEDCOM file"),
    ])
    func refusalsSayWhyAndChangeNothing(_ scenario: (String, String, String)) async throws {
        let rig = try rig("refuse-\(scenario.0)")
        defer { rig.layout.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        let text: String
        switch scenario.1 {
        case "": text = "0 HEAD\n1 SOUR getmyancestors\n0 TRLR\n"
        case "-": text = "this is not gedcom\n0 TRLR\n"
        default: text = AF.onePerson(fsid: scenario.1)
        }
        try answer(coordinator, with: text)
        #expect(await AF.waitUntil { isRefused(coordinator) })
        guard case .refused(let message) = coordinator.phase else { return }
        #expect(message.contains(scenario.2), "\(message)")
        #expect(message.contains("Nothing was changed"))
        #expect(rig.layout.overlayStore.load().entries.isEmpty)
        #expect(rig.lines.all.contains { $0.hasPrefix("[fs-refresh] refused reason=") })
    }

    /// SENSOR: FamilySearch shows a spouse the tree does not have. The
    /// sheet lists it, Apply applies every ticked box, and the tree's
    /// spouses are exactly what they were.
    @Test func relationshipDifferenceIsNeverApplied() async throws {
        let rig = try rig("relationship")
        defer { rig.layout.remove() }
        let before = rig.model.personFacts(familySearchID: "WWWW-111")!.spouses
        let coordinator = rig.coordinator()
        coordinator.launch()
        try answer(coordinator, with: AF.onePerson(extraSpouse: true))
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        #expect(diff.relationshipNotes.map(\.spouseFamilySearchID) == ["VVVV-777"])
        #expect(!diff.changes.contains { $0.field.key.contains("VVVV-777") })
        await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key)))
        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
        let after = rig.model.personFacts(familySearchID: "WWWW-111")!.spouses
        #expect(after.map(\.familySearchID) == before.map(\.familySearchID))
        #expect(after.count == 1)
        let keys = rig.layout.overlayStore.load().entries["WWWW-111"]!.facts.keys
        #expect(keys.allSatisfy { PersonRefreshField(key: $0) != nil })
    }

    @Test func cancelStopsWatchingAndALateFileIsIgnored() async throws {
        let rig = try rig("cancel")
        defer { rig.layout.remove() }
        let coordinator = rig.coordinator()
        coordinator.launch()
        guard case .waiting(let output) = coordinator.phase else { return }
        coordinator.cancel()
        #expect(coordinator.phase == .idle)
        try AF.onePerson().write(to: output, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(coordinator.phase == .idle)
        #expect(rig.lines.all.contains { $0.hasPrefix("[fs-refresh] cancelled") })
    }

    @Test func missingToolFailsWithTheInstallSentence() throws {
        let rig = try rig("notool")
        defer { rig.layout.remove() }
        let target = rig.model.personRefreshTarget(for: "@I1@")!
        let coordinator = PersonRefreshCoordinator(
            target: target, root: rig.layout.refreshRoot, overlayStore: rig.layout.overlayStore,
            installedFacts: { nil }, locator: FamilySearchToolLocator(overridePath: nil, candidatePaths: []),
            launcher: AF.SilentLauncher(), log: { _ in })
        coordinator.launch()
        #expect(coordinator.phase == .failed(message: FamilySearchPullError.toolNotFound.errorDescription!))
    }

    @Test func aPersonWithoutAFamilySearchIDHasNoRefreshTarget() throws {
        let layout = try AF.layout(tag: "nofsid")
        defer { layout.remove() }
        let text = "0 HEAD\n0 @I1@ INDI\n1 NAME No /Id/\n0 @I2@ INDI\n1 NAME Has /Id/\n1 _FSFTID HHHH-111\n0 TRLR"
        try text.write(to: layout.gedcom.appendingPathComponent("familysearch-tree.ged"), atomically: true, encoding: .utf8)
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.loadNow()
        #expect(model.personRefreshTarget(for: "@I1@") == nil)
        #expect(model.personRefreshTarget(for: "@I2@")?.familySearchID == "HHHH-111")
    }

    /// CyberBrain enrichments and person Documents are keyed by FS ID /
    /// person folder: a refresh must leave them — and the GEDCOM folder and
    /// the compiled store — byte-for-byte alone. Only person-refresh/ moves.
    @Test func refreshTouchesNothingOutsideItsOwnFolder() async throws {
        let rig = try rig("untouched")
        defer { rig.layout.remove() }
        let fm = FileManager.default
        let brain = rig.layout.base.appendingPathComponent("support/VideoScan/cyberbrain", isDirectory: true)
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        try #"{"items":[{"subject":"WWWW-111","text":"served in the Navy"}]}"#
            .write(to: brain.appendingPathComponent("cyberbrain.json"), atomically: true, encoding: .utf8)
        let documents = rig.layout.assets.appendingPathComponent("People/Walter_WWWW-111/Documents", isDirectory: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("%PDF-1.4 birth".utf8).write(to: documents.appendingPathComponent("birth.pdf"))

        func snapshot() -> [String: String] {
            var out: [String: String] = [:]
            let base = rig.layout.base.standardizedFileURL.path
            let e = fm.enumerator(at: rig.layout.base, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            while let url = e?.nextObject() as? URL {
                let path = url.standardizedFileURL.path
                if path.hasPrefix(rig.layout.refreshRoot.standardizedFileURL.path) { continue }
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                out[String(path.dropFirst(base.count))] =
                    "\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }
            return out
        }
        let before = snapshot()
        let coordinator = rig.coordinator()
        coordinator.launch()
        try answer(coordinator, with: AF.onePerson())
        #expect(await AF.waitUntil { isReady(coordinator) })
        guard case .ready(let diff) = coordinator.phase else { return }
        await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key)))
        await rig.model.reloadAfterPersonRefresh(selecting: "@I1@")
        #expect(snapshot() == before)
    }
}

// MARK: - The read path (Hallie / People / tree share it)

@Suite("Refresh from FamilySearch — the shared read path", .serialized)
struct PersonRefreshSharedCacheTests {

    private func record(_ store: PersonFactOverlayStore, birth: String, at date: Date = Date()) throws {
        var overlay = store.load()
        overlay.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: birth)],
                       familySearchID: "WWWW-111", displayName: "Walter", at: date)
        try store.save(overlay)
    }

    @Test func applyReachesTheNextReadWithoutReloadingTheTree() throws {
        let layout = try AF.layout(tag: "cache")
        defer { layout.remove() }
        let cache = FamilyGraphSharedCache(overlayStore: layout.overlayStore)
        let first = cache.load(for: layout.configuration, store: nil)
        #expect(first?.graph.person(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1928")
        #expect(cache.loaderRuns == 1)

        try record(layout.overlayStore, birth: "21 Feb 1929")
        let second = cache.load(for: layout.configuration, store: nil)
        #expect(second?.graph.person(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1929")
        #expect(second?.reused == false)                  // a new token: the tab rebuilds its bundle
        #expect(cache.loaderRuns == 1)                    // …but nothing was re-parsed

        // The outcome the Family Tree tab installs carries it too.
        let outcome = cache.outcome(for: layout.configuration, store: nil).outcome
        #expect(outcome?.graph?.person(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1929")
        #expect(cache.load(for: layout.configuration, store: nil)?.reused == true)
    }

    @Test func aNewerFullPullRetiresTheOverlayEntry() throws {
        let layout = try AF.layout(tag: "supersede")
        defer { layout.remove() }
        let lines = AF.Lines()
        let store = PersonFactOverlayStore(directory: layout.refreshRoot, log: { lines.append($0) })
        try record(store, birth: "21 Feb 1929", at: Date().addingTimeInterval(-3_600))
        let cache = FamilyGraphSharedCache(log: { lines.append($0) }, overlayStore: store)
        #expect(cache.graph(for: layout.configuration, store: nil)?.person(familySearchID: "WWWW-111")?.birthDate
                == "21 Feb 1929")

        // A fresh full pull lands (newer than the overlay entry) and says 1930.
        let pull = layout.gedcom.appendingPathComponent("familysearch-20260921.ged")
        try AF.fullTree().replacingOccurrences(of: "21 Feb 1928", with: "3 Mar 1930")
            .write(to: pull, atomically: true, encoding: .utf8)
        let graph = cache.graph(for: layout.configuration, store: nil)
        #expect(graph?.person(familySearchID: "WWWW-111")?.birthDate == "3 Mar 1930")
        #expect(graph?.people.count == 30)
        #expect(store.load().entries.isEmpty)
        #expect(store.load().retired.map(\.familySearchID) == ["WWWW-111"])
        #expect(lines.all.contains { $0.hasPrefix("[fs-refresh] retired overlay for Walter (WWWW-111)") })
    }

    /// SCALE: a 40,000-person tree (the real one is 39,250). After the
    /// one-time parse, an Apply is a re-overlay of the cached base — no
    /// decode, no parse. Budget 3 s in Debug for the re-overlay read
    /// (includes the lazy index patch, not the parse).
    @Test func reoverlayOverFortyThousandPeople() throws {
        let layout = try AF.layout(people: 40_000, tag: "scale")
        defer { layout.remove() }
        let cache = FamilyGraphSharedCache(overlayStore: layout.overlayStore)
        let first = cache.load(for: layout.configuration, store: nil)
        #expect(first?.graph.people.count == 40_000)
        _ = first?.graph.index
        try record(layout.overlayStore, birth: "21 Feb 1929")
        let clock = ContinuousClock()
        let start = clock.now
        let second = cache.load(for: layout.configuration, store: nil)
        let elapsed = clock.now - start
        #expect(second?.graph.person(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1929")
        #expect(second?.graph.people.count == 40_000)
        #expect(cache.loaderRuns == 1)
        #expect(elapsed < .seconds(3), "re-overlay over 40k people took \(elapsed)")
    }
}

// MARK: - Isolation

@Suite("Refresh from FamilySearch — isolation")
struct PersonRefreshIsolationTests {
    @Test @MainActor func aTestHostNeverResolvesTheRealFolder() {
        let root = PersonRefreshPaths.defaultRoot.standardizedFileURL.path
        #expect(root.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path))
        #expect(!root.contains("Application Support"))
        #expect(FamilyGraphSharedCache.shared.overlayStore?.directory.standardizedFileURL.path == root)
        #expect(PersonRefreshCenter.shared.root.standardizedFileURL.path == root)
    }

    @Test @MainActor func anInjectedTreeModelSeesNoOverlayUnlessHandedOne() throws {
        let layout = try AF.layout(tag: "iso-model")
        defer { layout.remove() }
        // A POISONED overlay in the scratch default folder must not leak in.
        let poisoned = PersonFactOverlayStore(directory: PersonRefreshPaths.defaultRoot)
        var overlay = PersonFactOverlay()
        overlay.record([PersonRefreshChange(field: .birthDate, label: "", old: nil, new: "1 Jan 1066")],
                       familySearchID: "WWWW-111", displayName: "poison", at: Date())
        try poisoned.save(overlay)
        defer { try? FileManager.default.removeItem(at: poisoned.fileURL) }
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        #expect(model.personRefreshOverlayStore == nil)
        model.loadNow()
        #expect(model.personFacts(familySearchID: "WWWW-111")?.birthDate == "21 Feb 1928")
    }
}
