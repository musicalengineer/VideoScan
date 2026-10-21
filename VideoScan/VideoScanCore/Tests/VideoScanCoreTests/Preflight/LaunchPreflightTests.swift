// LaunchPreflightTests.swift
// The launch preflight checklist (2026-10-21), against a fake machine.
// CLAUDE.md's five dimensions, where they apply:
//   1. Logic     — one test per threshold edge (both sides of each line).
//   2. Scale     — 1,000 whole runs with a fake probe inside a time budget,
//                  and the REAL probe's fast phase inside its 200 ms budget.
//   3. Media     — n/a (opens no media).
//   4. Isolation — a poisoned probe (throws / nil / missing volume / a volume
//                  with no size) gives "Couldn't check …", never a crash and
//                  never a green.
//   5. Sensor    — `unknownLevel` is never ok for any check id; the
//                  healthy machine's summary is exactly "All set".
// Plus cancellation: a cancelled run throws and never reports a verdict.
// The quick_check on a real (tiny, generated) SQLite file is in
// Store/CatalogPreflightReaderTests.swift — the SQLite toolkit is confined
// to Store/ folders (CatalogStoreSensorTests).

import Foundation
import Testing
@testable import VideoScanCore

// MARK: - The fake machine

struct FakePreflightProbe: PreflightProbe {
    struct Poisoned: Error, CustomStringConvertible {
        var description: String { "poisoned probe" }
    }

    static let gb = PreflightThresholds.gigabyte
    static let gib = PreflightThresholds.gibibyte

    var systemVolume: PreflightVolume? = PreflightVolume(id: "/", name: "Macintosh HD",
                                                        availableBytes: 500 * gb, totalBytes: 1_000 * gb)
    /// nil here AND `tempIsSystem` true → the temp folder is on the system volume.
    var tempVolume: PreflightVolume?
    var tempIsSystem = true
    var volumesThrow = false
    var mounted: Set<String> = []
    var memory: UInt64? = 64 * gib
    var swap: UInt64? = 0
    var swapThrows = false
    var thermal: PreflightThermalState? = .nominal
    var power: PreflightPowerSource? = .mains
    /// path → size; presence means the file exists.
    var files: [String: UInt64] = [:]
    var writableFolders: Set<String> = []
    var tools: [PreflightTool: String] = [.ffmpeg: "/opt/homebrew/bin/ffmpeg", .ffprobe: "/opt/homebrew/bin/ffprobe"]
    var schemaVersion: Int? = LaunchPreflightTests.expectedSchema
    var schemaThrows = false
    var quickCheck: PreflightQuickCheckOutcome? = .passed(elapsed: .milliseconds(100))
    var quickCheckThrows = false
    /// quick_check that only ends when cancelled (or after 5 s) — the quit-path shape.
    var quickCheckWaitsForCancel = false

    func volume(containing url: URL) throws -> PreflightVolume? {
        if volumesThrow { throw Poisoned() }
        if url == LaunchPreflightTests.context.temporaryFolder, !tempIsSystem { return tempVolume }
        return systemVolume
    }
    func isVolumeMounted(at url: URL) -> Bool { mounted.contains(url.path) }
    func physicalMemoryBytes() -> UInt64? { memory }
    func swapUsedBytes() throws -> UInt64? {
        if swapThrows { throw Poisoned() }
        return swap
    }
    func thermalState() -> PreflightThermalState? { thermal }
    func powerSource() -> PreflightPowerSource? { power }
    func fileExists(at url: URL) -> Bool { files[url.path] != nil }
    func fileSize(at url: URL) -> UInt64? { files[url.path] }
    func isWritableFolder(at url: URL) -> Bool { writableFolders.contains(url.path) }
    func executablePath(for tool: PreflightTool) -> String? { tools[tool] }
    func catalogSchemaVersion(at databaseURL: URL) throws -> Int? {
        if schemaThrows { throw Poisoned() }
        return schemaVersion
    }
    func catalogQuickCheck(at databaseURL: URL, budget: Duration,
                           cancellation: PreflightCancellation) throws -> PreflightQuickCheckOutcome {
        if quickCheckThrows { throw Poisoned() }
        if quickCheckWaitsForCancel {
            let deadline = Date().addingTimeInterval(5)
            while !cancellation.isCancelled, Date() < deadline { usleep(1_000) }
            return cancellation.isCancelled ? .cancelled : .ranOutOfTime(budget: budget)
        }
        guard let quickCheck else { throw Poisoned() }
        return quickCheck
    }

