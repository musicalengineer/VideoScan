//
//  CatalogLockRealBackupTests.swift
//  VideoScanTests
//
//  The python round-trip sensors (CatalogLockRobustnessTests' "fourth-clobber
//  gate") run against the REAL pre-reduction backup in Application Support
//  when it exists on this machine, and SKIP everywhere else. Split out of
//  CatalogLockRobustnessTests on 2026-10-18 so that suite holds no machine-
//  data dependency (the gauntlet treats any skip as a failure, and its
//  isolated HOME never has the backup). Unchanged bodies; read-only on the
//  backup: it is COPIED into a per-test temp dir first.
//

import XCTest
@testable import VideoScan

final class CatalogLockRealBackupTests: XCTestCase {

    private var dir: URL!
    private var catalogURL: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CatalogLockRealBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        catalogURL = dir.appendingPathComponent("catalog.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Same sensor against the REAL pre-reduction backup when it exists on
    /// this machine (skips elsewhere). Read-only on the backup: it is
    /// COPIED to the test's temp dir first, so the isolation contract
    /// holds. This is the test that answers "would re-running the
    /// reduction clobber a fourth time?" with production data.
    @MainActor
    func testPythonRoundTripOfRealBackupDecodes() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let backup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("VideoScan/catalog.pre-triage-20260814.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: backup.path),
                          "real backup only exists on Rick's M4")

        try FileManager.default.copyItem(at: backup, to: catalogURL)

        let script = """
        import json, sys
        p = sys.argv[1]
        d = json.load(open(p))
        d["records"] = d["records"][:500]   # decode failure is per-record; 500 is plenty
        json.dump(d, open(p, "w"))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", script, catalogURL.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        XCTAssertEqual(loaded.count, 500,
                       "python-round-tripped REAL records must decode")
        XCTAssertEqual(store.lastLoadOutcome, .loaded(fromBackup: false))
    }

    // testActualReducerOutputDecodes_endToEnd was removed 2026-10-19 together
    // with scripts/catalog_reduce.py (cutover audit gap 3: no script writes the
    // catalog behind the app's back; catalog.json is frozen). The version
    // history keeps both.
}
