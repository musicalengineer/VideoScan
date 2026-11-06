// MachineCountersTests.swift — the Realtime Content Analysis window's machine
// pane (Analyze/Realtime/MachineCounters.swift).
//
// Dimensions (CLAUDE.md rule 8):
//   TRUTH   with injected raw counters the arithmetic is exact: CPU is the
//           busy-tick share between two samples, disk read is the byte delta
//           over the elapsed seconds, memory is total − available, GPU is the
//           driver's number clamped; a first sample has no rate and says so;
//           a counter the kernel refused carries its words.
//   LOGIC   backwards counters and zero elapsed time are problems, never a
//           negative or infinite rate; the words beside each tile.
//   SENSOR  the production reader on this host: every counter is a value in
//           range OR a reason — never neither, never a made-up number.
//   SCALE / MEDIA / ISOLATION N/A (no state, no files).

import Foundation
import Testing
@testable import VideoScan

private func raw(at t: Double, busy: UInt64, total: UInt64, gpu: Double? = 11, available: UInt64 = 60 << 30,
                 physical: UInt64 = 96 << 30, disk: UInt64) -> MachineRawCounters {
    MachineRawCounters(monotonicSeconds: t,
                       cpu: .value(.init(busy: busy, total: total)),
                       gpuUtilizationPercent: gpu.map { .value($0) } ?? .absent("no IOAccelerator in the IORegistry"),
                       memoryAvailableBytes: .value(available),
                       memoryTotalBytes: physical,
                       diskRead: .value(.init(bytesReadByDevice: [1: disk])))
}

@Suite("Realtime Content Analysis — machine counters are deltas of real ticks, or a reason")
struct MachineCountersTests {

    @Test func theFirstSampleHasNoRate() {
        let s = MachineCounterReader.fold(previous: nil, now: raw(at: 10, busy: 100, total: 200, disk: 1_000_000))
        #expect(s.cpuBusyPercent == nil && s.cpuProblem == MachineSample.firstSample)
        #expect(s.diskReadMBPerSecond == nil && s.diskProblem == MachineSample.firstSample)
        #expect(s.gpuUtilizationPercent == 11 && s.gpuProblem == nil)
        #expect(s.memoryUsedGB == 36 && s.memoryTotalGB == 96 && s.memoryProblem == nil, "total − available")
    }

    @Test func cpuAndDiskAreTheDeltas() {
        let a = raw(at: 10, busy: 100, total: 200, disk: 1_000_000)
        let b = raw(at: 12, busy: 160, total: 300, disk: 3_000_000)
        let s = MachineCounterReader.fold(previous: a, now: b)
        #expect(s.cpuBusyPercent == 60, "(160 − 100) / (300 − 200)")
        #expect(s.diskReadMBPerSecond == 1, "2,000,000 bytes over 2 s")
        #expect(s.cpuProblem == nil && s.diskProblem == nil)
    }

    @Test func aCounterThatWentBackwardsOrStoodStillIsAProblemNotANumber() {
        let a = raw(at: 10, busy: 100, total: 200, disk: 5_000_000)
        let back = MachineCounterReader.fold(previous: a, now: raw(at: 12, busy: 100, total: 200, disk: 4_000_000))
        #expect(back.cpuBusyPercent == nil && back.cpuProblem == "no ticks elapsed between the two samples")
        #expect(back.diskReadMBPerSecond == nil && back.diskProblem?.contains("went backwards") == true)
        let still = MachineCounterReader.fold(previous: a, now: raw(at: 10, busy: 160, total: 300, disk: 6_000_000))
        #expect(still.cpuBusyPercent == 60, "ticks moved even if the clock did not")
        #expect(still.diskReadMBPerSecond == nil && still.diskProblem == "no time elapsed between the two samples")
    }