    /// A healthy Mac: half-empty 1 TB disk, 64 GB, a 275 MB catalog with its marker.
    static func healthy() -> FakePreflightProbe {
        let context = LaunchPreflightTests.context
        var probe = FakePreflightProbe()
        probe.files = [context.databaseURL.path: 275_000_000, context.latchURL.path: 195]
        probe.writableFolders = [context.logFolder.path]
        return probe
    }

    /// The system disk with `freeGB` of `totalGB` free.
    func disk(free freeGB: Double, of totalGB: Int64) -> FakePreflightProbe {
        var probe = self
        probe.systemVolume = PreflightVolume(id: "/", name: "Macintosh HD",
                                             availableBytes: Int64(freeGB * Double(Self.gb)),
                                             totalBytes: totalGB * Self.gb)
        return probe
    }
}

// MARK: - Tests

@Suite("LaunchPreflight")
struct LaunchPreflightTests {

    static let expectedSchema = 12
    static let context = PreflightContext(
        supportFolder: URL(fileURLWithPath: "/fake/Application Support/VideoScan", isDirectory: true),
        databaseURL: URL(fileURLWithPath: "/fake/Application Support/VideoScan/catalog.sqlite"),
        temporaryFolder: URL(fileURLWithPath: "/fake/tmp", isDirectory: true),
        logFolder: URL(fileURLWithPath: "/fake/Logs/VideoScan", isDirectory: true),
        masterArchiveVolume: nil,
        expectedSchemaVersion: expectedSchema)

    static let redWords = "free some space; long jobs, backups and copies to other Macs wait until you do"

    private func run(_ probe: FakePreflightProbe, context: PreflightContext = Self.context) async throws -> PreflightReport {
        try await LaunchPreflight.run(context, probe: probe)
    }

    private func check(_ id: PreflightCheck.ID, _ probe: FakePreflightProbe,
                       context: PreflightContext = Self.context) async throws -> PreflightCheck? {
        try await run(probe, context: context).checks.first { $0.id == id }
    }

    private func level(_ id: PreflightCheck.ID, _ probe: FakePreflightProbe,
                       context: PreflightContext = Self.context) async throws -> PreflightLevel? {
        try await check(id, probe, context: context)?.level
    }

    // MARK: The whole run

