//
//  DriveHealth.swift
//  VideoScan
//
//  Drive Health probe — pulls SMART data via `smartctl -a -j` and surfaces
//  a friendly recommendation alongside the manual Reliability/Trust field
//  in the Volumes editor. Rick has a fleet of aging external HDDs; this
//  exists so the retire/keep decision is informed by real numbers rather
//  than guesswork.
//
//  Architecture mirrors ToolLocator/ProcessRunner — no new dependencies,
//  reuses the same subprocess pattern, and stays a plain `actor` so it
//  can be lazily probed from the UI without main-thread blocking. The
//  Codable snapshot is the only surface area the views see.
//
//  Worst-case memory footprint: per-snapshot dictionary is bounded by
//  smartctl's JSON output (typically <50 KB raw, parsed into a struct of
//  ~30 fields). Session cache is keyed by devicePath and never holds the
//  raw JSON.
//

import Foundation

// MARK: - Public types

/// One probe result for one physical device. Always returned, even on
/// failure — the caller inspects `probeWarnings` + `recommendation` to
/// decide what to show.
struct DriveHealthSnapshot: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: String                       // devicePath ("/dev/diskN")
    let mountPath: String
    let devicePath: String
    let modelName: String?
    let serialNumber: String?
    let firmware: String?
    let capacityBytes: Int64?
    let protocolKind: ProtocolKind
    let mediaTech: DetectedMediaTech
    let smartStatus: SmartOverall
    let powerOnHours: Int?
    let reallocatedSectors: Int?
    let pendingSectors: Int?
    let offlineUncorrectable: Int?
    let reallocatedEvents: Int?
    let temperatureCelsius: Int?
    let ssdAvailableSpare: Int?          // %, NVMe only
    let ssdPercentageUsed: Int?          // %, NVMe only
    let ssdMediaErrors: Int?
    let dataWrittenBytes: Int64?
    let probedAt: Date
    let probeWarnings: [String]

    init(
        mountPath: String,
        devicePath: String,
        modelName: String? = nil,
        serialNumber: String? = nil,
        firmware: String? = nil,
        capacityBytes: Int64? = nil,
        protocolKind: ProtocolKind = .unknown,
        mediaTech: DetectedMediaTech = .unknown,
        smartStatus: SmartOverall = .unknown,
        powerOnHours: Int? = nil,
        reallocatedSectors: Int? = nil,
        pendingSectors: Int? = nil,
        offlineUncorrectable: Int? = nil,
        reallocatedEvents: Int? = nil,
        temperatureCelsius: Int? = nil,
        ssdAvailableSpare: Int? = nil,
        ssdPercentageUsed: Int? = nil,
        ssdMediaErrors: Int? = nil,
        dataWrittenBytes: Int64? = nil,
        probedAt: Date = Date(),
        probeWarnings: [String] = []
    ) {
        self.id = devicePath
        self.mountPath = mountPath
        self.devicePath = devicePath
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.firmware = firmware
        self.capacityBytes = capacityBytes
        self.protocolKind = protocolKind
        self.mediaTech = mediaTech
        self.smartStatus = smartStatus
        self.powerOnHours = powerOnHours
        self.reallocatedSectors = reallocatedSectors
        self.pendingSectors = pendingSectors
        self.offlineUncorrectable = offlineUncorrectable
        self.reallocatedEvents = reallocatedEvents
        self.temperatureCelsius = temperatureCelsius
        self.ssdAvailableSpare = ssdAvailableSpare
        self.ssdPercentageUsed = ssdPercentageUsed
        self.ssdMediaErrors = ssdMediaErrors
        self.dataWrittenBytes = dataWrittenBytes
        self.probedAt = probedAt
        self.probeWarnings = probeWarnings
    }
}

enum ProtocolKind: String, Codable, Sendable {
    case usb, sata, thunderbolt, nvmeInternal, nvmeExternal, unknown
}

enum DetectedMediaTech: String, Codable, Sendable {
    case hdd, ssd, nvme, unknown
}

enum SmartOverall: String, Codable, Sendable {
    case passed, failingNow, unknown, notSupported
}

