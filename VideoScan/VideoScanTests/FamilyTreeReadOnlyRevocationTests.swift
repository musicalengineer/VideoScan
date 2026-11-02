// FamilyTreeReadOnlyRevocationTests.swift
// Codex cycle #190 on the Family Tree's read-only state (BLOCK, 5 findings),
// each pinned by the regression Codex proposed, seen RED before the fix:
//
//   F1 (P0) — rulings and bookmarks from a wrong-UUID / absent archive must
//            never reach the displayed read-only tree: in the read-only state
//            they are empty, full stop. Production source resolution, with
//            the configuration `.unavailable` from the start; and a viewer.
//   F2 (P1) — a writer that does async work re-checks the CURRENT mode at the
//            moment of the write: a revocation mid-flight aborts before any
//            byte lands (snapshot at revocation == after), the absent mount
//            point is never recreated, and cancelling a started merge in the
//            read-only state does not remove its staging either.
//   F3 (P1) — model writers read the PUBLISHED authority at call time, not the
//            model's cached access: publish `.unavailable` without the tab
//            re-appearing, and the next write refuses and writes nothing.
//   F4 (P2) — an access change invalidates document reads in flight and
//            clears the caches/counts: a held listing released after the
//            transition publishes nothing.
//   F5 (P2) — on a viewer the pull-date refresh never opens manifest source
//            directories (archive paths): instrumented, zero searches.
//
// Every fixture is under one temp root; revocations are published on an
// INJECTED configuration centre or a per-test mode box, never process-wide.

import Testing
import Foundation
import CoreGraphics
import VideoScanCore
@testable import VideoScan

/// A mode a test flips from any thread (C++: an atomic enum).
final class ReadOnlyModeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FamilyTreeAccessMode
    init(_ value: FamilyTreeAccessMode = .full) { self.value = value }
    var mode: FamilyTreeAccessMode { lock.withLock { value } }
    func set(_ next: FamilyTreeAccessMode) { lock.withLock { value = next } }
}

/// Every file and folder under `root` (path → size|sha), for byte identity.
func revocationSnapshot(_ root: URL) throws -> [String: String] {
    var out: [String: String] = [:]
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return out
    }
    let base = root.resolvingSymlinksInPath().path.count
    for case let url as URL in walker {
        let rel = String(url.resolvingSymlinksInPath().path.dropFirst(base))
        if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            out[rel + "/"] = "dir"
        } else {
            let data = try Data(contentsOf: url)
            out[rel] = "\(data.count)|\(FamilyAssetStore.sha256Hex(data))"
        }
    }
    return out
}

private let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)

/// A configuration centre of our own, publishing what the catalog model
/// would publish for the fixture's archive.
private func center(_ fx: ReadOnlyFixture, available: Bool) -> FamilyAssetConfigurationCenter {
    let c = FamilyAssetConfigurationCenter()
    c.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: available, readOnly: false)
    return c
}

private func revoke(_ c: FamilyAssetConfigurationCenter, _ fx: ReadOnlyFixture) {
    c.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
}

/// A small valid PDF (documents are validated as PDFs or images).
private func pdfData() throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.fill(CGRect(x: 10, y: 10, width: 50, height: 20))
    context.endPDFPage()
    context.closePDF()
    return data as Data
}

// MARK: - F1: rulings and bookmarks never reach the read-only tree

@Suite("Family Tree read-only — F1 rulings/bookmarks from a rejected archive", .serialized)
@MainActor
struct FamilyTreeReadOnlyRulingsTests {

    /// Hide the root person, and bookmark them, in `directory`.
    private func plantRulingAndBookmark(_ fx: ReadOnlyFixture, in directory: URL) throws -> String {
        let graph = try #require(fx.store().loadCurrent()?.graph)
        let fsid = try #require(graph.people[fx.rootPersonID]?.familySearchID)
        var rulings = FamilyIdentityDecisions()
        rulings.record(.init(key: .familySearch(fsid), hidden: true))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try rulings.save(to: directory)
        var marks = FamilyTreeBookmarks()
        _ = marks.toggle(fx.rootPersonID)
        try marks.save(to: directory)
        return fsid
    }

