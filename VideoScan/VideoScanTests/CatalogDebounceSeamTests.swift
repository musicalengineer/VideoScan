// CatalogDebounceSeamTests.swift
//
// The two catalog save debounces are overridable per test, so the paths that
// need a debounce to ELAPSE no longer sleep out real seconds:
//
//   CatalogCommitter.$debounce      task-local (read when a commit is scheduled)
//   CatalogStore(saveDebounce:)     init parameter (the JSON store)
//
// Production is unchanged: nothing binds the task-local and nothing passes
// the parameter, so both are 2 s — pinned below.
//
// What a short debounce makes testable that was not (rule 8, catalog
// writers): an edit INSIDE the window, then Quit, then the window ELAPSING —
// the quit's commit holds the edit, the cancelled timer writes nothing more,
// and the relaunch reads it.
//
// Five dimensions: logic (here) · scale n/a (a timer; no per-record work) ·
// media n/a · isolation (a binding does not leak out of its scope; each test
// its own scratch catalog) · sensor (the production defaults are pinned).
//
// C++ readers: `$debounce.withValue(x) { … }` ≈ a scoped thread_local
// override, restored at the closing brace.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - catalog.sqlite's committer

@Suite("Catalog debounce seam — the committer (catalog.sqlite)", .serialized)
@MainActor
struct CatalogCommitterDebounceSeamTests {

    private static let short: Duration = .milliseconds(100)

    /// Until `condition` holds, at most ~5 s.
    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("SENSOR: with nothing bound the debounces are the production 2 s, and the dossier samples one second after")
    func productionDefaultsArePinned() {
        #expect(CatalogCommitter.debounce == .seconds(2))
        #expect(CatalogStore.saveDebounce == .seconds(2))
        #expect(FileDossierLoader.commitSample == CatalogCommitter.debounce + .seconds(1))
    }

    @Test("ISOLATION: a binding ends with its scope — a commit scheduled after it waits the production 2 s")
    func aBindingDoesNotLeak() async throws {
        let scene = try CutoverScene.make("deb_scope"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        CatalogCommitter.$debounce.withValue(Self.short) {
            #expect(CatalogCommitter.debounce == Self.short)
        }
        #expect(CatalogCommitter.debounce == .seconds(2))

        try scene.record(.healthy).userNotes = "scheduled outside any binding"
        let before = committer.commitCount
        scene.model.saveCatalogDebounced()                      // unbound: the 2 s timer
        try await Task.sleep(for: Self.short * 4)               // four SHORT windows
        #expect(committer.isBusy, "still on the production timer")
        #expect(committer.commitCount == before, "nothing written yet")
        #expect(scene.model.saveCatalogNow())                   // leave nothing pending
    }

    @Test("two edits inside one window make ONE commit, and both are in catalog.sqlite after a reload")
    func editsInsideTheWindowCoalesce() async throws {
        let scene = try CutoverScene.make("deb_coalesce"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let before = committer.commitCount

        let healthy = try scene.record(.healthy)
        CatalogCommitter.$debounce.withValue(Self.short) {
            scene.model.setUserNotes("first edit", for: healthy)
            healthy.starRating = 3
            scene.model.saveCatalogDebounced()                  // same turn: the timer cannot have fired
        }
        #expect(committer.commitCount == before, "an edit only schedules")
        try await wait { !committer.isBusy }

        #expect(committer.commitCount == before + 1, "one commit for the burst")
        #expect(committer.changedRecordCount() == 0, "the commit took everything: \(String(describing: committer.lastOutcome))")
        let stored = try await scene.reloaded(.healthy)
        #expect(stored.userNotes == "first edit")
        #expect(stored.starRating == 3)
    }

    @Test("an edit inside the window, then Quit: the quit's commit holds it, the elapsed window writes nothing more, and the relaunch reads it")
    func anEditInsideTheWindowThenQuit() async throws {
        let scene = try CutoverScene.make("deb_quit"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        let before = committer.commitCount

        let healthy = try scene.record(.healthy)
        CatalogCommitter.$debounce.withValue(Self.short) {
            scene.model.setUserNotes("typed just before Quit", for: healthy)
        }
        #expect(committer.isBusy, "the edit is on the timer — inside its window")
        _ = CatalogQuitRecovery.saveAtTermination(model: scene.model, writerDeadline: 5)   // Quit, inside the window

        #expect(!committer.isBusy, "the quit took the timer's commit")
        #expect(committer.commitCount == before + 1)
        #expect(try await scene.reloaded(.healthy).userNotes == "typed just before Quit")
        let generation = committer.knownGeneration

        try await Task.sleep(for: Self.short * 4)               // the window elapses, four times over
        #expect(committer.commitCount == before + 1, "the cancelled timer must not commit again")
        #expect(committer.knownGeneration == generation)
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: scene.folder.path)) ?? [])
            .filter { $0.hasPrefix(CatalogQuitRecovery.filePrefix) }
        #expect(copies.isEmpty, "nothing was at risk, so no recovery copy: \(copies)")

        try await scene.relaunch()
        #expect(try scene.record(.healthy).userNotes == "typed just before Quit", "the relaunch reads the edit")
    }

