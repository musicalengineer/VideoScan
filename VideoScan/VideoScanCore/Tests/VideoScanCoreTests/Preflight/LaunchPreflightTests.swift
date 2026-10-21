// LaunchPreflightTests.swift
// The launch preflight checklist (2026-10-21), against a fake machine.
// CLAUDE.md's five dimensions, where they apply:
//   1. Logic     — one test per threshold edge (both sides of each line).
//   2. Scale     — 1,000 whole runs with a fake probe inside a time budget,
//                  and the REAL probe's fast phase inside its 200 ms budget.
//   3. Media     — n/a (opens no media).
//   4. Isolation — a poisoned probe (throws / nil / missing volume) gives
//                  "Couldn't check …", never a crash and never a green.
//   5. Sensor    — `unknownLevel` is never ok for any check id; the
//                  healthy machine's summary is exactly "All set".
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
    func catalogQuickCheck(at databaseURL: URL, budget: Duration) throws -> PreflightQuickCheckOutcome {
        if quickCheckThrows { throw Poisoned() }
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

    private func run(_ probe: FakePreflightProbe, context: PreflightContext = Self.context) async -> PreflightReport {
        await LaunchPreflight.run(context, probe: probe)
    }

    private func check(_ id: PreflightCheck.ID, _ probe: FakePreflightProbe,
                       context: PreflightContext = Self.context) async -> PreflightCheck? {
        await run(probe, context: context).checks.first { $0.id == id }
    }

    private func level(_ id: PreflightCheck.ID, _ probe: FakePreflightProbe,
                       context: PreflightContext = Self.context) async -> PreflightLevel? {
        await check(id, probe, context: context)?.level
    }

    // MARK: The whole run

    @Test func healthyMacIsAllSetWithNoBanner() async {
        let report = await run(.healthy())
        #expect(report.level == .ok, "\(report.checks.filter { $0.level != .ok }.map(\.logLine))")
        #expect(report.summary == "All set")
        #expect(!report.showsBanner)
        #expect(report.problems.isEmpty)
        #expect(report.quickCheckElapsed != nil)
        // Same volume for temp and system: one disk check, not two.
        #expect(report.checks.map(\.id) == [.systemDisk, .memory, .swap, .catalogSwitched, .catalogSchema,
                                            .catalogJournal, .catalogQuickCheck, .tools, .logFolder,
                                            .thermal, .power, .masterArchive])
        #expect(report.outcomeLine.hasPrefix("[preflight] OUTCOME ok: All set"))
    }

    @Test func fastOnlyRunLeavesQuickCheckOut() async {
        let report = await LaunchPreflight.run(Self.context, probe: FakePreflightProbe.healthy(), includeQuickCheck: false)
        #expect(!report.checks.contains { $0.id == .catalogQuickCheck })
        #expect(report.quickCheckElapsed == nil)
        #expect(LaunchPreflight.fastChecks(Self.context, probe: FakePreflightProbe.healthy()).map(\.id)
                == report.checks.map(\.id))
    }

    @Test func redDiskSummaryIsRicksSentence() async {
        let report = await run(FakePreflightProbe.healthy().disk(free: 50, of: 1_000))
        #expect(report.level == .red)
        #expect(report.showsBanner)
        #expect(report.summary == "Your Mac's main disk is 95% full — free some space; long jobs and backups wait until you do")
        #expect(report.hold == .longOperations, "red holds long jobs, not editing (ruling b)")
        #expect(report.logLines.last == report.outcomeLine)
        #expect(report.logLines.contains { $0.hasPrefix("[preflight] system-disk red:") })
    }

    @Test func worstLevelWinsAndSummaryCountsTheRest() async {
        var probe = FakePreflightProbe.healthy().disk(free: 95, of: 1_000)   // warn (90.5%)
        probe.thermal = .critical                                            // warn
        probe.files.removeValue(forKey: Self.context.latchURL.path)          // red
        probe.power = .battery                                               // note: not counted
        let report = await run(probe)
        #expect(report.level == .red)
        #expect(report.problems.first?.id == .catalogSwitched)
        #expect(report.problems.map(\.level) == [.red, .warn, .warn, .note])
        #expect(report.summary.hasSuffix("(and 2 more things in Catalog Status)"), "\(report.summary)")
    }

    @Test func notesAloneShowNoBanner() async {
        var probe = FakePreflightProbe.healthy()
        probe.power = .battery
        let report = await run(probe)
        #expect(report.level == .note)
        #expect(!report.showsBanner)
        #expect(report.summary == "Running on battery — plug in before starting long jobs")
    }

    // MARK: Disk thresholds (1 TB disk unless said otherwise)

    @Test func diskAt90PercentWarnsAndJustUnderIsOK() async {
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 100, of: 1_000)) == .warn)
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 101, of: 1_000)) == .ok)
    }

    @Test func diskAt95PercentIsRedAndJustUnderWarns() async {
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 50, of: 1_000)) == .red)
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 51, of: 1_000)) == .warn)
    }

    @Test func under50GBFreeWarnsOnASmallDisk() async {
        // 400 GB disk: 49 GB free is 87.75% used — the free-space line fires, not the percent.
        let low = await check(.systemDisk, FakePreflightProbe.healthy().disk(free: 49, of: 400))
        #expect(low?.level == .warn)
        #expect(low?.words == "Your Mac's main disk has only 49 GB free — consider freeing some space soon")
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 50, of: 400)) == .ok)
    }

    @Test func under20GBFreeIsRedEvenBelow95Percent() async {
        // 300 GB disk: 19.9 GB free is 93.4% used.
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 19.9, of: 300)) == .red)
        #expect(await level(.systemDisk, FakePreflightProbe.healthy().disk(free: 20, of: 300)) == .warn)
    }

    @Test func redFloorIsThreeTimesCatalogPlusJournal() async {
        // catalog 8 GB + WAL 2 GB → floor 30 GB.
        var probe = FakePreflightProbe.healthy()
        probe.files[Self.context.databaseURL.path] = 8_000_000_000
        probe.files[Self.context.walURL.path] = 2_000_000_000
        #expect(Self.context.thresholds.diskRedFreeBytes(catalogBytes: 10_000_000_000) == 30 * FakePreflightProbe.gb)
        #expect(await level(.systemDisk, probe.disk(free: 29.9, of: 300)) == .red)
        #expect(await level(.systemDisk, probe.disk(free: 30, of: 300)) == .warn)
    }

    @Test func redFloorNeverOverflows() {
        #expect(PreflightThresholds().diskRedFreeBytes(catalogBytes: .max) == .max)
    }

    @Test func tempDiskOnAnotherVolumeIsCheckedByTheSameRule() async {
        var probe = FakePreflightProbe.healthy()
        probe.tempIsSystem = false
        probe.tempVolume = PreflightVolume(id: "/Volumes/Scratch", name: "Scratch",
                                           availableBytes: 10 * FakePreflightProbe.gb, totalBytes: 100 * FakePreflightProbe.gb)
        let temp = await check(.tempDisk, probe)
        #expect(temp?.level == .red)
        #expect(temp?.words == "The disk for temporary files (Scratch) has only 10 GB free — free some space; long jobs and backups wait until you do")
        #expect(await level(.systemDisk, probe) == .ok)
    }

    @Test func usedFractionOfAZeroSizedVolumeReadsFull() {
        #expect(PreflightVolume(id: "x", name: "x", availableBytes: 0, totalBytes: 0).usedFraction == 1)
    }

    // MARK: Memory

    @Test func memoryUnder16GBWarns() async {
        var probe = FakePreflightProbe.healthy()
        probe.memory = 16 * FakePreflightProbe.gib
        #expect(await level(.memory, probe) == .ok)
        probe.memory = 16 * FakePreflightProbe.gib - 1
        #expect(await level(.memory, probe) == .warn)
        probe.memory = 8 * FakePreflightProbe.gib
        #expect(await check(.memory, probe)?.words == "This Mac has 8 GB of memory — big jobs may be slow")
    }

    @Test func swapOver4GBIsANote() async {
        var probe = FakePreflightProbe.healthy()
        probe.swap = 4 * FakePreflightProbe.gib
        #expect(await level(.swap, probe) == .ok)
        probe.swap = 4 * FakePreflightProbe.gib + 1
        #expect(await level(.swap, probe) == .note)
    }

    // MARK: Catalog

    @Test func missingCutoverMarkerIsRed() async {
        var probe = FakePreflightProbe.healthy()
        probe.files.removeValue(forKey: Self.context.latchURL.path)
        let switched = await check(.catalogSwitched, probe)
        #expect(switched?.level == .red)
        #expect(switched?.detail.contains("catalog.cutover missing") == true)
    }

    @Test func missingCatalogFileIsRed() async {
        var probe = FakePreflightProbe.healthy()
        probe.files.removeValue(forKey: Self.context.databaseURL.path)
        #expect(await level(.catalogSwitched, probe) == .red)
    }

    @Test func schemaVersionEqualOKNewerRedOlderWarn() async {
        var probe = FakePreflightProbe.healthy()
        #expect(await level(.catalogSchema, probe) == .ok)
        probe.schemaVersion = Self.expectedSchema + 1
        #expect(await level(.catalogSchema, probe) == .red)
        probe.schemaVersion = Self.expectedSchema - 1
        #expect(await level(.catalogSchema, probe) == .warn)
    }

    @Test func journalOver256MBWarns() async {
        var probe = FakePreflightProbe.healthy()
        probe.files[Self.context.walURL.path] = 256 * PreflightThresholds.mebibyte
        #expect(await level(.catalogJournal, probe) == .ok)
        probe.files[Self.context.walURL.path] = 256 * PreflightThresholds.mebibyte + 1
        #expect(await level(.catalogJournal, probe) == .warn)
    }

    @Test func quickCheckOutcomes() async {
        var probe = FakePreflightProbe.healthy()
        #expect(await level(.catalogQuickCheck, probe) == .ok)
        probe.quickCheck = .problems(["*** in database main ***", "Page 7: btreeInitPage() returns error code 11"],
                                     elapsed: .milliseconds(5))
        let bad = await check(.catalogQuickCheck, probe)
        #expect(bad?.level == .red)
        #expect(bad?.detail.contains("btreeInitPage") == true)
        probe.quickCheck = .ranOutOfTime(budget: .seconds(2))
        #expect(await level(.catalogQuickCheck, probe) == .note)
    }

    // MARK: Tools, logs, machine, archive

    @Test func missingFFprobeWarnsAndNamesIt() async {
        var probe = FakePreflightProbe.healthy()
        probe.tools[.ffprobe] = nil
        let tools = await check(.tools, probe)
        #expect(tools?.level == .warn)
        #expect(tools?.words.contains("ffprobe") == true)
        #expect(tools?.detail.contains("ffprobe=missing") == true)
    }

    @Test func unwritableLogFolderWarns() async {
        var probe = FakePreflightProbe.healthy()
        probe.writableFolders = []
        #expect(await level(.logFolder, probe) == .warn)
    }

    @Test(arguments: [(PreflightThermalState.nominal, PreflightLevel.ok), (.fair, .ok), (.serious, .warn), (.critical, .warn)])
    func thermalSeriousOrCriticalWarns(state: PreflightThermalState, expected: PreflightLevel) async {
        var probe = FakePreflightProbe.healthy()
        probe.thermal = state
        #expect(await level(.thermal, probe) == expected)
    }

    @Test func batteryIsANote() async {
        var probe = FakePreflightProbe.healthy()
        probe.power = .battery
        #expect(await level(.power, probe) == .note)
    }

    @Test func masterArchiveOfflineIsOnlyANote() async {
        var context = Self.context
        context.masterArchiveVolume = URL(fileURLWithPath: "/Volumes/MasterArchive", isDirectory: true)
        var probe = FakePreflightProbe.healthy()
        #expect(await level(.masterArchive, probe, context: context) == .note)
        probe.mounted = ["/Volumes/MasterArchive"]
        #expect(await level(.masterArchive, probe, context: context) == .ok)
        #expect(await level(.masterArchive, probe) == .ok, "no archive set")
    }

    // MARK: Isolation — a poisoned probe never crashes and never reads green

    @Test func everyCheckThatThrowsSaysCouldntCheckAndIsNotGreen() async {
        var probe = FakePreflightProbe.healthy()
        probe.volumesThrow = true
        probe.swapThrows = true
        probe.schemaThrows = true
        probe.quickCheckThrows = true
        let report = await run(probe)
        for id in [PreflightCheck.ID.systemDisk, .swap, .catalogSchema, .catalogQuickCheck] {
            let found = report.checks.first { $0.id == id }
            #expect(found?.level ?? .ok > .ok, "\(id) read green from a throwing probe")
            #expect(found?.words.hasPrefix("Couldn't check") == true, "\(id): \(found?.words ?? "absent")")
            #expect(found?.detail.contains("poisoned probe") == true)
        }
        #expect(report.level == .warn)
        #expect(report.showsBanner)
    }

    @Test func everyCheckThatGetsNilSaysCouldntCheck() async {
        var probe = FakePreflightProbe.healthy()
        probe.systemVolume = nil            // a missing volume
        probe.memory = nil
        probe.swap = nil
        probe.thermal = nil
        probe.power = nil
        probe.schemaVersion = nil           // a file with no catalog_state row
        let report = await run(probe)
        for id in [PreflightCheck.ID.systemDisk, .memory, .swap, .thermal, .power, .catalogSchema] {
            let found = report.checks.first { $0.id == id }
            #expect(found?.level ?? .ok > .ok, "\(id) read green from a nil answer")
            #expect(found?.words.hasPrefix("Couldn't check") == true, "\(id): \(found?.words ?? "absent")")
        }
        #expect(report.level == .warn, "disk and catalog gaps are warn")
    }

    @Test func missingTempVolumeIsCheckedSeparatelyAndNotGreen() async {
        var probe = FakePreflightProbe.healthy()
        probe.tempIsSystem = false
        probe.tempVolume = nil
        #expect(await check(.tempDisk, probe)?.words == "Couldn't check how full the temporary-files disk is")
        #expect(await level(.tempDisk, probe) == .warn)
    }

    @Test func emptyMachineEverythingMissingStillReportsEveryCheck() async {
        // Nothing exists, nothing answers: a full report, no crash.
        let report = await run(FakePreflightProbe(systemVolume: nil, memory: nil, swap: nil, thermal: nil, power: nil,
                                                  tools: [:], schemaVersion: nil, quickCheck: nil))
        #expect(report.level == .red)
        // Neither volume answered, so system and temp are both "couldn't check" — 13, not 12.
        #expect(report.checks.count == 13)
        #expect(report.hold == .none, "an unreadable disk never holds edits on a guess")
        #expect(report.checks.allSatisfy { $0.level > .ok || $0.id == .catalogJournal || $0.id == .masterArchive })
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
        #expect(t.memoryWarnBelowBytes == 16 << 30)
        #expect(t.swapNoteAboveBytes == 4 << 30)
        #expect(t.journalWarnAboveBytes == 256 << 20)
    }

    // MARK: Scale / time budget

    @Test func thousandFakeRunsFitInOneSecond() async {
        let probe = FakePreflightProbe.healthy().disk(free: 60, of: 1_000)
        let loadBefore = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        let start = clock.now
        var levels = 0
        for _ in 0..<1_000 {
            levels += await LaunchPreflight.run(Self.context, probe: probe).level.rawValue
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
        let report = await LaunchPreflight.run(context, probe: SystemPreflightProbe(), includeQuickCheck: false)
        print(report.logLines.joined(separator: "\n"))
        #expect(report.checks.first { $0.id == .catalogSwitched }?.level == .red)
        #expect(report.checks.first { $0.id == .systemDisk }?.readings.isEmpty == false, "the real disk was read")
        #expect(report.checks.first { $0.id == .logFolder }?.level == .ok)
        #expect(report.checks.first { $0.id == .masterArchive }?.level == .note)
        expectWithinTimingBudget("preflight fast phase, real probe", measured: report.fastElapsed,
                                 budget: .milliseconds(200), loadBefore: loadBefore)
    }
}
