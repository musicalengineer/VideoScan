// FamilyMapRenderSensorTests.swift
// The Family Map at the REAL tree's size (GH #227 perf pass, 2026-09-29):
// 39,249 people over the BUNDLED border file (189 units, 907 polygon
// pieces, 32.6k vertices), the view mounted in a real window so MapKit
// builds its overlays. Numbers are logged every run; the assertions are
// coarse "not catastrophic" ceilings, load-aware in Debug.
//
// What is measured, in the order the app does it:
//   1. bundled units decode (once per process) — time + footprint delta
//   2. inputs for 39,249 people through the real resolver — wall + CPU
//   3. the tally — CPU
//   4. MKPolygon pieces (once per process) — time + footprint delta
//   5. first layout + first frame of FamilyTreeMapView — main-thread stall
//      and how many times the map content was evaluated
//   6. a click (select a unit) — main-thread stall + content evaluations
//   7. a change of Highlight checks (recompute → new shades) — the same
//   8. footprint at the end
//
// Runs only when hosted in VideoScan.app (the bundled file lives there);
// a bare test host prints why and returns. Never `import MapKit` here
// (MapKitLinkSensorTests). Steps 1–4 always run. Steps 5–8 put a window
// ON SCREEN (MapKit builds no overlays for an ordered-out window), so
// they are opt-in — Rick's M4 rule: no UI on his screen while he works:
//
//     TEST_RUNNER_VS_MAP_RENDER_ONSCREEN=1 xcodebuild test … \
//       -only-testing:VideoScanTests/FamilyMapRenderSensorTests
//
// (VS_MAP_RENDER_ONSCREEN=1 when run from Xcode / a bare xctest.)

import AppKit
import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("FamilyMapRenderSensor", .serialized)
@MainActor
struct FamilyMapRenderSensorTests {

    #if DEBUG
    static let config = "Debug"
    #else
    static let config = "Release"
    #endif

    // MARK: - Helpers

    /// phys_footprint in MB — what Activity Monitor calls "Memory".
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Pump the main runloop in 1 ms slices for `seconds`; returns the
    /// longest slice (a main-thread stall) and the busy total (slices over
    /// 2 ms, i.e. real work rather than the 1 ms timeout).
    @discardableResult
    static func pump(seconds: TimeInterval) -> (worst: TimeInterval, busy: TimeInterval) {
        // Time spent with the machine asleep is not a main-thread stall.
        // Keep runloop deadlines in Date's domain, but measure awake time.
        let clock = SuspendingClock()
        let end = clock.now.advanced(by: .seconds(seconds))
        var worst: TimeInterval = 0, busy: TimeInterval = 0
        while clock.now < end {
            let t0 = clock.now
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
            let dt = TimingBudget.seconds(t0.duration(to: clock.now))
            worst = max(worst, dt)
            if dt > 0.002 { busy += dt }
        }
        return (worst, busy)
    }

    static func ms(_ d: Duration) -> String { String(format: "%.1f ms", TimingBudget.seconds(d) * 1000) }
    static func ms(_ s: TimeInterval) -> String { String(format: "%.1f ms", s * 1000) }
    static func mb(_ x: Double) -> String { String(format: "%.1f MB", x) }