    @Test func healthyMacIsAllSetWithNoBanner() async throws {
        let report = try await run(.healthy())
        #expect(report.level == .ok, "\(report.checks.filter { $0.level != .ok }.map(\.logLine))")
        #expect(report.summary == "All set")
        #expect(!report.showsBanner)
        #expect(report.problems.isEmpty)
        #expect(report.hold == .none)
        #expect(report.situation.catalogFault == nil)
        #expect(report.situation.catalogBytes == 275_000_000)
        #expect(report.quickCheckElapsed != nil)
        // Same volume for temp and system: one disk check, not two.
        #expect(report.checks.map(\.id) == [.systemDisk, .memory, .swap, .catalogSwitched, .catalogSchema,
                                            .catalogJournal, .catalogQuickCheck, .tools, .logFolder,
                                            .thermal, .power, .masterArchive])
        #expect(report.outcomeLine.hasPrefix("[preflight] OUTCOME ok: All set"))
    }

    @Test func fastOnlyRunLeavesQuickCheckOut() async throws {
        let full = try await run(.healthy())
        let fast = try await LaunchPreflight.run(Self.context, probe: FakePreflightProbe.healthy(), includeQuickCheck: false)
        #expect(!fast.checks.contains { $0.id == .catalogQuickCheck })
        #expect(fast.quickCheckElapsed == nil)
        #expect(fast.checks.map(\.id) == full.checks.map(\.id).filter { $0 != .catalogQuickCheck })
    }

    @Test func redDiskSummaryHoldsLongOperationsNotEdits() async throws {
        let report = try await run(FakePreflightProbe.healthy().disk(free: 50, of: 1_000))
        #expect(report.level == .red)
        #expect(report.showsBanner)
        #expect(report.summary == "Your Mac's main disk is 95% full — " + Self.redWords)
        #expect(report.hold == .longOperations, "red holds long jobs, not editing (ruling b)")
        #expect(report.logLines.last == report.outcomeLine)
        #expect(report.logLines.contains { $0.hasPrefix("[preflight] system-disk red:") })
    }

    @Test func worstLevelWinsAndSummaryCountsTheRest() async throws {
        var probe = FakePreflightProbe.healthy().disk(free: 95, of: 1_000)   // warn (90.5%)
        probe.thermal = .critical                                            // warn
        probe.files.removeValue(forKey: Self.context.latchURL.path)          // red
        probe.power = .battery                                               // note: not counted
        let report = try await run(probe)
        #expect(report.level == .red)
        #expect(report.problems.first?.id == .catalogSwitched)
        #expect(report.problems.map(\.level) == [.red, .warn, .warn, .note])
        #expect(report.summary.hasSuffix("(and 2 more things in Catalog Status)"), "\(report.summary)")
    }

    @Test func notesAloneShowNoBanner() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.power = .battery
        let report = try await run(probe)
        #expect(report.level == .note)
        #expect(!report.showsBanner)
        #expect(report.summary == "Running on battery — plug in before starting long jobs")
    }

    // MARK: Disk thresholds (1 TB disk unless said otherwise)

    @Test func diskAt90PercentWarnsAndJustUnderIsOK() async throws {
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 100, of: 1_000)) == .warn)
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 101, of: 1_000)) == .ok)
    }

    @Test func diskAt95PercentIsRedAndJustUnderWarns() async throws {
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 50, of: 1_000)) == .red)
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 51, of: 1_000)) == .warn)
    }

    @Test func under50GBFreeWarnsOnASmallDisk() async throws {
        // 400 GB disk: 49 GB free is 87.75% used — the free-space line fires, not the percent.
        let low = try await check(.systemDisk, FakePreflightProbe.healthy().disk(free: 49, of: 400))
        #expect(low?.level == .warn)
        #expect(low?.words == "Your Mac's main disk has only 49 GB free — consider freeing some space soon")
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 50, of: 400)) == .ok)
    }

    @Test func under20GBFreeIsRedEvenBelow95Percent() async throws {
        // 300 GB disk: 19.9 GB free is 93.4% used.
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 19.9, of: 300)) == .red)
        #expect(try await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 20, of: 300)) == .warn)
    }

    @Test func redFloorIsThreeTimesCatalogPlusJournal() async throws {
        // catalog 8 GB + WAL 2 GB → floor 30 GB.
        var probe = FakePreflightProbe.healthy()
        probe.files[Self.context.databaseURL.path] = 8_000_000_000
        probe.files[Self.context.walURL.path] = 2_000_000_000
        #expect(Self.context.thresholds.diskRedFreeBytes(catalogBytes: 10_000_000_000) == 30 * FakePreflightProbe.gb)
        #expect(try await level(.systemDisk, probe.disk(free: 29.9, of: 300)) == .red)
        #expect(try await level(.systemDisk, probe.disk(free: 30, of: 300)) == .warn)
    }

    @Test func redFloorNeverOverflows() {
        #expect(PreflightThresholds().diskRedFreeBytes(catalogBytes: .max) == .max)
    }

    @Test func tempDiskOnAnotherVolumeIsCheckedByTheSameRule() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.tempIsSystem = false
        probe.tempVolume = PreflightVolume(id: "/Volumes/Scratch", name: "Scratch",
                                           availableBytes: 10 * FakePreflightProbe.gb, totalBytes: 100 * FakePreflightProbe.gb)
        let temp = try await check(.tempDisk, probe)
        #expect(temp?.level == .red)
        #expect(temp?.words == "The disk for temporary files (Scratch) has only 10 GB free — " + Self.redWords)
        #expect(try await level(.systemDisk, probe) == .ok)
    }

    @Test func usedFractionOfAZeroSizedVolumeReadsFull() {
        #expect(PreflightVolume(id: "x", name: "x", availableBytes: 0, totalBytes: 0).usedFraction == 1)
    }

    @Test func zeroSizedVolumeIsCouldntCheckNotFull() async throws {
        let probe = FakePreflightProbe.healthy().disk(free: 0, of: 0)
        let disk = try await check(.systemDisk, probe)
        #expect(disk?.level == .warn)
        #expect(disk?.words == "Couldn't check how full your Mac's main disk is")
        #expect(disk?.detail.contains("reported a size of 0 bytes") == true)
        #expect(try await run(probe).hold == .none, "an unmeasurable disk never holds edits on a guess")
    }

    @Test func purgeableInclusiveFreeIsShownButNeverJudged() async throws {
        // 40 GB truly free (96% used → red), 200 GB counting purgeable files.
        var probe = FakePreflightProbe.healthy()
        probe.systemVolume = PreflightVolume(id: "/", name: "Macintosh HD", availableBytes: 40 * FakePreflightProbe.gb,
                                             totalBytes: 1_000 * FakePreflightProbe.gb,
                                             freeIncludingPurgeableBytes: 200 * FakePreflightProbe.gb)
        let disk = try await check(.systemDisk, probe)
        #expect(disk?.level == .red)
        #expect(disk?.readings.contains { $0.name == "freeIncludingPurgeable" && $0.value == 200e9 } == true)
    }

    // MARK: Memory

    @Test func memoryUnder16GBWarns() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.memory = 16 * FakePreflightProbe.gib
        #expect(try await level(.memory, probe) == .ok)
        probe.memory = 16 * FakePreflightProbe.gib - 1
        #expect(try await level(.memory, probe) == .warn)
        probe.memory = 8 * FakePreflightProbe.gib
        #expect(try await check(.memory, probe)?.words == "This Mac has 8 GB of memory — big jobs may be slow")
    }

    @Test func swapOver4GBIsANote() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.swap = 4 * FakePreflightProbe.gib
        #expect(try await level(.swap, probe) == .ok)
        probe.swap = 4 * FakePreflightProbe.gib + 1
        #expect(try await level(.swap, probe) == .note)
    }

    // MARK: Catalog (red catalog checks hold edits — QA r1 M3)

    @Test func missingCutoverMarkerIsRedAndHoldsEdits() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.files.removeValue(forKey: Self.context.latchURL.path)
        let report = try await run(probe)
        let switched = report.checks.first { $0.id == .catalogSwitched }
        #expect(switched?.level == .red)
        #expect(switched?.detail.contains("catalog.cutover missing") == true)
        #expect(report.hold == .edits)
        #expect(report.situation.catalogFault?.id == .catalogSwitched)
    }

    @Test func missingCatalogFileIsRedAndHoldsEdits() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.files.removeValue(forKey: Self.context.databaseURL.path)
        let report = try await run(probe)
        #expect(report.checks.first { $0.id == .catalogSwitched }?.level == .red)
        #expect(report.hold == .edits)
    }

    @Test func schemaVersionEqualOKNewerRedOlderWarn() async throws {
        var probe = FakePreflightProbe.healthy()
        #expect(try await level(.catalogSchema, probe) == .ok)
        probe.schemaVersion = Self.expectedSchema + 1
        #expect(try await level(.catalogSchema, probe) == .red)
        #expect(try await run(probe).hold == .edits, "a newer build's catalog: no writes")
        probe.schemaVersion = Self.expectedSchema - 1
        #expect(try await level(.catalogSchema, probe) == .warn)
        #expect(try await run(probe).hold == .none, "warn informs; it doesn't hold")
    }

    @Test func journalOver256MBWarns() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.files[Self.context.walURL.path] = 256 * PreflightThresholds.mebibyte
        #expect(try await level(.catalogJournal, probe) == .ok)
        probe.files[Self.context.walURL.path] = 256 * PreflightThresholds.mebibyte + 1
        #expect(try await level(.catalogJournal, probe) == .warn)
    }

    @Test func quickCheckOutcomes() async throws {
        var probe = FakePreflightProbe.healthy()
        #expect(try await level(.catalogQuickCheck, probe) == .ok)
        probe.quickCheck = .problems(["*** in database main ***", "Page 7: btreeInitPage() returns error code 11"],
                                     elapsed: .milliseconds(5))
        let bad = try await check(.catalogQuickCheck, probe)
        #expect(bad?.level == .red)
        #expect(bad?.detail.contains("btreeInitPage") == true)
        // No verdict is never a quiet green (QA r1 minor 2): warn, with a banner.
        probe.quickCheck = .ranOutOfTime(budget: .seconds(5))
        let late = try await run(probe)
        #expect(late.checks.first { $0.id == .catalogQuickCheck }?.level == .warn)
        #expect(late.showsBanner)
        #expect(late.hold == .none)
        probe.quickCheck = .cancelled
        #expect(try await level(.catalogQuickCheck, probe) == .warn)
    }

    // MARK: Tools, logs, machine, archive

    @Test func missingFFprobeWarnsAndNamesIt() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.tools[.ffprobe] = nil
        let tools = try await check(.tools, probe)
        #expect(tools?.level == .warn)
        #expect(tools?.words.contains("ffprobe") == true)
        #expect(tools?.detail.contains("ffprobe=missing") == true)
    }

    @Test func unwritableLogFolderWarns() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.writableFolders = []
        #expect(try await level(.logFolder, probe) == .warn)
    }

    @Test(arguments: [(PreflightThermalState.nominal, PreflightLevel.ok), (.fair, .ok), (.serious, .warn), (.critical, .warn)])
    func thermalSeriousOrCriticalWarns(state: PreflightThermalState, expected: PreflightLevel) async throws {
        var probe = FakePreflightProbe.healthy()
        probe.thermal = state
        #expect(try await level(.thermal, probe) == expected)
    }

    @Test func batteryIsANote() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.power = .battery
        #expect(try await level(.power, probe) == .note)
    }

    @Test func masterArchiveOfflineIsOnlyANote() async throws {
        var context = Self.context
        context.masterArchiveVolume = URL(fileURLWithPath: "/Volumes/MasterArchive", isDirectory: true)
        var probe = FakePreflightProbe.healthy()
        #expect(try await level(.masterArchive, probe, context: context) == .note)
        probe.mounted = ["/Volumes/MasterArchive"]
        #expect(try await level(.masterArchive, probe, context: context) == .ok)
        #expect(try await level(.masterArchive, probe) == .ok, "no archive set")
    }

    // MARK: Isolation — a poisoned probe never crashes and never reads green

    @Test func everyCheckThatThrowsSaysCouldntCheckAndIsNotGreen() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.volumesThrow = true
        probe.swapThrows = true
        probe.schemaThrows = true
        probe.quickCheckThrows = true
        let report = try await run(probe)
        for id in [PreflightCheck.ID.systemDisk, .swap, .catalogSchema, .catalogQuickCheck] {
            let found = report.checks.first { $0.id == id }
            #expect(found?.level ?? .ok > .ok, "\(id) read green from a throwing probe")
            #expect(found?.words.hasPrefix("Couldn't check") == true, "\(id): \(found?.words ?? "absent")")
            #expect(found?.detail.contains("poisoned probe") == true)
        }
        #expect(report.level == .warn)
        #expect(report.showsBanner)
        #expect(report.hold == .none, "a failed probe is not evidence of a full disk or a bad catalog")
    }

    @Test func everyCheckThatGetsNilSaysCouldntCheck() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.systemVolume = nil            // a missing volume
        probe.memory = nil
        probe.swap = nil
        probe.thermal = nil
        probe.power = nil
        probe.schemaVersion = nil           // a file with no catalog_state row
        let report = try await run(probe)
        for id in [PreflightCheck.ID.systemDisk, .memory, .swap, .thermal, .power, .catalogSchema] {
            let found = report.checks.first { $0.id == id }
            #expect(found?.level ?? .ok > .ok, "\(id) read green from a nil answer")
            #expect(found?.words.hasPrefix("Couldn't check") == true, "\(id): \(found?.words ?? "absent")")
        }
        #expect(report.level == .warn, "disk and catalog gaps are warn")
    }

    @Test func missingTempVolumeIsCheckedSeparatelyAndNotGreen() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.tempIsSystem = false
        probe.tempVolume = nil
        #expect(try await check(.tempDisk, probe)?.words == "Couldn't check how full the temporary-files disk is")
        #expect(try await level(.tempDisk, probe) == .warn)
    }

    @Test func emptyMachineEverythingMissingStillReportsEveryCheck() async throws {
        // Nothing exists, nothing answers: a full report, no crash.
        let report = try await run(FakePreflightProbe(systemVolume: nil, memory: nil, swap: nil, thermal: nil, power: nil,
                                                      tools: [:], schemaVersion: nil, quickCheck: nil))
        #expect(report.level == .red)
        // Neither volume answered, so system and temp are both "couldn't check" — 13, not 12.
        #expect(report.checks.count == 13)
        // The catalog file is missing: a red catalog check holds edits (QA r1 M3).
        #expect(report.hold == .edits)
        #expect(report.checks.allSatisfy { $0.level > .ok || $0.id == .catalogJournal || $0.id == .masterArchive })
    }

    // MARK: Cancellation (QA r1 minors 4–5)

    @Test func alreadyCancelledRunThrowsAndReportsNothing() async {
        let task = Task { try await LaunchPreflight.run(Self.context, probe: FakePreflightProbe.healthy()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func cancelDuringQuickCheckStopsItAtOnce() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.quickCheckWaitsForCancel = true
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await LaunchPreflight.run(Self.context, probe: probe) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - start < .seconds(3), "the cancel reached quick_check; it did not run to its 5 s end")
    }

    @Test func cancellationTokenRunsItsHandlerOnceAndLateRegistrationFiresAtOnce() {
        let token = PreflightCancellation()
        let counter = PreflightTally()
        token.whileRegistered({ counter.bump() }) {
            token.cancel()
            token.cancel()
        }
        #expect(counter.value == 1)
        token.whileRegistered({ counter.bump() }) {}
        #expect(counter.value == 2, "registering on a cancelled token fires the handler at once")
    }

    // MARK: Sensors

    @Test func aGapIsNeverOKForAnyCheck() {
        for id in PreflightCheck.ID.allCases {
            #expect(PreflightThresholds.unknownLevel(for: id) > .ok, "\(id)")
        }
        #expect(PreflightThresholds.unknownLevel(for: .systemDisk) == .warn)
        #expect(PreflightThresholds.unknownLevel(for: .catalogQuickCheck) == .warn)
    }

    @Test func defaultsAreRicksNumbers() {
        let t = PreflightThresholds()
        #expect(t.diskWarnUsedFraction == 0.90)
        #expect(t.diskWarnFreeBytes == 50_000_000_000)
        #expect(t.diskRedUsedFraction == 0.95)
        #expect(t.diskRedFloorBytes == 20_000_000_000)
        #expect(t.diskRedCatalogMultiple == 3)
        #expect(t.editHoldCatalogMultiple == 2)
        #expect(t.editHoldFloorBytes == 1_000_000_000)
        #expect(t.memoryWarnBelowBytes == 16 << 30)
        #expect(t.swapNoteAboveBytes == 4 << 30)
        #expect(t.journalWarnAboveBytes == 256 << 20)
        #expect(PreflightThresholds.quickCheckBudget == .seconds(5))
    }

    // MARK: Scale / time budget

    @Test func thousandFakeRunsFitInOneSecond() async throws {
        let probe = FakePreflightProbe.healthy().disk(free: 60, of: 1_000)
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var levels = 0
        for _ in 0..<1_000 {
            levels += try await LaunchPreflight.run(Self.context, probe: probe).level.rawValue
        }
        let elapsed = clock.now - start
        #expect(levels == 1_000 * PreflightLevel.warn.rawValue)
        expectWithinTimingBudget("1,000 preflight runs, fake probe", measured: elapsed, budget: .seconds(1),
                                 loadBefore: loadBefore)
    }

    @Test func realProbeFastPhaseFitsIn200ms() async throws {
        // The real machine, pointed at an empty scratch folder (no catalog —
        // the catalog checks report its absence, quickly).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-real-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let context = PreflightContext(supportFolder: scratch, databaseURL: scratch.appendingPathComponent("catalog.sqlite"),
                                       temporaryFolder: FileManager.default.temporaryDirectory,
                                       logFolder: scratch.appendingPathComponent("Logs", isDirectory: true),
                                       masterArchiveVolume: URL(fileURLWithPath: "/Volumes/NoSuchArchive-\(UUID().uuidString)"),
                                       expectedSchemaVersion: Self.expectedSchema)
        let loadBefore = TimingBudget.sampleLoad()
        let report = try await LaunchPreflight.run(context, probe: SystemPreflightProbe(), includeQuickCheck: false)
        print(report.logLines.joined(separator: "\n"))
        #expect(report.checks.first { $0.id == .catalogSwitched }?.level == .red)
        #expect(report.checks.first { $0.id == .systemDisk }?.readings.isEmpty == false, "the real disk was read")
        #expect(report.checks.first { $0.id == .logFolder }?.level == .ok)
        #expect(report.checks.first { $0.id == .masterArchive }?.level == .note)
        expectWithinTimingBudget("preflight fast phase, real probe", measured: report.fastElapsed,
                                 budget: .milliseconds(200), loadBefore: loadBefore)
    }
}

/// A thread-safe tally for handler tests.
final class PreflightTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
