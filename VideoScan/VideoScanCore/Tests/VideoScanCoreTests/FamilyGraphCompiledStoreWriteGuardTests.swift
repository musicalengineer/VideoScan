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

    /// codex #192 F1: the guard must be asked at PROMOTION, after the
    /// compile — not only at entry. Revoked while verifying: nothing is
    /// promoted, and nothing changes under the root from that moment on.
    func testARevocationDuringVerificationPromotesNothing() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let ged = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "a.ged")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: ged))
        let flag = Flag()
        var store = box.store()
        store.writeGuard = { flag.allows }
        XCTAssertNotNil(store.ingest(graph: graph, sources: [ged]), "a first generation while allowed")
        let promoted = store.readPointer()
        let second = try box.write(GedcomSyntheticPedigree.gedcom(people: 40, generations: 3), as: "b.ged")
        let graph2 = try XCTUnwrap(GedcomFamilyGraph(fileURL: second))
        let verify = store.verify
        final class Snap: @unchecked Sendable { var at: [String] = [] }
        let snap = Snap()
        let root = box.compiled
        store.verify = { decoded, source in
            flag.revoke()
            snap.at = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
            return verify(decoded, source)
        }
        XCTAssertNil(store.ingest(graph: graph2, sources: [second]), "promoted after revocation")
        XCTAssertEqual(store.readPointer(), promoted, "the pointer moved")
        XCTAssertEqual(listing(box.compiled), snap.at, "the root changed after the revocation")
    }

    /// codex #193 F2a: revoked as the compile starts — the artifact must
    /// not be written afterwards.
    func testARevocationBeforeArtifactWriteChangesNothing() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let ged = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "a.ged")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: ged))
        let flag = Flag()
        var store = box.store()
        store.writeGuard = { flag.allows }
        final class Snap: @unchecked Sendable { var at: [String]? }
        let snap = Snap()
        let root = box.compiled
        XCTAssertNil(store.ingest(graph: graph, sources: [ged], progress: { phase in
            if phase.hasPrefix("Compiling family tree"), snap.at == nil {
                flag.revoke()
                snap.at = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
            }
        }))
        XCTAssertNotNil(snap.at, "the compile never reported — the test did not revoke")
        XCTAssertEqual(listing(box.compiled), snap.at, "the root changed after the revocation")
    }

    /// codex #193 F2b: a source change AND a revocation during verify — the
    /// changed-source cleanup must not remove the staged generation either.
    func testSourceChangeAndRevocationDuringVerificationRemoveNothing() throws {
        let box = try StoreBox(); defer { box.tearDown() }
        let ged = try box.write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), as: "a.ged")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: ged))
        let flag = Flag()
        var store = box.store()
        store.writeGuard = { flag.allows }
        let verify = store.verify
        final class Snap: @unchecked Sendable { var at: [String]? }
        let snap = Snap()
        let root = box.compiled
        store.verify = { decoded, source in
            try? "0 HEAD\n0 TRLR\n".write(to: ged, atomically: true, encoding: .utf8)
            flag.revoke()
            snap.at = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
            return verify(decoded, source)
        }
        XCTAssertNil(store.ingest(graph: graph, sources: [ged]))
        XCTAssertEqual(listing(box.compiled), snap.at, "the cleanup removed bytes after the revocation")
    }
}
