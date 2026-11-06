// MachineCounters.swift — the Realtime Content Analysis window's machine
// pane: CPU, GPU, memory and disk read, read from the kernel with no admin
// rights (Rick 2026-11-05: "we can see the GPU/CPU/DISK … melting silicon").
//
// Truth rules: every counter is a value WITH its source, or the reason it is
// absent — never a made-up number. CPU and disk are rates, so the FIRST
// sample has none ("a rate needs two samples"); the second has the delta.
// The raw read is injectable (`RawRead`), so tests pin the arithmetic with
// known ticks and the production read is proven on the host only for shape
// (a value in range or a reason, never neither).
//
// Sources (each is the tile's tooltip, MachineCounterSource):
//   CPU    host_processor_info(PROCESSOR_CPU_LOAD_INFO): per-core user+system+nice
//          ticks over user+system+nice+idle, between two samples.
//   GPU    IOKit IOAccelerator → PerformanceStatistics["Device Utilization %"]
//          (the AGX driver's own number; the max over accelerators).
//   Memory ProcessInfo.physicalMemory − MemoryPressureMonitor.availableMemory()
//          (host_statistics64: free + inactive pages).
//   Disk   IOKit IOBlockStorageDriver → Statistics["Bytes (Read)"] summed over
//          every driver (every disk, not just the one being read), Δ/Δt.
//
// Off the main actor: `MachineCounterReader` is an actor; the store awaits
// `sample()` and the kernel calls run on the actor's executor.
//
// Memory: the previous raw sample (a few words) — nothing else.
//
// (For Rick: `actor` ≈ a class whose every method runs under one mutex on a
// worker thread; `enum MachineCounterRaw<T>` ≈ std::expected<T, std::string>.)

import Darwin.Mach
import Foundation
import IOKit

enum MachineCounterSource {
    static let cpu = "CPU: host_processor_info (PROCESSOR_CPU_LOAD_INFO) — busy ÷ total ticks over all cores, between two samples"
    static let gpu = "GPU: IOKit IOAccelerator → PerformanceStatistics[\"Device Utilization %\"] (the GPU driver's own number)"
    static let memory = "Memory: physical memory − available (host_statistics64 free + inactive pages)"
    static let diskRead = "Disk read: IOKit IOBlockStorageDriver → Statistics[\"Bytes (Read)\"] over every disk, between two samples"
}

/// A raw counter: the number, or the words for why there is none.
enum MachineCounterRaw<T: Sendable & Equatable>: Sendable, Equatable {
    case value(T)
    case absent(String)

    var value: T? { if case .value(let v) = self { return v } else { return nil } }
    var problem: String? { if case .absent(let w) = self { return w } else { return nil } }
}

/// What one raw read of the kernel gives (pure data; the actor keeps the previous one).
struct MachineRawCounters: Sendable, Equatable {
    struct CPUTicks: Sendable, Equatable {
        var busy: UInt64
        var total: UInt64
    }
    /// Monotonic seconds at the read (CLOCK_MONOTONIC_RAW), for the rates.
    var monotonicSeconds: Double
    var cpu: MachineCounterRaw<CPUTicks>
    var gpuUtilizationPercent: MachineCounterRaw<Double>
    var memoryAvailableBytes: MachineCounterRaw<UInt64>
    var memoryTotalBytes: UInt64
    /// Bytes read since boot PER DISK (IORegistry entry id → bytes), so a
    /// disk that comes or goes between two samples is seen, not summed in
    /// (Codex F7, 2026-11-05).
    var diskRead: MachineCounterRaw<DiskCounters>

    struct DiskCounters: Sendable, Equatable {
        var bytesReadByDevice: [UInt64: UInt64]
    }
}

/// One finished sample: the pane's numbers, each with its problem words when absent.
struct MachineSample: Sendable, Equatable {
    var cpuBusyPercent: Double?
    var cpuProblem: String?
    var gpuUtilizationPercent: Double?
    var gpuProblem: String?
    var memoryUsedGB: Double?
    var memoryTotalGB: Double = 0
    var memoryProblem: String?
    var diskReadMBPerSecond: Double?
    var diskProblem: String?

    static let firstSample = "first sample — a rate needs two"
}

