// BackgroundServiceSensorTests.swift — VideoScan Background can never write
// the catalog (docs/design/background_service_2026_10_30.md §3.6, §6 sensors;
// hard rule 6: one committer).
//
// SENSOR 1 — no committer in the helper:
//   (a) the helper BUILT into the app bundle (Contents/Library/LoginItems/)
//       carries no `CatalogCommitter` / `VideoScanModel` symbol (nm), with the
//       app's own binary as the positive control so an empty scan cannot pass;
//   (b) the helper's source folder and Core's Background/ folder import no
//       committer, no GRDB, no write-side SQLite flag, no AppKit in Core.
// SENSOR 2 — the catalog door is read-only: `BackgroundCatalogAccess` opens
//   with SQLITE_OPEN_READONLY only (source) and a live handle refuses a write.
// SENSOR 3 — MFO lifecycle: START/OUTCOME with counts for a finished and a
//   stopped job, never a START without its OUTCOME.
// Plus the embedded shape: LSUIElement, bundle id = app id + ".Background",
// the LaunchAgents plist names the embedded binary.
//
// Dimensions: SENSOR (source + built product), LOGIC (3). Runs in the
// sensor lane (reads source; shares no real state — temp dirs only).

import Foundation
import SQLite3
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("VideoScan Background — SENSOR: the helper can never write the catalog")
struct BackgroundServiceSensorTests {

    // MARK: - Paths

    /// VideoScan/VideoScanBackground — the helper target's synchronized folder.
    static let helperSourceRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // VideoScanTests/
        .deletingLastPathComponent()        // VideoScan/ (project dir)
        .appendingPathComponent("VideoScanBackground", isDirectory: true)

    /// VideoScan/VideoScanCore/Sources/VideoScanCore/Background
    static let coreBackgroundRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("VideoScanCore/Sources/VideoScanCore/Background", isDirectory: true)

    static let embeddedHelperRelativePath = "Contents/Library/LoginItems/VideoScan Background.app"

