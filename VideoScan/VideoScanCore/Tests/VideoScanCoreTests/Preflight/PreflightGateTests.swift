// PreflightGateTests.swift
// What a full disk may stop (Rick's ruling (b), 2026-10-21), at every edge,
// to the byte: exactly at 90% / 95%, each floor ± 1 byte, a 0-byte volume,
// an unreadable volume, a huge WAL, and each operation sized to its need.
// Plus the cost of each real probe question ("if it is expensive, tell me").

import Foundation
import Testing
@testable import VideoScanCore

@Suite("PreflightGate")
struct PreflightGateTests {

    static let gb = PreflightThresholds.gigabyte
    static let tb = 1_000 * gb
    let limits = PreflightThresholds()

    private func volume(free: Int64, total: Int64, id: String = "/", name: String = "Macintosh HD") -> PreflightVolume {
        PreflightVolume(id: id, name: name, availableBytes: free, totalBytes: total)
    }

    // MARK: The disk rule, to the byte

    @Test func exactly90PercentWarnsOneByteLessUsedIsOK() {
        let total = Self.tb
        #expect(PreflightDiskRule.judge(volume(free: total / 10, total: total), catalogBytes: 0, thresholds: limits).0 == .warn)
        #expect(PreflightDiskRule.judge(volume(free: total / 10 + 1, total: total), catalogBytes: 0, thresholds: limits).0 == .ok)
    }

    @Test func exactly95PercentIsRedOneByteLessUsedWarns() {
        let total = Self.tb
        #expect(PreflightDiskRule.judge(volume(free: total / 20, total: total), catalogBytes: 0, thresholds: limits).0 == .red)
        #expect(PreflightDiskRule.judge(volume(free: total / 20 + 1, total: total), catalogBytes: 0, thresholds: limits).0 == .warn)
    }

    @Test func warnFreeLine50GBPlusMinusOneByte() {
        let total = 400 * Self.gb   // 50 GB free is 87.5% used: only the free-space line can fire
        #expect(PreflightDiskRule.judge(volume(free: 50 * Self.gb - 1, total: total), catalogBytes: 0, thresholds: limits).0 == .warn)
        #expect(PreflightDiskRule.judge(volume(free: 50 * Self.gb, total: total), catalogBytes: 0, thresholds: limits).0 == .ok)
    }

    @Test func redFloor20GBPlusMinusOneByte() {
        let total = 300 * Self.gb   // 20 GB free is 93.3% used
        #expect(PreflightDiskRule.judge(volume(free: 20 * Self.gb - 1, total: total), catalogBytes: 0, thresholds: limits).0 == .red)
        #expect(PreflightDiskRule.judge(volume(free: 20 * Self.gb, total: total), catalogBytes: 0, thresholds: limits).0 == .warn)
    }

    @Test func redCatalogFloorPlusMinusOneByte() {
        // catalog + WAL = 10 GB → red below 30 GB. 400 GB disk: 30 GB free is 92.5% used (warn, not red).
        let catalog: UInt64 = 10_000_000_000
        let total = 400 * Self.gb
        #expect(PreflightDiskRule.judge(volume(free: 30 * Self.gb - 1, total: total), catalogBytes: catalog, thresholds: limits).0 == .red)
        #expect(PreflightDiskRule.judge(volume(free: 30 * Self.gb, total: total), catalogBytes: catalog, thresholds: limits).0 == .warn)
    }

    @Test func zeroByteVolumeIsRedAndHoldsEdits() {
        let empty = volume(free: 0, total: 0)
        #expect(empty.usedFraction == 1)
        #expect(PreflightDiskRule.judge(empty, catalogBytes: 0, thresholds: limits).0 == .red)
        #expect(PreflightGate.hold(catalogVolume: empty, catalogBytes: 0) == .edits)
        #expect(PreflightGate.decide(.edit, catalogVolume: empty, catalogBytes: 0) != .go)
    }

    @Test func negativeOrOverfullReadingsNeverCrash() {
        // A confused filesystem: more free than total, or negative free.
        #expect(volume(free: 2 * Self.tb, total: Self.tb).usedFraction == 0)
        #expect(volume(free: -5, total: Self.tb).usedFraction == 1)
    }

    // MARK: The hard edit floor: 2 × (catalog + WAL), never under 1 GB

