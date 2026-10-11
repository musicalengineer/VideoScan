import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Volume table Files / Media Size (bug fix 2026-10-11)
//
// docs/reviews/night/diagnose_trash_and_volume_floor_2026_10_10.md §2c:
// the per-volume Media Size counted trashed / removed / set-aside /
// superseded / Manually Deleted rows (so a volume never shrank after a
// delete) and matched "/Volumes/A" against "/Volumes/AB/…". The rows
// summed to ~13.4 TB against a 7.85 TB footer.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — every record state, migrated records, the path boundary,
//               the negative-size clamp.
//   Scale     — 100k records × 20 targets with a time budget (the pass
//               runs on the main actor inside the coalesced recompute).
//   Isolation — pure function over constructed records; no UserDefaults,
//               no filesystem, no shared caches. N/A beyond that.
//   Sensor    — Σ rows == footer TOTAL CATALOG at production scale, plus
//               source pins that the pane reads the shared predicate.
// Media matrix: N/A — catalog metadata only, no file is opened.

private let GB: Int64 = 1_000_000_000

private enum State: CaseIterable {
    case live, purged, setAside, superseded, manuallyDeleted
}

private func rec(
    _ path: String,
    bytes: Int64 = GB,
    state: State = .live,
    origin: String? = nil,
    stream: StreamType = .videoAndAudio
) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.ext = (path as NSString).pathExtension.uppercased()
    r.sizeBytes = bytes
    r.streamTypeRaw = stream.rawValue
    r.originalFullPath = origin
    switch state {
    case .live: break
    case .purged: r.purgedAt = Date(timeIntervalSince1970: 1_000_000); r.lifecycleStage = .trashed
    case .setAside: r.setAsideReason = "tidy"
    case .superseded: r.supersededByID = UUID()
    case .manuallyDeleted: r.archiveStage = .manuallyDeleted
    }
    return r
}

@Suite("Volume Media Size — live records only")
struct VolumeMediaTallyLogicTests {

    let a = UUID(), ab = UUID()

    @Test func onlyRecordsTheFooterCountsAreLive() throws {
        let recs = State.allCases.map { rec("/Volumes/A/\($0).mov", state: $0) }
        let b = try #require(VolumeMediaTally.compute(recs, targets: [(a, "/Volumes/A")])[a])
        #expect(b.liveFiles == 1, "only the live record counts toward Files")
        #expect(b.liveBytes == GB, "trashed / set-aside / superseded / manually deleted bytes are gone from Media Size")
        #expect(b.history.count == State.allCases.count, "history (⌘I, Uncataloged filter) still sees every row")
        for r in recs {
            #expect(CatalogStorageTotalsCalculator.isCounted(r) == (r.filename == "live.mov"),
                    "the column's rule IS the footer's rule")
        }
    }

    @Test func trashingAFileLowersItsVolume() {
        let keep = rec("/Volumes/A/keep.mov", bytes: 3 * GB)
        let gone = rec("/Volumes/A/gone.mov", bytes: 2 * GB)
        let before = VolumeMediaTally.compute([keep, gone], targets: [(a, "/Volumes/A")])[a]
        #expect(before?.liveBytes == 5 * GB)
        gone.purgedAt = Date()
        gone.lifecycleStage = .trashed
        let after = VolumeMediaTally.compute([keep, gone], targets: [(a, "/Volumes/A")])[a]
        #expect(after?.liveBytes == 3 * GB, "the reported bug: the row never went down")
        #expect(after?.liveFiles == 1)
    }

    @Test func siblingVolumeWithALongerNameIsNotSwallowed() {
        let recs = [rec("/Volumes/A/x.mov", bytes: 1 * GB),
                    rec("/Volumes/AB/y.mov", bytes: 7 * GB),
                    rec("/Volumes/A", bytes: 1 * GB)]           // the root itself
        let out = VolumeMediaTally.compute(recs, targets: [(a, "/Volumes/A/"), (ab, "/Volumes/AB")])
        #expect(out[a]?.liveBytes == 2 * GB, "/Volumes/A must not count /Volumes/AB/…")
        #expect(out[a]?.history.count == 2)
        #expect(out[ab]?.liveBytes == 7 * GB)
    }

    @Test func emptyOrRootTargetMatchesNothing() {
        let recs = [rec("/Volumes/A/x.mov")]
        let out = VolumeMediaTally.compute(recs, targets: [(a, ""), (ab, "/")])
        #expect(out[a]?.history.isEmpty == true)
        #expect(out[ab]?.history.isEmpty == true)
    }

    @Test func migratedBytesCountWhereTheFileIsNow() {
        let moved = rec("/Volumes/B/x.mov", bytes: 4 * GB, origin: "/Volumes/A/x.mov")
        let bID = UUID()
        let out = VolumeMediaTally.compute([moved], targets: [(a, "/Volumes/A"), (bID, "/Volumes/B")])
        #expect(out[a]?.liveBytes == 0, "the source volume no longer holds the bytes")
        #expect(out[a]?.history.count == 1, "…but still remembers the record (Uncataloged filter)")
        #expect(out[bID]?.liveBytes == 4 * GB)
    }

    @Test func errorsAndNegativeSizes() {
        let recs = [rec("/Volumes/A/bad.bin", bytes: -5, stream: .ffprobeFailed),
                    rec("/Volumes/A/bad2.bin", state: .purged, stream: .ffprobeFailed)]
        let b = VolumeMediaTally.compute(recs, targets: [(a, "/Volumes/A")])[a]
        #expect(b?.errors == 2, "errors read history, as before")
        #expect(b?.liveBytes == 0, "a negative size is corrupt metadata, not a credit — same clamp as the footer")
        #expect(b?.liveFiles == 1)
    }

    @Test func everyTargetGetsABucketEvenWhenEmpty() {
        let out = VolumeMediaTally.compute([], targets: [(a, "/Volumes/A")])
        #expect(out[a]?.liveFiles == 0)
    }
}

