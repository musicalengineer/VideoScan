// FamilyGraphCurrentManifestReadTests.swift
//
// Stage-0 static triage R1 (2026-09-29). FamilySearchPullCoordinator is
// @MainActor and wanted only the compiled generation's MANIFEST (a people
// count, a family count, the source file names) for the pull sheet and for
// the merge's fail-closed baseline. It got it through `loadCurrent()`, which
// hashes every source file, decodes the whole ~39k-person graph and — when
// the current artifact will not decode — REPOINTS to the previous
// generation. A beachball and a pointer write, on the UI thread, for a
// read whose own comment promised "cannot promote anything".
//
// `loadCurrentManifest()` is the manifest-only read. These tests pin it:
//
//   1. Logic     — returns the manifest the pointer names; nil for no
//                  pointer / wrong versions
//   2. Scale     — a 20,000-person store: the read is O(manifest), inside a
//                  time budget a full decode cannot meet
//   3. Media     — n/a
//   4. Isolation — the current artifact is POISONED: the read still answers
//                  and the pointer file is byte-identical afterwards (no
//                  decode, no rollback, no write); a source is deleted: no
//                  hashing, the manifest still answers
//   5. Sensor    — the coordinator source no longer calls
//                  `loadCurrent()?.manifest`

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Compiled family-tree manifest-only read")
struct FamilyGraphCurrentManifestReadTests {

    struct Sandbox {
        let root: URL
        let originals: URL
        let compiled: URL
        let log = FamilyGraphCompiledStoreTests.LogCapture()
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
                .appendingPathComponent("ManifestRead-\(UUID().uuidString)")
            originals = root.appendingPathComponent("originals")
            compiled = root.appendingPathComponent("compiled")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        }
        func store() -> FamilyGraphCompiledStore {
            var store = FamilyGraphCompiledStore(root: compiled)
            store.log = { [log] in log.append($0) }
            return store
        }
        func write(_ text: String, as name: String) throws -> URL {
            let url = originals.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func tearDown() { try? FileManager.default.removeItem(at: root) }

        /// Two generations: previous = [a], current = [a, b].
        func twoGenerations() throws -> (store: FamilyGraphCompiledStore, a: URL, b: URL) {
            let a = try write(GedcomSyntheticPedigree.gedcom(people: 120, generations: 5), as: "a.ged")
            let b = try write(GedcomSyntheticPedigree.gedcom(people: 80, generations: 4)
                .replacingOccurrences(of: "_FSFTID ", with: "_FSFTID D"), as: "b.ged")
            let s = store()
            let ga = try #require(GedcomFamilyGraph(fileURL: a))
            let gb = try #require(GedcomFamilyGraph(fileURL: b))
            #expect(s.ingest(graph: ga, sources: [a]) != nil)
            #expect(s.ingest(graph: ga.merged(with: gb), sources: [a, b]) != nil)
            return (s, a, b)
        }
    }

    private func poison(_ store: FamilyGraphCompiledStore, generation: String) throws {
        try Data("not a compiled tree".utf8).write(to: store.artifactURL(generation))
    }

    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        while let url = e?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                out[url.path] = try Data(contentsOf: url)
            }
        }
        return out
    }

    // MARK: - 4. Isolation: poisoned artifact — no decode, no rollback, no write

    @Test func poisonedCurrentStillAnswersAndThePointerIsNotTouched() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.twoGenerations()
        let pointer = try #require(store.readPointer())
        #expect(pointer.previous != nil, "fixture must have a rollback target, or the test proves nothing")
        try poison(store, generation: pointer.current)
        let pointerBytes = try Data(contentsOf: store.pointerURL)
        let before = try snapshot(box.compiled)

        let manifest = store.loadCurrentManifest()

        #expect(manifest?.generation == pointer.current,
                "the read reports what the pointer names — it does not roll back to previous")
        #expect(manifest?.sources.count == 2)
        #expect(try Data(contentsOf: store.pointerURL) == pointerBytes, "pointer file must be byte-identical")
        #expect(try snapshot(box.compiled) == before, "nothing in the store may be written")
        #expect(!box.log.contains("rolled back"))
        #expect(!box.log.contains("corrupt"), "a decode was attempted")
    }

    @Test func poisonedOnlyGenerationStillAnswers() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 60, generations: 4), as: "a.ged")
        let store = box.store()
        #expect(store.ingest(graph: try #require(GedcomFamilyGraph(fileURL: a)), sources: [a]) != nil)
        let pointer = try #require(store.readPointer())
        try poison(store, generation: pointer.current)

        #expect(store.loadCurrentManifest()?.generation == pointer.current)
    }

    /// No source hashing: a source that has vanished does not hide the
    /// manifest. The merge guard relies on this to FAIL CLOSED — a compiled
    /// tree with more sources than the loader could see must still be seen.
    @Test func missingSourceIsNotHashedAndDoesNotHideTheManifest() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, b) = try box.twoGenerations()
        let pointer = try #require(store.readPointer())
        try FileManager.default.removeItem(at: b)
        let linesBefore = box.log.all.count   // ingest itself logs "hashed …"

        let manifest = store.loadCurrentManifest()
        #expect(manifest?.generation == pointer.current)
        #expect(manifest?.sources.map(\.fileName) == ["a.ged", "b.ged"])
        #expect(box.log.all.count == linesBefore, "the read must log nothing — no hashing, no refusal: \(box.log.all.dropFirst(linesBefore))")
    }

    // MARK: - 1. Logic: the nil cases

    @Test func noPointerIsNil() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        #expect(box.store().loadCurrentManifest() == nil)
    }

    @Test func pointerFromAnotherSchemaIsNil() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.twoGenerations()
        var pointer = try #require(store.readPointer())
        pointer.schema &+= 1
        try JSONEncoder().encode(pointer).write(to: store.pointerURL)
        #expect(store.loadCurrentManifest() == nil)
    }

    @Test func manifestMatchesWhatAFullLoadReports() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let (store, _, _) = try box.twoGenerations()
        #expect(store.loadCurrentManifest() == store.loadCurrent()?.manifest)
    }

    // MARK: - 2. Scale: O(manifest), not O(people)

    @Test func manifestReadOnALargeStoreIsCheap() throws {
        let box = try Sandbox(); defer { box.tearDown() }
        let a = try box.write(GedcomSyntheticPedigree.gedcom(people: 20_000, generations: 16), as: "big.ged")
        let store = box.store()
        #expect(store.ingest(graph: try #require(GedcomFamilyGraph(fileURL: a)), sources: [a]) != nil)

        let clock = ContinuousClock()
        var worst = Duration.zero
        for _ in 0..<10 {
            let elapsed = clock.measure { #expect(store.loadCurrentManifest()?.peopleCount ?? 0 >= 20_000) }
            worst = max(worst, elapsed)
        }
        // A manifest is a few KB of JSON; the artifact for 20k people is
        // megabytes. 25 ms is generous for the first and far too little for
        // a hash + decode of the second.
        #expect(worst < .milliseconds(25), "worst manifest read \(worst)")
    }

    // MARK: - 5. Sensor: the main-actor coordinator reads manifests only

    @Test func pullCoordinatorNeverDecodesTheGraphForAManifest() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/FamilySearchPullCoordinator.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.contains("loadCurrent()?.manifest"))
        #expect(text.contains("loadCurrentManifest()"))
    }
}
