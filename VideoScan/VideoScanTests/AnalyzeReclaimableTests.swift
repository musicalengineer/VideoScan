// AnalyzeReclaimableTests.swift
// The Storage tab's Reclaimable card arithmetic (Phase A trial, 2026-10-02).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — which extra copies count (same-drive keeper; cross-drive
//               only with the toggle), bytes, the verified-copies floor,
//               rows short of two, offline siblings, the knowledge line
//               (never checked / last checked / policy stale), and that
//               the survival rule QUOTES DeletionTierDecision's constants.
//   Scale     — 100k records, 2k dup groups, explicit budget.
//   Isolation — pure functions; no filesystem, no defaults.
//   Sensor    — AnalyzePanelSensorTests.swift (source-level).
// Media matrix: N/A — catalog metadata only.
//
// Suites: AnalyzeReclaimableLogicTests · AnalyzeReclaimableScaleTests

import Foundation
import Testing
@testable import VideoScan

private let GB: Int64 = 1_073_741_824
private let mounted: Set<String> = ["/", "/Volumes/SanDisk", "/Volumes/LaCie"]

private func row(_ path: String, bytes: Int64 = GB, extra: Bool = false, keeper: Bool = false,
                 group: UUID? = nil, digest: Bool = false, checked: Date? = nil) -> ReclaimableInput {
    ReclaimableInput(fullPath: path, sizeBytes: bytes, isExtraCopy: extra, isKeeper: keeper,
                     groupID: group, hasUsableDigest: digest, dupAnalyzedAt: checked)
}

private func compute(_ inputs: [ReclaimableInput], volume: String = "/Volumes/SanDisk",
                     crossMode: Bool = false, now: Date = Date(timeIntervalSince1970: 100_000)) -> ReclaimableEstimate {
    ReclaimableCalculator.compute(inputs: inputs, volumeRoot: volume, mountedRoots: mounted,
                                  alsoCleanUpWorkingCopies: crossMode, now: now)
}

@Suite("Reclaimable — which copies count")
struct AnalyzeReclaimableLogicTests {

    @Test func sameDriveExtraCopiesCountWithBytesAndVerifiedFloor() {
        let g = UUID()
        let e = compute([
            row("/Volumes/SanDisk/keep.mov", keeper: true, group: g, digest: true, checked: Date(timeIntervalSince1970: 90_000)),
            row("/Volumes/SanDisk/copy1.mov", bytes: 2 * GB, extra: true, group: g, checked: Date(timeIntervalSince1970: 95_000)),
            row("/Volumes/LaCie/copy2.mov", extra: true, group: g, digest: true),      // another drive — a verified sibling
            row("/Volumes/SanDisk/unrelated.mov", checked: Date(timeIntervalSince1970: 80_000)),
        ])
        #expect(e.copies == 1, "only the SanDisk extra copy is reclaimable here")
        #expect(e.bytes == 2 * GB)
        #expect(e.verifiedFloor == 2, "keeper + LaCie copy carry usable digests; the row itself does not")
        #expect(e.copiesShortOfTwo == 0)
        // ByteCountFormatter's own words for the size (decimal GB), then ours.
        #expect(e.headline == "\(ByteCountFormatter.string(fromByteCount: 2 * GB, countStyle: .file)) in 1 duplicate copy on this drive")
        #expect(e.headline.hasSuffix("in 1 duplicate copy on this drive"))
        #expect(e.copiesLine == "each has 2+ verified copies elsewhere")
        #expect(e.volumeFiles == 3)
        #expect(e.neverChecked == 0)
        #expect(e.lastChecked == Date(timeIntervalSince1970: 95_000))
    }

    @Test func crossDriveKeeperCountsOnlyWithTheWorkingCopiesToggle() {
        let g = UUID()
        let inputs = [
            row("/Volumes/LaCie/master.mov", keeper: true, group: g, digest: true),
            row("/Volumes/SanDisk/working.mov", extra: true, group: g),
        ]
        #expect(compute(inputs).copies == 0, "toggle off: the keeper is on another drive")
        let on = compute(inputs, crossMode: true)
        #expect(on.copies == 1)
        #expect(on.verifiedFloor == 1)
        #expect(on.copiesShortOfTwo == 0, "keep one: the verified keeper elsewhere is enough for the Trash")
        #expect(on.copiesLine == "each has 1+ verified copy elsewhere")
    }

    @Test func offlineSiblingsAreNotVerifiedAndAreReported() {
        let g = UUID()
        let e = compute([
            row("/Volumes/SanDisk/keep.mov", keeper: true, group: g, digest: true),
            row("/Volumes/SanDisk/copy.mov", extra: true, group: g),
            row("/Volumes/Gone/copy2.mov", extra: true, group: g, digest: true),   // drive not mounted
        ])
        #expect(e.copies == 1)
        #expect(e.verifiedFloor == 1, "the offline sibling's digest does not count")
        #expect(e.copiesWithOfflineSiblings == 1)
        #expect(e.copiesLine == "each has 1+ verified copy elsewhere", "keep one: the keeper alone is enough")
    }

    @Test func aRowWithItsOwnDigestDoesNotCountItself() {
        let g = UUID()
        let e = compute([
            row("/Volumes/SanDisk/keep.mov", keeper: true, group: g, digest: true),
            row("/Volumes/SanDisk/copy.mov", extra: true, group: g, digest: true),
        ])
        #expect(e.verifiedFloor == 1)
    }

