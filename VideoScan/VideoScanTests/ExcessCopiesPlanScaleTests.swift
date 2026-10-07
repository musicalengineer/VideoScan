// ExcessCopiesPlanScaleTests.swift
// SCALE dimension (CLAUDE.md feature-test checklist) for "Delete excess
// copies", Tier 1: the pure plan over 100k synthetic snapshots — 1,000
// archived items, 5,000 matching copies, 94,000 records that match nothing —
// inside a 2 s budget (the design's forecast budget, Phase 1). Also the
// SENSOR: the plan's answer at that scale is exactly the constructed truth,
// so a regression that slows OR changes the nomination trips here.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Excess copies — plan at 100k records")
struct ExcessCopiesPlanScaleTests {

    static let budgetSeconds = 2.0

    static func catalog() -> [ExcessCopySnapshot] {
        var out: [ExcessCopySnapshot] = []
        out.reserveCapacity(100_000)
        for i in 0..<1_000 {
            let root = UUID()
            out.append(ExcessCopySnapshot(filename: "test_\(i).vs.preserve.mkv", fullPath: "/Volumes/FamilyArchive/A/\(i)/m.mkv",
                                          volumeName: "FamilyArchive", sizeBytes: 9_000, durationSeconds: 3_600,
                                          isArchiveSide: true, archiveDigest: "m\(i)", isPreservationMaster: true,
                                          archiveRelPath: "/A/\(i)/m.mkv", derivedFrom: root))
            out.append(ExcessCopySnapshot(filename: "test_\(i).mov", fullPath: "/Volumes/FamilyArchive/A/\(i)/o.mov",
                                          volumeName: "FamilyArchive", sizeBytes: 4_000 + Int64(i), durationSeconds: 3_600,
                                          contentHash: "v1:o\(i)", isArchiveSide: true, archiveDigest: "o\(i)",
                                          archiveRelPath: "/A/\(i)/o.mov", derivedFrom: root))
        }
        for i in 0..<5_000 {
            let n = i % 1_000
            let sampled = i % 2 == 1
            out.append(ExcessCopySnapshot(filename: "test_c\(i).mov", fullPath: "/Volumes/Work\(i % 7)/c/\(i).mov",
                                          volumeName: "Work\(i % 7)", sizeBytes: 4_000 + Int64(n), durationSeconds: 3_600,
                                          contentHash: sampled ? "v1:o\(n)" : "", wholeDigest: sampled ? nil : "o\(n)"))
        }
        while out.count < 100_000 {
            let i = out.count
            out.append(ExcessCopySnapshot(filename: "test_x\(i).mov", fullPath: "/Volumes/Work\(i % 7)/x/\(i).mov",
                                          volumeName: "Work\(i % 7)", sizeBytes: Int64(i), durationSeconds: 60,
                                          contentHash: "v1:x\(i)", wholeDigest: "x\(i)"))
        }
        return out
    }

    @Test("100k records → 1,000 items, 5,000 offered copies, under the 2 s budget")
    func scale100k() {
        let snaps = Self.catalog()
        #expect(snaps.count == 100_000)
        let clock = ContinuousClock()
        var plan = ExcessCopiesPlan.empty
        let elapsed = clock.measure { plan = ExcessCopiesPlan.compute(snaps) }
        #expect(plan.items.count == 1_000)
        #expect(plan.offeredCount == 5_000)
        #expect(plan.sampledCount == 2_500)
        #expect(plan.leftAloneCount == 0 && plan.longerCount == 0)
        #expect(plan.items.allSatisfy { $0.master.isPreservationMaster })
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(seconds < Self.budgetSeconds, "plan took \(seconds) s over 100k records (budget \(Self.budgetSeconds) s)")
    }
}
