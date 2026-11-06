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
    var diskReadBytes: MachineCounterRaw<UInt64>
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

        switch now.diskReadBytes {
        case .absent(let why): s.diskProblem = why
        case .value(let bytes):
            if let p = previous?.diskReadBytes.value {
                if dt > 0, bytes >= p {
                    s.diskReadMBPerSecond = Double(bytes - p) / dt / 1_000_000
                } else {
                    s.diskProblem = dt > 0 ? "the byte counter went backwards (a disk came or went)" : "no time elapsed between the two samples"
                }
            } else {
                s.diskProblem = MachineSample.firstSample
            }
        }
        return s
    }

    // MARK: The host read (production)

    static let hostRead: RawRead = {
        MachineRawCounters(
            monotonicSeconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9,
            cpu: readCPUTicks(),
            gpuUtilizationPercent: readGPUUtilization(),
            memoryAvailableBytes: readAvailableMemory(),
            memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
            diskReadBytes: readDiskReadBytes())
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
        var best: Double?
        var accelerators = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            accelerators += 1
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard accelerators > 0 else { return .absent("no IOAccelerator in the IORegistry") }
        guard let best else { return .absent("IOAccelerator has no PerformanceStatistics[\"Device Utilization %\"]") }
        return .value(best)
    }

    static func readAvailableMemory() -> MachineCounterRaw<UInt64> {
        let available = MemoryPressureMonitor.shared.availableMemory()
        return available > 0 ? .value(available) : .absent("host_statistics64 failed")
    }

    /// Bytes read since boot, summed over every IOBlockStorageDriver.
    static func readDiskReadBytes() -> MachineCounterRaw<UInt64> {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
        guard kr == KERN_SUCCESS else { return .absent("IOServiceGetMatchingServices(IOBlockStorageDriver) failed (kern_return \(kr))") }
        defer { IOObjectRelease(iterator) }
        var sum: UInt64 = 0
        var drivers = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let bytes = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value {
                sum &+= bytes
                drivers += 1
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        guard drivers > 0 else { return .absent("no IOBlockStorageDriver with Statistics in the IORegistry") }
        return .value(sum)
    }
}
