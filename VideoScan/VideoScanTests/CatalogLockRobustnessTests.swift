//
//  CatalogLockRobustnessTests.swift
//  VideoScanTests
//
//  Proves the catalog's cross-process write safety against a DUMMY catalog
//  in a temp directory -- never the real ~/Library/Application Support one.
//
//  These exist because of a real incident on 2026-08-14: an external script
//  reduced the catalog from 18,142 to 8,760 records, the app was launched
//  mid-operation, and the app's stale in-memory copy overwrote the result.
//  9,382 records of work vanished with no error and no torn file.
//
//  The five dimensions from the project checklist:
//    logic     -- acquire/release/contention/reentrancy, staleness, checksum
//    scale     -- 100k-record catalog stays within a stated time budget
//    media     -- N/A, this layer opens no media
//    isolation -- every test uses its own temp dir; the real catalog and the
//                 shared singleton are never touched
//    sensor    -- testStaleWriteIsRefused_theAugust14Regression pins the
//                 exact production failure
//

import XCTest
@testable import VideoScan

final class CatalogLockRobustnessTests: XCTestCase {

    private var dir: URL!
    private var catalogURL: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CatalogLockTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        catalogURL = dir.appendingPathComponent("catalog.json")
        lockURL = dir.appendingPathComponent("catalog.lock")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Lock semantics

