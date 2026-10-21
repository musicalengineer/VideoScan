// PreflightGateTests.swift
// What the preflight may stop (Rick's rulings, 2026-10-21, and QA r1), at
// every edge, to the byte: exactly at 90% / 95%, each floor ± 1 byte, a
// 0-byte volume, an unreadable volume or destination, a huge WAL, a red
// catalog check, and each operation sized to its need — the WHOLE shortfall,
// with the disk left out of red by BOTH halves of the red line.
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

    private func shortfall(_ verdict: PreflightGateVerdict) -> Int64? {
        if case .refused(_, _, let short) = verdict { return short }
        return nil
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

    @Test func leastFreeOutOfRedIsExactToTheByte() {
        // 1 TB at exactly 95% is red; one byte more free is not.
        let disk = volume(free: 0, total: Self.tb)
        let line = limits.leastFreeOutOfRed(disk, catalogBytes: 0)
        #expect(line == 50 * Self.gb + 1)
        #expect(PreflightDiskRule.judge(volume(free: line, total: Self.tb), catalogBytes: 0, thresholds: limits).0 != .red)
        #expect(PreflightDiskRule.judge(volume(free: line - 1, total: Self.tb), catalogBytes: 0, thresholds: limits).0 == .red)
        // A small disk: the byte floor (20 GB) is the higher half.
        #expect(limits.leastFreeOutOfRed(volume(free: 0, total: 100 * Self.gb), catalogBytes: 0) == 20 * Self.gb)
    }

    @Test func zeroByteVolumeIsUnmeasurableNeverHoldsEditsButRefusesLongOperations() {
        let empty = volume(free: 0, total: 0)
        #expect(!empty.isMeasurable)
        #expect(empty.usedFraction == 1)
        #expect(PreflightGate.hold(catalogVolume: empty, catalogBytes: 0) == .none)
        #expect(PreflightGate.decide(.edit, catalogVolume: empty, catalogBytes: 0) == .go)
        #expect(PreflightGate.decide(.backup, catalogVolume: empty, catalogBytes: 0) != .go)
    }

    @Test func negativeOrOverfullReadingsNeverCrashOrOverflow() {
        // A confused filesystem: more free than total, or negative free.
        #expect(volume(free: 2 * Self.tb, total: Self.tb).usedFraction == 0)
        #expect(volume(free: 2 * Self.tb, total: Self.tb).freeBytes == Self.tb)
        #expect(volume(free: -5, total: Self.tb).usedFraction == 1)
        #expect(volume(free: .min, total: Self.tb).freeBytes == 0)
        let negative = volume(free: .min, total: Self.tb)
        #expect(PreflightGate.hold(catalogVolume: negative, catalogBytes: .max) == .edits)
        #expect(shortfall(PreflightGate.decide(.edit, catalogVolume: negative, catalogBytes: .max)) == .max)
        #expect(shortfall(PreflightGate.decide(.longJob(name: "x", estimatedBytes: .max), catalogVolume: negative,
                                               catalogBytes: 0)) == .max)
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
        #expect(shortfall(PreflightGate.decide(.edit, catalogVolume: below, catalogBytes: catalog)) == 1)
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

    // MARK: Red disk holds long operations, not editing (ruling b), with the WHOLE shortfall

    @Test func redDiskRefusesLongOperationsButNotEdits() {
        let red = volume(free: 50 * Self.gb, total: Self.tb)   // exactly 95%
        let catalog: UInt64 = 275_000_000
        #expect(PreflightGate.decide(.edit, catalogVolume: red, catalogBytes: catalog) == .go)
        let operations: [(PreflightOperation, Int64)] = [
            (.backup, 275_000_000), (.viewerPublish, 275_000_000), (.longJob(name: "Transcode", estimatedBytes: 1), 1),
        ]
        for (operation, need) in operations {
            guard case .refused(let words, _, let short) = PreflightGate.decide(operation, catalogVolume: red,
                                                                                 catalogBytes: catalog) else {
                Issue.record("\(operation) started on a red disk")
                continue
            }
            // To start, it must fit AND leave the disk one byte out of red.
            #expect(short == need + 1, "\(operation): short \(short)")
            #expect(words.contains("can't start"))
        }
    }

    @Test func freeingTheStatedShortfallLetsTheOperationStart() {
        // The refusal never lies: free exactly `short` more and it goes.
        let catalog: UInt64 = 275_000_000
        for free in [40 * Self.gb, 50 * Self.gb, 120 * Self.gb, 199 * Self.gb] {
            let disk = volume(free: free, total: Self.tb)
            let job = PreflightOperation.longJob(name: "Transcode", estimatedBytes: 100 * Self.gb)
            guard let short = shortfall(PreflightGate.decide(job, catalogVolume: disk, catalogBytes: catalog)) else { continue }
            let freed = volume(free: free + short, total: Self.tb)
            #expect(PreflightGate.decide(job, catalogVolume: freed, catalogBytes: catalog) == .go, "free \(free)")
            let almost = volume(free: free + short - 1, total: Self.tb)
            #expect(PreflightGate.decide(job, catalogVolume: almost, catalogBytes: catalog) != .go, "free \(free)")
        }
    }

    // MARK: Sized to the operation

    @Test func longJobMustFitAndLeaveTheDiskOutOfRed() {
        // 1 TB disk, 200 GB free (80%): out of red needs 50 GB + 1 byte left (the percent half).
        let disk = volume(free: 200 * Self.gb, total: Self.tb)
        let catalog: UInt64 = 275_000_000
        let fits = 150 * Self.gb - 1
        #expect(PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: fits),
                                     catalogVolume: disk, catalogBytes: catalog) == .go)
        let verdict = PreflightGate.decide(.longJob(name: "Transcode", estimatedBytes: fits + 1),
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
        // 300 GB disk: out of red needs max(15 GB + 1, 20 GB) = 20 GB left; a backup needs 5 GB + 20 GB.
        let total = 300 * Self.gb
        #expect(PreflightGate.decide(.backup, catalogVolume: volume(free: 25 * Self.gb, total: total), catalogBytes: catalog) == .go)
        #expect(PreflightGate.decide(.viewerPublish, catalogVolume: volume(free: 25 * Self.gb, total: total), catalogBytes: catalog) == .go)
        #expect(shortfall(PreflightGate.decide(.backup, catalogVolume: volume(free: 25 * Self.gb - 1, total: total),
                                               catalogBytes: catalog)) == 1)
    }

    // MARK: Destinations (QA r1 minor 1)

    @Test func otherDestinationNeedsNoCatalogReserve() {
        let catalog: UInt64 = 5_000_000_000
        let home = volume(free: 400 * Self.gb, total: Self.tb)
        let backupDrive = volume(free: 5 * Self.gb, total: 100 * Self.gb, id: "/Volumes/Backup", name: "Backup")
        #expect(PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: catalog,
                                     destination: .volume(backupDrive)) == .go)
        let tooSmall = volume(free: 5 * Self.gb - 1, total: 100 * Self.gb, id: "/Volumes/Backup", name: "Backup")
        guard case .refused(let words, _, let short) = PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: catalog,
                                                                            destination: .volume(tooSmall)) else {
            Issue.record("a backup that doesn't fit started")
            return
        }
        #expect(short == 1)
        #expect(words.contains("Backup has only"))
    }

    @Test func destinationThatIsTheCatalogDiskGetsTheCatalogReserve() {
        let home = volume(free: 200 * Self.gb, total: Self.tb)
        let job = PreflightOperation.longJob(name: "Transcode", estimatedBytes: 150 * Self.gb)
        #expect(PreflightGate.decide(job, catalogVolume: home, catalogBytes: 0, destination: .volume(home))
                == PreflightGate.decide(job, catalogVolume: home, catalogBytes: 0, destination: .catalogDisk))
        #expect(PreflightGate.decide(job, catalogVolume: home, catalogBytes: 0, destination: .volume(home)) != .go)
    }

    @Test func unreadableDestinationRefusesLongOperations() {
        let home = volume(free: 400 * Self.gb, total: Self.tb)
        guard case .refused(let words, _, _) = PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: 0,
                                                                    destination: .unreadable) else {
            Issue.record("a backup started to a disk nobody could read")
            return
        }
        #expect(words.contains("couldn't check how much free space the disk it writes to has"))
        let noSize = volume(free: 0, total: 0, id: "/Volumes/Odd", name: "Odd")
        #expect(PreflightGate.decide(.backup, catalogVolume: home, catalogBytes: 0, destination: .volume(noSize)) != .go)
        #expect(PreflightGate.decide(.edit, catalogVolume: home, catalogBytes: 0, destination: .unreadable) == .go,
                "edits write the catalog disk, never the destination")
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

    // MARK: A red catalog check holds everything, with its words (QA r1 M3)

    @Test func catalogFaultRefusesEditsAndLongOperationsWithTheChecksWords() {
        let fault = PreflightCheck(.catalogQuickCheck, .red,
                                   words: "The catalog failed its health check — please don't edit until it's sorted out",
                                   detail: "quick_check: Page 7 …")
        let situation = PreflightSituation(catalogVolume: volume(free: 500 * Self.gb, total: Self.tb),
                                           catalogBytes: 275_000_000, catalogFault: fault)
        #expect(PreflightGate.hold(situation) == .edits)
        #expect(PreflightGate.decide(.edit, in: situation)
                == .refused(words: fault.words, detail: "catalog check catalog-quick-check is red: quick_check: Page 7 …",
                            shortBytes: 0))
        guard case .refused(let words, _, _) = PreflightGate.decide(.backup, in: situation) else {
            Issue.record("a backup started on a damaged catalog")
            return
        }
        #expect(words == "The catalog backup can't start: " + fault.words)
    }

    @Test func onlyRedCatalogChecksAreFaults() {
        let checks = [
            PreflightCheck(.systemDisk, .red, words: "disk", detail: ""),
            PreflightCheck(.catalogSchema, .warn, words: "older", detail: ""),
            PreflightCheck(.catalogQuickCheck, .warn, words: "ran out of time", detail: ""),
            PreflightCheck(.tools, .warn, words: "tools", detail: ""),
        ]
        #expect(PreflightSituation.catalogFault(in: checks) == nil, "a red disk or a catalog warn is not a catalog fault")
        let switched = PreflightCheck(.catalogSwitched, .red, words: "marker", detail: "")
        #expect(PreflightSituation.catalogFault(in: checks + [switched])?.id == .catalogSwitched)
    }

    @Test func aWALThatGrewDuringTheSessionRaisesTheEditFloor() {
        // Launch: 275 MB catalog → edit floor 1 GB; 5 GB free on a big disk edits fine.
        let disk = volume(free: 5 * Self.gb, total: 100 * Self.tb)
        let launch = PreflightSituation(catalogVolume: disk, catalogBytes: 275_000_000)
        #expect(PreflightGate.decide(.edit, in: launch) == .go)
        // Ten minutes later the WAL is 3 GB: floor 2 × 3.275 GB = 6.55 GB.
        let grown = launch.with(catalogVolume: disk, catalogBytes: 275_000_000 + 3_000_000_000)
        #expect(limits.editHoldFreeBytes(catalogBytes: grown.catalogBytes) == 6_550_000_000)
        #expect(shortfall(PreflightGate.decide(.edit, in: grown)) == 1_550_000_000)
        #expect(PreflightGate.hold(grown) == .edits)
        // The disk-only refresh keeps the stale size — and so understates the floor.
        #expect(PreflightGate.decide(.edit, in: launch.with(catalogVolume: disk)) == .go)
        // A backup's need grows with it too.
        let roomy = volume(free: 30 * Self.gb, total: 300 * Self.gb)
        #expect(PreflightGate.decide(.backup, in: launch.with(catalogVolume: roomy, catalogBytes: 275_000_000)) == .go)
        #expect(shortfall(PreflightGate.decide(.backup, in: launch.with(catalogVolume: roomy,
                                                                         catalogBytes: 10_000_000_000))) == 10 * Self.gb)
    }

    @Test func freshDiskReadingKeepsTheCatalogFault() {
        let fault = PreflightCheck(.catalogSwitched, .red, words: "marker", detail: "")
        let situation = PreflightSituation(catalogVolume: nil, catalogBytes: 1, catalogFault: fault)
        let fresh = situation.with(catalogVolume: volume(free: 500 * Self.gb, total: Self.tb))
        #expect(fresh.catalogFault == fault)
        #expect(fresh.catalogVolume?.freeBytes == 500 * Self.gb)
    }

    // MARK: Launch report: the hard floor in words

    @Test func launchReportBelowEditFloorSaysEditsAreHeld() async throws {
        var probe = FakePreflightProbe.healthy().disk(free: 0.5, of: 10_000)   // 500 MB free, floor 1 GB
        probe.files[LaunchPreflightTests.context.walURL.path] = 0
        let report = try await LaunchPreflight.run(LaunchPreflightTests.context, probe: probe)
        #expect(report.hold == .edits)
        let disk = report.checks.first { $0.id == .systemDisk }
        #expect(disk?.level == .red)
        #expect(disk?.words == "Your Mac's main disk is too full to save changes safely — free at least 0.5 GB more; "
                + "your edits are on hold until then")
        #expect(report.outcomeLine.contains("hold edits"))
    }

    @Test func launchReportHugeWALIsWarnAndHoldsEdits() async throws {
        var probe = FakePreflightProbe.healthy()
        probe.files[LaunchPreflightTests.context.walURL.path] = .max
        let report = try await LaunchPreflight.run(LaunchPreflightTests.context, probe: probe)
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
