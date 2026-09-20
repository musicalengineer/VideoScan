// FamilyDocumentModelTests.swift
// The Family Tree model's side of person documents (Rick, 2026-09-20):
// read ONCE per selection off the main actor, memoised per person, dropped
// on add/remove — and, after codex review 1593 (#9, #10):
//
//   • the previous person's rows are cleared the moment the selection
//     moves, and a Remove is bound to the row's OWNER, re-validated at
//     confirmation (a suspended read for B must not leave A's certificate
//     removable under B's name);
//   • a read started before an import/removal can never republish its
//     stale rows over the refresh, whatever order the reads finish in.
//
// Isolation: the compiled-store Sandbox for the tree, a temp store for the
// documents; the model is given that store explicitly (an injected model
// never sees the real People/ folder). The reads are held open through
// `documentListing`, the model's injectable listing, so the finishing
// order is the test's choice and not the scheduler's.

import Foundation
import PDFKit
import Testing
@testable import VideoScan

@Suite("Family documents — tree model", .serialized)
struct FamilyDocumentModelTests {
    private typealias Sandbox = FamilyGraphCompiledStoreTests.Sandbox
    private static let settings = FamilyTreeLaunchBundle.Settings(speakers: .none, ownerFamilySearchID: nil)
    private static let twoPeople =
        "0 HEAD\n0 @I1@ INDI\n1 NAME Eileen /Latta/\n0 @I2@ INDI\n1 NAME Barry /Latta/\n0 TRLR\n"

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func hit() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    /// Holds each listing open until the test releases it BY CALL NUMBER.
    /// ≈ a per-call condition variable: the reading thread parks in
    /// `hold()`; the test decides which call wakes first.
    private final class ListingGate: @unchecked Sendable {
        private let lock = NSLock()
        private var semaphores: [Int: DispatchSemaphore] = [:]
        private var next = 0
        /// On the reading thread: register, then block until released.
        @discardableResult
        func hold() -> Int {
            let semaphore = DispatchSemaphore(value: 0)
            let n: Int = lock.withLock {
                next += 1
                semaphores[next] = semaphore
                return next
            }
            semaphore.wait()
            return n
        }
        func release(_ n: Int) { lock.withLock { semaphores[n] }?.signal() }
        /// Never leave a pool thread parked after a failed expectation.
        func releaseAll() { lock.withLock { Array(semaphores.values) }.forEach { $0.signal() } }
        var calls: Int { lock.withLock { next } }
    }

