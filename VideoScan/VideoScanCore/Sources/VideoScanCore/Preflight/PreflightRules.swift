// PreflightRules.swift (VideoScanCore/Preflight)
// One rule per check: ask the probe one question, turn the answer into one
// `PreflightCheck` with words for the person and detail for the log. The
// numbers are the named constants in `PreflightThresholds`.
//
// The "couldn't check" rule: a probe that throws or answers nil — or a disk
// that reports no size — gives a check at `PreflightThresholds.unknownLevel`:
// warn for the disks and the catalog (the things that guard data), note for
// the rest. Never ok: a broken probe must not read as a green light.
//
// (For Rick: `Result<T, E>` ≈ std::expected<T, E>; a generic struct over
// `Probe: PreflightProbe` ≈ a template constrained to the interface — static
// dispatch, no vtable.)

import Foundation

/// What a probe question gave: the answer, or why there isn't one.
typealias PreflightAnswer<T> = Result<T, PreflightGap>

struct PreflightGap: Error {
    let why: String
}

struct PreflightRules<Probe: PreflightProbe> {
    let context: PreflightContext
    let probe: Probe
    /// The catalog's disk, asked ONCE per run: the capacity read is the one
    /// costly probe question (≈ 7–20 ms — macOS totals purgeable space), and
    /// the disk check, the hold and the gate all need it.
    let system: PreflightAnswer<PreflightVolume>

    init(context: PreflightContext, probe: Probe) {
        self.context = context
        self.probe = probe
        self.system = Self.askVolume(probe, containing: context.supportFolder)
    }

    private var limits: PreflightThresholds { context.thresholds }

    /// Ask the probe; a throw or a nil becomes a gap with the reason.
    private static func ask<T>(_ question: () throws -> T?) -> PreflightAnswer<T> {
        do {
            guard let value = try question() else { return .failure(PreflightGap(why: "the Mac gave no answer")) }
            return .success(value)
        } catch {
            return .failure(PreflightGap(why: String(describing: error)))
        }
    }

    private func ask<T>(_ question: () throws -> T?) -> PreflightAnswer<T> { Self.ask(question) }

    /// A volume that reports no size is a gap, not "100% full" (QA r1 nit).
    private static func askVolume(_ probe: Probe, containing url: URL) -> PreflightAnswer<PreflightVolume> {
        ask { try probe.volume(containing: url) }.flatMap { volume in
            volume.isMeasurable ? .success(volume)
                : .failure(PreflightGap(why: "\(volume.name) reported a size of \(volume.totalBytes) bytes"))
        }
    }

    private func unknown(_ id: PreflightCheck.ID, _ what: String, _ gap: PreflightGap) -> PreflightCheck {
        PreflightCheck(id, PreflightThresholds.unknownLevel(for: id),
                       words: "Couldn't check \(what)",
                       detail: "probe failed: \(gap.why)")
    }

    // MARK: Disks

    /// catalog.sqlite + its WAL, in bytes (0 for a missing file).
    func catalogBytes() -> UInt64 {
        let (sum, overflow) = (probe.fileSize(at: context.databaseURL) ?? 0)
            .addingReportingOverflow(probe.fileSize(at: context.walURL) ?? 0)
        return overflow ? .max : sum
    }

    /// The disk holding the catalog, or nil when it couldn't be read.
    func systemVolume() -> PreflightVolume? {
        try? system.get()
    }

    /// The system disk, then the temp disk when it is a different volume.
    func diskChecks() -> [PreflightCheck] {
        let catalogBytes = catalogBytes()
        var checks = [disk(.systemDisk, system, label: "Your Mac's main disk",
                           unknownWhat: "how full your Mac's main disk is",
                           folder: context.supportFolder, catalogBytes: catalogBytes)]
        let temp = Self.askVolume(probe, containing: context.temporaryFolder)
        if case .success(let tempVolume) = temp, case .success(let systemVolume) = system,
           tempVolume.id == systemVolume.id {
            return checks   // same volume: one check covers both
        }
        let tempLabel = "The disk for temporary files" + ((try? temp.get()).map { " (\($0.name))" } ?? "")
        checks.append(disk(.tempDisk, temp, label: tempLabel,
                           unknownWhat: "how full the temporary-files disk is",
                           folder: context.temporaryFolder, catalogBytes: catalogBytes))
        return checks
    }