    static func swiftFiles(in root: URL) throws -> [(name: String, code: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".swift") }.sorted()
        try #require(!names.isEmpty, "no Swift sources under \(root.path) — the sensor would read nothing")
        return try names.map { name in
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            return (name, try SourceTree.code(of: text, named: name))
        }
    }

    /// The Mach-O files that hold a product's code: the executable and, in a
    /// Debug build, the `<name>.debug.dylib` beside it (Xcode 16+ links the
    /// debug code into that dylib and leaves a stub executable; Release has
    /// everything in the executable).
    static func codeBinaries(for executable: URL) -> [URL] {
        let dylib = executable.deletingLastPathComponent()
            .appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        return [executable] + (FileManager.default.fileExists(atPath: dylib.path) ? [dylib] : [])
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read before wait: a full pipe would otherwise deadlock nm.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - SENSOR 1a: the built helper

    @Test("SENSOR 1a: the helper embedded in the app bundle carries no CatalogCommitter or VideoScanModel symbol (the app binary does — positive control)")
    func noCommitterSymbolInTheBuiltHelper() throws {
        let appBundle = Bundle.main.bundleURL
        let helperApp = appBundle.appendingPathComponent(Self.embeddedHelperRelativePath)
        let helperBinary = helperApp.appendingPathComponent("Contents/MacOS/VideoScan Background")
        try #require(FileManager.default.fileExists(atPath: helperBinary.path),
                     "the helper is not embedded at \(helperBinary.path) — the Copy Files phase or the target dependency is missing")
        // Mangled Swift names carry the type's identifier verbatim ("…16CatalogCommitterC…"),
        // so a symbol-name scan is a class-presence scan.
        var helperSymbols = ""
        for binary in Self.codeBinaries(for: helperBinary) {
            helperSymbols += try Self.run("/usr/bin/nm", ["-j", "-U", binary.path])
        }
        try #require(helperSymbols.count > 10_000, "nm read almost nothing from the helper")
        #expect(!helperSymbols.contains("CatalogCommitter"), "the helper links the committer")
        #expect(!helperSymbols.contains("VideoScanModel"), "the helper links the app's model")
        #expect(helperSymbols.contains("JobSupervisor"), "the helper should carry the supervisor (sanity: it is the right binary)")

        // Positive control: the same scan on the app's own code DOES find the committer.
        let appBinary = try #require(Bundle.main.executableURL)
        var appHits = 0
        var helperHits = 0
        for binary in Self.codeBinaries(for: appBinary) {
            appHits += Int(try Self.run("/usr/bin/grep", ["-c", "CatalogCommitter", binary.path]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        for binary in Self.codeBinaries(for: helperBinary) {
            helperHits += Int(try Self.run("/usr/bin/grep", ["-c", "CatalogCommitter", binary.path]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        #expect(appHits > 0, "the control scan on the app's code found no CatalogCommitter — the scan is broken, not the helper clean")
        #expect(helperHits == 0, "the helper's bytes mention CatalogCommitter")
    }

    @Test("the embedded shape: LSUIElement, bundle id = app id + .Background, and the LaunchAgents plist names the embedded binary")
    func embeddedShape() throws {
        let appBundle = Bundle.main.bundleURL
        let helperApp = appBundle.appendingPathComponent(Self.embeddedHelperRelativePath)
        let helper = try #require(Bundle(url: helperApp), "no bundle at \(helperApp.path)")
        let appID = try #require(Bundle.main.bundleIdentifier)
        #expect(helper.bundleIdentifier == BackgroundServiceNames.helperBundleIdentifier(appBundleIdentifier: appID))
        #expect(helper.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true, "the helper must not appear in the Dock")

        let plistName = BackgroundServiceNames.launchdPlistName(appBundleIdentifier: appID)
        let plistURL = appBundle.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)")
        let data = try #require(FileManager.default.contents(atPath: plistURL.path), "no launchd plist at \(plistURL.path)")
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let mach = BackgroundServiceNames.machServiceName(appBundleIdentifier: appID)
        #expect(plist["Label"] as? String == mach)
        #expect((plist["MachServices"] as? [String: Any])?[mach] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool == false, "exit-when-idle needs SuccessfulExit false")
        #expect(plist["ProcessType"] as? String == "Background")
        #expect(plist["LowPriorityIO"] as? Bool == true)
        #expect(plist["Nice"] as? Int == 10)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        let program = try #require(plist["BundleProgram"] as? String)
        #expect(FileManager.default.isExecutableFile(atPath: appBundle.appendingPathComponent(program).path),
                "BundleProgram \(program) is not an executable inside the app bundle")
    }

    // MARK: - SENSOR 1b: the sources

    @Test("SENSOR 1b: the helper's sources import no committer, no GRDB, no write-side SQLite; Core's Background/ imports no AppKit, CoreGraphics, SwiftUI or GRDB")
    func sourcesStayOnTheReadSide() throws {
        let forbiddenInHelper: [(String, String)] = [
            ("CatalogCommitter", "the committer is the app's"),
            ("import " + "GRDB", "GRDB stays in Store/ and the app"),   // split: CatalogStoreSensorTests scans files for that line
            ("GRDBCatalogRepository", "the catalog store class is the writer's"),
            ("SQLITE_OPEN_READWRITE", "no read-write open"),
            ("SQLITE_OPEN_CREATE", "no create"),
            ("sqlite3_open(", "sqlite3_open defaults to read-write"),
            ("import SwiftUI", "the helper has no UI"),
            ("@testable import VideoScan", "the helper never links the app"),
            ("import VideoScan\n", "the helper never links the app"),
        ]
        for file in try Self.swiftFiles(in: Self.helperSourceRoot) {
            for (needle, why) in forbiddenInHelper {
                #expect(!file.code.contains(needle), "VideoScanBackground/\(file.name) contains `\(needle)` — \(why)")
            }
        }
        let forbiddenInCore: [(String, String)] = [
            ("import AppKit", "Core is Foundation-only"),
            ("import CoreGraphics", "inject what needs it (ActivitySource)"),
            ("import SwiftUI", "Core is UI-free"),
            ("import " + "GRDB", "only Store/ may link GRDB"),
            ("SQLITE_OPEN_READWRITE", "the door opens one way"),
            ("SQLITE_OPEN_CREATE", "the door opens one way"),
            ("sqlite3_open(", "sqlite3_open defaults to read-write"),
            ("CatalogCommitter", "the committer is the app's"),
        ]
        let coreFiles = try Self.swiftFiles(in: Self.coreBackgroundRoot)
        for file in coreFiles {
            for (needle, why) in forbiddenInCore {
                #expect(!file.code.contains(needle), "Core/Background/\(file.name) contains `\(needle)` — \(why)")
            }
        }
        let door = try #require(coreFiles.first { $0.name == "BackgroundCatalogAccess.swift" }, "the read-only door moved or went")
        #expect(door.code.contains("SQLITE_OPEN_READONLY"), "the door no longer names SQLITE_OPEN_READONLY")
        #expect(door.code.contains("sqlite3_open_v2(url.path, &handle, openFlags, nil)"), "the open must pass the constant flags, not a parameter")
        #expect(door.code.components(separatedBy: "sqlite3_open_v2(").count == 2, "exactly one open call in the door")
        #expect(!door.code.contains("sqlite3_exec("), "no statement executor on the door — reads only through strings(_:)")
    }

    // MARK: - SENSOR 2: the live handle

    @Test("SENSOR 2: the catalog door's flags are SQLITE_OPEN_READONLY and a live handle refuses a write in words")
    func catalogDoorIsReadOnly() throws {
        #expect(BackgroundCatalogAccess.openFlags & SQLITE_OPEN_READONLY != 0)
        #expect(BackgroundCatalogAccess.openFlags & SQLITE_OPEN_READWRITE == 0)
        #expect(BackgroundCatalogAccess.openFlags & SQLITE_OPEN_CREATE == 0)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundSensor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("catalog.sqlite")
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        try #require(sqlite3_exec(db, "CREATE TABLE files (digest TEXT PRIMARY KEY); INSERT INTO files VALUES ('d1');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close_v2(db)

        let access = try BackgroundCatalogAccess.open(at: url)
        defer { access.close() }
        #expect(access.isReadOnly)
        let error = #expect(throws: Refusal.self) { try access.strings("INSERT INTO files VALUES ('d2')") }
        #expect(error?.words.contains("reading only") == true)
        #expect(try access.strings("SELECT count(*) FROM files") == ["1"])
    }

    // MARK: - SENSOR 3: MFO lifecycle

    @Test("SENSOR 3: every job writes START and OUTCOME with counts — a finished one and a stopped one — and the supervisor source still emits both")
    func lifecycleLines() async throws {
        let supervisorSource = try String(contentsOf: Self.coreBackgroundRoot.appendingPathComponent("JobSupervisor.swift"), encoding: .utf8)
        let code = try SourceTree.code(of: supervisorSource, named: "JobSupervisor.swift")
        #expect(code.contains("\"START "), "the supervisor no longer writes START lines")
        #expect(code.contains("\"OUTCOME "), "the supervisor no longer writes OUTCOME lines")

        let log = InMemoryBackgroundLog()
        var configuration = JobSupervisor.Configuration()
        configuration.pausePollInterval = .milliseconds(10)
        let supervisor = JobSupervisor(queue: InMemoryJobQueueStore(), checkpoints: InMemoryCheckpointStore(), factory: DefaultJobFactory(),
                                       backoff: Backoff(source: FakeActivitySource(ActivitySample()), trickleInterval: .milliseconds(1)),
                                       log: log, configuration: configuration)

        let finished = NoOpJob.request(units: 3, sleepMilliseconds: 0, lane: "a", requestedBy: "sensor")
        _ = await supervisor.enqueue(finished)
        let stopped = NoOpJob.request(units: 5_000, sleepMilliseconds: 5, lane: "b", requestedBy: "sensor")
        _ = await supervisor.enqueue(stopped)
        var polls = 0
        while polls < 500, (await supervisor.snapshot(stopped.id)?.completedUnits ?? 0) < 2 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(await supervisor.stop(stopped.id))
        await supervisor.drain()

        let lines = log.lines
        #expect(lines.contains { $0.hasPrefix("START noop \(finished.id) — 3 units, lane a, by sensor") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("OUTCOME noop \(finished.id) — finished: 3 run · 0 skipped · 0 failed") }, "\(lines)")
        #expect(lines.contains { $0.hasPrefix("START noop \(stopped.id) — 5000 units, lane b, by sensor") }, "\(lines)")
        let stoppedOutcome = lines.filter { $0.hasPrefix("OUTCOME noop \(stopped.id) — stopped at") }
        #expect(stoppedOutcome.count == 1, "\(lines)")
        #expect(stoppedOutcome.first?.contains(" run · 0 skipped · 0 failed") == true)
        #expect(lines.filter { $0.hasPrefix("START ") }.count == lines.filter { $0.hasPrefix("OUTCOME ") }.count,
                "a START without its OUTCOME: \(lines)")
    }
}