    @Test func editFloorPlusMinusOneByte() {
        // catalog + WAL = 15 GB → edit floor 30 GB; red floor 45 GB.
        // 500 GB disk: 45 GB free is 91% used, 30 GB is 94% — percent stays out of red.
        let catalog: UInt64 = 15_000_000_000
        let total = 500 * Self.gb
        #expect(limits.editHoldFreeBytes(catalogBytes: catalog) == 30 * Self.gb)
        let below = volume(free: 30 * Self.gb - 1, total: total)
        let at = volume(free: 30 * Self.gb, total: total)
        #expect(PreflightGate.hold(catalogVolume: below, catalogBytes: catalog) == .edits)
        #expect(PreflightGate.hold(catalogVolume: at, catalogBytes: catalog) == .longOperations)
        #expect(PreflightGate.decide(.edit, catalogVolume: below, catalogBytes: catalog) != .go)
        #expect(PreflightGate.decide(.edit, catalogVolume: at, catalogBytes: catalog) == .go)
        // And the red line above it: 45 GB ± 1 byte.
        #expect(PreflightGate.hold(catalogVolume: volume(free: 45 * Self.gb - 1, total: total), catalogBytes: catalog) == .longOperations)
        #expect(PreflightGate.hold(catalogVolume: volume(free: 45 * Self.gb, total: total), catalogBytes: catalog) == .none)
    }

    @Test func editFloorNeverUnder1GB() {
        #expect(limits.editHoldFreeBytes(catalogBytes: 0) == Self.gb)
        #expect(limits.editHoldFreeBytes(catalogBytes: 100_000_000) == Self.gb)
        #expect(PreflightGate.hold(catalogVolume: volume(free: Self.gb - 1, total: Self.tb), catalogBytes: 0) == .edits)
    }

    @Test func heldEditSaysHowMuchToFreeRoundedUp() {
        let catalog: UInt64 = 15_000_000_000
        let verdict = PreflightGate.decide(.edit, catalogVolume: volume(free: 27_500_000_000, total: 10 * Self.tb),
                                           catalogBytes: catalog)
        guard case .refused(let words, _, let short) = verdict else {
            Issue.record("expected a held edit, got \(verdict)")
            return
        }
        #expect(short == 2_500_000_000)
        #expect(words == "Saving changes is on hold: Macintosh HD has only 28 GB free — free at least 2.5 GB more first")
    }

    @Test func hugeWALClampsInsteadOfOverflowing() {
        #expect(limits.diskRedFreeBytes(catalogBytes: .max) == .max)
        #expect(limits.editHoldFreeBytes(catalogBytes: .max) == .max)
        let big = volume(free: 900 * Self.tb, total: 1_000 * Self.tb)
        #expect(PreflightGate.hold(catalogVolume: big, catalogBytes: .max) == .edits)
        #expect(PreflightGate.decide(.backup, catalogVolume: big, catalogBytes: .max) != .go)
    }

    // MARK: Red holds long operations, not editing (ruling b)

    @Test func redDiskRefusesLongOperationsButNotEdits() {
        let red = volume(free: 50 * Self.gb, total: Self.tb)   // exactly 95%
        let catalog: UInt64 = 275_000_000
        #expect(PreflightGate.decide(.edit, catalogVolume: red, catalogBytes: catalog) == .go)
        for operation in [PreflightOperation.backup, .viewerPublish, .longJob(name: "Transcode", estimatedBytes: 1)] {
            guard case .refused(let words, let detail, let short) = PreflightGate.decide(operation, catalogVolume: red,
                                                                                          catalogBytes: catalog) else {
                Issue.record("\(operation) started on a red disk")
                continue
            }
            #expect(short == 1, "one byte more free takes 1 TB at exactly 95% out of red")
            #expect(words.contains("can't start"))
            #expect(detail.contains("red"))
        }
    }

    // MARK: Sized to the operation