    /// Codex's reproduction: production source resolution, `.unavailable`
    /// from the start, a wrong-UUID volume carrying a ruling and a bookmark.
    @Test func aWrongUUIDVolumesRulingAndBookmarkNeverReachTheReadOnlyTree() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        _ = try plantRulingAndBookmark(fx, in: fx.gedcomDirectory)
        let published = center(fx, available: false)
        let source = fx.configuration(access: .unavailable)
        let defaults = try #require(UserDefaults(suiteName: "ft-ro-f1-\(UUID().uuidString)"))
        let model = FamilyTreeLiveModel(compiledStore: fx.store(), cyberBrainRootURL: fx.brain,
                                        noteAuthor: "Rick", pronunciationFallback: { .shipped },
                                        focusDefaults: defaults, profilesProvider: { [] },
                                        documentStoreProvider: { nil },
                                        sourceConfiguration: source, configurationCenter: published)
        await model.prepareForAppearance(revision: "ro", source: source, settings: settings)
        #expect(model.accessMode == .readOnly(.archiveUnavailable))
        #expect(model.isLive)
        #expect(!model.isSuppressedRecord(fx.rootPersonID), "a wrong-UUID volume's ruling hid a person")
        #expect(model.filteredPeople.contains { $0.id == fx.rootPersonID })
        #expect(model.peopleCount == fx.people)
        #expect(model.bookmarks.ids.isEmpty, "a wrong-UUID volume's bookmarks were read")
        #expect(model.identityDecisions.isEmpty)
    }

    /// The same rule on a viewer: read-only means no rulings, no bookmarks.
    @Test func aViewerShowsNoRulingsAndNoBookmarks() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let configuration = fx.viewerConfiguration
        _ = try plantRulingAndBookmark(fx, in: configuration.gedcomDirectory())
        let h = ReadOnlyHarness(fx, configuration: configuration, asViewer: true)
        await h.appear(configuration)
        #expect(h.model.accessMode == .readOnly(.viewer))
        #expect(h.model.isLive)
        #expect(!h.model.isSuppressedRecord(fx.rootPersonID))
        #expect(h.model.bookmarks.ids.isEmpty)
    }
}

// MARK: - F3: writers read the published authority at call time

@Suite("Family Tree read-only — F3 published revocation reaches the next write", .serialized)
@MainActor
struct FamilyTreeReadOnlyPublishedAuthorityTests {

    @Test func aPublishedRevocationRefusesTheNextWriteWithoutReappearing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let published = center(fx, available: true)
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped }, configurationCenter: published)
        let lines = ReadOnlyLines()
        model.writeRefusalLog = { lines.append($0) }
        await model.prepareForAppearance(revision: "full", source: fx.configuration(access: .readWrite),
                                         settings: settings)
        #expect(model.accessMode == .full)

        // The archive goes away: the catalog model republishes; the tab does
        // NOT re-appear (no configure, no load).
        revoke(published, fx)
        let before = try revocationSnapshot(fx.root)
        #expect(throws: (any Error).self) { try model.addNote("written after revocation", about: fx.rootPersonID) }
        #expect(try revocationSnapshot(fx.root) == before, "a write landed after the authority was revoked")
        #expect(lines.all.contains { $0.contains(FamilyTreeWriteGate.logPrefix) })
    }
}

// MARK: - F2: revocation mid-flight

@Suite("Family Tree read-only — F2 revocation while a write is in flight", .serialized)
@MainActor
struct FamilyTreeReadOnlyInFlightTests {

    // -- Get Family Tree: Add to current tree --

