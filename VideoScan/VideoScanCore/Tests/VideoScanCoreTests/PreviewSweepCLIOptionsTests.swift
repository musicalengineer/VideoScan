// PreviewSweepCLIOptionsTests.swift
// Logic dimension for the out-of-process preview helper (Stage 1):
// argument parsing, catalog-freshness re-read decision, and the
// single-instance lock. No process spawning — the testable logic lives in
// VideoScanCore precisely so it can be pinned here.

import XCTest
@testable import VideoScanCore

final class PreviewSweepCLIOptionsTests: XCTestCase {

    private let defaultCatalog = URL(fileURLWithPath: "/tmp/default/catalog.json")

    // MARK: - Arg parsing

    func testDefaultsAreWatchModeNoDryRun() throws {
        let opts = try XCTUnwrap(try? PreviewSweepCLIOptions.parse([], defaultCatalog: defaultCatalog).get())
        XCTAssertEqual(opts.mode, .watch)
        XCTAssertFalse(opts.dryRun)
        XCTAssertEqual(opts.catalogURL, defaultCatalog)
        XCTAssertEqual(opts.workerCount, 2)
        XCTAssertNil(opts.cacheDirOverride)
        XCTAssertEqual(opts.idleExitSeconds, 300, "Stage 2 default: self-exit after 5 min warm+idle")
    }

    func testIdleExitFlagParsesAndZeroDisables() throws {
        let opts = try PreviewSweepCLIOptions.parse(["--idle-exit", "60"],
                                                    defaultCatalog: defaultCatalog).get()
        XCTAssertEqual(opts.idleExitSeconds, 60)
        let never = try PreviewSweepCLIOptions.parse(["--idle-exit", "0"],
                                                     defaultCatalog: defaultCatalog).get()
        XCTAssertEqual(never.idleExitSeconds, 0)
    }

    func testIdleExitBadNumberFails() {
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["--idle-exit", "-5"], defaultCatalog: defaultCatalog),
                       .failure(.badNumber(forFlag: "--idle-exit", value: "-5")))
    }

    func testOnceAndDryRunFlags() throws {
        let opts = try PreviewSweepCLIOptions.parse(["--once", "--dry-run"],
                                                    defaultCatalog: defaultCatalog).get()
        XCTAssertEqual(opts.mode, .once)
        XCTAssertTrue(opts.dryRun)
    }

    func testCatalogAndCacheDirAndWorkersAndInterval() throws {
        let opts = try PreviewSweepCLIOptions.parse(
            ["--catalog", "/data/cat.json", "--cache-dir", "/data/cache",
             "--workers", "4", "--interval", "12.5"],
            defaultCatalog: defaultCatalog).get()
        XCTAssertEqual(opts.catalogURL.path, "/data/cat.json")
        XCTAssertEqual(opts.cacheDirOverride?.path, "/data/cache")
        XCTAssertEqual(opts.workerCount, 4)
        XCTAssertEqual(opts.intervalSeconds, 12.5)
    }

    func testUnknownFlagFails() {
        let result = PreviewSweepCLIOptions.parse(["--nope"], defaultCatalog: defaultCatalog)
        XCTAssertEqual(result, .failure(.unknownFlag("--nope")))
    }

    func testMissingValueFails() {
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["--catalog"], defaultCatalog: defaultCatalog),
                       .failure(.missingValue(forFlag: "--catalog")))
    }

    func testBadNumbersFail() {
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["--workers", "0"], defaultCatalog: defaultCatalog),
                       .failure(.badNumber(forFlag: "--workers", value: "0")))
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["--interval", "abc"], defaultCatalog: defaultCatalog),
                       .failure(.badNumber(forFlag: "--interval", value: "abc")))
    }

    func testHelpRequested() {
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["--help"], defaultCatalog: defaultCatalog),
                       .failure(.helpRequested))
        XCTAssertEqual(PreviewSweepCLIOptions.parse(["-h"], defaultCatalog: defaultCatalog),
                       .failure(.helpRequested))
    }

    // MARK: - Catalog freshness

    func testFreshnessFirstCheckIsChangedThenStableThenChangedOnRewrite() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = dir.appendingPathComponent("catalog.json")
        try Data("{}".utf8).write(to: catalog)

        var freshness = CatalogFreshness()
        XCTAssertTrue(freshness.hasChanged(catalogURL: catalog), "first check is always changed")
        XCTAssertFalse(freshness.hasChanged(catalogURL: catalog), "unchanged file is stable")

        // Rewrite with a bumped mtime (whole-second resolution — push it).
        let later = Date().addingTimeInterval(5)
        try Data("{\"records\":[]}".utf8).write(to: catalog)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: catalog.path)
        XCTAssertTrue(freshness.hasChanged(catalogURL: catalog), "rewrite is detected")
    }

    func testFreshnessMissingFileCountsAsChanged() {
        var freshness = CatalogFreshness()
        let missing = URL(fileURLWithPath: "/no/such/\(UUID().uuidString)/catalog.json")
        XCTAssertTrue(freshness.hasChanged(catalogURL: missing))
        // Still nil mtime — treated as changed so a later reappearance is caught.
        XCTAssertTrue(freshness.hasChanged(catalogURL: missing))
    }

    // MARK: - Single-instance lock

    func testSingleInstanceLockRefusesSecondThenReacquiresAfterRelease() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("instlock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockURL = dir.appendingPathComponent(".previewsweepd.lock")

        let first = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL),
                                  "first acquire should succeed")
        XCTAssertNil(SingleInstanceLock.acquire(at: lockURL),
                     "second acquire must refuse while the first holds the lock")
        first.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path),
                      "release leaves the stable lockfile inode in place")
        XCTAssertNil(PreviewHelperInstance.runningPID(pidfileURL: lockURL),
                     "an unlocked stale pidfile is not a running helper")
        let third = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL),
                                  "after release the lock is available again")
        XCTAssertEqual(PreviewHelperInstance.runningPID(pidfileURL: lockURL), getpid(),
                       "reacquire reuses the same path and stamps its live PID")
        third.release()
    }

    func testAcquireInvalidatesStaleIdentityBeforeProviderAndFailsEmpty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("instlock-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockURL = dir.appendingPathComponent(".previewsweepd.lock")
        let stale = PreviewHelperProcessIdentity(
            pid: getpid(), executablePath: "/old/helper",
            startSeconds: 1, startMicroseconds: 2)
        try XCTUnwrap(stale.encoded()).write(to: lockURL)

        var providerSawEmptyFile = false
        let failed = SingleInstanceLock.acquire(at: lockURL) { _ in
            providerSawEmptyFile = (try? Data(contentsOf: lockURL).isEmpty) ?? false
            return nil
        }
        XCTAssertNil(failed)
        XCTAssertTrue(providerSawEmptyFile,
                      "stale identity must be erased before identity capture")
        XCTAssertEqual(try Data(contentsOf: lockURL), Data(),
                       "capture failure leaves an empty fail-closed record")

        let replacement = PreviewHelperProcessIdentity(
            pid: getpid(), executablePath: "/new/helper",
            startSeconds: 3, startMicroseconds: 4)
        let reacquired = try XCTUnwrap(SingleInstanceLock.acquire(at: lockURL) { _ in replacement },
                                      "provider failure must leave the flock reacquirable")
        defer { reacquired.release() }
        XCTAssertEqual(PreviewHelperProcessIdentity.decode(try Data(contentsOf: lockURL)),
                       replacement)
    }
}
