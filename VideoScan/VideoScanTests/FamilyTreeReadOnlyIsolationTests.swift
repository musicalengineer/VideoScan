// FamilyTreeReadOnlyIsolationTests.swift
// DECISIONS 2026-11-01 — nothing is written anywhere in the Family Tree's
// read-only state. Three poisoned worlds:
//   • the Master Archive unplugged (its mount point is empty);
//   • the archive mounted with the WRONG UUID (present, but not the archive);
//   • this Mac a CatalogSync viewer.
// In each, the fixture folder (archive + App Support: compiled tree,
// CyberBrain, overlay, decorations, Person of the Day, portrait) must be
// byte-identical after the load and after every action a test can drive;
// each attempted write refuses in words and logs exactly one line; and the
// unplugged archive's mount point is never created.
//
// Plus the scale dimension: the 39,250-person graph loads read-only within
// the launch prewarm test's budget (FamilyTreeLaunchBundleTests).

import Testing
import AppKit
import Foundation
import VideoScanCore
@testable import VideoScan

@Suite("Family Tree read-only — isolation (nothing is written)", .serialized)
@MainActor
struct FamilyTreeReadOnlyIsolationTests {

    enum World: String, CaseIterable { case archiveUnplugged, wrongUUID, viewer }

    @Test(arguments: World.allCases)
    func aReadOnlyLoadAndEveryActionLeaveTheFolderByteIdentical(world: World) async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        try fx.seedNote()
        let configuration: FamilyAssetConfiguration
        switch world {
        case .archiveUnplugged:
            try fx.unplug()
            configuration = fx.configuration(access: .unavailable)
        case .wrongUUID:
            configuration = fx.configuration(access: .unavailable)
        case .viewer:
            configuration = fx.viewerConfiguration
        }
        let before = try fx.snapshot()

        let h = ReadOnlyHarness(fx, configuration: configuration, asViewer: world == .viewer)
        await h.appear(configuration)
        let model = h.model
        #expect(model.isLive, "\(world): the compiled tree is shown")
        #expect(model.accessMode.isReadOnly)
        #expect(try fx.snapshot() == before, "\(world): the LOAD wrote something")

