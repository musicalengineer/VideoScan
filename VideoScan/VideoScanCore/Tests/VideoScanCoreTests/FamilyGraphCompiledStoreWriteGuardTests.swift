// FamilyGraphCompiledStoreWriteGuardTests.swift
// codex #190 F2 (the app's Family Tree read-only state): `writeGuard` is
// asked at the MOMENT of every store write. A compile that was allowed when
// it started must not promote after the guard turned false — and a false
// guard writes nothing at all under the root (not even the lock file).

import XCTest
@testable import VideoScanCore

final class FamilyGraphCompiledStoreWriteGuardTests: XCTestCase {

    typealias StoreBox = GedcomCompiledTreeTests.StoreBox

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var allows: Bool { lock.withLock { value } }
        func revoke() { lock.withLock { value = false } }
    }

    private func listing(_ root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }

    func testAFalseGuardRefusesIngestAndWritesNothing() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let ged = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "a.ged")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: ged))
        let flag = Flag()
        var store = box.store()
        store.writeGuard = { flag.allows }
        flag.revoke()
        XCTAssertNil(store.ingest(graph: graph, sources: [ged]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: box.compiled.path), "the root was created")
        XCTAssertTrue(box.lines.all.contains { $0.hasPrefix(FamilyGraphCompiledStore.refusedWritePrefix) })
    }

    func testTheGuardIsReadAtTheWriteNotWhenTheStoreWasMade() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let ged = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "a.ged")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: ged))
        let flag = Flag()
        var store = box.store()
        store.writeGuard = { flag.allows }
        XCTAssertNotNil(store.ingest(graph: graph, sources: [ged]), "allowed while the guard says yes")
        let before = listing(box.compiled)
        flag.revoke()
        XCTAssertNil(store.ingest(graph: graph, sources: [ged]))
        XCTAssertFalse(store.rollback())
        XCTAssertEqual(listing(box.compiled), before, "a refused store changed its root")
    }
}
