// ScanTargetRecordFactsTests.swift
// Pins the Catalog Options menu's per-target projection (codex #1368,
// 2026-09-12; #1393 same day). The menu used to run `model.records.contains`
// / `.filter` / `planContentHashBackfill(records:)` once PER SCAN TARGET
// inside the pane's view builder — O(records × targets) per render.
// The projection runs once per catalog mutation; the body reads a
// dictionary. These tests pin:
//   1. PARITY — the signature plan equals the legacy body expression;
//      the Delete count equals what the GUARDED REMOVAL removes
//      (TargetRemovalScope), including the three cases the raw-prefix
//      count got wrong: "/Volumes/X" vs "/Volumes/X2", origin-only rows,
//      nested targets (codex #1393 MAJOR 2).
//   2. INVALIDATION — `catalogMutationRevision` moves, and the projection
//      changes, for the four mutations the old trigger set missed: Tidy
//      apply/undo, Confirm Repair/undo, a same-count scan merge, and a
//      Browse… re-point (codex #1393 MAJOR 1). None changes records.count.
//   3. COLD CACHE — no targets → empty; a target with no records → a
//      zeroed entry, never nil.
//   4. PERFORMANCE — the pass at 100k × 20 stays within budget and the
//      body-side read is a dictionary lookup (regression sensor).
//   5. SOURCE SENSORS — the pane's view builder and ContentView's Delete
//      alert contain no `model.records` expression other than O(1)
//      `.isEmpty` / `.count` (not `.count(where:)`); the pane observes
//      the one authoritative revision.

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
        r.partialMD5 = "md5-\(fullPath)"
        r.originalFullPath = origin
        r.contentHash = hash
        if purged { r.purgedAt = Date() }
        if setAside { r.setAsideReason = "still-image" }
        if superseded { r.supersededByID = UUID() }
        return r
    }

    private func targets(of model: VideoScanModel) -> [ScanTargetRecordFacts.Target] {
        model.scanTargets.map { ($0.id, $0.searchPath) }
    }

    private func project(_ model: VideoScanModel) -> [UUID: ScanTargetRecordFacts] {
        ScanTargetRecordFacts.project(model.records, targets: targets(of: model))
    }

    /// The raw-prefix count the pane body used to show (pre-#1393) —
    /// kept ONLY so the sensors can prove where it diverges from removal.
    private func legacyRawCount(_ records: [VideoRecord], _ searchPath: String) -> Int {
        records.filter { $0.fullPath.hasPrefix(searchPath) || ($0.originalFullPath?.hasPrefix(searchPath) ?? false) }.count
    }
    /// The One Volume… expression the pane body used to evaluate, verbatim.
    private func legacySignaturePlan(_ records: [VideoRecord], _ searchPath: String)
        -> VideoScanModel.ContentHashBackfillPlan {
        VideoScanModel.planContentHashBackfill(
            records: records, isReachable: { _ in true }, pathPrefix: searchPath)
    }

    // MARK: - 1. Parity

    private func fixture() -> (records: [VideoRecord], targets: [ScanTargetRecordFacts.Target]) {
        let records: [VideoRecord] = [
            makeRecord("/Volumes/A/a1.mov", hash: "sig"),          // A, signed
            makeRecord("/Volumes/A/a2.mov"),                       // A, candidate
            makeRecord("/Volumes/A/sub/a3.mov", size: 0),          // A, zero-byte: removed, not planned
            makeRecord("/Volumes/A2/x.mov"),                       // sibling trap: never A's
            makeRecord("/Volumes/B/b1.mov", origin: "/Volumes/A/moved.mov"),   // migrated A→B: A's plan, B's removal
            makeRecord("/Volumes/B/b2.mov", purged: true),         // removed, not planned
            makeRecord("/Volumes/B/Sub/s1.mov", setAside: true),   // Sub's removal (B covers → kept for B)
            makeRecord("/Volumes/B/Sub/s2.mov", hash: "sig"),
            makeRecord("/Volumes/B/Sub/s3.mov", superseded: true),
            makeRecord("/Volumes/C/c1.mov", origin: "/Volumes/A"), // origin == prefix exactly (plan's == arm)
            makeRecord("/Volumes/A", hash: ""),                    // fullPath == prefix exactly
        ]
        let targets: [ScanTargetRecordFacts.Target] = [
            (UUID(), "/Volumes/A"),
            (UUID(), "/Volumes/A2"),
            (UUID(), "/Volumes/B"),
            (UUID(), "/Volumes/B/Sub"),
            (UUID(), "/Volumes/B/"),        // trailing-slash duplicate of B: same root, not "other"
            (UUID(), "/Volumes/Gone"),      // no records
            (UUID(), ""),                   // empty search path (unset target)
        ]
        return (records, targets)
    }

    @Test
    func signaturePlanMatchesLegacyBodyExpression() throws {
        let (records, targets) = fixture()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        #expect(facts.count == targets.count)
        for t in targets {
            let f = try #require(facts[t.id])
            #expect(f.signaturePlan == legacySignaturePlan(records, t.searchPath),
                    "signature plan for \(t.searchPath)")
        }
        let a = try #require(facts[targets[0].id])
        #expect(a.signaturePlan.candidates == 4)    // a2, b1 (origin under A), c1 (origin == A), "/Volumes/A"
        #expect(a.signaturePlan.alreadyHashed == 1) // a1
        #expect(a.signaturePlan.unreachable == 0)
    }

    @Test
    func deleteCountIsTheGuardedRemovalScope() throws {
        let (records, targets) = fixture()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        let roots = targets.map(\.searchPath)
        for t in targets {
            let scope = TargetRemovalScope(root: t.searchPath, allTargetRoots: roots)
            let expected = records.filter { scope.claims($0.fullPath) }.count
            #expect(facts[t.id]?.records == expected, "Delete count for \(t.searchPath)")
        }
        // Spot values.
        #expect(facts[targets[0].id]?.records == 4)   // a1 a2 a3 "/Volumes/A" — NOT A2/x, NOT origin-only rows
        #expect(facts[targets[1].id]?.records == 1)   // A2/x
        #expect(facts[targets[2].id]?.records == 2)   // b1 b2 — Sub rows kept for B/Sub
        #expect(facts[targets[3].id]?.records == 0)   // every Sub row is covered by B
        #expect(facts[targets[4].id]?.records == 2)   // "/Volumes/B/" is B, not another target
        #expect(facts[targets[5].id] == ScanTargetRecordFacts())
        #expect(facts[targets[6].id]?.records == 0, "an empty root can never delete anything")
    }

    /// The three shapes codex #1393 named: the projection must equal the
    /// count `removeCatalogRecords` ACTUALLY removes, and the raw count
    /// must differ so the sensor is proven to bite.
    private func assertProjectionEqualsRemoval(_ model: VideoScanModel,
                                               target: CatalogScanTarget,
                                               legacyDiffers: Bool = true,
                                               _ label: String) {
        let projected = project(model)[target.id]?.records
        let legacy = legacyRawCount(model.records, target.searchPath)
        let outcome = model.removeCatalogRecords(underTargetRoot: target.searchPath, action: "sensor")
        #expect(projected == outcome.removed,
                "\(label): projection \(String(describing: projected)) vs removed \(outcome.removed)")
        if legacyDiffers {
            #expect(legacy != outcome.removed, "\(label): the raw-prefix count must differ or this sensor proves nothing")
        }
    }

    @Test
    func siblingVolumeXvsX2CountsOnlyItsOwnRows() {
        let model = VideoScanModel()
        let x = CatalogScanTarget(searchPath: "/Volumes/X")
        let x2 = CatalogScanTarget(searchPath: "/Volumes/X2")
        model.scanTargets = [x, x2]
        model.records = [
            makeRecord("/Volumes/X/a.mov"), makeRecord("/Volumes/X/b.mov"),
            makeRecord("/Volumes/X2/c.mov"), makeRecord("/Volumes/X2/d.mov"), makeRecord("/Volumes/X2/e.mov"),
        ]
        assertProjectionEqualsRemoval(model, target: x, "X vs X2")
        #expect(model.records.count == 3, "X2's rows survive X's removal")
    }

    @Test
    func originOnlyRowsAreNotCountedForRemoval() {
        let model = VideoScanModel()
        let a = CatalogScanTarget(searchPath: "/Volumes/A")
        let b = CatalogScanTarget(searchPath: "/Volumes/B")
        model.scanTargets = [a, b]
        model.records = [
            makeRecord("/Volumes/B/moved1.mov", origin: "/Volumes/A/moved1.mov"),
            makeRecord("/Volumes/B/moved2.mov", origin: "/Volumes/A/moved2.mov"),
            makeRecord("/Volumes/A/still.mov"),
        ]
        assertProjectionEqualsRemoval(model, target: a, "origin-only rows")
        #expect(model.records.count == 2, "only the row physically under A goes")
    }

    @Test
    func nestedTargetRowsStayWithTheCoveringTarget() {
        let model = VideoScanModel()
        let vol = CatalogScanTarget(searchPath: "/Volumes/V")
        let sub = CatalogScanTarget(searchPath: "/Volumes/V/Sub")
        model.scanTargets = [vol, sub]
        model.records = [
            makeRecord("/Volumes/V/top.mov"),
            makeRecord("/Volumes/V/Sub/s1.mov"), makeRecord("/Volumes/V/Sub/s2.mov"),
        ]
        // Sub: everything under it is covered by V → removal takes nothing.
        assertProjectionEqualsRemoval(model, target: sub, "nested target (inner)")
        #expect(model.records.count == 3)
        // V: Sub's rows are covered by Sub → only top.mov goes.
        assertProjectionEqualsRemoval(model, target: vol, "nested target (outer)")
        #expect(model.records.count == 2)
    }

    // MARK: - 2. Invalidation (codex #1393 MAJOR 1)

    /// Every mutation below leaves `records.count` unchanged; the old
    /// trigger set would not have refreshed the projection.
    private func expectRevisionAndProjectionMove(_ model: VideoScanModel,
                                                 _ label: String,
                                                 _ mutate: () -> Void) {
        let countBefore = model.records.count
        let revBefore = model.catalogMutationRevision
        let factsBefore = project(model)
        mutate()
        #expect(model.records.count == countBefore, "\(label) must not change records.count (the point of the sensor)")
        #expect(model.catalogMutationRevision != revBefore, "\(label) must bump catalogMutationRevision")
        #expect(project(model) != factsBefore, "\(label) must change the projection")
    }

    @Test
    func tidyApplyAndUndoInvalidate() {
        let model = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/T")
        model.scanTargets = [t]
        let still = makeRecord("/Volumes/T/photo.jpg")
        model.records = [still, makeRecord("/Volumes/T/clip.mov")]

        expectRevisionAndProjectionMove(model, "Tidy apply (Remove from Catalog)") {
            #expect(model.removeFromCatalog(recordIDs: [still.id]) == 1)
        }
        #expect(project(model)[t.id]?.signaturePlan.candidates == 1, "a set-aside row leaves the signature plan")
        expectRevisionAndProjectionMove(model, "Tidy undo") {
            #expect(model.undoLastTidyCatalog())
        }
        #expect(project(model)[t.id]?.signaturePlan.candidates == 2)
    }

    @Test
    func confirmRepairAndUndoInvalidate() {
        let model = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/T")
        model.scanTargets = [t]
        let original = makeRecord("/Volumes/T/tape.mov")
        let repair = makeRecord("/Volumes/T/tape_RepairedAudio.mov")
        repair.derivedFrom = original.id
        repair.derivationKind = RebuildAudioFix.derivationKind
        model.records = [original, repair]
        #expect(repair.isAwaitingConfirmation)

        expectRevisionAndProjectionMove(model, "Confirm Repair") {
            #expect(model.confirmRepair(repairID: repair.id))
        }
        #expect(original.isSuperseded)
        #expect(project(model)[t.id]?.signaturePlan.candidates == 1, "a superseded original leaves the signature plan")
        expectRevisionAndProjectionMove(model, "Confirm Repair undo") {
            #expect(model.undoConfirmRepair())
        }
        #expect(project(model)[t.id]?.signaturePlan.candidates == 2)
    }

    @Test
    func sameCountScanMergeInvalidates() async {
        let model = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/S/vids")
        model.scanTargets = [t]
        // Old instance: zero bytes, so it is NOT a signature candidate.
        model.records = [makeRecord("/Volumes/S/vids/clip.mov", size: 0)]
        #expect(project(model)[t.id]?.signaturePlan.candidates == 0)

        let countBefore = model.records.count
        let revBefore = model.catalogMutationRevision
        // The rescan re-saw the same path with real bytes: same count,
        // fresh instance replaces the old one.
        let fresh = makeRecord("/Volumes/S/vids/clip.mov", size: 4_096)
        _ = await model.commitScanResults(root: "/Volumes/S/vids", volName: "S",
                                          targetRecords: [fresh], scanWasComplete: true)
        #expect(model.records.count == countBefore, "same-count merge")
        #expect(model.catalogMutationRevision != revBefore, "a same-count merge must bump catalogMutationRevision")
        #expect(project(model)[t.id]?.signaturePlan.candidates == 1, "the projection follows the merged record")
    }

    @Test
    func browseRepointInvalidates() {
        let model = VideoScanModel()
        let t = CatalogScanTarget(searchPath: "/Volumes/Old")
        model.scanTargets = [t]
        model.records = [makeRecord("/Volumes/New/a.mov"), makeRecord("/Volumes/New/b.mov")]
        #expect(project(model)[t.id]?.records == 0)

        expectRevisionAndProjectionMove(model, "Browse… re-point") {
            #expect(model.repointScanTarget(t, to: "/Volumes/New"))
        }
        #expect(project(model)[t.id]?.records == 2)
        // Scratch volumes are still refused (the ninth ingestion vector).
        #expect(!model.repointScanTarget(t, to: "/Volumes/VideoScan_Temp"))
        #expect(t.searchPath == "/Volumes/New")
    }

    @Test
    func theFunnelsBumpTheRevision() {
        let model = VideoScanModel()
        var rev = model.catalogMutationRevision
        func expectBump(_ label: String, _ body: () -> Void) {
            body()
            #expect(model.catalogMutationRevision != rev, "\(label) must bump catalogMutationRevision")
            rev = model.catalogMutationRevision
        }
        expectBump("records.didSet") { model.records = [makeRecord("/Volumes/F/a.mov")] }
        expectBump("saveCatalogDebounced") { model.saveCatalogDebounced() }
        expectBump("saveCatalogNow") { _ = model.saveCatalogNow() }
        expectBump("notifyVolumeAggregatesStale") { model.notifyVolumeAggregatesStale() }
        expectBump("scanTargets.didSet") { model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/F")] }
        expectBump("notifyTargetsChanged") { model.notifyTargetsChanged() }
    }

    // MARK: - 3. Cold cache

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

    // MARK: - 4. Performance

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
    // 2026-09-12 on the M4 Max at 100k × 20: this pass 0.13 s Release /
    // 0.64 s Debug (#1393, exact removal predicate; was 0.06 / 0.26 with
    // the raw prefix), ONCE per catalog-mutation window; the legacy body
    // expressions it replaces (contains + filter + plan per target) cost
    // 0.54 s Release / 0.94 s Debug PER BODY EVALUATION.
    @Test
    func projectionPassStaysWithinBudgetAtScale() {
        let (records, targets) = scaleFixture()
        let start = Date()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        let elapsed = Date().timeIntervalSince(start)
        print("ScanTargetRecordFacts.project 100k×20: \(String(format: "%.3f", elapsed)) s")
        #expect(facts.count == 20)
        // Exactly 5,000 live on each volume; origin rows no longer count.
        #expect(facts[targets[0].id]?.records == 5_000)
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

    /// codex #1417: the first cut asked one `TargetRemovalScope` per
    /// target per record; with NESTED targets every root contains the
    /// path and every hit re-walks every other root — O(records ×
    /// targets²). Fixture: one volume target plus 19 folder targets
    /// nested in a chain 20 deep, 100k records spread over the depths.
    /// Pins (a) byte-identical results to the per-target scope loop and
    /// (b) a cost that does not blow up against the flat 20-volume
    /// fixture above (same records × targets, same budget).
    @Test
    func nestedTargetsProjectionMatchesScope_worstCaseIsLinearInTargets() {
        var roots = ["/Volumes/Nest"]
        for d in 1..<20 { roots.append(roots[d - 1] + "/level\(d)") }
        let targets: [ScanTargetRecordFacts.Target] = roots.map { (UUID(), $0) }
        let records: [VideoRecord] = (0..<100_000).map { i in
            makeRecord("\(roots[i % 20])/clip\(i).mov", hash: i % 3 == 0 ? "sig" : "")
        }

        let start = Date()
        let facts = ScanTargetRecordFacts.project(records, targets: targets)
        let elapsed = Date().timeIntervalSince(start)
        print("ScanTargetRecordFacts.project nested 100k×20: \(String(format: "%.3f", elapsed)) s")

        // Equivalence with the removal's own predicate, per target.
        let scopes = roots.map { TargetRemovalScope(root: $0, allTargetRoots: roots) }
        for (i, t) in targets.enumerated() {
            let expected = records.reduce(0) { $0 + (scopes[i].claims($1.fullPath) ? 1 : 0) }
            #expect(facts[t.id]?.records == expected, "target \(i) (\(roots[i]))")
        }
        // A record at depth d sits under roots 0…d. Only depth-0 files
        // (directly in the volume root) are under exactly ONE root, so
        // the volume target claims its own 5,000 and every nested
        // folder target — all covered by its ancestors — claims none.
        #expect(facts[targets[0].id]?.records == 5_000, "volume root: its direct files are under no other target")
        #expect(facts[targets[1].id]?.records == 0, "first nested folder is covered by the volume target")
        #expect(facts[targets[19].id]?.records == 0, "deepest nested root is covered by all 19 ancestors")
        #expect(elapsed < 1.0,
                "nested 100k×20 must cost the same order as flat 100k×20 (got \(elapsed)s)")
    }


    // MARK: - 5. Source sensors

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// `model.records` used as anything but O(1) `.isEmpty` / `.count`.
    /// `.count(where:)` is a walk and is NOT allowed (codex #1393).
    private static let forbiddenRecordsUse = try! NSRegularExpression(
        pattern: #"\bmodel\.records\b(?!\.isEmpty\b)(?!\.count\b(?!\s*\())"#)

    /// Walk `lines` from every line matching `regionStart`, brace-counted
    /// to the region's close, collecting forbidden uses. Line comments are
    /// stripped so prose about the rule can't trip it.
    private func offenders(in lines: [String], regionStart: NSRegularExpression) -> (regions: Int, hits: [String]) {
        var regions = 0
        var hits: [String] = []
        var depth = 0
        var inRegion = false
        for (idx, raw) in lines.enumerated() {
            let code = raw.components(separatedBy: "//").first ?? raw
            let range = NSRange(code.startIndex..., in: code)
            if !inRegion {
                guard regionStart.firstMatch(in: code, range: range) != nil else { continue }
                inRegion = true
                regions += 1
                depth = 0
            }
            if Self.forbiddenRecordsUse.firstMatch(in: code, range: range) != nil {
                hits.append("line \(idx + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
            for ch in code {
                if ch == "{" { depth += 1 }
                if ch == "}" { depth -= 1 }
            }
            if depth <= 0 && code.contains("}") { inRegion = false }
        }
        return (regions, hits)
    }

    @Test
    func paneViewBuilderHasNoRecordsWalk() throws {
        let file = repoRoot.appendingPathComponent("VideoScan/VideoScan/CatalogView+ScanTargetsPane.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        let start = try NSRegularExpression(
            pattern: #"^\s*(?:private |fileprivate |internal |public )?(?:var \w+\s*:\s*some View\s*\{|@ViewBuilder\b)"#)
        let found = offenders(in: lines, regionStart: start)
        #expect(found.regions >= 1, "sensor must find at least one view-builder region")
        let report = found.hits.joined(separator: "\n")
        #expect(found.hits.isEmpty, "O(records) expression(s) inside the pane's view builder:\n\(report)")
    }

    @Test
    func contentViewDeleteAlertHasNoRecordsWalk() throws {
        let file = repoRoot.appendingPathComponent("VideoScan/VideoScan/ContentView.swift")
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        // The alert stage (`withAlerts`) hosts the Delete Volume Catalog
        // confirmation whose message read the same per-target walk.
        let start = try NSRegularExpression(pattern: #"^\s*(?:private )?func withAlerts\b"#)
        let found = offenders(in: lines, regionStart: start)
        #expect(found.regions == 1, "withAlerts must exist exactly once")
        let report = found.hits.joined(separator: "\n")
        #expect(found.hits.isEmpty, "O(records) expression(s) inside ContentView's alert stage:\n\(report)")
    }

    @Test
    func recomputeWindowIsSelfSizing() {
        #expect(CatalogView.aggregateRecomputeWindow(forPassCost: 0.001) == 1.0, "cheap pass: one-second floor")
        #expect(CatalogView.aggregateRecomputeWindow(forPassCost: 0.55) == 2.2, "0.55 s pass: ≤ 25 % duty")
    }

    @Test
    func paneObservesTheOneAuthoritativeRevision() throws {
        let file = repoRoot.appendingPathComponent("VideoScan/VideoScan/CatalogView+ScanTargetsPane.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(source.contains(".onChange(of: model.catalogMutationRevision)"),
                "the pane must be driven by catalogMutationRevision")
        for stale in [".onChange(of: model.records.count)",
                      ".onChange(of: model.lastPurgedBatch)",
                      ".onChange(of: model.volumeAggregatesRevision)",
                      ".onChange(of: model.scanTargets.count)"] {
            #expect(!source.contains(stale), "\(stale) is subsumed by catalogMutationRevision — one trigger, not five")
        }
    }
}