        // The lines one refusal adds: archive → the model's refusal log;
        // viewer → the injected viewer center (ViewerWriteGuard, unchanged).
        var seen = h.refusals.all.count
        func expectOneLine(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
            let now = h.refusals.all.count
            #expect(now == seen + 1, "\(world) \(what): \(now - seen) refusal line(s)", sourceLocation: sourceLocation)
            if let last = h.refusals.all.last {
                #expect(last.contains(world == .viewer ? ViewerWriteGuard.logPrefix : FamilyTreeWriteGate.logPrefix),
                        "\(world) \(what): \(last)", sourceLocation: sourceLocation)
            }
            seen = now
        }
        func expectWords(_ error: Error, sourceLocation: SourceLocation = #_sourceLocation) {
            let words = error.localizedDescription
            #expect(words.contains(world == .viewer ? "on the master" : "until the Master Archive is connected"),
                    "\(world): \(words)", sourceLocation: sourceLocation)
        }

        // Reads: browsing never writes.
        model.select(fx.rootPersonID)
        model.searchText = "Breen"
        model.selectNext()
        model.searchText = ""
        model.focusHome()
        model.showFullTree()
        await model.verifyTree()
        await model.loadFromDisk(settings: FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil))
        model.select(fx.rootPersonID)
        model.loadCyberBrainNow()
        model.select(fx.rootPersonID)
        let note = try #require(model.selectedNotes.first, "\(world): the seeded note is shown (CyberBrain is read)")

        // Every writer, attempted.
        let wasMarked = model.isBookmarked(fx.rootPersonID)
        #expect(model.toggleBookmark(fx.rootPersonID) == wasMarked)
        expectOneLine("bookmark")
        #expect(!model.setRecordHidden(true, personID: fx.rootPersonID))
        expectOneLine("hide")
        do { try model.addNote("x", about: fx.rootPersonID); Issue.record("addNote wrote") } catch { expectWords(error) }
        expectOneLine("addNote")
        model.noteDraftChanged(isEmpty: false)
        do { try model.saveNoteDraft("x"); Issue.record("saveNoteDraft wrote") } catch { expectWords(error) }
        expectOneLine("saveNoteDraft")
        do { _ = try model.editNote(note, newText: "y"); Issue.record("editNote wrote") } catch { expectWords(error) }
        expectOneLine("editNote")
        do {
            _ = try model.removeNote(note, reason: .wrongPerson)
            Issue.record("removeNote wrote")
        } catch { expectWords(error) }
        expectOneLine("removeNote")
        do { try model.setPronunciation(word: "Breen", saidAs: "BREEN"); Issue.record("pronunciation wrote") }
        catch { expectWords(error) }
        expectOneLine("setPronunciation")
        let testimony = CyberBrainWriter.Testimony(subjectName: "Anyone", subjectAliases: [], speakerName: "Rick",
                                                   text: "t", date: Date())
        do { _ = try model.recordTestimony(testimony); Issue.record("recordTestimony wrote") } catch { expectWords(error) }
        expectOneLine("recordTestimony")
        let recorder = try #require(model.cyberBrainRecorder())
        do { _ = try recorder(testimony); Issue.record("recorder wrote") } catch { expectWords(error) }
        expectOneLine("cyberBrainRecorder")
        let doc = PersonDocument(id: UUID(), kind: .birth, filename: "BC.pdf", originalFilename: "BC.pdf",
                                 addedAt: Date(), note: "", sha256: "00", byteCount: 1,
                                 fileURL: fx.assetsRoot.appendingPathComponent("People/x/Documents/BC.pdf"))
        let row = PersonDocumentRow(document: doc, ownerID: fx.rootPersonID,
                                    owner: FamilyAssetPerson(gedcomID: fx.rootPersonID, name: "Root"))
        let removal = await model.removeDocument(row)
        #expect(removal?.contains(world == .viewer ? "on the master" : "until the Master Archive is connected") == true,
                "\(world): \(removal ?? "nil")")
        expectOneLine("removeDocument")
        model.revealOriginalsFolder()
        expectOneLine("revealOriginalsFolder")
        model.setPhotoOverride(NSImage(size: NSSize(width: 4, height: 4)), for: fx.rootPersonID)
        #expect(model.photo(for: fx.rootPersonID) == nil, "\(world): no photo override is put on a card")
        await model.recompile()   // nothing pending: refused without a write either way
        #expect(model.loadWarning != nil)

        // Writers that live beside the model, in the same state.
        let mode = model.accessMode
        try assertSideWritersRefuse(fx, mode: mode, viewer: h.viewer, world: world)

        #expect(h.storeRequests == 0, "\(world): the asset store was asked for")
        #expect(try fx.snapshot() == before, "\(world): an action wrote something")
        if world == .archiveUnplugged {
            #expect(!FileManager.default.fileExists(atPath: fx.archive.path),
                    "the empty mount point must never be created")
        }
    }

    /// Walk decorations, Person of the Day, research, the couple portrait,
    /// identity pins, person refresh undo — each refuses in the same state.
    private func assertSideWritersRefuse(_ fx: ReadOnlyFixture, mode: FamilyTreeAccessMode,
                                         viewer: ViewerModeCenter, world: World) throws {
        // Viewer-mode delegation reads ViewerModeCenter.shared for these
        // process-wide writers; play the archive-absent mode for them so the
        // test never flips the whole process into viewer mode.
        let sideMode: FamilyTreeAccessMode = .readOnly(.archiveUnavailable)

        // Person of the Day: the rotation memory is not saved.
        let potd = PersonOfTheDayGatedStore(base: PersonOfTheDayFileStore(url: fx.personOfTheDay),
                                            mode: { sideMode })
        #expect(throws: FamilyTreeWriteGate.Refused.self) { try potd.save(.empty) }

        // Research Person… cache.
        var research = ResearchStore(peopleRoot: fx.assetsRoot.appendingPathComponent("People"))
        research.writeMode = { sideMode }
        let page = ResearchStore.CachedPage(url: "https://example.org", retrievedAt: Date(), statusCode: 200,
                                            body: Data("x".utf8))
        #expect(throws: FamilyTreeWriteGate.Refused.self) { try research.cache(page, key: "KWZQ-123") }

        // The couple portrait.
        let defaults = try #require(UserDefaults(suiteName: "ft-readonly-\(UUID().uuidString)"))
        let image = fx.root.appendingPathComponent("portrait-source.png")
        #expect(throws: FamilyTreeWriteGate.Refused.self) {
            try CouplePortraitPreference.importPhoto(at: image, into: fx.portraitDirectory,
                                                     defaults: defaults, mode: sideMode)
        }
        CouplePortraitPreference.remove(from: defaults, directory: fx.portraitDirectory, mode: sideMode)
        CouplePortraitPreference.saveCaption("Rick & Donna", to: defaults, mode: sideMode)
        #expect(defaults.string(forKey: CouplePortraitPreference.captionKey) == nil)

        // Identity pins: the store closure is never reached.
        let identity = TreeIdentityCenter(kinshipCenter: KinshipDisplayCenter())
        var stored = 0
        identity.store = { _ in stored += 1 }
        identity.defaults = nil
        identity.writeMode = { sideMode }
        let profile = POIProfile(name: "Read Only \(UUID().uuidString)", referencePath: fx.root.path)
        if case .saved = identity.unpin(profile) { Issue.record("unpin saved in read-only") }
        if case .saved = identity.markNotInTree(profile) { Issue.record("markNotInTree saved in read-only") }
        #expect(stored == 0)

        // Walk decorations: aCanonicalWalkInTheReadOnlyStateIsNotSaved.
        _ = (mode, viewer, world)
    }

    /// The canonical foreground walk: it runs (display) and is not saved.
    @Test func aCanonicalWalkInTheReadOnlyStateIsNotSaved() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let walk = FamilyTreeWalkCenter()
        walk.storeURL = fx.decorations
        walk.writeMode = { .readOnly(.archiveUnavailable) }
        walk.ownerFamilySearchID = { nil }
        walk.refreshDebounce = .zero
        let graph = try #require(fx.store().loadCurrent()?.graph)
        let starts = FamilyTreeWalkCenter.defaultStarts(in: graph, ownerFamilySearchID: nil)
        try #require(!starts.isEmpty)
        let before = try fx.snapshot()
        walk.treeDidChange(graph, reason: "tree loaded")
        await walk.waitForRefresh()
        #expect(walk.automaticWalkCount == 0, "no automatic re-walk in read-only")
        let result = await walk.run(graph: graph, options: .init(starts: starts), mode: .foreground,
                                    displayNames: ["A"])
        #expect(result != nil, "the walk itself still runs (display only)")
        #expect(walk.recentLines.contains { $0.contains(FamilyTreeWriteGate.logPrefix) })
        #expect(walk.recentLines.last?.contains("decorations not saved (read-only") == true,
                "\(walk.recentLines.last ?? "")")
        #expect(try fx.snapshot() == before)
    }

    /// Refresh from FamilySearch — Undo is a write (overlay + journal).
    @Test func personRefreshUndoRefusesInWordsAndWritesNothing() async throws {
        let fx = try ReadOnlyFixture(); defer { fx.tearDown() }
        let before = try fx.snapshot()
        let words = await PersonRefreshCoordinator.undoLast(
            familySearchID: "KWZQ-123", personName: "Anyone", overlayStore: fx.overlayStore,
            journalDirectory: fx.overlayDirectory, sink: .init(videoscanLog: { _ in }),
            mode: { .readOnly(.archiveUnavailable) })
        #expect(words.contains("until the Master Archive is connected"), "\(words)")
        #expect(try fx.snapshot() == before)
    }
}