    @Test func groupsWithoutAKeeperAreNotOffered() {
        let g = UUID()
        let e = compute([row("/Volumes/SanDisk/orphan.mov", extra: true, group: g)])
        #expect(e.copies == 0)
        #expect(e.verifiedFloor == nil)
        #expect(e.headline == "No duplicate copies to reclaim on this drive")
        #expect(e.copiesLine == "")
    }

    @Test func hiddenRowsAreNotInTheProjection() async {
        // The projection drops purged / set-aside / superseded rows before
        // the calculator sees them — proven on live records.
        await MainActor.run {
            let live = VideoRecord(); live.fullPath = "/Volumes/SanDisk/a.mov"
            let purged = VideoRecord(); purged.fullPath = "/Volumes/SanDisk/b.mov"; purged.purgedAt = Date()
            let aside = VideoRecord(); aside.fullPath = "/Volumes/SanDisk/c.mov"; aside.setAsideReason = "photo"
            let inputs = ReclaimableCalculator.project([live, purged, aside])
            #expect(inputs.map(\.fullPath) == ["/Volumes/SanDisk/a.mov"])
        }
    }

    @Test func knowledgeLineWords() {
        let now = Date(timeIntervalSince1970: 100_000)
        var e = ReclaimableEstimate()
        #expect(e.knowledgeLine(policyStale: false, now: now) == "Duplicate knowledge: nothing catalogued here")
        e.volumeFiles = 10
        e.neverChecked = 10
        #expect(e.knowledgeLine(policyStale: false, now: now) == "Duplicate knowledge: 10 files never checked")
        e.neverChecked = 3
        e.lastChecked = now.addingTimeInterval(-7_200)
        // The relative phrase ("2 hr. ago") is the system formatter's and
        // locale-dependent; pin the structure around it.
        let stale = e.knowledgeLine(policyStale: false, now: now)
        #expect(stale.hasPrefix("Duplicate knowledge: last checked "), "\(stale)")
        #expect(!stale.contains("current"), "never-checked files mean NOT current")
        #expect(stale.hasSuffix(" · 3 files never checked"), "\(stale)")
        e.neverChecked = 0
        let current = e.knowledgeLine(policyStale: false, now: now)
        #expect(current.hasPrefix("Duplicate knowledge: current · last checked "), "\(current)")
        let policy = e.knowledgeLine(policyStale: true, now: now)
        #expect(!policy.contains("current"), "a changed keeper policy means NOT current")
        #expect(policy.hasSuffix(" · keeper policy changed since the last check"), "\(policy)")
    }

    /// The card prints the RULE, quoted from the tier decision's constants
    /// — never a paraphrase that could drift from the code.
    @Test func survivalRuleQuotesDeletionTierDecision() {
        // Keep one, Trash only (2026-10-09).
        #expect(DeletionTierDecision.minimumForTrash == 1)
        #expect(ReclaimableEstimate.survivalRule == DeletionTierDecision.ruleSentence)
        #expect(ReclaimableEstimate.survivalRule.contains("at least one verified copy remains")
                && ReclaimableEstimate.survivalRule.contains("Nothing is ever deleted outright"))
    }

    @Test func internalFolderTargetIsItsOwnDrive() {
        let g = UUID()
        let e = compute([
            row("/Users/rick/Movies/keep.mov", keeper: true, group: g, digest: true),
            row("/Users/rick/Movies/copy.mov", extra: true, group: g),
        ], volume: "/Users/rick/Movies/")
        #expect(e.copies == 1)
        #expect(e.volumeFiles == 2)
    }
}

@Suite("Reclaimable — scale")
struct AnalyzeReclaimableScaleTests {

    /// 100k records, 2,000 groups of ~25 spread over 4 drives — under 1 s
    /// in Debug (two passes over the inputs, one dictionary of groups).
    @Test func hundredThousandRowsUnderBudget() {
        let groups = (0..<2_000).map { _ in UUID() }
        var inputs: [ReclaimableInput] = []
        inputs.reserveCapacity(100_000)
        let drives = ["/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9", "/Volumes/Gone"]
        for i in 0..<100_000 {
            // Even rows belong to a group; the group's FIRST member (the
            // one in 0..<2000) is its keeper, every later one an extra copy.
            let inGroup = i % 2 == 0
            let g = inGroup ? groups[i % groups.count] : nil
            inputs.append(row("\(drives[i % 4])/f\(i % 30)/clip\(i).mov",
                              bytes: Int64(1 + i % 9) * 100_000_000,
                              extra: inGroup && i >= groups.count,
                              keeper: inGroup && i < groups.count,
                              group: g, digest: i % 3 == 0,
                              checked: i % 4 == 0 ? nil : Date(timeIntervalSince1970: Double(i))))
        }
        let start = ContinuousClock.now
        let e = ReclaimableCalculator.compute(inputs: inputs, volumeRoot: "/Volumes/SanDisk",
                                              mountedRoots: ["/", "/Volumes/SanDisk", "/Volumes/LaCie", "/Volumes/X9"],
                                              alsoCleanUpWorkingCopies: true)
        let elapsed = ContinuousClock.now - start
        #expect(e.volumeFiles == 25_000)
        #expect(e.copies > 0)
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_000)),
                "reclaimable estimate took \(elapsed) for 100k records — over the 1 s budget")
    }
}
