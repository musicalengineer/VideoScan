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

    /// END-TO-END: the ACTUAL reducer script against the REAL backup, full
    /// output, decoded by the app. The [:500]-sample sensor above passed
    /// while the app rejected the reducer's real output TWICE (clobbers 3
    /// and 4) — because the sample round-tripped the backup without the
    /// reducer's MUTATIONS, and truncated before the poison. This test
    /// runs the real transform on all 18,142 records and, on failure,
    /// surfaces the decoder's actual error via lastLoadOutcome + NSLog.
    @MainActor
    func testActualReducerOutputDecodes_endToEnd() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python))
        let backup = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask)[0]
            .appendingPathComponent("VideoScan/catalog.pre-triage-20260814.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: backup.path))
        // The reducer script lives in the repo; find it relative to this
        // test file's known location at compile time.
        let script = URL(fileURLWithPath: #filePath)          // …/VideoScan/VideoScanTests/…
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()                       // repo root
            .appendingPathComponent("scripts/catalog_reduce.py")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: script.path))

        try FileManager.default.copyItem(at: backup, to: catalogURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [script.path, "--catalog", catalogURL.path, "--apply"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        try proc.run()
        proc.waitUntilExit()
        let scriptOut = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0, "reducer failed:\n\(scriptOut.suffix(500))")
        XCTAssertTrue(scriptOut.contains("WRITTEN"), "reducer must have applied:\n\(scriptOut.suffix(500))")

        // The reducer deliberately keeps records on volumes mounted at run
        // time. Capture what it actually emitted instead of freezing the
        // mount topology from August 14 (8,760 records): mounting LACIE500,
        // for example, correctly adds its 702 records.
        let emittedCount: Int = try autoreleasepool {
            let rawOutput = try JSONSerialization.jsonObject(
                with: Data(contentsOf: catalogURL))
            let outputDocument = try XCTUnwrap(rawOutput as? [String: Any])
            let outputRecords = try XCTUnwrap(outputDocument["records"] as? [Any])
            return outputRecords.count
        }
        XCTAssertGreaterThan(emittedCount, 0,
                             "the reducer must not emit an empty catalog")

        let store = CatalogStore(directory: dir)
        let loaded = store.load()
        XCTAssertEqual(store.lastLoadOutcome, .loaded(fromBackup: false),
                       "the app REJECTED the reducer's real output — outcome \(store.lastLoadOutcome). "
                       + "The decoder's error is in this test run's NSLog output; read it.")
        XCTAssertEqual(loaded.count, emittedCount,
                       "the app must decode every record the reducer emitted")
    }
}