actor MachineCounterReader {
    typealias RawRead = @Sendable () -> MachineRawCounters

    private let read: RawRead
    private var previous: MachineRawCounters?

    init(read: @escaping RawRead = MachineCounterReader.hostRead) {
        self.read = read
    }

    /// Read the counters once and fold them against the previous read.
    func sample() -> MachineSample {
        let now = read()
        defer { previous = now }
        return Self.fold(previous: previous, now: now)
    }

    /// The arithmetic, pure (tests pin it with known ticks).
    static func fold(previous: MachineRawCounters?, now: MachineRawCounters) -> MachineSample {
        var s = MachineSample(memoryTotalGB: Double(now.memoryTotalBytes) / 1_073_741_824)
        let dt = previous.map { now.monotonicSeconds - $0.monotonicSeconds } ?? 0

        switch now.cpu {
        case .absent(let why): s.cpuProblem = why
        case .value(let ticks):
            if let p = previous?.cpu.value {
                let dBusy = ticks.busy &- p.busy
                let dTotal = ticks.total &- p.total
                if dTotal > 0, ticks.total >= p.total {
                    s.cpuBusyPercent = min(100, 100 * Double(dBusy) / Double(dTotal))
                } else {
                    s.cpuProblem = "no ticks elapsed between the two samples"
                }
            } else {
                s.cpuProblem = MachineSample.firstSample
            }
        }

        switch now.gpuUtilizationPercent {
        case .absent(let why): s.gpuProblem = why
        case .value(let v): s.gpuUtilizationPercent = min(100, max(0, v))
        }

        switch now.memoryAvailableBytes {
        case .absent(let why): s.memoryProblem = why
        case .value(let available):
            let used = now.memoryTotalBytes >= available ? now.memoryTotalBytes - available : 0
            s.memoryUsedGB = Double(used) / 1_073_741_824
        }

        switch now.diskRead {
        case .absent(let why): s.diskProblem = why
        case .value(let disks):
            guard let p = previous?.diskRead.value else { s.diskProblem = MachineSample.firstSample; break }
            switch diskDelta(previous: p, now: disks, seconds: dt) {
            case .value(let rate): s.diskReadMBPerSecond = rate
            case .absent(let why): s.diskProblem = why
            }
        }
        return s
    }

    /// The per-device byte delta over `seconds` as MB/s — or why the interval
    /// has no rate: a changed device set, a counter that went backwards, no
    /// time elapsed (pure; MachineCountersTests pins each).
    static func diskDelta(previous: MachineRawCounters.DiskCounters, now: MachineRawCounters.DiskCounters,
                          seconds: Double) -> MachineCounterRaw<Double> {
        guard seconds > 0 else { return .absent("no time elapsed between the two samples") }
        let before = Set(previous.bytesReadByDevice.keys)
        let after = Set(now.bytesReadByDevice.keys)
        guard before == after else {
            return .absent("the set of disks changed between the two samples (\(before.count) → \(after.count); a drive came or went)")
        }
        var delta: UInt64 = 0
        for (device, bytes) in now.bytesReadByDevice {
            guard let earlier = previous.bytesReadByDevice[device], bytes >= earlier else {
                return .absent("a disk's byte counter went backwards (device \(device))")
            }
            delta += bytes - earlier
        }
        return .value(Double(delta) / seconds / 1_000_000)
    }

    // MARK: The host read (production)

    static let hostRead: RawRead = {
        MachineRawCounters(
            monotonicSeconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9,
            cpu: readCPUTicks(),
            gpuUtilizationPercent: readGPUUtilization(),
            memoryAvailableBytes: readAvailableMemory(),
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            diskRead: readDiskReadBytes())
    }

    /// Per-core load ticks summed. The info array is kernel memory and must
    /// be vm_deallocate'd; the host port is a send right we must release.
    static func readCPUTicks() -> MachineCounterRaw<MachineRawCounters.CPUTicks> {
        let host = mach_host_self()
        defer { mach_port_deallocate(task_self_trap(), host) }
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return .absent("host_processor_info failed (kern_return \(kr))") }
        defer {
            vm_deallocate(task_self_trap(), vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }
        let states = Int(CPU_STATE_MAX)
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            guard base + states <= Int(infoCount) else { break }
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard cpuCount > 0 else { return .absent("host_processor_info reported no cores") }
        return .value(.init(busy: busy, total: total))
    }

    /// The AGX driver's "Device Utilization %" — the max over every accelerator.
    static func readGPUUtilization() -> MachineCounterRaw<Double> {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard kr == KERN_SUCCESS else { return .absent("IOServiceGetMatchingServices(IOAccelerator) failed (kern_return \(kr))") }
        defer { IOObjectRelease(iterator) }
        var entries: [MachineCounterRaw<Double>] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                entries.append(.value(util))
            } else {
                entries.append(.absent("no PerformanceStatistics[\"Device Utilization %\"]"))
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return gpuUtilization(entries: entries)
    }

    /// The max over accelerators — unless any entry refused, which makes the
    /// whole reading absent with the reason (the disk reader's rule; Codex
    /// re-review 2, finding 4: a partial max is not a max). Pure.
    static func gpuUtilization(entries: [MachineCounterRaw<Double>]) -> MachineCounterRaw<Double> {
        guard !entries.isEmpty else { return .absent("no IOAccelerator in the IORegistry") }
        let refused = entries.compactMap(\.problem)
        if let first = refused.first {
            return .absent("\(refused.count) of \(entries.count) IOAccelerator entries refused: \(first)")
        }
        return .value(entries.compactMap(\.value).max() ?? 0)
    }

    static func readAvailableMemory() -> MachineCounterRaw<UInt64> {
        let available = MemoryPressureMonitor.shared.availableMemory()
        return available > 0 ? .value(available) : .absent("host_statistics64 failed")
    }

    /// Bytes read since boot per IOBlockStorageDriver, keyed by the entry's
    /// registry id. One driver that refuses its Statistics makes the whole
    /// read absent (a partial sum would be a made-up rate — Codex F7).
    static func readDiskReadBytes() -> MachineCounterRaw<MachineRawCounters.DiskCounters> {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
        guard kr == KERN_SUCCESS else { return .absent("IOServiceGetMatchingServices(IOBlockStorageDriver) failed (kern_return \(kr))") }
        defer { IOObjectRelease(iterator) }
        var byDevice: [UInt64: UInt64] = [:]
        var refused = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var id: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS,
               let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let bytes = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                byDevice[id] = bytes
            } else {
                refused += 1
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard refused == 0 else {
            return .absent("\(refused) of \(refused + byDevice.count) IOBlockStorageDriver entries refused their Statistics")
        }
        guard !byDevice.isEmpty else { return .absent("no IOBlockStorageDriver in the IORegistry") }
        return .value(.init(bytesReadByDevice: byDevice))
    }
}