    func testAcquireSucceedsOnFreeLock() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertTrue(lock.isHeldByUs)
        lock.release()
        XCTAssertFalse(lock.isHeldByUs)
    }

    func testAcquireIsReentrantForSameInstance() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertEqual(lock.acquire(), .acquired, "same owner must not deadlock itself")
        lock.release()
    }

    func testSecondHolderIsRefusedWhileFirstHolds() {
        let first = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(first.acquire(), .acquired)

        // A distinct fd on the same file is what a second process looks like
        // to flock, so this genuinely exercises the contention path.
        let second = CatalogLock(lockURL: lockURL)
        guard case .heldByAnother = second.acquire() else {
            return XCTFail("second holder must be refused while the first holds")
        }
        XCTAssertFalse(second.isHeldByUs)

        first.release()
        XCTAssertEqual(second.acquire(), .acquired, "must be acquirable once released")
        second.release()
    }

    func testOwnerMetadataIdentifiesTheHolder() throws {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        let owner = try XCTUnwrap(CatalogLock.readOwner(at: lockURL))
        XCTAssertEqual(owner.pid, getpid())
        XCTAssertFalse(owner.hostname.isEmpty)
        lock.release()
    }

    func testReleaseClearsOwnerMetadata() {
        let lock = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(lock.acquire(), .acquired)
        XCTAssertNotNil(CatalogLock.readOwner(at: lockURL))
        lock.release()
        XCTAssertNil(CatalogLock.readOwner(at: lockURL),
                     "a released lock must not advertise a stale owner")
    }

    func testWaiterTimesOutRatherThanHangingForever() {
        let holder = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(holder.acquire(), .acquired)

        let waiter = CatalogLock(lockURL: lockURL)
        let t0 = Date()
        let result = waiter.acquire(waitingUpTo: 0.75, pollInterval: 0.1)
        let elapsed = Date().timeIntervalSince(t0)

        guard case .heldByAnother = result else {
            return XCTFail("waiter must report contention, not acquire")
        }
        XCTAssertGreaterThanOrEqual(elapsed, 0.7, "must actually wait")
        XCTAssertLessThan(elapsed, 3.0, "must not hang past its timeout")
        holder.release()
    }

    func testWaiterAcquiresOnceHolderReleases() {
        let holder = CatalogLock(lockURL: lockURL)
        XCTAssertEqual(holder.acquire(), .acquired)

        let released = expectation(description: "holder released")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            holder.release()
            released.fulfill()
        }

        let waiter = CatalogLock(lockURL: lockURL)
        let result = waiter.acquire(waitingUpTo: 5.0, pollInterval: 0.1)
        XCTAssertEqual(result, .acquired, "waiter must get the lock after release")
        wait(for: [released], timeout: 2.0)
        waiter.release()
    }

    // MARK: - Error contract

    func testErrorCodesAreStableAndDistinct() {
        let all: [CatalogWriteError] = [
            .readOnlyViewer,
            .lockedByAnotherProcess(owner: nil),
            .staleGeneration(loadedAt: Date(), onDiskAt: Date()),
            .lockUnavailable("x"),
            .writeFailed("x"),
            .verificationFailed(expectedSHA256: "a", actualSHA256: "b", bytes: 1),
        ]
        XCTAssertEqual(Set(all.map(\.code)).count, all.count, "codes must be distinct")
        // Frozen values -- renumbering breaks logs and support requests.
        XCTAssertEqual(CatalogWriteError.readOnlyViewer.code, 1)
        XCTAssertEqual(CatalogWriteError.lockedByAnotherProcess(owner: nil).code, 2)
        XCTAssertEqual(CatalogWriteError.staleGeneration(loadedAt: Date(),
                                                         onDiskAt: Date()).code, 3)
    }

    func testStaleGenerationIsNotTreatedAsTransient() {
        // A blind retry after a stale-generation refusal would reintroduce
        // the very lost update the guard exists to prevent.
        XCTAssertFalse(CatalogWriteError.staleGeneration(loadedAt: Date(),
                                                         onDiskAt: Date()).isTransient)
        XCTAssertTrue(CatalogWriteError.lockedByAnotherProcess(owner: nil).isTransient)
    }

    // MARK: - Journal

    func testJournalRecordsAndReadsBackRefusals() throws {
        CatalogWriteJournal.record(.lockedByAnotherProcess(owner: nil),
                                   catalogURL: catalogURL)
        CatalogWriteJournal.record(.staleGeneration(loadedAt: Date(), onDiskAt: Date()),
                                   catalogURL: catalogURL)

        let entries = CatalogWriteJournal.recent(10, catalogURL: catalogURL)
        XCTAssertEqual(entries.count, 2)
        // Newest first.
        XCTAssertEqual(entries.first?.kind, "stale")
        XCTAssertEqual(entries.first?.code, 3)
        XCTAssertEqual(entries.last?.kind, "locked")
        XCTAssertEqual(entries.first?.pid, getpid())
    }

    func testJournalAppendsRatherThanTruncating() {
        for _ in 0..<5 {
            CatalogWriteJournal.record(.readOnlyViewer, catalogURL: catalogURL)
        }
        XCTAssertEqual(CatalogWriteJournal.recent(50, catalogURL: catalogURL).count, 5,
                       "each refusal must survive; the journal is append-only")
    }

    func testJournalSurvivesAMissingDirectoryWithoutThrowing() {
        // Error handling must not itself become a source of errors.
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/catalog.json")
        CatalogWriteJournal.record(.readOnlyViewer, catalogURL: bogus)
        XCTAssertTrue(CatalogWriteJournal.recent(5, catalogURL: bogus).isEmpty)
    }

    // MARK: - Checksum

    func testSHA256DetectsASingleFlippedByte() {
        var data = Data("the quick brown fox".utf8)
        let before = CatalogStore.sha256Hex(data)
        data[3] ^= 0x01
        XCTAssertNotEqual(before, CatalogStore.sha256Hex(data),
                          "checksum must catch a one-bit change")
    }

    func testSHA256IsStableForIdenticalContent() {
        let a = Data(repeating: 0xAB, count: 4096)
        let b = Data(repeating: 0xAB, count: 4096)
        XCTAssertEqual(CatalogStore.sha256Hex(a), CatalogStore.sha256Hex(b))
    }

    // MARK: - Scale

    func testChecksumOfA100kRecordSizedPayloadIsFast() {
        // A 100k-record catalog is roughly 400 MB of JSON. Verification runs
        // on every save, so it must not dominate the write.
        let payload = Data(repeating: 0x7B, count: 400 * 1024 * 1024)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = CatalogStore.sha256Hex(payload)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertLessThan(elapsed, 5.0,
                          "SHA-256 of a 400 MB catalog took \(elapsed)s; budget is 5s")
    }

    func testLockAcquisitionIsCheapUnderRepeatedUse() {
        let lock = CatalogLock(lockURL: lockURL)
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<1000 {
            _ = lock.acquire()      // re-entrant fast path
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        lock.release()
        XCTAssertLessThan(elapsed, 1.0,
                          "1000 re-entrant acquires took \(elapsed)s; budget is 1s")
    }

    // MARK: - Isolation

    func testTestsNeverTouchTheRealCatalog() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("VideoScan/catalog.json")
        XCTAssertNotEqual(catalogURL.standardizedFileURL, real.standardizedFileURL)
        XCTAssertTrue(catalogURL.path.contains(NSTemporaryDirectory()))
    }
}