/// Plain-English recommendation. `reason` is the line we put in front of
/// Rick — keep it in his voice, no SMART jargon. See
/// feedback_friendly_language.md.
enum DriveHealthRecommendation: Equatable, Sendable {
    case healthy(reason: String)
    case watch(reason: String)
    case planToRetire(reason: String)
    case retireNow(reason: String)

    var headline: String {
        switch self {
        case .healthy:      return "All good for now"
        case .watch:        return "Worth keeping an eye on"
        case .planToRetire: return "Plan to retire"
        case .retireNow:    return "Get the data off now"
        }
    }

    var sfSymbol: String {
        switch self {
        case .healthy:      return "checkmark.circle.fill"
        case .watch:        return "exclamationmark.triangle"
        case .planToRetire: return "exclamationmark.triangle.fill"
        case .retireNow:    return "xmark.octagon.fill"
        }
    }

    /// Bucket key used for an at-a-glance traffic light. Kept off the
    /// raw enum so the recommendation can carry its prose reason.
    var severityKey: String {
        switch self {
        case .healthy:      return "green"
        case .watch:        return "yellow"
        case .planToRetire: return "orange"
        case .retireNow:    return "red"
        }
    }

    var reasonText: String {
        switch self {
        case .healthy(let r), .watch(let r), .planToRetire(let r), .retireNow(let r):
            return r
        }
    }

    /// Map a recommendation onto Rick's existing Trust enum so the
    /// "Update Trust" affordance has something concrete to suggest.
    /// Nil means "no change recommended" (e.g. healthy + already
    /// reliable).
    func suggestedTrust(currentTrust: VolumeTrust) -> VolumeTrust? {
        let target: VolumeTrust
        switch self {
        case .retireNow:    target = .unreliable
        case .planToRetire: target = .unreliable
        case .watch:        target = .aging
        case .healthy:      target = .reliable
        }
        return target == currentTrust ? nil : target
    }
}

extension DriveHealthSnapshot {
    /// Pure heuristic — no I/O. See feature spec for thresholds.
    /// Reasons phrased for Rick, not for an enterprise NOC.
    var recommendation: DriveHealthRecommendation {
        // SMART failing is the loudest signal. Always wins.
        if smartStatus == .failingNow {
            return .retireNow(reason: "This drive is reporting a SMART failure. Get the data off as soon as you can.")
        }

        // HDD signals
        if mediaTech == .hdd {
            if let reall = reallocatedSectors, reall > 100 {
                return .retireNow(reason: "This drive has remapped \(reall) bad sectors. That's well past the warning line — copy the data off and retire it.")
            }
            if let pend = pendingSectors, pend > 5 {
                return .retireNow(reason: "There are \(pend) sectors waiting to be remapped. The drive is actively going bad — back it up now.")
            }
            if let off = offlineUncorrectable, off > 0 {
                return .retireNow(reason: "The drive can't read \(off) sectors. Treat it as failing.")
            }
            if let reall = reallocatedSectors, reall > 0 {
                return .planToRetire(reason: "The drive has started remapping bad sectors (\(reall) so far). Plan to move the data off it.")
            }
            if let years = estimatedYearsPowered, years > 6 {
                let yrs = String(format: "%.1f", years)
                return .watch(reason: "This drive's been working hard for about \(yrs) years. No problems yet, but it's earned a watchful eye.")
            }
        }

        // SSD / NVMe signals
        if mediaTech == .ssd || mediaTech == .nvme {
            if let spare = ssdAvailableSpare, spare < 10 {
                return .retireNow(reason: "Only \(spare)% spare capacity left for replacement cells. The SSD is at the end of its rope — copy the data off.")
            }
            if let used = ssdPercentageUsed, used > 85 {
                return .retireNow(reason: "The SSD reports it's \(used)% through its rated write life. Don't trust it with new writes — move the data off.")
            }
            if let used = ssdPercentageUsed, used > 70 {
                return .watch(reason: "The SSD is \(used)% through its rated write life. Still healthy, but worth a look every so often.")
            }
        }

        // No actionable signal — fall back to "couldn't read SMART" if
        // we have warnings, otherwise call it healthy.
        if smartStatus == .notSupported || smartStatus == .unknown {
            return .healthy(reason: "Couldn't read SMART data — judge by age and use.")
        }
        return .healthy(reason: "No warning signs from this drive. Keep doing what you're doing.")
    }