    @Test func anAbsentCounterCarriesItsWords() {
        let now = MachineRawCounters(monotonicSeconds: 1, cpu: .absent("host_processor_info failed (kern_return 5)"),
                                     gpuUtilizationPercent: .absent("no IOAccelerator in the IORegistry"),
                                     memoryAvailableBytes: .absent("host_statistics64 failed"), memoryTotalBytes: 96 << 30,
                                     diskRead: .absent("no IOBlockStorageDriver in the IORegistry"))
        let s = MachineCounterReader.fold(previous: nil, now: now)
        #expect(s.cpuBusyPercent == nil && s.cpuProblem == "host_processor_info failed (kern_return 5)")
        #expect(s.gpuUtilizationPercent == nil && s.gpuProblem == "no IOAccelerator in the IORegistry")
        #expect(s.memoryUsedGB == nil && s.memoryProblem == "host_statistics64 failed")
        #expect(s.diskReadMBPerSecond == nil && s.diskProblem?.hasPrefix("no IOBlockStorageDriver") == true)
        #expect(s.memoryTotalGB == 96)
    }

    @Test func gpuIsClampedToPercent() {
        #expect(MachineCounterReader.fold(previous: nil, now: raw(at: 1, busy: 1, total: 2, gpu: 140, disk: 1)).gpuUtilizationPercent == 100)
        #expect(MachineCounterReader.fold(previous: nil, now: raw(at: 1, busy: 1, total: 2, gpu: -3, disk: 1)).gpuUtilizationPercent == 0)
    }

    @Test func theReaderKeepsOnlyThePreviousSample() async {
        final class Clock: @unchecked Sendable { var reads = 0 }   // the injected read's call counter (test only)
        let clock = Clock()
        let reader = MachineCounterReader(read: {
            clock.reads += 1
            let t = Double(clock.reads)
            return raw(at: t, busy: UInt64(50 * clock.reads), total: UInt64(100 * clock.reads), disk: UInt64(1_000_000 * clock.reads))
        })
        let first = await reader.sample()
        #expect(first.cpuProblem == MachineSample.firstSample)
        let second = await reader.sample()
        #expect(second.cpuBusyPercent == 50 && second.diskReadMBPerSecond == 1)
        let third = await reader.sample()
        #expect(third.cpuBusyPercent == 50 && third.diskReadMBPerSecond == 1)
        #expect(clock.reads == 3, "one kernel read per sample")
    }

    @Test func theWordsBesideATile() {
        func reading(_ v: Double?, _ unit: String) -> RealtimeAnalysisState.Reading {
            RealtimeAnalysisState.Reading(value: v, unit: unit, source: "src", problem: v == nil ? "why" : nil)
        }
        #expect(reading(nil, "%").words == "—" && reading(nil, "%").tooltip == "src — why")
        #expect(reading(42.4, "%").words == "42%" && reading(42.4, "%").tooltip == "src")
        #expect(reading(38.16, "GB").words == "38.2 GB")
        #expect(reading(210.4, "MB/s").words == "210 MB/s")
        #expect(reading(5.25, "MB/s").words == "5.2 MB/s" || reading(5.25, "MB/s").words == "5.3 MB/s")
    }

    @Test("SENSOR: on this host every counter is a value in range or a reason — never neither")
    func theHostReadIsAValueOrAReason() async throws {
        let reader = MachineCounterReader()
        _ = await reader.sample()
        try await Task.sleep(for: .milliseconds(120))
        let s = await reader.sample()
        func check(_ name: String, _ value: Double?, _ problem: String?, range: ClosedRange<Double>) {
            #expect((value == nil) != (problem == nil), "\(name): value \(String(describing: value)) problem \(String(describing: problem))")
            if let value { #expect(range.contains(value), "\(name) = \(value)") }
        }
        check("cpu", s.cpuBusyPercent, s.cpuProblem, range: 0...100)
        check("gpu", s.gpuUtilizationPercent, s.gpuProblem, range: 0...100)
        check("memory", s.memoryUsedGB, s.memoryProblem, range: 0...s.memoryTotalGB)
        check("disk", s.diskReadMBPerSecond, s.diskProblem, range: 0...1_000_000)
        #expect(s.memoryTotalGB > 1)
        // The two rates need two samples: by the second sample they are either numbers or a kernel refusal, not "first sample".
        #expect(s.cpuProblem != MachineSample.firstSample && s.diskProblem != MachineSample.firstSample)
    }
}