// MARK: - Invariant + scale

/// Deterministic production-shaped catalog. Volume names V0…V19 include
/// prefix collisions (V1 vs V10…V19), so the boundary rule is exercised
/// at scale too.
private func syntheticCatalog(count: Int, volumes: Int) -> [VideoRecord] {
    var out: [VideoRecord] = []
    out.reserveCapacity(count)
    let states = State.allCases
    for i in 0..<count {
        let v = i % volumes
        // ~70% live, the rest spread over the four removed states.
        let state: State = i % 10 < 7 ? .live : states[1 + (i % 4)]
        let origin: String? = i % 17 == 0 ? "/Volumes/V\((v + 1) % volumes)/old/\(i).mov" : nil
        let bytes: Int64 = i % 101 == 0 ? -1 : Int64(1_000 + (i % 977) * 1_000_003)
        out.append(rec("/Volumes/V\(v)/Family/\(i / 100)/clip\(i).mov",
                       bytes: bytes, state: state, origin: origin))
    }
    return out
}

@Suite("Volume Media Size — sum of rows equals the footer")
struct VolumeMediaTallyInvariantTests {

    private func check(_ recs: [VideoRecord], volumes: Int) {
        let targets = (0..<volumes).map { (id: UUID(), searchPath: "/Volumes/V\($0)") }
        let out = VolumeMediaTally.compute(recs, targets: targets)
        let footer = CatalogStorageTotalsCalculator.compute(records: recs)
        let rowBytes = targets.reduce(Int64(0)) { $0 + (out[$1.id]?.liveBytes ?? 0) }
        let rowFiles = targets.reduce(0) { $0 + (out[$1.id]?.liveFiles ?? 0) }
        #expect(rowBytes == footer.grossBytes, "Σ Media Size must equal TOTAL CATALOG")
        #expect(rowFiles == footer.fileCount, "Σ Files must equal the footer's file count")
    }

    @Test func smallMixedCatalog() {
        check(syntheticCatalog(count: 2_000, volumes: 20), volumes: 20)
    }

    /// SENSOR: production scale (100k records, 20 targets — Rick's
    /// catalog is ~14k across ~15). Pins the invariant AND the cost.
    /// Budget: Debug 2026-10-11 measured 0.36 s on the M4 Max; 3 s
    /// leaves CI headroom yet still catches an O(n²) regression.
    @Test func hundredThousandRecordsSumToTheFooterWithinBudget() {
        let volumes = 20
        let recs = syntheticCatalog(count: 100_000, volumes: volumes)
        let targets = (0..<volumes).map { (id: UUID(), searchPath: "/Volumes/V\($0)") }
        let start = Date()
        let out = VolumeMediaTally.compute(recs, targets: targets)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0, "VolumeMediaTally.compute took \(elapsed) s for 100k × 20")
        let footer = CatalogStorageTotalsCalculator.compute(records: recs)
        let rowBytes = targets.reduce(Int64(0)) { $0 + (out[$1.id]?.liveBytes ?? 0) }
        #expect(rowBytes == footer.grossBytes)
        #expect(footer.grossBytes > 0)
        // V1 vs V10…V19: plain-prefix matching would hand V1 ~11× its share.
        let v1 = out[targets[1].id]?.history.count ?? 0
        #expect(v1 < 100_000 / volumes * 2, "V1 swallowed its longer-named siblings (\(v1) rows)")
    }
}

// MARK: - Source sensors

@Suite("Volume Media Size — one predicate (sensors)")
struct VolumeMediaTallySensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func thePaneUsesTheSharedTally() throws {
        let src = try code("CatalogView+ScanTargetsPane.swift")
        let start = try #require(src.range(of: "private func recomputeVolumeAggregates() {"))
        let end = try #require(src.range(of: "func scheduleStorageTotals(onlineVolumes: Set<String>) {",
                                         range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        #expect(body.contains("VolumeMediaTally.compute("))
        #expect(body.contains("mediaBytes: b.liveBytes"))
        #expect(body.contains("files: b.liveFiles"))
        #expect(!body.contains(".hasPrefix("), "a plain string-prefix volume match is back")
        #expect(!body.contains("$1.sizeBytes"), "a raw per-volume byte sum is back")
        #expect(src.contains("(agg?.catalogRecords ?? 0) > 0"),
                "the Uncataloged filter must read history, not the live count")
    }

    /// The other plain-prefix volume match on the volume table: the
    /// "Caption Videos (N)" count and the job it starts share one rule.
    @Test func captionJobAndMenuCountShareOneScopeRule() throws {
        let src = try code("CaptionOrchestrator+Lifecycle.swift")
        #expect(src.contains("VolumeContextMenuRules.captionableVideos("),
                "the caption job must scope with the same rule the menu counts with")
        #expect(!src.contains("r.fullPath.hasPrefix(targetPrefix)"), "the plain-prefix job scope is back")
    }

    @Test func theTallyAsksTheFootersPredicate() throws {
        let tally = try code("VolumeMediaTally.swift")
        #expect(tally.contains("CatalogStorageTotalsCalculator.isCounted("))
        #expect(tally.contains("PathScope.Root("))
        #expect(!tally.contains("isPurged"), "a second copy of the footer's rule")
        let totals = try code("CatalogStorageTotals.swift")
        #expect(totals.contains("for rec in records where isActive(rec) {"),
                "partition must use the same isActive the column's isCounted builds on")
    }
}