    /// Convenience — HDDs publish hours, SSDs sometimes do too.
    /// 24 × 365 ≈ 8760 hours/year. Returns nil if the drive didn't
    /// report it.
    var estimatedYearsPowered: Double? {
        powerOnHours.map { Double($0) / (24 * 365) }
    }
}

// MARK: - Probe

/// Probes a mounted volume's underlying device for SMART data.
///
/// Swift `actor` ≈ a class with implicit mutex around its mutable state.
/// We use one to memoize per-device probes inside a session — a slow
/// `smartctl` call against an external HDD can take 1-2 seconds, and the
/// UI may ask for the same snapshot from multiple surfaces (the inline
/// card + the standalone sheet).
actor DriveHealthProbe {
    /// Per-process session start; baked into the cache key so cached
    /// snapshots don't persist across app restarts.
    static let shared = DriveHealthProbe()

    private let sessionStart = Date()
    private var cache: [String: DriveHealthSnapshot] = [:]

    /// Returns a cached snapshot if one exists; otherwise probes.
    func snapshot(forMountPath mountPath: String,
                         forceRefresh: Bool = false) async -> DriveHealthSnapshot {
        // First resolve mount → device. We cache on device path so two
        // mounts of the same physical disk share a snapshot.
        let resolution = await Self.resolveDevice(forMountPath: mountPath)
        let devicePath = resolution.devicePath ?? mountPath

        if !forceRefresh, let cached = cache[devicePath] {
            return cached
        }

        let snapshot = await Self.probe(mountPath: mountPath, resolution: resolution)
        cache[devicePath] = snapshot
        return snapshot
    }

    /// Drop a cached snapshot. Called when the user clicks Re-probe.
    func invalidate(devicePath: String) {
        cache.removeValue(forKey: devicePath)
    }

    /// Clear all cached snapshots — useful for tests.
    func reset() {
        cache.removeAll()
    }
}

// MARK: - Probe implementation (nonisolated statics so tests can hit them)

extension DriveHealthProbe {

    /// Result of mapping a mount path to its underlying physical device.
    struct DeviceResolution: Sendable {
        let devicePath: String?       // /dev/diskN
        let protocolKind: ProtocolKind
        let mediaTech: DetectedMediaTech
        let warnings: [String]
    }

    /// `diskutil info -plist <mount>` parsing. Errors fold into the
    /// warnings list — we still return a resolution.
    nonisolated static func resolveDevice(forMountPath mountPath: String) async -> DeviceResolution {
        var warnings: [String] = []
        // /usr/sbin/diskutil — absolute path so we don't depend on PATH
        let result = await ProcessRunner.runProcess(
            executable: "/usr/sbin/diskutil",
            arguments: ["info", "-plist", mountPath]
        )
        guard let stdout = result.stdout, !stdout.isEmpty,
              let plistData = stdout.data(using: .utf8) else {
            warnings.append("Couldn't ask the system about this drive — diskutil didn't reply.")
            return DeviceResolution(devicePath: nil, protocolKind: .unknown,
                                    mediaTech: .unknown, warnings: warnings)
        }

        let plist: [String: Any]
        do {
            guard let dict = try PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any] else {
                warnings.append("Couldn't read disk info plist.")
                return DeviceResolution(devicePath: nil, protocolKind: .unknown,
                                        mediaTech: .unknown, warnings: warnings)
            }
            plist = dict
        } catch {
            warnings.append("Couldn't parse disk info plist: \(error.localizedDescription)")
            return DeviceResolution(devicePath: nil, protocolKind: .unknown,
                                    mediaTech: .unknown, warnings: warnings)
        }

        // DeviceIdentifier looks like "disk5s1"; strip the slice/sN
        // suffix to get the physical disk node we hand to smartctl.
        var devicePath: String?
        if let ident = plist["DeviceIdentifier"] as? String {
            devicePath = "/dev/" + stripSliceSuffix(from: ident)
        }

