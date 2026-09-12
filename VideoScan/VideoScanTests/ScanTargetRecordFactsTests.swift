// ScanTargetRecordFactsTests.swift
// Pins the Catalog Options menu's per-target projection (codex #1368,
// 2026-09-12). The menu used to run `model.records.contains` /
// `.filter` / `planContentHashBackfill(records:)` once PER SCAN TARGET
// inside the pane's view builder — O(records × targets) per render.
// The projection runs once per records-change trigger; the body reads
// a dictionary. These tests pin:
//   1. PARITY — the projection equals the legacy body expressions,
//      including the deliberate raw-prefix Delete count ("/Volumes/X"
//      counts "/Volumes/X2") and the `isUnder`-scoped signature plan.
//   2. COLD CACHE — no targets → empty; a target with no records → a
//      zeroed entry, never nil.
//   3. PERFORMANCE — the pass at 100k × 20 stays within budget and the
//      body-side read is a dictionary lookup (regression sensor).
//   4. SOURCE SENSOR — the pane's view builder contains no
//      `model.records` expression other than O(1) `.isEmpty` / `.count`.

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct ScanTargetRecordFactsTests {

    private func makeRecord(_ fullPath: String,
                            origin: String? = nil,
                            size: Int64 = 100,
                            hash: String = "",
                            purged: Bool = false,
                            setAside: Bool = false,
                            superseded: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.originalFullPath = origin
        r.contentHash = hash
        if purged { r.purgedAt = Date() }
        if setAside { r.setAsideReason = "still-image" }
        if superseded { r.supersededByID = UUID() }
        return r
    }

    /// The two expressions the pane body used to evaluate per target,
    /// verbatim (CatalogView+ScanTargetsPane.swift before #1368).
    private func legacyDeleteCount(_ records: [VideoRecord], _ searchPath: String) -> Int {
        records.filter { $0.fullPath.hasPrefix(searchPath) || ($0.originalFullPath?.hasPrefix(searchPath) ?? false) }.count
    }
    private func legacyHadRecords(_ records: [VideoRecord], _ searchPath: String) -> Bool {
        records.contains { $0.fullPath.hasPrefix(searchPath) || ($0.originalFullPath?.hasPrefix(searchPath) ?? false) }
    }
    private func legacySignaturePlan(_ records: [VideoRecord], _ searchPath: String)
        -> VideoScanModel.ContentHashBackfillPlan {
        VideoScanModel.planContentHashBackfill(
            records: records, isReachable: { _ in true }, pathPrefix: searchPath)
    }

    private func fixture() -> (records: [VideoRecord], targets: [ScanTargetRecordFacts.Target]) {
        let records: [VideoRecord] = [
            makeRecord("/Volumes/A/a1.mov", hash: "sig"),          // A, signed
            makeRecord("/Volumes/A/a2.mov"),                       // A, candidate
            makeRecord("/Volumes/A/sub/a3.mov", size: 0),          // A, zero-byte: counted, not planned
            makeRecord("/Volumes/A2/x.mov"),                       // raw prefix trap: A's Delete count, not A's plan
            makeRecord("/Volumes/B/b1.mov", origin: "/Volumes/A/moved.mov"),   // migrated A→B: both count it
            makeRecord("/Volumes/B/b2.mov", purged: true),         // counted, not planned
            makeRecord("/Volumes/B/Sub/s1.mov", setAside: true),   // counted (B and B/Sub), not planned
            makeRecord("/Volumes/B/Sub/s2.mov", hash: "sig"),      // B and B/Sub, signed
            makeRecord("/Volumes/B/Sub/s3.mov", superseded: true), // counted, not planned
            makeRecord("/Volumes/C/c1.mov", origin: "/Volumes/A"), // origin == prefix exactly (isUnder's == arm)
            makeRecord("/Volumes/A", hash: ""),                    // fullPath == prefix exactly
        ]
        let targets: [ScanTargetRecordFacts.Target] = [
            (UUID(), "/Volumes/A"),
            (UUID(), "/Volumes/A2"),
            (UUID(), "/Volumes/B"),
            (UUID(), "/Volumes/B/Sub"),
            (UUID(), "/Volumes/B/"),        // trailing slash form
            (UUID(), "/Volumes/Gone"),      // no records
            (UUID(), ""),                   // empty search path (unset target)
        ]
        return (records, targets)
    }

    @Test
    func parityWithLegacyBodyExpressions() {
        let (records, targets) = fixture()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        #expect(facts.count == targets.count)
        for t in targets {
            let f = try! #require(facts[t.id])
            #expect(f.records == legacyDeleteCount(records, t.searchPath),
                    "Delete count for \(t.searchPath)")
            #expect((f.records > 0) == legacyHadRecords(records, t.searchPath),
                    "Delete row presence for \(t.searchPath)")
            #expect(f.signaturePlan == legacySignaturePlan(records, t.searchPath),
                    "signature plan for \(t.searchPath)")
        }
        // Spot values so a parity bug in BOTH sides cannot hide.
        let a = facts[targets[0].id]!
        #expect(a.records == 7)                     // a1 a2 a3 A2/x moved-origin c1-origin "/Volumes/A"
        #expect(a.signaturePlan.candidates == 4)    // a2, b1 (origin under A), c1 (origin == A), "/Volumes/A" — not A2/x, not zero-byte a3
        #expect(a.signaturePlan.alreadyHashed == 1) // a1
        #expect(a.signaturePlan.unreachable == 0)
        let a2 = facts[targets[1].id]!
        #expect(a2.records == 1 && a2.signaturePlan.candidates == 1)
        let bSub = facts[targets[3].id]!
        #expect(bSub.records == 3 && bSub.signaturePlan.alreadyHashed == 1 && bSub.signaturePlan.candidates == 0)
        #expect(facts[targets[5].id] == ScanTargetRecordFacts())
        #expect(facts[targets[6].id]!.records == records.count)
    }

    @Test
    func coldCacheShapes() {
        let (records, _) = fixture()
        #expect(ScanTargetRecordFacts.project([], targets: []).isEmpty)
        #expect(ScanTargetRecordFacts.project(records, targets: []).isEmpty)
        let lonely: [ScanTargetRecordFacts.Target] = [(UUID(), "/Volumes/Nothing")]
        let facts = ScanTargetRecordFacts.project([], targets: lonely)
        #expect(facts[lonely[0].id] == ScanTargetRecordFacts(),
                "a target with no records gets a zeroed entry, never nil")
    }

    private func scaleFixture() -> (records: [VideoRecord], targets: [ScanTargetRecordFacts.Target]) {
        let volumes = (0..<20).map { "/Volumes/Perf\($0)" }
        let records: [VideoRecord] = (0..<100_000).map { i in
            makeRecord("\(volumes[i % 20])/dir\(i % 37)/clip\(i).mov",
                       origin: i % 11 == 0 ? "\(volumes[(i + 1) % 20])/old/clip\(i).mov" : nil,
                       hash: i % 3 == 0 ? "sig\(i)" : "",
                       purged: i % 50 == 0)
        }
        return (records, volumes.map { (UUID(), $0) })
    }

    // Budget is generous (Debug build, loaded test hosts). Measured
    // 2026-09-12 on the M4 Max at 100k × 20: this pass 0.056 s Release /
    // 0.26 s Debug, ONCE per records-change event; the legacy body
    // expressions it replaces (contains + filter + plan per target)
    // cost 0.57 s Release / 1.1 s Debug PER BODY EVALUATION.
    @Test
    func projectionPassStaysWithinBudgetAtScale() {
        let (records, targets) = scaleFixture()
        let start = Date()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        let elapsed = Date().timeIntervalSince(start)
        print("ScanTargetRecordFacts.project 100k×20: \(String(format: "%.3f", elapsed)) s")
        #expect(facts.count == 20)
        // 5,000 live on each volume + 1/11th of the catalog double-counted
        // on its origin volume.
        let t0 = facts[targets[0].id]!
        #expect(t0.records > 5_000 && t0.records < 6_000)
        #expect(elapsed < 1.0,
                "projection at 100k×20 must stay well under 1 s (got \(elapsed)s)")
    }

    @Test
    func bodySideReadIsADictionaryLookup() {
        let (records, targets) = scaleFixture()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        // What the body does per target per render, 100k times over:
        // must not scale with `records` at all.
        let start = Date()
        var acc = 0
        for i in 0..<100_000 {
            let t = targets[i % 20]
            acc &+= facts[t.id]?.records ?? 0
            acc &+= facts[t.id]?.signaturePlan.candidates ?? 0
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(acc > 0)
        #expect(elapsed < 0.5, "100k body-side reads must be O(1) each (got \(elapsed)s)")
    }


    /// Source sensor: the pane's view builder must not walk the catalog.
    /// Scans every `var …: some View {` / `@ViewBuilder` region in
    /// CatalogView+ScanTargetsPane.swift for `model.records` used as
    /// anything but the O(1) `.isEmpty` / `.count`. Same shape as the
    /// repo's other source-pinning sensors; matches the project rule
    /// "NO O(records) work in view bodies".
    @Test
    func paneViewBuilderHasNoRecordsWalk() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = repoRoot
            .appendingPathComponent("VideoScan/VideoScan/CatalogView+ScanTargetsPane.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")

        let regionStart = try NSRegularExpression(
            pattern: #"^\s*(?:private |fileprivate |internal |public )?(?:var \w+\s*:\s*some View\s*\{|@ViewBuilder\b)"#)
        let forbidden = try NSRegularExpression(
            pattern: #"\bmodel\.records\b(?!\.isEmpty\b)(?!\.count\b)"#)

        var regions = 0
        var offenders: [String] = []
        var depth = 0
        var inRegion = false
        for (idx, raw) in lines.enumerated() {
            // Strip line comments so prose about the rule can't trip it.
            let code = raw.components(separatedBy: "//").first ?? raw
            let range = NSRange(code.startIndex..., in: code)
            if !inRegion {
                if regionStart.firstMatch(in: code, range: range) != nil {
                    inRegion = true
                    regions += 1
                    depth = 0
                } else {
                    continue
                }
            }
            if forbidden.firstMatch(in: code, range: range) != nil {
                offenders.append("line \(idx + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
            for ch in code {
                if ch == "{" { depth += 1 }
                if ch == "}" { depth -= 1 }
            }
            if depth <= 0 && code.contains("}") { inRegion = false }
        }
        #expect(regions >= 1, "sensor must find at least one view-builder region")
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty,
                "O(records) expression(s) inside the pane's view builder:\n\(report)")
    }
}