    /// Captures `PersonDocumentLog` lines; the refusal lines are written
    /// on the main actor but the sink is locked anyway.
    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func attach() { PersonDocumentLog.shared.setExtraSink { [weak self] in self?.append($0) } }
        func detach() { PersonDocumentLog.shared.setExtraSink(nil) }
        private func append(_ line: String) { lock.withLock { lines.append(line) } }
        func first(containing needle: String) -> String? {
            lock.withLock { lines.first { $0.contains(needle) } }
        }
    }

    @MainActor
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func pdfData() throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        return try #require(document.dataRepresentation())
    }

    /// A sandbox store with one birth certificate filed for Eileen (@I1@).
    private struct Fixture {
        let store: FamilyAssetStore
        let eileen: FamilyAssetPerson
        let folder: URL
        let source: URL
    }

    private func fixture(in box: Sandbox) throws -> Fixture {
        let store = FamilyAssetStore(
            root: box.root.appendingPathComponent("assets/40_Family_Tree", isDirectory: true),
            cacheRoot: box.root.appendingPathComponent("cache", isDirectory: true))
        let eileen = FamilyAssetPerson(gedcomID: "@I1@", name: "Eileen Latta")
        let folder = try store.folderForPhotoRequest(person: eileen)
        let source = box.root.appendingPathComponent("bc.pdf")
        try pdfData().write(to: source)
        _ = try store.importPersonDocument(from: source, kind: .birth, note: "", into: folder)
        return Fixture(store: store, eileen: eileen, folder: folder, source: source)
    }

    // MARK: Cache contract

    @Test @MainActor func documentsAreReadOncePerSelectionAndInvalidatedOnChange() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.twoPeople)
        let fx = try fixture(in: box)

        let reads = Counter()
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals,
                                        documentStoreProvider: { reads.hit(); return fx.store })
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        #expect(model.isLive)

        model.select("@I1@")
        await waitUntil("Eileen's document") { model.selectedDocuments.count == 1 }
        await waitUntil("Eileen's chip count") { model.documentCount(for: "@I1@") == 1 }
        #expect(model.selectedDocuments.first?.document.kind == .birth)
        #expect(model.selectedDocuments.first?.ownerID == "@I1@")
        #expect(model.selectedDocuments.first?.personFolder == fx.folder.standardizedFileURL)
        #expect(!model.isLoadingSelectedDocuments)
        let afterFirst = reads.count
        #expect(afterFirst >= 1)

        // Away and back: the memo answers, the store is not asked again.
        model.select("@I2@")
        await waitUntil("Barry's (empty) list") { !model.isLoadingSelectedDocuments }
        #expect(model.selectedDocuments.isEmpty)
        let afterBarry = reads.count
        model.select("@I1@")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedDocuments.count == 1)
        #expect(reads.count == afterBarry, "re-selecting Eileen must be a cache hit")

        // A change for Eileen drops her memo and re-reads.
        _ = try fx.store.importPersonDocument(from: fx.source, kind: .death, note: "", into: fx.folder)
        #expect(model.selectedDocuments.count == 1)
        let revision = model.documentsRevision
        model.noteDocumentsChanged(for: "@I1@")
        #expect(model.documentsRevision == revision &+ 1)
        await waitUntil("Eileen's second document") { model.selectedDocuments.count == 2 }
        #expect(model.documentCount(for: "@I1@") == 2)
        #expect(reads.count > afterBarry)
    }

    @Test @MainActor func anInjectedModelWithoutAStoreReadsNothing() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write("0 HEAD\n0 @I1@ INDI\n1 NAME Eileen /Latta/\n0 TRLR\n")
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals)
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        model.select("@I1@")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.selectedDocuments.isEmpty)
        #expect(!model.isLoadingSelectedDocuments)
        #expect(model.documentCount(for: "@I1@") == 0)
        #expect(model.documentStoreProvider() == nil)
    }

    // MARK: codex 1593 #9 — the previous person's rows under the next person

    /// Eileen's certificate is on screen; Rick clicks Barry, whose read is
    /// slow. Eileen's rows must vanish at once, and a Remove confirmed on
    /// her row while Barry is shown must be refused, with her file intact
    /// and a log line naming both people.
    @Test @MainActor func aRowReadForOnePersonCannotBeRemovedUnderTheNext() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.twoPeople)
        let fx = try fixture(in: box)
        let gate = ListingGate(); defer { gate.releaseAll() }
        let log = LogLines(); log.attach(); defer { log.detach() }

        let model = FamilyTreeLiveModel(originalsDirectory: box.originals,
                                        documentStoreProvider: { fx.store })
        // Barry's selection read parks; everything else runs as normal.
        model.documentListing = { store, person, purpose in
            let documents = store.documents(for: person)
            if purpose == .selection, person.gedcomID == "@I2@" { gate.hold() }
            return documents
        }
        await model.prepareForAppearance(revision: "a", settings: Self.settings)

        model.select("@I1@")
        await waitUntil("Eileen's document") { model.selectedDocuments.count == 1 }
        let row = try #require(model.selectedDocuments.first)
        let file = try #require(row.document.fileURL)
        #expect(FileManager.default.fileExists(atPath: file.path))

        model.select("@I2@")
        // Cleared synchronously, before Barry's read has even started.
        #expect(model.selectedDocuments.isEmpty, "A's rows must not survive the switch to B")
        #expect(model.isLoadingSelectedDocuments)
        await waitUntil("Barry's read parked") { gate.calls == 1 }
        #expect(model.selectedDocuments.isEmpty)

        // Rick confirms Remove on the row he was looking at a moment ago.
        #expect(model.validateDocumentRemoval(row) == .ownerNotSelected(ownerID: "@I1@", selectedID: "@I2@"))
        let message = await model.removeDocument(row)
        #expect(message?.contains("Eileen Latta") == true, "message: \(message ?? "nil")")
        #expect(FileManager.default.fileExists(atPath: file.path), "Eileen's certificate must be untouched")
        #expect(fx.store.documents(for: fx.eileen).count == 1)
        let refusal = log.first(containing: "refused to remove")
        #expect(refusal?.contains("@I1@") == true && refusal?.contains("@I2@") == true,
                "the log must name the mismatch: \(refusal ?? "no line")")
        #expect(log.first(containing: "removed Birth") == nil)

        // Barry's read lands: still nothing for Barry, loading over.
        gate.release(1)
        await waitUntil("Barry's list") { !model.isLoadingSelectedDocuments }
        #expect(model.selectedDocuments.isEmpty)

        // Back on Eileen the same row is served from the memo and CAN go —
        // through the row's own owner and folder.
        model.select("@I1@")
        #expect(model.selectedDocuments == [row])
        #expect(model.validateDocumentRemoval(row) == nil)
        let removed = await model.removeDocument(row)
        #expect(removed == nil, "removal under the owner must succeed: \(removed ?? "")")
        await waitUntil("Eileen's list empties") { model.selectedDocuments.isEmpty && !model.isLoadingSelectedDocuments }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(log.first(containing: "removed Birth")?.contains("moved to Documents/.trash/") == true)
        #expect(model.documentCount(for: "@I1@") == 0)
    }

    /// The row is current and the owner is selected, but the file was
    /// moved away behind the app's back: refuse, log, and let the listing
    /// drop the row — nothing in the sidecar is rewritten by a refusal.
    @Test @MainActor func aRowWhoseFileIsGoneIsRefusedAndDroppedFromTheList() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.twoPeople)
        let fx = try fixture(in: box)
        let log = LogLines(); log.attach(); defer { log.detach() }
        PersonDocumentLog.shared.resetMissing()

        let model = FamilyTreeLiveModel(originalsDirectory: box.originals,
                                        documentStoreProvider: { fx.store })
        await model.prepareForAppearance(revision: "a", settings: Self.settings)
        model.select("@I1@")
        await waitUntil("Eileen's document") { model.selectedDocuments.count == 1 }
        let row = try #require(model.selectedDocuments.first)
        let file = try #require(row.document.fileURL)
        try FileManager.default.moveItem(at: file, to: box.root.appendingPathComponent("elsewhere.pdf"))

        #expect(model.validateDocumentRemoval(row) == nil, "still listed and still the owner")
        let message = await model.removeDocument(row)
        #expect(message?.contains("no longer on disk") == true, "message: \(message ?? "nil")")
        #expect(log.first(containing: "missing on disk")?.contains(row.document.filename) == true)
        await waitUntil("the listing drops the row") { model.selectedDocuments.isEmpty && !model.isLoadingSelectedDocuments }
        #expect(model.validateDocumentRemoval(row) == .notListed)
        // The sidecar was not rewritten: the entry is still there for the
        // day the file comes back.
        let sidecar = FamilyAssetStore.documentsFolder(in: fx.folder)
            .appendingPathComponent(FamilyAssetStore.documentsSidecarName)
        let raw = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(raw.contains(row.document.filename))
        #expect(!FileManager.default.fileExists(atPath: FamilyAssetStore.documentsFolder(in: fx.folder)
            .appendingPathComponent(FamilyAssetStore.documentsTrashFolderName).path))
    }

    // MARK: codex 1593 #10 — an older read cannot overwrite an invalidation

    /// Read #1 (one document) is held; a second document is imported and
    /// the model told; read #2 (two documents) is held too. #2 is released
    /// first, then #1: the rows must stay at two — the pre-import read is
    /// stale and must be dropped, not republished.
    @Test @MainActor func aReadFromBeforeAnImportCannotOverwriteTheRefresh() async throws {
        let box = try Sandbox(); defer { box.tearDown() }
        _ = try box.write(Self.twoPeople)
        let fx = try fixture(in: box)
        let gate = ListingGate(); defer { gate.releaseAll() }

        let model = FamilyTreeLiveModel(originalsDirectory: box.originals,
                                        documentStoreProvider: { fx.store })
        // Snapshot the listing BEFORE parking, so read #1 really carries
        // the pre-import rows when it is finally let through.
        model.documentListing = { store, person, purpose in
            let documents = store.documents(for: person)
            if purpose == .selection { gate.hold() }
            return documents
        }
        await model.prepareForAppearance(revision: "a", settings: Self.settings)

        model.select("@I1@")
        await waitUntil("read #1 parked") { gate.calls == 1 }
        #expect(model.selectedDocuments.isEmpty)
        #expect(model.isLoadingSelectedDocuments)

        _ = try fx.store.importPersonDocument(from: fx.source, kind: .death, note: "", into: fx.folder)
        model.noteDocumentsChanged(for: "@I1@")
        await waitUntil("read #2 parked") { gate.calls == 2 }

        gate.release(2)
        await waitUntil("the refresh lands") { model.selectedDocuments.count == 2 }
        #expect(!model.isLoadingSelectedDocuments)

        gate.release(1)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.selectedDocuments.count == 2, "the pre-import read republished stale rows")
        #expect(model.documentCount(for: "@I1@") == 2)
        #expect(Set(model.selectedDocuments.map(\.document.kind)) == [.birth, .death])

        // And the same the other way round for a removal: hold the refresh,
        // let a pre-removal read through last.
        let victim = try #require(model.selectedDocuments.first { $0.document.kind == .death })
        model.select("@I2@")
        await waitUntil("Barry parked") { gate.calls == 3 }
        gate.release(3)
        await waitUntil("Barry landed") { !model.isLoadingSelectedDocuments }
        model.noteDocumentsChanged(for: "@I1@")          // memo dropped: next select reads afresh
        model.select("@I1@")
        await waitUntil("read #4 parked") { gate.calls == 4 }
        try fx.store.removeDocument(victim.document, from: fx.folder, for: fx.eileen)
        model.noteDocumentsChanged(for: "@I1@")
        await waitUntil("read #5 parked") { gate.calls == 5 }
        gate.release(5)
        await waitUntil("post-removal rows") { model.selectedDocuments.count == 1 }
        gate.release(4)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.selectedDocuments.count == 1, "the pre-removal read republished the removed row")
        #expect(model.documentCount(for: "@I1@") == 1)
    }
}