        let protocolKind = parseProtocol(plist["BusProtocol"] as? String)
        let mediaTech = parseMediaTech(
            protocolKind: protocolKind,
            solidState: plist["SolidState"] as? Bool
        )

        return DeviceResolution(devicePath: devicePath,
                                protocolKind: protocolKind,
                                mediaTech: mediaTech,
                                warnings: warnings)
    }

    /// "disk5s1" → "disk5". Avid Bin numbering aside, the slice is
    /// always after the second numeric run.
    nonisolated static func stripSliceSuffix(from ident: String) -> String {
        // Strip first "sN..." after the leading digit block.
        // e.g. "disk5s1" → "disk5", "disk0s3s2" → "disk0", "disk12" → "disk12"
        guard ident.hasPrefix("disk") else { return ident }
        let body = ident.dropFirst("disk".count)
        var result = "disk"
        for ch in body {
            if ch.isNumber {
                result.append(ch)
            } else {
                break
            }
        }
        return result
    }

    nonisolated static func parseProtocol(_ raw: String?) -> ProtocolKind {
        guard let raw = raw?.lowercased() else { return .unknown }
        if raw.contains("usb") { return .usb }
        if raw.contains("sata") { return .sata }
        if raw.contains("thunderbolt") { return .thunderbolt }
        if raw.contains("apple fabric") { return .nvmeInternal }
        if raw.contains("pcie") || raw.contains("pci-express") { return .nvmeExternal }
        if raw.contains("nvme") { return .nvmeExternal }
        return .unknown
    }

    nonisolated static func parseMediaTech(protocolKind: ProtocolKind,
                                            solidState: Bool?) -> DetectedMediaTech {
        if protocolKind == .nvmeInternal || protocolKind == .nvmeExternal {
            return .nvme
        }
        if solidState == true { return .ssd }
        if solidState == false { return .hdd }
        return .unknown
    }

    /// End-to-end probe: resolve, run smartctl (or system_profiler
    /// fallback for Apple Fabric), parse, return a snapshot. Never
    /// throws — failure cases populate `probeWarnings`.
    nonisolated static func probe(mountPath: String,
                                  resolution: DeviceResolution) async -> DriveHealthSnapshot {
        var warnings = resolution.warnings
        let devicePath = resolution.devicePath ?? mountPath
        let smartctlPath = "/opt/homebrew/bin/smartctl"

        // No device path means we can't probe at all — return the
        // skeleton snapshot.
        guard resolution.devicePath != nil else {
            return DriveHealthSnapshot(
                mountPath: mountPath,
                devicePath: devicePath,
                protocolKind: resolution.protocolKind,
                mediaTech: resolution.mediaTech,
                probeWarnings: warnings + ["Couldn't figure out which disk this volume lives on."]
            )
        }

        // Internal Apple Fabric NVMe — smartctl may or may not work
        // depending on smartmontools version. Try smartctl first; if it
        // returns nothing useful, fall back to system_profiler.
        let isInternalNVMe = resolution.protocolKind == .nvmeInternal

        guard FileManager.default.isExecutableFile(atPath: smartctlPath) else {
            warnings.append("smartmontools isn't installed — `brew install smartmontools` to enable Drive Health.")
            if isInternalNVMe {
                return await probeAppleFabric(mountPath: mountPath,
                                              devicePath: devicePath,
                                              resolution: resolution,
                                              warnings: warnings)
            }
            return DriveHealthSnapshot(
                mountPath: mountPath,
                devicePath: devicePath,
                protocolKind: resolution.protocolKind,
                mediaTech: resolution.mediaTech,
                probeWarnings: warnings
            )
        }

        let result = await ProcessRunner.runProcess(
            executable: smartctlPath,
            arguments: ["-a", "-j", devicePath]
        )

        // smartctl's exit codes are a bitmask — 0 is clean, but a value
        // like 4 (read errors in error log) still carries useful JSON.
        // We try to parse whatever stdout we got first, then layer in
        // warnings for non-zero exit codes.
        if let stdout = result.stdout, !stdout.isEmpty,
           let snapshot = parseSmartctlJSON(
                stdout,
                mountPath: mountPath,
                devicePath: devicePath,
                protocolKind: resolution.protocolKind,
                mediaTechHint: resolution.mediaTech,
                exitCode: result.exitCode,
                priorWarnings: warnings
           ) {
            return snapshot
        }

        // No usable JSON. For external USB bridges this is the typical
        // failure — they don't pass SMART through.
        warnings.append(friendlySmartctlFailure(exitCode: result.exitCode,
                                                stderr: result.stderr,
                                                protocolKind: resolution.protocolKind))
        if isInternalNVMe {
            return await probeAppleFabric(mountPath: mountPath,
                                          devicePath: devicePath,
                                          resolution: resolution,
                                          warnings: warnings)
        }
        return DriveHealthSnapshot(
            mountPath: mountPath,
            devicePath: devicePath,
            protocolKind: resolution.protocolKind,
            mediaTech: resolution.mediaTech,
            probeWarnings: warnings
        )
    }

    /// system_profiler fallback for Apple internal NVMe. Lossy compared
    /// to smartctl — we get capacity + SMART pass/fail and not much
    /// else. Still better than nothing.
    nonisolated static func probeAppleFabric(mountPath: String,
                                              devicePath: String,
                                              resolution: DeviceResolution,
                                              warnings: [String]) async -> DriveHealthSnapshot {
        var warnings = warnings
        let result = await ProcessRunner.runProcess(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPNVMeDataType", "-json"]
        )
        guard let stdout = result.stdout, !stdout.isEmpty,
              let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            warnings.append("Couldn't read internal SSD info from system_profiler.")
            return DriveHealthSnapshot(
                mountPath: mountPath,
                devicePath: devicePath,
                protocolKind: resolution.protocolKind,
                mediaTech: .nvme,
                probeWarnings: warnings
            )
        }
        return parseSystemProfilerNVMe(json,
                                       mountPath: mountPath,
                                       devicePath: devicePath,
                                       protocolKind: resolution.protocolKind,
                                       priorWarnings: warnings)
    }

    /// Plain-English explanation of a non-zero smartctl exit. Anything
    /// shown to Rick goes through this so we don't leak "exit_status 1".
    nonisolated static func friendlySmartctlFailure(exitCode: Int32,
                                                     stderr: String,
                                                     protocolKind: ProtocolKind) -> String {
        if protocolKind == .usb {
            return "This drive's USB enclosure doesn't pass SMART data through, so we can't read its health."
        }
        if stderr.lowercased().contains("permission") {
            return "Couldn't read SMART data — permission denied. Some controllers need to be run with elevated privileges."
        }
        if exitCode == 2 {
            return "Drive didn't respond to a SMART query."
        }
        return "Couldn't read SMART data from this drive."
    }
}