    private struct PullRig {
        let root: URL
        let volume: URL, unplugged: URL
        let gedcom: URL, downloads: URL, staging: URL
        let box = ReadOnlyModeBox()
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ft-ro-pull-\(UUID().uuidString)", isDirectory: true)
            volume = root.appendingPathComponent("Volumes/MasterArchive", isDirectory: true)
            unplugged = root.appendingPathComponent("Unplugged", isDirectory: true)
            gedcom = volume.appendingPathComponent("40_Family_Tree/GEDCOM", isDirectory: true)
            downloads = root.appendingPathComponent("Downloads", isDirectory: true)
            staging = root.appendingPathComponent("AppSupport/family-tree/staging", isDirectory: true)
            for d in [gedcom, downloads, unplugged] {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
        }
        func unplug() throws {
            try FileManager.default.moveItem(at: volume, to: unplugged.appendingPathComponent("MasterArchive"))
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private static let base = ReadOnlyFixture.gedcom(people: 12, generations: 3)
    private static let incoming = ReadOnlyFixture.gedcom(people: 8, generations: 2)
        .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID N")

    private func readyCoordinator(_ rig: PullRig) async throws -> FamilySearchPullCoordinator {
        let current = rig.gedcom.appendingPathComponent("familysearch-tree.ged")
        try Self.base.write(to: current, atomically: true, encoding: .utf8)
        let download = rig.downloads.appendingPathComponent("familysearch-new.ged")
        try Self.incoming.write(to: download, atomically: true, encoding: .utf8)
        let c = FamilySearchPullCoordinator(
            gedcomDirectory: rig.gedcom, defaultUsername: "rick@example.com",
            scriptURL: rig.downloads.appendingPathComponent("get-family-tree.command"),
            stagingDirectory: rig.staging,
            locator: FamilySearchToolLocator(overridePath: "/nonexistent/getmyancestors"),
            launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(30),
            parseDelay: .milliseconds(400))
        c.compiledStore = { nil }
        let box = rig.box
        c.writeMode = { box.mode }
        c.installFromFile(download)
        for _ in 0..<400 {
            if case .ready = c.phase { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .ready = c.phase else { throw ReadOnlyFixture.FixtureError("not ready: \(c.phase)") }
        return c
    }

    /// Codex's reproduction: staging finished, archive unplugged and the
    /// mode revoked, then activation — which must not recreate the mount
    /// point or publish the merged GEDCOM.
    @Test func aMergeRevokedAfterStagingNeverActivates() async throws {
        let rig = try PullRig(); defer { rig.tearDown() }
        let c = try await readyCoordinator(rig)
        let task = c.installMerged()
        try await Task.sleep(for: .milliseconds(150))     // staged; inside the 400 ms window
        try rig.unplug()
        rig.box.set(.readOnly(.archiveUnavailable))
        let atRevocation = try revocationSnapshot(rig.root)
        await task.value
        #expect(try revocationSnapshot(rig.root) == atRevocation, "bytes landed after revocation")
        #expect(!FileManager.default.fileExists(atPath: rig.volume.path), "the absent mount point was recreated")
        if case .installed = c.phase { Issue.record("a revoked merge activated") }
    }

    /// Cancelling a started merge in the read-only state removes nothing.
    @Test func cancellingAMergeInTheReadOnlyStateRemovesNothing() async throws {
        let rig = try PullRig(); defer { rig.tearDown() }
        let c = try await readyCoordinator(rig)
        let task = c.installMerged()
        try await Task.sleep(for: .milliseconds(150))
        rig.box.set(.readOnly(.archiveUnavailable))
        let atRevocation = try revocationSnapshot(rig.root)
        c.cancel()
        await task.value
        #expect(try revocationSnapshot(rig.root) == atRevocation, "cancel removed staging in read-only")
    }

    // -- Recompile (the tab) --

    @Test func aRecompileRevokedMidCompilePromotesNothing() async throws {
        let box = try FamilyTreeRecompileButtonTests.Sandbox(); defer { box.tearDown() }
        var (store, sources, _) = try box.promoteTwoPullsWithAnOldCodec()
        let published = FamilyAssetConfigurationCenter()
        published.publish(masterArchiveRoot: box.root, masterIsSafelyAvailable: true, readOnly: false)
        let log = box.log
        // Revoke the moment the compile has parsed its first pull — before
        // the ingest writes anything.
        store.log = { line in
            log.append(line)
            if line.contains("recompile parsed") {
                published.publish(masterArchiveRoot: box.root, masterIsSafelyAvailable: false, readOnly: false)
            }
        }
        let model = FamilyTreeLiveModel(originalsDirectory: box.gedcom, compiledStore: store,
                                        configurationCenter: published)
        await model.loadFromDisk()
        #expect(model.needsRecompile == sources)
        let before = try revocationSnapshot(box.compiled)
        await model.recompile()
        #expect(try revocationSnapshot(box.compiled) == before, "the compile promoted after revocation: \(log.all)")
        #expect(!model.needsRecompile.isEmpty)
    }

    // -- Recompile (the standalone centre: Hallie's chip with no tab) --

    @Test func aStandaloneRecompileRevokedMidCompilePromotesNothing() async throws {
        let box = try FamilyTreeRecompileButtonTests.Sandbox(); defer { box.tearDown() }
        var (store, _, _) = try box.promoteTwoPullsWithAnOldCodec()
        let mode = ReadOnlyModeBox()
        let log = box.log
        store.log = { line in
            log.append(line)
            if line.contains("recompile parsed") { mode.set(.readOnly(.archiveUnavailable)) }
        }
        let centre = FamilyTreeRecompileCenter()
        centre.writeMode = { mode.mode }
        let before = try revocationSnapshot(box.compiled)
        let outcome = await centre.recompile(configuration: box.configuration(), store: store,
                                             cache: FamilyGraphSharedCache(), progress: { _ in })
        #expect(outcome != .promoted)
        #expect(try revocationSnapshot(box.compiled) == before, "\(log.all)")
    }

    // -- Document removal --

    @Test func aDocumentRemovalRevokedBeforeItRunsMovesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let store = fx.configuration(access: .readWrite).makeStore()
        let graph = try #require(fx.store().loadCurrent()?.graph)
        let person = FamilyAssetPerson(try #require(graph.people[fx.rootPersonID]))
        let source = fx.root.appendingPathComponent("birth.pdf")
        try pdfData().write(to: source)
        let folder = try store.folderForPhotoRequest(person: person)
        _ = try store.importPersonDocument(from: source, kind: .birth, note: "", into: folder, for: person)

        let published = center(fx, available: true)
        let revokeOnProvide = ReadOnlyModeBox()
        let model = FamilyTreeLiveModel(
            originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(), cyberBrainRootURL: fx.brain,
            noteAuthor: "Rick", pronunciationFallback: { .shipped },
            documentStoreProvider: {
                if revokeOnProvide.mode.isReadOnly { revoke(published, fx) }
                return store
            },
            configurationCenter: published)
        await model.prepareForAppearance(revision: "full", source: fx.configuration(access: .readWrite),
                                         settings: settings)
        model.select(fx.rootPersonID)
        #expect(await PersonRefreshAppFixtures.waitUntil { !model.selectedDocuments.isEmpty })
        let row = try #require(model.selectedDocuments.first)
        revokeOnProvide.set(.readOnly(.archiveUnavailable))   // the archive goes as the removal starts
        let atRevocation = try revocationSnapshot(fx.root)
        let words = await model.removeDocument(row)
        #expect(words != nil)
        #expect(try revocationSnapshot(fx.root) == atRevocation, "a document moved after revocation")
    }

    // -- Refresh from FamilySearch: Apply --

    @Test func aRefreshApplyRevokedBeforeTheOverlayWriteWritesNothing() async throws {
        let layout = try PersonRefreshAppFixtures.layout(tag: "ro-apply")
        defer { layout.remove() }
        let model = FamilyTreeLiveModel(originalsDirectory: layout.gedcom)
        model.personRefreshOverlayStore = layout.overlayStore
        model.loadNow()
        let target = try #require(model.personRefreshTarget(for: "@I1@"))
        let box = ReadOnlyModeBox()
        let flipOnNow = ReadOnlyModeBox()
        let coordinator = PersonRefreshCoordinator(
            target: target, root: layout.refreshRoot, overlayStore: layout.overlayStore,
            installedFacts: { model.personFacts(familySearchID: target.familySearchID) },
            locator: FamilySearchToolLocator(overridePath: layout.tool.path, candidatePaths: []),
            launcher: PersonRefreshAppFixtures.SilentLauncher(), pollInterval: .milliseconds(20),
            sink: PersonRefreshNoteSink(videoscanLog: { _ in }),
            now: {
                if flipOnNow.mode.isReadOnly { box.set(.readOnly(.archiveUnavailable)) }
                return Date()
            })
        coordinator.writeMode = { box.mode }
        coordinator.launch()
        guard case .waiting(let output) = coordinator.phase else { Issue.record("\(coordinator.phase)"); return }
        try PersonRefreshAppFixtures.onePerson().write(to: output, atomically: true, encoding: .utf8)
        #expect(await PersonRefreshAppFixtures.waitUntil { if case .ready = coordinator.phase { true } else { false } })
        guard case .ready(let diff) = coordinator.phase else { return }
        flipOnNow.set(.readOnly(.archiveUnavailable))          // revoked inside apply, after its entry gate
        let atRevocation = try revocationSnapshot(layout.refreshRoot)
        let applied = await coordinator.apply(selectedFieldKeys: Set(diff.changes.map(\.field.key)))
        #expect(!applied)
        #expect(try revocationSnapshot(layout.refreshRoot) == atRevocation, "the overlay or journal was written")
    }

    // -- I found a record: filing --

    @Test func aFilingRevokedAfterItsChecksFilesNothing() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("ft-ro-filing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
                                     access: .readWrite)
        let graph = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Honora /Fenlane/
        1 SEX F
        1 BIRT
        2 DATE 1878
        1 DEAT
        2 DATE 1935
        1 _FSFTID ZZZZ-901
        0 TRLR
        """)
        let record = try #require(graph.people["@I1@"])
        let file = downloads.appendingPathComponent("record.pdf")
        try pdfData().write(to: file)
        let box = ReadOnlyModeBox()
        let calls = ReadOnlyLines()
        var filer = RecordFinderFiler(
            assetStore: store, assetPerson: FamilyAssetPerson(record),
            researchStore: ResearchStore(peopleRoot: store.peopleDirectory),
            subject: ResearchSubject(person: record), speakerName: "Tester", record: nil,
            log: { _ in },
            now: {
                // The second clock read is at the end of the checks, after
                // the entry gate: the archive goes away right there.
                calls.append("now")
                if calls.all.count >= 2 { box.set(.readOnly(.archiveUnavailable)) }
                return Date(timeIntervalSince1970: 1_790_000_000)
            })
        filer.writeMode = { box.mode }
        try fm.createDirectory(at: base.appendingPathComponent("archive"), withIntermediateDirectories: true)
        let before = try revocationSnapshot(base.appendingPathComponent("archive"))
        let outcome = await filer.file(FoundRecordSubmission(
            file: file, siteID: "ie.irishgenealogy.civil-church", siteTitle: "irishgenealogy.ie",
            recordType: .birth, year: "1878", district: "Skibbereen", recordID: "T1",
            pageURL: "https://www.irishgenealogy.ie/view?record_id=T1", transcription: "", confirmedRead: false))
        #expect(calls.all.count >= 2, "the clock hook never ran — the test did not revoke mid-flight")
        if case .filed = outcome { Issue.record("filed after revocation") }
        #expect(try revocationSnapshot(base.appendingPathComponent("archive")) == before)
    }
}

// MARK: - F4: document reads in flight across the transition

/// A listing a test holds open and releases (C++: a latch).
final class HeldListing: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = 0
    var startedCount: Int { lock.withLock { started } }
    func wait() { lock.withLock { started += 1 }; gate.wait() }
    func releaseAll() { for _ in 0..<64 { gate.signal() } }
}

@Suite("Family Tree read-only — F4 document reads across the transition", .serialized)
@MainActor
struct FamilyTreeReadOnlyDocumentTransitionTests {

    @Test func aHeldListingReleasedAfterTheTransitionPublishesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let full = fx.configuration(access: .readWrite)
        let store = full.makeStore()
        let graph = try #require(fx.store().loadCurrent()?.graph)
        let person = FamilyAssetPerson(try #require(graph.people[fx.rootPersonID]))
        let source = fx.root.appendingPathComponent("birth.pdf")
        try pdfData().write(to: source)
        _ = try store.importPersonDocument(from: source, kind: .birth, note: "",
                                           into: try store.folderForPhotoRequest(person: person), for: person)
        let held = HeldListing()
        let model = FamilyTreeLiveModel(originalsDirectory: fx.gedcomDirectory, compiledStore: fx.store(),
                                        cyberBrainRootURL: fx.brain, noteAuthor: "Rick",
                                        pronunciationFallback: { .shipped },
                                        documentStoreProvider: { store })
        // The read happens BEFORE the transition; only its publication is
        // held until after it.
        model.documentListing = { store, person, _ in
            let rows = store.documents(for: person)
            held.wait()
            return rows
        }
        await model.prepareForAppearance(revision: "full", source: full, settings: settings)
        model.select(fx.rootPersonID)
        #expect(await PersonRefreshAppFixtures.waitUntil { held.startedCount >= 2 },
                "both a selection read and a card-count read are in flight")

        // The archive goes. The tab is configured for the new source first;
        // the reads in flight land before (or while) the tree reloads.
        try fx.unplug()
        let offline = fx.configuration(access: .unavailable)
        model.configure(source: offline)
        #expect(model.accessMode == .readOnly(.archiveUnavailable))
        held.releaseAll()
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.selectedDocuments.isEmpty, "a pre-transition listing was published in read-only")
        #expect(model.documentCount(for: fx.rootPersonID) == 0, "a pre-transition count is still on the card")
        // And the read-only reload of the same compiled graph keeps it so.
        await model.prepareForAppearance(revision: "offline", source: offline, settings: settings)
        #expect(model.selectedDocuments.isEmpty)
        #expect(model.documentCount(for: fx.rootPersonID) == 0)
    }
}

// MARK: - F5: viewer pull dates never search archive paths

@Suite("Family Tree read-only — F5 viewer pull dates", .serialized)
@MainActor
struct FamilyTreeReadOnlyPullDateTests {

    @Test func aViewerAppearanceNeverSearchesManifestSourceFolders() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let searched = ReadOnlyLines()

        // Control: on the master the instrument does see the archive folder.
        let master = ReadOnlyHarness(fx, configuration: fx.configuration(access: .readWrite), asViewer: false)
        master.model.pullDates.searchRootsObserver = { roots in for r in roots { searched.append(r.path) } }
        await master.appear(fx.configuration(access: .readWrite))
        #expect(await PersonRefreshAppFixtures.waitUntil { !searched.all.isEmpty }, "the instrument is blind")

        let viewerSearched = ReadOnlyLines()
        let h = ReadOnlyHarness(fx, configuration: fx.viewerConfiguration, asViewer: true)
        h.model.pullDates.searchRootsObserver = { roots in for r in roots { viewerSearched.append(r.path) } }
        await h.appear(fx.viewerConfiguration)
        #expect(h.model.isLive)
        try await Task.sleep(for: .milliseconds(500))
        let archive = fx.archive.resolvingSymlinksInPath().path
        #expect(viewerSearched.all.allSatisfy { !$0.hasPrefix(archive) && !$0.hasPrefix(fx.archive.path) },
                "a viewer searched archive paths: \(viewerSearched.all)")
        #expect(viewerSearched.all.isEmpty, "a viewer ran the pull-date search at all: \(viewerSearched.all)")
    }
}

// MARK: - F1/F2 seams: the probe and the live store

/// Counts every directory listing (C++: a mock FileSystem).
final class ListingSpy: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var listed: [String] { lock.withLock { paths } }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
                                      options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        lock.withLock { paths.append(url.path) }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}

@Suite("Family Tree read-only — the archive is not listed; live stores re-check")
struct FamilyTreeReadOnlySeamTests {

    @Test func anUnavailableArchiveIsNeverListedToResolveTheGEDCOMFolder() throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let spy = ListingSpy()
        let unavailable = fx.configuration(access: .unavailable)
        #expect(unavailable.resolvedGEDCOMDirectory(fileManager: spy) == fx.gedcomDirectory)
        #expect(spy.listed.isEmpty, "listed \(spy.listed)")
        // Control: an available archive is probed as before.
        _ = fx.configuration(access: .readWrite).resolvedGEDCOMDirectory(fileManager: spy)
        #expect(!spy.listed.isEmpty, "the spy is blind")
    }

    @Test func aLiveStoreRefusesOnceTheAuthorityIsRevokedAndCreatesNothing() throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let centre = FamilyAssetConfigurationCenter()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: true, readOnly: false)
        let store = centre.makeLiveStore()
        #expect(throws: Never.self) { try store.requireWriteAccess() }
        try fx.unplug()
        centre.publish(masterArchiveRoot: fx.archive, masterIsSafelyAvailable: false, readOnly: false)
        #expect(throws: FamilyAssetStore.StoreError.sourceUnavailable) { try store.requireWriteAccess() }
        #expect(throws: FamilyAssetStore.StoreError.sourceUnavailable) {
            _ = try store.folderForPhotoRequest(person: FamilyAssetPerson(gedcomID: "@I0_0@", name: "Root"))
        }
        #expect(!FileManager.default.fileExists(atPath: fx.archive.path), "the absent mount point was created")
        // Another archive published in its place is not this store's.
        centre.publish(masterArchiveRoot: fx.root.appendingPathComponent("Other"), masterIsSafelyAvailable: true,
                       readOnly: false)
        #expect(throws: FamilyAssetStore.StoreError.sourceUnavailable) { try store.requireWriteAccess() }
    }
}