    @Test("an edit during a write hold waits out several windows unwritten, lands when the hold ends, and survives the relaunch")
    func anEditDuringAHoldLandsAtRelease() async throws {
        let scene = try CutoverScene.make("deb_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try scene.committer()
        #expect(scene.model.saveCatalogNow(), "the launch commit lands first")
        _ = await scene.model.catalogStore.holdWrites(reason: "a job is reading the catalog", owner: CatalogWriteHoldOwner())
        let before = committer.commitCount

        let healthy = try scene.record(.healthy)
        CatalogCommitter.$debounce.withValue(Self.short) {
            scene.model.setUserNotes("typed during the hold", for: healthy)
        }
        try await wait { scene.sandbox.catalogLogText().contains("HELD — a job is reading the catalog") }
        try await Task.sleep(for: Self.short * 3)
        #expect(committer.commitCount == before, "nothing is written while the job holds")
        #expect(try await scene.reloaded(.healthy).userNotes != "typed during the hold")

        _ = scene.model.catalogStore.releaseWriteHold()
        try await wait { !committer.isBusy }
        #expect(committer.commitCount == before + 1, "one commit once the hold ends")
        try await scene.relaunch()
        #expect(try scene.record(.healthy).userNotes == "typed during the hold")
    }
}

// MARK: - The JSON store

@Suite("Catalog debounce seam — the JSON store")
@MainActor
struct CatalogStoreDebounceSeamTests {

    private func scratchDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test_debounce_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    }

    private func record(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        return r
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("a scheduled save lands by itself one (injected) debounce later, and a burst is one write of the last state")
    func aDebouncedSaveLands() async throws {
        let dir = scratchDir("lands"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir, saveDebounce: .milliseconds(50))
        store.scheduleSave(records: [record("first.mov")])
        store.scheduleSave(records: [record("first.mov"), record("second.mov")])    // same turn: resets the timer
        #expect(!FileManager.default.fileExists(atPath: store.fileLocation), "scheduling writes nothing")
        #expect(store.hasUnsavedChanges)

        try await wait { !store.hasUnsavedChanges }
        #expect(!store.hasUnsavedChanges)
        let back = CatalogStore(directory: dir).load()
        #expect(Set(back.map(\.filename)) == ["first.mov", "second.mov"])
        #expect(store.currentGeneration == 1, "one write for the burst, not two")
    }

    @Test("an edit inside the window, then Quit (saveNow): the file holds it, the elapsed window writes nothing more, and the relaunch reads it")
    func anEditInsideTheWindowThenQuit() async throws {
        let dir = scratchDir("quit"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir, saveDebounce: .milliseconds(50))
        let records = [record("typed-before-quit.mov")]
        store.scheduleSave(records: records)                    // the edit, on the timer
        #expect(store.saveNow(records: records))                // Quit, inside the window
        let generation = store.currentGeneration
        let bytes = try Data(contentsOf: URL(fileURLWithPath: store.fileLocation))

        try await Task.sleep(for: .milliseconds(250))           // five windows
        #expect(!store.hasUnsavedChanges)
        #expect(store.currentGeneration == generation, "the cancelled timer must not save again")
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.fileLocation)) == bytes)
        #expect(CatalogStore(directory: dir).load().map(\.filename) == ["typed-before-quit.mov"])
    }

    @Test("with no parameter a store waits the production 2 s: nothing is on disk after several short windows")
    func theDefaultIsTheProductionDebounce() async throws {
        let dir = scratchDir("default"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.scheduleSave(records: [record("a.mov")])
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.hasUnsavedChanges, "still on the 2 s timer")
        #expect(!FileManager.default.fileExists(atPath: store.fileLocation))
        #expect(store.saveNow(records: [record("a.mov")]))      // leave nothing pending
    }
}