    private func disk(_ id: PreflightCheck.ID, _ answer: PreflightAnswer<PreflightVolume>, label: String,
                      unknownWhat: String, folder: URL, catalogBytes: UInt64) -> PreflightCheck {
        let volume: PreflightVolume
        switch answer {
        case .failure(let gap): return unknown(id, unknownWhat, gap)
        case .success(let found): volume = found
        }
        let (level, reason) = PreflightDiskRule.judge(volume, catalogBytes: catalogBytes, thresholds: limits)
        let free = volume.freeBytes
        let editFloor = limits.editHoldFreeBytes(catalogBytes: catalogBytes)
        var readings = [
            PreflightReading("free", Double(free), .bytes),
            PreflightReading("total", Double(volume.totalBytes), .bytes),
            PreflightReading("used", volume.usedFraction, .fraction),
            PreflightReading("redBelow", Double(limits.diskRedFreeBytes(catalogBytes: catalogBytes)), .bytes),
            PreflightReading("editHoldBelow", Double(editFloor), .bytes),
            PreflightReading("catalog", Double(catalogBytes), .bytes),
        ]
        if let purgeable = volume.freeIncludingPurgeableBytes {
            readings.append(PreflightReading("freeIncludingPurgeable", Double(purgeable), .bytes))
        }
        let detail = "\(volume.name) (\(volume.id)) holding \(folder.path): \(reason)"
        if id == .systemDisk, free < editFloor {
            // The hard floor: the person's edits are held, so say exactly that.
            let more = PreflightWords.gigabytesRoundedUp(editFloor - free)
            return PreflightCheck(id, .red,
                                  words: "\(label) is too full to save changes safely — free at least \(more) more; "
                                      + "your edits are on hold until then",
                                  detail: detail + "; below the edit floor \(PreflightWords.gigabytes(editFloor))",
                                  readings: readings)
        }
        return PreflightCheck(id, level, words: diskWords(label, level, reason, volume), detail: detail,
                              readings: readings)
    }

    private func diskWords(_ label: String, _ level: PreflightLevel, _ reason: PreflightDiskRule.Reason,
                           _ volume: PreflightVolume) -> String {
        let state: String
        switch reason {
        case .fine: return "\(label) has \(PreflightWords.gigabytes(volume.freeBytes)) free"
        case .percentFull(let used): state = "is \(PreflightWords.percent(used)) full"
        case .lowFree(let free): state = "has only \(PreflightWords.gigabytes(free)) free"
        }
        // Red holds long jobs, backups and viewer publishes — not editing
        // (Rick's ruling (b), 2026-10-21).
        let advice = level == .red ? "free some space; long jobs, backups and copies to other Macs wait until you do"
                                   : "consider freeing some space soon"
        return "\(label) \(state) — \(advice)"
    }

    // MARK: Memory

    func memory() -> PreflightCheck {
        switch ask({ probe.physicalMemoryBytes() }) {
        case .failure(let gap):
            return unknown(.memory, "how much memory this Mac has", gap)
        case .success(let bytes):
            let gb = "\(bytes / PreflightThresholds.gibibyte) GB"
            let readings = [PreflightReading("physical", Double(bytes), .bytes)]
            guard bytes < limits.memoryWarnBelowBytes else {
                return PreflightCheck(.memory, .ok, words: "\(gb) of memory", detail: "physical memory \(gb)",
                                      readings: readings)
            }
            return PreflightCheck(.memory, .warn,
                                  words: "This Mac has \(gb) of memory — big jobs may be slow",
                                  detail: "physical memory \(gb) < \(limits.memoryWarnBelowBytes / PreflightThresholds.gibibyte) GB",
                                  readings: readings)
        }
    }