// MARK: - smartctl JSON parser (pure, nonisolated, tested directly)

extension DriveHealthProbe {

    /// Parses smartctl's `-a -j` JSON output into a snapshot.
    /// Returns nil only if the input isn't valid JSON at all; partial
    /// JSON (missing fields) still yields a snapshot.
    nonisolated static func parseSmartctlJSON(
        _ jsonString: String,
        mountPath: String,
        devicePath: String,
        protocolKind: ProtocolKind,
        mediaTechHint: DetectedMediaTech,
        exitCode: Int32,
        priorWarnings: [String]
    ) -> DriveHealthSnapshot? {
        guard let data = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var warnings = priorWarnings

        let model = root["model_name"] as? String
        let serial = root["serial_number"] as? String
        let firmware = root["firmware_version"] as? String

        let capacityBytes: Int64? = {
            if let cap = root["user_capacity"] as? [String: Any],
               let bytes = (cap["bytes"] as? NSNumber)?.int64Value {
                return bytes
            }
            return nil
        }()

        // SMART overall pass/fail. NVMe smart_status has a "nvme" sub-
        // dict where `value > 0` means failure; HDD/SATA just has
        // "passed: bool".
        let smartStatus: SmartOverall = {
            guard let smart = root["smart_status"] as? [String: Any] else {
                return .unknown
            }
            if let passed = smart["passed"] as? Bool {
                return passed ? .passed : .failingNow
            }
            if let nvme = smart["nvme"] as? [String: Any],
               let value = (nvme["value"] as? NSNumber)?.intValue {
                return value == 0 ? .passed : .failingNow
            }
            return .unknown
        }()

        // Detected media tech — start with the caller's hint, refine if
        // smartctl tells us more.
        var mediaTech = mediaTechHint
        if root["nvme_smart_health_information_log"] != nil {
            mediaTech = .nvme
        } else if let rotation = (root["rotation_rate"] as? NSNumber)?.intValue {
            if rotation == 0 {
                mediaTech = (mediaTech == .nvme) ? .nvme : .ssd
            } else if rotation > 0 {
                mediaTech = .hdd
            }
        }

        let powerOnHours: Int? = {
            if let pot = root["power_on_time"] as? [String: Any],
               let hours = (pot["hours"] as? NSNumber)?.intValue {
                return hours
            }
            // NVMe carries it inside the SMART log.
            if let log = root["nvme_smart_health_information_log"] as? [String: Any],
               let hours = (log["power_on_hours"] as? NSNumber)?.intValue {
                return hours
            }
            return nil
        }()

        let temperature: Int? = {
            if let t = root["temperature"] as? [String: Any],
               let current = (t["current"] as? NSNumber)?.intValue {
                return current
            }
            if let log = root["nvme_smart_health_information_log"] as? [String: Any],
               let temp = (log["temperature"] as? NSNumber)?.intValue {
                return temp
            }
            return nil
        }()

        // ATA SMART attribute table → look up by ID.
        var realloc: Int?
        var pending: Int?
        var offlineUncorr: Int?
        var reallocEvents: Int?
        if let attrs = root["ata_smart_attributes"] as? [String: Any],
           let table = attrs["table"] as? [[String: Any]] {
            for entry in table {
                guard let id = (entry["id"] as? NSNumber)?.intValue else { continue }
                let raw = ((entry["raw"] as? [String: Any])?["value"] as? NSNumber)?.intValue
                switch id {
                case 5:   realloc = raw
                case 196: reallocEvents = raw
                case 197: pending = raw
                case 198: offlineUncorr = raw
                default:  break
                }
            }
        }

        var availableSpare: Int?
        var percentageUsed: Int?
        var mediaErrors: Int?
        var dataUnitsWritten: Int64?
        if let log = root["nvme_smart_health_information_log"] as? [String: Any] {
            availableSpare = (log["available_spare"] as? NSNumber)?.intValue
            percentageUsed = (log["percentage_used"] as? NSNumber)?.intValue
            mediaErrors = (log["media_errors"] as? NSNumber)?.intValue
            // data_units_written is in 512KB chunks per NVMe spec.
            if let units = (log["data_units_written"] as? NSNumber)?.int64Value {
                dataUnitsWritten = units &* 512_000
            }
        }

        // Non-zero exit but parseable JSON: surface a soft warning so
        // the UI can show "we had to work around something".
        if exitCode != 0 {
            // smartctl sets bit-flag exit codes; bit 6 (64) is "log
            // entry error" which is benign on Apple's NVMe.
            // We only flag if it's not just that bit.
            if (exitCode & ~64) != 0 {
                warnings.append("smartctl reported a non-fatal hiccup while reading this drive (exit \(exitCode)). Data below may be partial.")
            }
        }

        return DriveHealthSnapshot(
            mountPath: mountPath,
            devicePath: devicePath,
            modelName: model,
            serialNumber: serial,
            firmware: firmware,
            capacityBytes: capacityBytes,
            protocolKind: protocolKind,
            mediaTech: mediaTech,
            smartStatus: smartStatus,
            powerOnHours: powerOnHours,
            reallocatedSectors: realloc,
            pendingSectors: pending,
            offlineUncorrectable: offlineUncorr,
            reallocatedEvents: reallocEvents,
            temperatureCelsius: temperature,
            ssdAvailableSpare: availableSpare,
            ssdPercentageUsed: percentageUsed,
            ssdMediaErrors: mediaErrors,
            dataWrittenBytes: dataUnitsWritten,
            probedAt: Date(),
            probeWarnings: warnings
        )
    }