    static func log(_ s: String) {
        let line = "[family-map-render] " + s
        print(line)
        let path = "/tmp/familyMapRenderSensor.log"
        let bytes = Data((line + "\n").utf8)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(bytes); try? h.close()
        } else {
            try? bytes.write(to: URL(fileURLWithPath: path))
        }
    }

    /// The real tree's mix (2026-09-29 totals line: 24,500 of 39,249 placed;
    /// 20,284 country-only; 14,749 unresolved of which 825 recorded but off
    /// the map), spread over EVERY bundled fine unit so the map is at its
    /// busiest. Place strings are "<unit name>, <country label>" — the
    /// spellings the resolver's tables carry — checked to resolve to the
    /// unit before use.
    static func syntheticPlaces(units: FamilyMapUnits, n: Int) -> [String?] {
        var fine: [String] = []
        for u in units.units where u.kind != .country {
            let s = "\(u.name), \(u.country.label)"
            if BirthplaceUnitResolver.resolve(s)?.unitKey == u.key { fine.append(s) }
        }
        let countries = FamilyMap.Country.allCases.map(\.label)
        precondition(fine.count > 100, "only \(fine.count) bundled units resolve by name")
        return (0..<n).map { i in
            let r = i % 1000
            if r < 517 { return countries[i % countries.count] }            // 51.7% country-only
            if r < 624 { return fine[i % fine.count] }                       // 10.7% county / state
            if r < 645 { return "Berlin, Germany" }                          //  2.1% recorded, off the map
            return nil                                                       // 35.5% nothing recorded
        }
    }

    struct Synthetic {
        let inputs: FamilyMapModel.Inputs
        let highlight: TreeWalkHighlighter.Inputs
    }

    static func synthetic(units: FamilyMapUnits, n: Int) -> (Synthetic, inputsWall: Duration, inputsCPU: Duration) {
        let family = ["Breen", "Lamb", "Latta", "McGill", "Hudson", "Stone", "Hill", "Adams", "Alden", "Bradford",
                      "Brewster", "Standish", "Winslow", "Howland", "Warren", "Fuller", "Cooke", "Allerton", "Chilton",
                      "Eaton", "Hopkins", "Mullins", "Priest", "Rogers", "Soule", "Tilley", "White", "Billington"]
        // Typed step by step: the one-line closures with a ternary inside a
        // string concatenation made Xcode 26.3's type-checker give up
        // ("unable to type-check this expression in reasonable time",
        // CI red on f6bdbd10) — Xcode 27 compiled them.
        let surnames: [String] = (0..<n).map { i -> String in
            let base: String = family[(i * 7919) % family.count]
            let trailingSpace: String = (i % 97 == 0) ? " " : ""
            return base + trailingSpace
        }
        let ids: [String] = (0..<n).map { i -> String in "@I\(i)@" }
        let names: [String] = (0..<n).map { i -> String in "Person \(i)" }
        let keys = TreeWalkHighlight.surnameKeys(surnames)
        let places = syntheticPlaces(units: units, n: n)
        let years: [Int?] = (0..<n).map { i -> Int? in
            if i % 11 == 0 { return nil }
            return 1500 + i % 400
        }
        let generations: [Int?] = (0..<n).map { i -> Int? in i % 20 }
        let lines: [TreeWalk.Line] = (0..<n).map { i -> TreeWalk.Line in TreeWalk.Line.allCases[i % 3] }
        let allRegions = BirthplaceClassifier.BirthRegion.allCases
        let regions = (0..<n).map { allRegions[$0 % allRegions.count] }
        let visited = Array(0..<n)

        // A throwaway so the measured build is the only one: `inputs` is
        // non-optional for the caller (no force unwrap on the way out).
        var inputs = FamilyMapModel.inputs(ids: [], names: [], surnames: [], surnameKeys: [], birthPlaces: [],
                                           birthYears: [], generations: [], lines: [], visited: [], regions: [])
        var wall: Duration = .zero
        let cpu = TimingBudget.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                inputs = FamilyMapModel.inputs(ids: ids, names: names, surnames: surnames, surnameKeys: keys,
                                               birthPlaces: places, birthYears: years, generations: generations,
                                               lines: lines, visited: visited, regions: regions)
            }
        }
        let placed = (0..<n).map { o in
            TreeWalkFanLayout.Placed(point: .zero, radius: 2, from: nil, line: lines[o], hasCheck: false,
                                     generation: generations[o] ?? 0, ordinal: Int32(o))
        }
        let facets = TreeWalkHighlight.facets(visited: visited, surnames: surnames, regions: regions)
        let highlight = TreeWalkHighlighter.Inputs(placed: placed, visited: visited, ids: ids, names: names,
                                                   surnameKeys: keys, regions: regions, birthYears: years, facets: facets)
        return (Synthetic(inputs: inputs, highlight: highlight), wall, cpu)
    }

    @MainActor final class Probe {
        var evaluations = 0
        var pieces = 0
        func reset() { evaluations = 0; pieces = 0 }
    }

    /// Wait until the model has published a tally for `considered` people.
    static func waitForTally(_ m: FamilyMapModel, considered: Int) async throws -> Duration {
        let clock = ContinuousClock()
        let t0 = clock.now
        for _ in 0..<600 {
            if m.computed.totals.considered == considered { return clock.now - t0 }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("tally for \(considered) people not published within 3 s")
        return clock.now - t0
    }

    // MARK: - The measurement

    @Test func theBundledMapAtTheRealTreeSize() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Self.log("not hosted in the app (\(Bundle.main.bundleURL.lastPathComponent)) — skipped")
            return
        }
        let n = 39_249
        Self.log("=== \(Self.config), \(TimingBudget.loadDescription()), n=\(n) ===")
        let clock = ContinuousClock()

        // 1. Units.
        let f0 = Self.footprintMB()
        var units: FamilyMapUnits?
        let unitsWall = try await clock.measure { units = try await FamilyMapUnitsCache.shared.units() }
        let u = try #require(units)
        let f1 = Self.footprintMB()
        let pieceCount = u.units.reduce(0) { $0 + $1.polygons.count }
        let vertexCount = u.units.reduce(0) { n, unit in n + unit.polygons.reduce(0) { $0 + $1.outer.count } }
        Self.log("1 units: \(u.count) units, \(pieceCount) pieces, \(vertexCount) vertices; decode \(Self.ms(unitsWall)); footprint +\(Self.mb(f1 - f0)) (\(Self.mb(f1)))")

        // 2. Inputs (the resolver, once per person).
        let (syn, inputsWall, inputsCPU) = Self.synthetic(units: u, n: n)
        let f2 = Self.footprintMB()
        let resolved = syn.inputs.people.unitKeys.compactMap { $0 }.count
        Self.log("2 inputs 39,249: wall \(Self.ms(inputsWall)), cpu \(Self.ms(inputsCPU)); \(resolved) resolved; footprint +\(Self.mb(f2 - f1))")
        #expect(inputsCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(400)), "inputs took \(inputsCPU) cpu (\(PerformanceLane.loadDescription()))")

        // 3. Tally.
        var result: FamilyMapTally.Result?
        let tallyCPU = TimingBudget.measureThreadCPUTime {
            result = try? FamilyMapTally.counts(people: syn.inputs.people, visited: syn.inputs.visited,
                                                unplacedLimit: FamilyMapModel.unplacedLimit)
        }
        let r = try #require(result)
        var computed: FamilyMapModel.Computed?
        let computedWall = clock.measure { computed = FamilyMapModel.computed(from: r, units: u) }
        let c = try #require(computed)
        Self.log("3 tally: cpu \(Self.ms(tallyCPU)); \(r.counts.count) units counted; computed(shades/labels/camera) \(Self.ms(computedWall)); \(c.shades.count) shades")
        #expect(tallyCPU < PerformanceLane.loadAwareDebugCeiling(.milliseconds(150)), "tally took \(tallyCPU) cpu")

        // 4. MKPolygon pieces, once per process.
        let f3 = Self.footprintMB()
        var pieces = 0
        let piecesWall = clock.measure { pieces = FamilyMapShapes.pieces(for: u).count }
        let f4 = Self.footprintMB()
        let piecesAgain = clock.measure { _ = FamilyMapShapes.pieces(for: u) }
        Self.log("4 pieces: \(pieces) MKPolygons built in \(Self.ms(piecesWall)) (cached lookup \(Self.ms(piecesAgain))); footprint +\(Self.mb(f4 - f3))")
        #expect(pieces == pieceCount)

        // 5. Mount the view, first layout, first frame — on screen, opt-in.
        guard ProcessInfo.processInfo.environment["VS_MAP_RENDER_ONSCREEN"] == "1" else {
            Self.log("5–8 skipped: set VS_MAP_RENDER_ONSCREEN=1 (TEST_RUNNER_VS_MAP_RENDER_ONSCREEN=1 via xcodebuild) to mount the map on screen and measure first frame / click / re-shade")
            return
        }
        let model = FamilyMapModel(inputs: syn.inputs, units: u, displayNames: ["Rick", "Donna"])
        let highlighter = TreeWalkHighlighter(inputs: syn.highlight)
        model.bind(to: highlighter)
        model.apply(selection: highlighter.selection, yearCeiling: nil)
        let applyWall = try await Self.waitForTally(model, considered: n)
        Self.log("5a model.apply → published: \(Self.ms(applyWall)) (off-main tally + computed + hop)")

        let probe = Probe()
        FamilyTreeMapView.mapContentProbe = { count in
            MainActor.assumeIsolated { probe.evaluations += 1; probe.pieces = count }
        }
        defer { FamilyTreeMapView.mapContentProbe = nil }

        let f5 = Self.footprintMB()
        let hosting = NSHostingView(rootView: FamilyTreeMapView(model: model, highlighter: highlighter, onBack: {}))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1100, height: 720),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "FamilyMapRenderSensor"
        window.contentView = hosting
        let layoutWall = clock.measure { hosting.layoutSubtreeIfNeeded() }
        window.orderFrontRegardless()
        let first = Self.pump(seconds: 3.0)
        let f6 = Self.footprintMB()
        Self.log("5b mount: layoutSubtreeIfNeeded \(Self.ms(layoutWall)); first 3 s on screen: worst main-thread slice \(Self.ms(first.worst)), busy \(Self.ms(first.busy)); map content evaluated \(probe.evaluations)× (\(probe.pieces) pieces); footprint +\(Self.mb(f6 - f5)) (\(Self.mb(f6)))")
        #expect(probe.pieces == pieceCount)
        let evaluationsAtRest = probe.evaluations

        // 6. Clicks: select a counted unit by key (the panel + the stroke),
        //    then by coordinate (the point-in-polygon path), five each.
        let countedFine = c.counts.keys.filter { !FamilyMapKey.isCountryKey($0) }.sorted()
        #expect(countedFine.count > 50, "the synthetic mix should shade most fine units, got \(countedFine.count)")
        var clickWorst: [TimeInterval] = [], clickBusy: [TimeInterval] = [], clickEvals: [Int] = []
        // The selection call ITSELF is synchronous main-thread work that
        // runs before `pump` starts counting (codex re-check F3), so it is
        // timed on its own — awake time, like `pump`, so a sleeping Mac
        // cannot fail it.
        let awake = SuspendingClock()
        var keySelect: [Duration] = []
        // Three keys from the START of the (key-sorted) piece list and two
        // from the END: if MapKit rebuilds every overlay after the first
        // changed one, the late keys are cheap and the early ones are not.
        let pieceIndex: [String: Int] = {
            var out: [String: Int] = [:]
            for (i, unit) in u.units.enumerated() { out[unit.key] = i }
            return out
        }()
        let clickKeys = Array(countedFine.prefix(3)) + Array(countedFine.suffix(2))
        for key in clickKeys {
            probe.reset()
            let sel = awake.measure { model.select(unitKey: key) }
            keySelect.append(sel)
            let p = Self.pump(seconds: 0.5)
            clickWorst.append(p.worst)
            clickBusy.append(p.busy)
            clickEvals.append(probe.evaluations)
        }
        let keySelectText: String = keySelect.map { (d: Duration) -> String in Self.ms(d) }.joined(separator: ", ")
        Self.log("6a click by key ×5 \(clickKeys.map { "\($0)@\(pieceIndex[$0] ?? -1)" }): select(unitKey:) \(keySelectText); worst slice \(clickWorst.map(Self.ms).joined(separator: ", ")); busy \(clickBusy.map(Self.ms).joined(separator: ", ")); content evaluations \(clickEvals)")
        // The same key again: `selectedKey` is assigned the SAME value, so
        // objectWillChange fires and the body re-runs with IDENTICAL map
        // content — the cost of re-declaring 907 unchanged polygons.
        probe.reset()
        let sameSelect = awake.measure { model.select(unitKey: clickKeys[clickKeys.count - 1]) }
        keySelect.append(sameSelect)
        let same = Self.pump(seconds: 0.5)
        Self.log("6a' identical content re-evaluation: worst slice \(Self.ms(same.worst)), busy \(Self.ms(same.busy)); content evaluations \(probe.evaluations)")
        var coordWorst: [TimeInterval] = [], coordSelect: [Duration] = [], coordEvals: [Int] = [], picked: [String] = []
        for key in countedFine.prefix(5) {
            let unit = try #require(u.unit(forKey: key))
            let centre = unit.cameraBox.center
            probe.reset()
            let sel = awake.measure { model.select(coordinate: centre) }
            coordSelect.append(sel)
            picked.append(model.selectedKey ?? "-")
            let p = Self.pump(seconds: 0.5)
            coordWorst.append(p.worst)
            coordEvals.append(probe.evaluations)
        }
        Self.log("6b click by coordinate ×5: select(coordinate:) \(coordSelect.map(Self.ms).joined(separator: ", ")); picked \(picked); worst slice \(coordWorst.map(Self.ms).joined(separator: ", ")); content evaluations \(coordEvals)")

        // 7. A change of checks: the Highlight's top surname → recompute → new shades.
        probe.reset()
        let top = try #require(syn.highlight.facets.surnames.first?.key)
        highlighter.setSurname(top, on: true)
        let expected = syn.highlight.surnameKeys.filter { $0 == top }.count
        let publish = try await Self.waitForTally(model, considered: expected)
        let p7 = Self.pump(seconds: 1.0)
        Self.log("7 surname check (\(expected) people) → published \(Self.ms(publish)); then worst slice \(Self.ms(p7.worst)), busy \(Self.ms(p7.busy)); content evaluations \(probe.evaluations); \(model.computed.shades.count) shades now")
        probe.reset()
        highlighter.clear()
        let publishClear = try await Self.waitForTally(model, considered: n)
        let p7b = Self.pump(seconds: 1.0)
        Self.log("7b clear → published \(Self.ms(publishClear)); worst slice \(Self.ms(p7b.worst)), busy \(Self.ms(p7b.busy)); content evaluations \(probe.evaluations)")

        // 8. Footprint at the end; units are one instance per process.
        let f8 = Self.footprintMB()
        let again = try await FamilyMapUnitsCache.shared.units()
        #expect(again.count == u.count)
        Self.log("8 footprint end \(Self.mb(f8)) (Δ since start +\(Self.mb(f8 - f0))); content evaluations at rest \(evaluationsAtRest)")
        window.orderOut(nil)

        // Coarse ceiling: a click must never stall the main thread for ten
        // frames at 60 Hz (Debug, load-aware).
        let stallCeiling = TimingBudget.seconds(PerformanceLane.loadAwareDebugCeiling(.milliseconds(170)))
        #expect((clickWorst.max() ?? 0) < stallCeiling, "a click stalled the main thread \(Self.ms(clickWorst.max() ?? 0)) (\(PerformanceLane.loadDescription()))")
        #expect((coordWorst.max() ?? 0) < stallCeiling, "a coordinate click stalled the main thread \(Self.ms(coordWorst.max() ?? 0)) (\(PerformanceLane.loadDescription()))")
        // The same ceiling on the selection call itself (codex re-check F3).
        let keySelectWorst: TimeInterval = Self.worstSeconds(keySelect)
        let coordSelectWorst: TimeInterval = Self.worstSeconds(coordSelect)
        #expect(keySelectWorst < stallCeiling, "select(unitKey:) itself took \(Self.ms(keySelectWorst)) (\(PerformanceLane.loadDescription()))")
        #expect(coordSelectWorst < stallCeiling, "select(coordinate:) itself took \(Self.ms(coordSelectWorst)) (\(PerformanceLane.loadDescription()))")
    }

    /// The longest of a set of measured durations, in seconds (0 when empty).
    static func worstSeconds(_ durations: [Duration]) -> TimeInterval {
        var worst: TimeInterval = 0
        for d in durations {
            let s = TimingBudget.seconds(d)
            if s > worst { worst = s }
        }
        return worst
    }

    // MARK: - Headless pins (always run; no window)

    /// codex re-check F3: the on-screen step 6 must gate the synchronous
    /// selection calls themselves, not only the pump after them. Step 6
    /// only runs on screen, so this reads its own source and pins the
    /// shape — awake-time measurement of both selections, and a gate on
    /// each. The needles are built from pieces so this test's own text
    /// cannot satisfy them.
    @Test func selectionItselfIsGatedNotOnlyThePump() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let stepStart = try #require(source.range(of: "// 6" + ". Clicks"))
        let stepEnd = try #require(source.range(of: "// 7" + ". A change of checks"))
        let step6 = String(source[stepStart.upperBound..<stepEnd.lowerBound])
        #expect(step6.contains("let awake = " + "SuspendingClock()"), "selections are timed on awake time")
        #expect(step6.contains("awake.measure { model." + "select(unitKey: key) }"), "each key selection is measured")
        #expect(step6.contains("awake.measure { model." + "select(coordinate: centre) }"), "each coordinate selection is measured")
        let gateStart = try #require(source.range(of: "// Coarse ceiling" + ": a click"))
        let gate = String(source[gateStart.upperBound...])
        #expect(gate.contains("#expect(keySelectWorst" + " < stallCeiling"), "key selection duration is gated")
        #expect(gate.contains("#expect(coordSelectWorst" + " < stallCeiling"), "coordinate selection duration is gated")
        #expect(gate.contains("#expect((clickWorst.max() ?? 0)" + " < stallCeiling"), "the post-selection pump gate stays")
        #expect(gate.contains("#expect((coordWorst.max() ?? 0)" + " < stallCeiling"), "the post-selection coordinate pump gate stays")
    }

    /// `worstSeconds` is what the gates compare — pinned headlessly.
    @Test func worstSecondsIsTheLongestDuration() {
        let none: [Duration] = []
        #expect(Self.worstSeconds(none) == 0)
        let some: [Duration] = [.milliseconds(12), .milliseconds(240), .milliseconds(3)]
        #expect(abs(Self.worstSeconds(some) - 0.240) < 0.000_001)
    }
}