    func swap() -> PreflightCheck {
        switch ask({ try probe.swapUsedBytes() }) {
        case .failure(let gap):
            return unknown(.swap, "how much swap is in use", gap)
        case .success(let bytes):
            let readings = [PreflightReading("swapUsed", Double(bytes), .bytes)]
            guard bytes > limits.swapNoteAboveBytes else {
                return PreflightCheck(.swap, .ok, words: "Memory is not under pressure",
                                      detail: "swap in use \(PreflightWords.gigabytes(bytes))", readings: readings)
            }
            return PreflightCheck(.swap, .note,
                                  words: "Your Mac is short of memory (\(PreflightWords.gigabytes(bytes)) of swap in use) — "
                                      + "if things feel slow, quit other apps",
                                  detail: "swap in use \(PreflightWords.gigabytes(bytes)) > "
                                      + "\(PreflightWords.gigabytes(limits.swapNoteAboveBytes)); check MLX helpers",
                                  readings: readings)
        }
    }

    // MARK: Catalog

    func catalogChecks() -> [PreflightCheck] {
        [catalogSwitched(), catalogSchema(), catalogJournal()]
    }

    func catalogSwitched() -> PreflightCheck {
        let database = context.databaseURL
        guard probe.fileExists(at: database) else {
            return PreflightCheck(.catalogSwitched, .red,
                                  words: "VideoScan can't find its catalog — please don't edit until it's sorted out",
                                  detail: "no \(database.lastPathComponent) at \(database.path)")
        }
        guard probe.fileExists(at: context.latchURL) else {
            return PreflightCheck(.catalogSwitched, .red,
                                  words: "VideoScan can't confirm this catalog is the current one — please don't edit until it's sorted out",
                                  detail: "\(SQLiteCatalogReader.latchFileName) missing beside \(database.path) (#354: refuse loudly)")
        }
        return PreflightCheck(.catalogSwitched, .ok, words: "The catalog is in place",
                              detail: "\(database.lastPathComponent) and \(SQLiteCatalogReader.latchFileName) present")
    }

    func catalogSchema() -> PreflightCheck {
        let expected = context.expectedSchemaVersion
        let found: Int
        switch ask({ try probe.catalogSchemaVersion(at: context.databaseURL) }) {
        case .failure(let gap): return unknown(.catalogSchema, "the catalog's version", gap)
        case .success(let version): found = version
        }
        let readings = [PreflightReading("found", Double(found), .version),
                        PreflightReading("expected", Double(expected), .version)]
        let detail = "schema_version \(found), this build expects \(expected)"
        if found == expected {
            return PreflightCheck(.catalogSchema, .ok, words: "The catalog is up to date", detail: detail, readings: readings)
        }
        if found > expected {
            return PreflightCheck(.catalogSchema, .red,
                                  words: "This catalog was saved by a newer VideoScan — update the app before editing",
                                  detail: detail, readings: readings)
        }
        return PreflightCheck(.catalogSchema, .warn,
                              words: "The catalog wasn't brought up to date when it opened — please mention this before editing",
                              detail: detail + " (open should have migrated it)", readings: readings)
    }

    func catalogJournal() -> PreflightCheck {
        let bytes = probe.fileSize(at: context.walURL) ?? 0   // no WAL file = an empty journal
        let readings = [PreflightReading("wal", Double(bytes), .bytes)]
        guard bytes > limits.journalWarnAboveBytes else {
            return PreflightCheck(.catalogJournal, .ok, words: "The catalog's change journal is small",
                                  detail: "WAL \(PreflightWords.gigabytes(bytes))", readings: readings)
        }
        return PreflightCheck(.catalogJournal, .warn,
                              words: "The catalog's change journal has grown large (\(PreflightWords.gigabytes(bytes))) — "
                                  + "quitting and reopening VideoScan usually clears it",
                              detail: "WAL \(bytes) bytes > \(limits.journalWarnAboveBytes): checkpoint starvation?",
                              readings: readings)
    }