    /// Best-effort parse of system_profiler SPNVMeDataType output.
    /// We only extract what the spec asked for; everything else stays
    /// nil and the recommendation falls back to the friendly default.
    nonisolated static func parseSystemProfilerNVMe(
        _ root: [String: Any],
        mountPath: String,
        devicePath: String,
        protocolKind: ProtocolKind,
        priorWarnings: [String]
    ) -> DriveHealthSnapshot {
        var warnings = priorWarnings
        var capacityBytes: Int64?
        var smartStatus: SmartOverall = .unknown
        var dataWritten: Int64?
        var model: String?
        var serial: String?
        var firmware: String?

        // SPNVMeDataType payload is an array of controller dicts, each
        // with a `_items` sub-array of namespaces. We grab the first
        // entry that looks like a system drive — capacity is the most
        // reliable signal.
        let outer = (root["SPNVMeDataType"] as? [[String: Any]]) ?? []
        for controller in outer {
            // Each controller has _items (namespaces) and metadata at the
            // top level. We treat the whole controller dict as a record.
            let items = (controller["_items"] as? [[String: Any]]) ?? [controller]
            for entry in items {
                if model == nil {
                    model = entry["_name"] as? String ?? entry["device_model"] as? String
                }
                if serial == nil {
                    serial = entry["device_serial"] as? String
                }
                if firmware == nil {
                    firmware = entry["device_revision"] as? String
                }
                if capacityBytes == nil,
                   let bytes = parseAppleBytesString(entry["spnvme_drive_capacity"]) {
                    capacityBytes = bytes
                }
                if dataWritten == nil,
                   let bytes = parseAppleBytesString(entry["spnvme_total_bytes_written"]) {
                    dataWritten = bytes
                }
                if smartStatus == .unknown,
                   let raw = entry["spnvme_smart_status"] as? String {
                    smartStatus = raw.lowercased().contains("verified") ? .passed : .unknown
                }
            }
        }

        if model == nil && serial == nil && capacityBytes == nil {
            warnings.append("Couldn't read internal SSD details from system_profiler.")
        }

        return DriveHealthSnapshot(
            mountPath: mountPath,
            devicePath: devicePath,
            modelName: model,
            serialNumber: serial,
            firmware: firmware,
            capacityBytes: capacityBytes,
            protocolKind: protocolKind,
            mediaTech: .nvme,
            smartStatus: smartStatus,
            dataWrittenBytes: dataWritten,
            probeWarnings: warnings
        )
    }