    @Test func longJobMustFitAndLeaveTheRedFloorBehind() {
        // 1 TB disk, 200 GB free (80%): a small catalog's red floor is 20 GB.
        let disk = volume(free: 200 * Self.gb, total: Self.tb)
        let catalog: UInt64 = 275_000_000
        #expect(PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: 180 * Self.gb),
                                     catalogVolume: disk, catalogBytes: catalog) == .go)
        let verdict = PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: 180 * Self.gb + 1),
                                           catalogVolume: disk, catalogBytes: catalog)
        guard case .refused(let words, _, let short) = verdict else {
            Issue.record("expected refused, got \(verdict)")
            return
        }
        #expect(short == 1)
        #expect(words.hasPrefix("Transcode can't start: Macintosh HD has only 200 GB free"))
    }

    @Test func backupAndPublishNeedOneCatalog() {
        let catalog: UInt64 = 5_000_000_000
        // Red floor = max(20 GB, 15 GB) = 20 GB; a backup needs 5 GB + 20 GB = 25 GB.
        let total = 300 * Self.gb
        // 25 GB free is 91.7% used: warn, not red — the size rule decides.
        #expect(PreflightGate.decide(.backup, catalogVolume: volume(free: 25 * Self.gb, total: total), catalogBytes: catalog) == .go)
        #expect(PreflightGate.decide(.viewerPublish, catalogVolume: volume(free: 25 * Self.gb, total: total), catalogBytes: catalog) == .go)
        #expect(PreflightGate.decide(.backup, catalogVolume: volume(free: 25 * Self.gb - 1, total: total), catalogBytes: catalog) != .go)
    }

    @Test func otherDestinationNeedsNoCatalogReserve() {
        let catalog: UInt64 = 5_000_000_000
        let home = volume(free: 400 * Self.gb, total: Self.tb)
        let backupDrive = volume(free: 5 * Self.gb, total: 100 * Self.gb, id: "/Volumes/Backup", name: "Backup")
        #expect(PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: catalog, destination: backupDrive) == .go)
        let tooSmall = volume(free: 5 * Self.gb - 1, total: 100 * Self.gb, id: "/Volumes/Backup", name: "Backup")
        guard case .refused(let words, _, let short) = PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: catalog,
                                                                            destination: tooSmall) else {
            Issue.record("a backup that doesn't fit started")
            return
        }
        #expect(short == 1)
        #expect(words.contains("Backup has only"))
    }

    @Test func unreadableDiskNeverHoldsEditsButRefusesLongOperations() {
        #expect(PreflightGate.decide(.edit, catalogVolume: nil, catalogBytes: 0) == .go)
        #expect(PreflightGate.hold(catalogVolume: nil, catalogBytes: 0) == .none)
        guard case .refused(let words, _, _) = PreflightGate.decide(.backup, catalogVolume: nil, catalogBytes: 0) else {
            Issue.record("a backup started blind")
            return
        }
        #expect(words.contains("couldn't check how much free space"))
    }

    @Test func negativeJobEstimateCountsAsZero() {
        #expect(PreflightOperation.longJob(name: "x", estimatedBytes: -5).bytesNeeded(catalogBytes: 0) == 0)
    }

    // MARK: Launch report: the hard floor in words

    @Test func launchReportBelowEditFloorSaysEditsAreHeld() async {
        var probe = FakePreflightProbe.healthy().disk(free: 0.5, of: 10_000)   // 500 MB free, floor 1 GB
        probe.files[LaunchPreflightTests.context.walURL.path] = 0
        let report = await LaunchPreflight.run(LaunchPreflightTests.context, probe: probe)
        #expect(report.hold == .edits)
        let disk = report.checks.first { $0.id == .systemDisk }
        #expect(disk?.level == .red)
        #expect(disk?.words == "Your Mac's main disk is too full to save changes safely — free at least 0.5 GB more; "
                + "your edits are on hold until then")
        #expect(report.outcomeLine.contains("hold edits"))
    }

    @Test func launchReportHugeWALIsWarnAndHoldsEdits() async {
        var probe = FakePreflightProbe.healthy()
        probe.files[LaunchPreflightTests.context.walURL.path] = .max
        let report = await LaunchPreflight.run(LaunchPreflightTests.context, probe: probe)
        #expect(report.checks.first { $0.id == .catalogJournal }?.level == .warn)
        #expect(report.hold == .edits, "a WAL bigger than any disk: no room to checkpoint it")
        #expect(report.level == .red)
    }

    // MARK: Cost of each real probe question (Rick: "if it is expensive, tell me")

    @Test func eachRealProbeQuestionIsCheap() throws {
        let probe = SystemPreflightProbe()
        let loadBefore = TimingBudget.sampleLoad()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let clock = ContinuousClock()
        let questions: [(String, () -> Void)] = [
            ("volume", { _ = try? probe.volume(containing: home) }),
            ("mounted", { _ = probe.isVolumeMounted(at: URL(fileURLWithPath: "/Volumes/NoSuchDisk")) }),
            ("memory", { _ = probe.physicalMemoryBytes() }),
            ("swap", { _ = try? probe.swapUsedBytes() }),
            ("thermal", { _ = probe.thermalState() }),
            ("power", { _ = probe.powerSource() }),
            ("fileSize", { _ = probe.fileSize(at: home) }),
            ("writable", { _ = probe.isWritableFolder(at: home) }),
            ("tools", { _ = PreflightTool.allCases.map(probe.executablePath(for:)) }),
        ]
        var lines: [String] = []
        for (name, ask) in questions {
            ask()   // first call pays any one-time setup
            let rounds = 20
            let start = clock.now
            for _ in 0..<rounds { ask() }
            let each = (clock.now - start) / rounds
            lines.append("\(name)=\(String(format: "%.3f", TimingBudget.seconds(each) * 1_000)) ms")
            // 20 ms each would already be "expensive" for a 10-minute re-check.
            // Judged the house way (GH #208): strict when quiet, known issue up to 3× when busy.
            expectWithinTimingBudget("preflight probe question \(name)", measured: each,
                                     budget: .milliseconds(20), loadBefore: loadBefore)
        }
        print("[preflight-cost] per question: " + lines.joined(separator: ", "))
    }
}