    func quickCheck(cancellation: PreflightCancellation) -> PreflightCheck {
        let budget = context.quickCheckBudget
        switch ask({ try probe.catalogQuickCheck(at: context.databaseURL, budget: budget, cancellation: cancellation) }) {
        case .failure(let gap):
            return unknown(.catalogQuickCheck, "the catalog's health", gap)
        case .success(.passed(let elapsed)):
            return PreflightCheck(.catalogQuickCheck, .ok, words: "The catalog passed its quick health check",
                                  detail: "quick_check ok in \(PreflightWords.milliseconds(elapsed))",
                                  readings: [milliseconds("elapsed", elapsed)])
        case .success(.problems(let lines, let elapsed)):
            return PreflightCheck(.catalogQuickCheck, .red,
                                  words: "The catalog failed its health check — please don't edit until it's sorted out",
                                  detail: "quick_check: \(lines.joined(separator: "; "))",
                                  readings: [milliseconds("elapsed", elapsed),
                                             PreflightReading("problems", Double(lines.count), .count)])
        case .success(.ranOutOfTime(let budget)):
            // WARN, not a note (QA r1 minor 2): no verdict is never a quiet green.
            return PreflightCheck(.catalogQuickCheck, .warn,
                                  words: "The catalog's quick health check didn't finish in time — run Validate Catalog for the full check",
                                  detail: "quick_check interrupted at its \(PreflightWords.milliseconds(budget)) budget",
                                  readings: [milliseconds("budget", budget)])
        case .success(.cancelled):
            return PreflightCheck(.catalogQuickCheck, .warn,
                                  words: "The catalog's quick health check was stopped before it finished",
                                  detail: "quick_check cancelled")
        }
    }

    private func milliseconds(_ name: String, _ duration: Duration) -> PreflightReading {
        PreflightReading(name, TimingBudget.seconds(duration) * 1_000, .milliseconds)
    }

    // MARK: Tools, logs, machine

    func tools() -> PreflightCheck {
        let found = PreflightTool.allCases.map { ($0, probe.executablePath(for: $0)) }
        let missing = found.filter { $0.1 == nil }.map(\.0.rawValue)
        let paths = found.map { "\($0.0.rawValue)=\($0.1 ?? "missing")" }.joined(separator: ", ")
        guard missing.isEmpty else {
            return PreflightCheck(.tools, .warn,
                                  words: "VideoScan can't find its video tools (\(missing.joined(separator: " and "))) — "
                                      + "scanning and previews won't work",
                                  detail: paths)
        }
        return PreflightCheck(.tools, .ok, words: "Video tools found", detail: paths)
    }

    func logFolder() -> PreflightCheck {
        let folder = context.logFolder
        guard probe.isWritableFolder(at: folder) else {
            return PreflightCheck(.logFolder, .warn,
                                  words: "VideoScan can't write its log — if something goes wrong, there'll be no record",
                                  detail: "not writable: \(folder.path)")
        }
        return PreflightCheck(.logFolder, .ok, words: "The log is writable", detail: folder.path)
    }

    func thermal() -> PreflightCheck {
        switch ask({ probe.thermalState() }) {
        case .failure(let gap):
            return unknown(.thermal, "how warm the Mac is", gap)
        case .success(let state) where state == .serious || state == .critical:
            return PreflightCheck(.thermal, .warn,
                                  words: "Your Mac is running hot — long jobs will be slow; let it cool first",
                                  detail: "thermal state \(state.rawValue)")
        case .success(let state):
            return PreflightCheck(.thermal, .ok, words: "Temperature is normal", detail: "thermal state \(state.rawValue)")
        }
    }

    func power() -> PreflightCheck {
        switch ask({ probe.powerSource() }) {
        case .failure(let gap):
            return unknown(.power, "whether the Mac is plugged in", gap)
        case .success(.battery):
            return PreflightCheck(.power, .note, words: "Running on battery — plug in before starting long jobs",
                                  detail: "power source battery")
        case .success(.mains):
            return PreflightCheck(.power, .ok, words: "Plugged in", detail: "power source AC")
        }
    }

    func masterArchive() -> PreflightCheck {
        guard let volume = context.masterArchiveVolume else {
            return PreflightCheck(.masterArchive, .ok, words: "No Master Archive drive is set",
                                  detail: "no master archive configured")
        }
        guard probe.isVolumeMounted(at: volume) else {
            return PreflightCheck(.masterArchive, .note,
                                  words: "The Master Archive drive isn't connected — that's fine unless you're archiving today",
                                  detail: "not mounted: \(volume.path)")
        }
        return PreflightCheck(.masterArchive, .ok, words: "The Master Archive drive is connected", detail: volume.path)
    }
}