// MARK: - Scale

@Suite("Family Tree read-only — scale (39,250 people)", .serialized)
@MainActor
struct FamilyTreeReadOnlyScaleTests {

    /// Rick's real tree size. The budget is the launch prewarm test's
    /// (FamilyTreeLaunchBundleTests.prewarmWaitAttempts × 50 ms: 10 s in
    /// Release, 60 s in Debug), applied to the read-only load alone — the
    /// compile that builds the fixture is set-up, not measured.
    @Test func theRealSizedTreeLoadsReadOnlyWithinThePrewarmBudget() async throws {
        let fx = try ReadOnlyFixture(people: 39_250, generations: 17); defer { fx.tearDown() }
        try fx.unplug()
        let configuration = fx.configuration(access: .unavailable)
        let h = ReadOnlyHarness(fx, configuration: configuration, asViewer: false)
        let before = try fx.snapshot()
        let budget = Duration.milliseconds(50 * FamilyTreeLaunchBundleTests.prewarmWaitAttempts)
        let clock = ContinuousClock(), start = clock.now
        await h.appear(configuration)
        let took = clock.now - start
        #expect(h.model.peopleCount == 39_250)
        #expect(h.model.accessMode == .readOnly(.archiveUnavailable))
        #expect(took < budget, "read-only load took \(took), budget \(budget)")
        #expect(try fx.snapshot() == before, "the read-only load of 39k people wrote something")
    }
}