    /// system_profiler returns capacity as either a localized string
    /// ("1 TB") or a dictionary with `_value` and `_units`. Handle both.
    nonisolated static func parseAppleBytesString(_ raw: Any?) -> Int64? {
        if let dict = raw as? [String: Any],
           let value = (dict["_value"] as? NSNumber)?.doubleValue,
           let units = dict["_units"] as? String {
            return Int64(value * unitMultiplier(units))
        }
        if let string = raw as? String {
            return parseBytesFromString(string)
        }
        if let n = raw as? NSNumber {
            return n.int64Value
        }
        return nil
    }

    nonisolated static func parseBytesFromString(_ s: String) -> Int64? {
        // "1 TB", "500 GB", "994,662,584,320 bytes"
        let trimmed = s.replacingOccurrences(of: ",", with: "")
        let parts = trimmed.split(separator: " ").map { String($0) }
        guard parts.count >= 2, let value = Double(parts[0]) else {
            // Try just digits ("994662584320")
            if let n = Int64(trimmed) { return n }
            return nil
        }
        return Int64(value * unitMultiplier(parts[1]))
    }

    nonisolated static func unitMultiplier(_ raw: String) -> Double {
        switch raw.uppercased() {
        case "B", "BYTES":      return 1
        case "KB":              return 1_000
        case "MB":              return 1_000_000
        case "GB":              return 1_000_000_000
        case "TB":              return 1_000_000_000_000
        case "KIB":             return 1_024
        case "MIB":             return 1_024 * 1_024
        case "GIB":             return 1_024 * 1_024 * 1_024
        case "TIB":             return 1_024 * 1_024 * 1_024 * 1_024
        default:                return 1
        }
    }
}
