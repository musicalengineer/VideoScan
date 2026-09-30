// FamilyTreeWalkAnimation.swift
// The FOREGROUND Family Tree Walk: a radial pedigree fan that lights up
// person by person, generation by generation, as the walk reached them
// (Rick 2026-09-27: "animated, watchable").
//
// WHAT YOU SEE. The start people sit at the centre — Rick a little left,
// Donna a little right. Each generation is a ring further out. Every person
// is placed inside the angular slice of the child the walk first reached
// them through: that child's slice is split between its parents, father
// first — so Rick's ancestors fan out over the left half of the circle,
// Donna's over the right, and the fan thins to hair-width by generation 20.
// A newly reached person appears as a bright dot with a soft halo and a
// faint spoke back to the child; dots are coloured by line (Rick blue,
// Donna rose, BOTH violet — pedigree collapse lights up the far side —
// none grey) and a person with a check gets a small amber mark. When the
// replay ends every dot is in its line colour — the white "just revealed"
// look is only ever the batch being revealed right now.
//
// FIT (Rick 2026-09-27: "it doesn't fit"). The layout is computed in ring
// units around the origin, then scaled so every dot AND its reveal halo
// lies inside the canvas with a margin, with the origin at the canvas
// centre — the two sides get the same room, whatever the depth. The view
// then scales the whole canvas to the space the sheet has (Canvas draws in
// layout coordinates under one transform), so the fan shrinks with the
// window instead of running off it.
//
// HOW IT STAYS CHEAP (no O(people) work in a SwiftUI body):
//   • The walk itself ran in Core, off the main actor, before the
//     animation starts (~50 ms of analysis for Rick's 39k tree); this
//     REPLAYS its layers at the chosen pace (default 600 people/s,
//     30…6,000, or Instant). The side panel says so, so a slow replay is
//     never mistaken for a slow algorithm.
//   • `TreeWalkFanLayout` computes every position once, off-main.
//   • Revealed dots are drawn once into an offscreen bitmap (the trail).
//     Each tick (≤ 30 Hz) draws only that tick's batch into it and
//     publishes a new `Frame`: the trail image + the batch (the "frontier"
//     glow) + counters. The Canvas draws one image and ≤ batch dots.
//   • Memory: the trail bitmap is 1,200 × 1,200 px × 4 B ≈ 5.8 MB, plus the
//     prepared layout (8 bytes × people visited).
//
// (For Rick: `Canvas` ≈ an immediate-mode paint callback like drawRect;
// `TimelineView(.animation)` ≈ a display-link timer that re-runs it;
// `gc.scaleBy` ≈ pushing a scale onto the CTM before painting.)

import AppKit
import Combine
import SwiftUI
import VideoScanCore

// MARK: - Layout (pure)

/// Positions for every visited person: the fan described above.
struct TreeWalkFanLayout: Sendable {
    struct Placed: Sendable, Equatable {
        let point: CGPoint
        let radius: CGFloat
        let from: CGPoint?
        let line: TreeWalk.Line
        let hasCheck: Bool
        let generation: Int
        /// The person (the walk's ordinal) — what the highlight matches on.
        let ordinal: Int32
    }

    /// The reveal halo's largest radius as a multiple of the dot's (the
    /// view pulses it between 2.2× and 3.2×). The fit keeps it inside.
    static let haloFactor: CGFloat = 3.2
    /// Clear space between the outermost halo and the canvas edge.
    static let margin: CGFloat = 8
    /// The two start people sit this many rings either side of the centre.
    static let startOffset = 0.35

    static func dotRadius(generation g: Int) -> CGFloat { max(1.2, 5.5 - 0.22 * CGFloat(g)) }

    let size: CGSize
    /// In visit order (generation by generation) — the replay order.
    let placed: [Placed]
    let layerEnds: [Int]
    let maxGeneration: Int
    /// Points per generation ring after the fit.
    let ringSpacing: CGFloat

    init(result: TreeWalk.Result, size: CGSize) {
        self.size = size
        let visits = result.layers.flatMap { $0 }
        maxGeneration = max(1, result.layers.count - 1)
        var ends: [Int] = []
        var running = 0
        for layer in result.layers { running += layer.count; ends.append(running) }
        layerEnds = ends

        // Pass 1 — ring units, origin at (0, 0), y up. Angular interval per
        // ordinal (sparse: only visited people).
        var lo: [Int32: Double] = [:], hi: [Int32: Double] = [:]
        lo.reserveCapacity(visits.count); hi.reserveCapacity(visits.count)
        var unit: [(x: Double, y: Double)] = []
        unit.reserveCapacity(visits.count)
        let startCount = max(1, result.layers.first?.count ?? 1)
        for v in visits {
            let a0: Double, a1: Double
            if v.from < 0 {
                if startCount == 1 {
                    a0 = 0; a1 = 2 * .pi
                } else {
                    // First start: the left half; second: the right half.
                    a0 = v.slot == 0 ? .pi / 2 : -.pi / 2
                    a1 = a0 + .pi
                }
            } else {
                let plo = lo[v.from] ?? 0, phi = hi[v.from] ?? 2 * .pi
                let share = (phi - plo) / Double(max(1, v.slots))
                // Father first, counter-clockwise from the slice's start.
                a0 = plo + share * Double(v.slot)
                a1 = a0 + share
            }
            lo[v.ordinal] = a0; hi[v.ordinal] = a1
            if v.from < 0 {
                unit.append((startCount == 1 ? 0 : (v.slot == 0 ? -Self.startOffset : Self.startOffset), 0))
            } else {
                let mid = (a0 + a1) / 2, g = Double(v.generation)
                unit.append((g * cos(mid), g * sin(mid)))
            }
        }

        // Pass 2 — the fit: the largest ring spacing k with every node's
        // |unit| × k + its halo inside half the canvas less the margin,
        // on both axes. Centred on the origin, so both sides get the same
        // room. Capped at (half the short side) ÷ depth so a shallow or
        // one-person walk is not blown up to the edges.
        let halfW = size.width / 2 - Self.margin, halfH = size.height / 2 - Self.margin
        var k = max(1, min(halfW, halfH)) / CGFloat(maxGeneration)
        for (i, v) in visits.enumerated() {
            let e = Self.dotRadius(generation: Int(v.generation)) * Self.haloFactor
            let ux = CGFloat(abs(unit[i].x)), uy = CGFloat(abs(unit[i].y))
            if ux > 1e-9 { k = min(k, (halfW - e) / ux) }
            if uy > 1e-9 { k = min(k, (halfH - e) / uy) }
        }
        k = max(k, 0.01)
        ringSpacing = k

        // Pass 3 — canvas coordinates (top-left origin, y down).
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var point: [Int32: CGPoint] = [:]
        point.reserveCapacity(visits.count)
        var out: [Placed] = []
        out.reserveCapacity(visits.count)
        for (i, v) in visits.enumerated() {
            let p = CGPoint(x: center.x + k * CGFloat(unit[i].x), y: center.y - k * CGFloat(unit[i].y))
            point[v.ordinal] = p
            out.append(Placed(point: p, radius: Self.dotRadius(generation: Int(v.generation)),
                              from: v.from < 0 ? nil : point[v.from], line: v.line,
                              hasCheck: v.hasCheck, generation: Int(v.generation), ordinal: v.ordinal))
        }
        placed = out
    }
}

// MARK: - The frame model

@MainActor
final class TreeWalkAnimator: ObservableObject {

    /// What the Canvas draws: one image and at most one batch of dots.
    struct Frame {
        var trail: CGImage?
        /// This tick's reveal — the glowing frontier. Bounded by the batch
        /// size, never by the number of people. EMPTY once `finished`:
        /// at the end every dot is settled in the trail, in its line colour.
        var recent: [TreeWalkFanLayout.Placed] = []
        var visited = 0
        var total = 0
        var generation = 0
        /// People with at least one check (the amber marks).
        var peopleWithChecks = 0
        var byLine: [TreeWalk.Line: Int] = [:]
        var finished = false
    }

    static let ticksPerSecond = 30.0
    /// The most dots one tick may draw, whatever the speed ("Instant" is
    /// many ticks of this, so the window stays responsive).
    static let maxBatch = 4_000

    @Published private(set) var frame = Frame()
    @Published var nodesPerSecond: Double = 600
    @Published var instant = false
    @Published var paused = false

    let layout: TreeWalkFanLayout
    let summary: TreeWalk.Summary
    let displayNames: [String]
    private var cursor = 0
    private var carry = 0.0
    private let context: CGContext?
    private let scale: CGFloat
    private var runTask: Task<Void, Never>?

    init(layout: TreeWalkFanLayout, summary: TreeWalk.Summary, displayNames: [String], scale: CGFloat = 2) {
        self.layout = layout
        self.summary = summary
        self.displayNames = displayNames
        self.scale = scale
        let w = Int(layout.size.width * scale), h = Int(layout.size.height * scale)
        context = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        // Flip so drawing uses the layout's top-left origin.
        context?.translateBy(x: 0, y: CGFloat(h))
        context?.scaleBy(x: scale, y: -scale)
        frame.total = layout.placed.count
    }

    /// Everything needed to animate, built OFF the main actor.
    nonisolated static func prepare(_ result: TreeWalk.Result, size: CGSize) async -> TreeWalkFanLayout {
        await Task.detached(priority: .userInitiated) { TreeWalkFanLayout(result: result, size: size) }.value
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.frame.finished {
                if !self.paused { self.tick() }
                try? await Task.sleep(for: .milliseconds(Int(1000 / Self.ticksPerSecond)))
            }
        }
    }

    func stop() { runTask?.cancel(); runTask = nil }

    func skipToEnd() { instant = true; paused = false }

    /// One frame: reveal this tick's share, draw it into the trail, publish.
    /// O(batch) drawing + one image snapshot; never O(people).
    func tick() {
        let remaining = layout.placed.count - cursor
        guard remaining > 0 else {
            if !frame.finished { frame.finished = true; frame.recent = [] }
            return
        }
        let batch: Int
        if instant {
            batch = min(remaining, Self.maxBatch)
        } else {
            carry += nodesPerSecond / Self.ticksPerSecond
            batch = min(remaining, Self.maxBatch, Int(carry))
            carry -= Double(batch)
        }
        guard batch > 0 else { return }
        let slice = layout.placed[cursor..<(cursor + batch)]
        draw(slice)
        cursor += batch
        var next = frame
        next.visited = cursor
        for p in slice {
            next.byLine[p.line, default: 0] += 1
            if p.hasCheck { next.peopleWithChecks += 1 }
            next.generation = max(next.generation, p.generation)
        }
        next.trail = context?.makeImage()
        next.finished = cursor >= layout.placed.count
        // The last batch is already in the trail in its line colour; the
        // run loop stops at `finished`, so nothing would clear it later
        // (the "white dots at Walk complete" bug, 2026-09-27).
        next.recent = next.finished ? [] : Array(slice)
        frame = next
    }

    /// One line that separates the ANALYSIS (done, milliseconds) from the
    /// REPLAY (an animation at a chosen pace) — Rick 2026-09-27: a
    /// 45-second replay of a 50 ms walk must not look like a slow walk.
    nonisolated static func paceNote(analysisMilliseconds ms: Double, visited: Int, total: Int,
                                     nodesPerSecond: Double, instant: Bool, paused: Bool,
                                     finished: Bool) -> String {
        let took = ms < 1_000 ? "\(Int(ms.rounded()).formatted()) ms" : String(format: "%.1f s", ms / 1_000)
        if finished { return "Analysis took \(took); the replay is only the animation." }
        let head = "Analysis done in \(took) — "
        if paused { return head + "replay paused. Skip to end shows it all now." }
        if instant { return head + "drawing the rest now." }
        let left = Double(max(0, total - visited)) / max(1, nodesPerSecond)
        let eta: String
        switch left {
        case ..<1: eta = "under a second"
        case ..<90: eta = "about \(Int(left.rounded())) s"
        default: eta = "about \(Int((left / 60).rounded())) min"
        }
        return head + "replaying the walk at \(Int(nodesPerSecond.rounded()).formatted()) people/s "
            + "(\(eta) left). Skip to end shows it all now."
    }

    var paceNote: String {
        Self.paceNote(analysisMilliseconds: summary.totalMilliseconds, visited: frame.visited, total: frame.total,
                      nodesPerSecond: nodesPerSecond, instant: instant, paused: paused, finished: frame.finished)
    }

    private func draw(_ slice: ArraySlice<TreeWalkFanLayout.Placed>) {
        guard let ctx = context else { return }
        for p in slice {
            let color = NSColor(TreeWalkPalette.color(p.line))
            if let from = p.from {
                ctx.setStrokeColor(color.withAlphaComponent(0.18).cgColor)
                ctx.setLineWidth(0.5)
                ctx.move(to: from)
                ctx.addLine(to: p.point)
                ctx.strokePath()
            }
            ctx.setFillColor(color.withAlphaComponent(0.85).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.point.x - p.radius, y: p.point.y - p.radius,
                                       width: p.radius * 2, height: p.radius * 2))
            if p.hasCheck {
                let r = max(1.2, p.radius * 0.55)
                ctx.setFillColor(NSColor(TreeWalkPalette.check).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.point.x + p.radius * 0.6, y: p.point.y - p.radius * 1.4,
                                           width: r * 2, height: r * 2))
            }
        }
    }
}

// MARK: - The view

/// The fan (left, scales to the space it is given) and the side panel
/// (right, fixed width): status, the analysis-vs-replay note, controls,
/// counters, and — once the replay ends — the summary in a scroll view.
struct TreeWalkAnimationView: View {
    @ObservedObject var animator: TreeWalkAnimator
    /// Surname / place highlight (Donna 2026-09-29); drawn once the replay
    /// has ended.
    @ObservedObject var highlighter: TreeWalkHighlighter
    /// "Show on map" from the Highlight panel's places (GH #227); nil hides it.
    var onShowMap: (() -> Void)? = nil

    static let sidePanelWidth: CGFloat = 320
    /// How much of the trail shows through while a highlight is on.
    static let dimmedOpacity = 0.14
    static let minimumFan: CGFloat = 240

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            fan
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: Self.minimumFan, maxWidth: .infinity,
                       minHeight: Self.minimumFan, maxHeight: .infinity, alignment: .top)
            sidePanel
                .frame(width: Self.sidePanelWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var fan: some View {
        TimelineView(.animation(minimumInterval: 1 / TreeWalkAnimator.ticksPerSecond,
                                paused: animator.frame.finished)) { timeline in
            let frame = animator.frame
            let layoutSize = animator.layout.size
            let pulse = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6)
            let highlighting = frame.finished && !highlighter.selection.isEmpty
            let lit = highlighting ? highlighter.lit : []
            Canvas { gc, size in
                gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))
                // Draw in layout coordinates, scaled to fit and centred.
                let s = min(size.width / layoutSize.width, size.height / layoutSize.height)
                gc.translateBy(x: (size.width - layoutSize.width * s) / 2, y: (size.height - layoutSize.height * s) / 2)
                gc.scaleBy(x: s, y: s)
                if let trail = frame.trail {
                    // A highlight dims everyone; the matches are drawn on top.
                    gc.opacity = highlighting ? Self.dimmedOpacity : 1
                    gc.draw(Image(decorative: trail, scale: 2), in: CGRect(origin: .zero, size: layoutSize))
                    gc.opacity = 1
                }
                for p in lit {
                    let r = max(p.radius * 1.3, 2.2)
                    let ring = CGRect(x: p.point.x - r - 1.2, y: p.point.y - r - 1.2,
                                      width: (r + 1.2) * 2, height: (r + 1.2) * 2)
                    gc.fill(Path(ellipseIn: ring), with: .color(.white.opacity(0.9)))
                    gc.fill(Path(ellipseIn: CGRect(x: p.point.x - r, y: p.point.y - r, width: r * 2, height: r * 2)),
                            with: .color(TreeWalkPalette.color(p.line)))
                }
                // The frontier: this tick's people, haloed (never after the end).
                for p in frame.recent {
                    let halo = p.radius * (2.2 + CGFloat(pulse))
                    gc.fill(Path(ellipseIn: CGRect(x: p.point.x - halo, y: p.point.y - halo,
                                                    width: halo * 2, height: halo * 2)),
                            with: .color(TreeWalkPalette.color(p.line).opacity(0.25)))
                    gc.fill(Path(ellipseIn: CGRect(x: p.point.x - p.radius, y: p.point.y - p.radius,
                                                    width: p.radius * 2, height: p.radius * 2)),
                            with: .color(.white))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var sidePanel: some View {
        let f = animator.frame
        return VStack(alignment: .leading, spacing: 8) {
            Text(f.finished ? "Walk complete" : (animator.paused ? "Paused" : "Replaying the walk…"))
                .font(.headline)
            Text(animator.paceNote)
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !f.finished { controls }
            counter("Visited", "\(f.visited.formatted()) of \(f.total.formatted())")
            counter("Generation", "\(f.generation)")
            counter("People with checks", f.peopleWithChecks.formatted(), color: TreeWalkPalette.check)
            ForEach(TreeWalk.Line.allCases, id: \.self) { line in
                if let n = f.byLine[line], n > 0 {
                    counter(TreeWalkPalette.lineName(line, names: animator.displayNames), n.formatted(),
                            color: TreeWalkPalette.color(line))
                }
            }
            if f.finished {
                Divider()
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        TreeWalkHighlightPanel(highlighter: highlighter, onShowMap: onShowMap)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.07)))
                        TreeWalkSummaryView(summary: animator.summary, displayNames: animator.displayNames)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Skip to end") { animator.skipToEnd() }
                Button(animator.paused ? "Resume" : "Pause") { animator.paused.toggle() }
            }
            .controlSize(.small)
            Toggle("Instant", isOn: $animator.instant).toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replay speed: \(Int(animator.nodesPerSecond).formatted()) people/s").font(.system(size: 11))
                // Log scale: 30 … 6,000 people per second.
                Slider(value: Binding(get: { log10(animator.nodesPerSecond) },
                                      set: { animator.nodesPerSecond = pow(10, $0) }),
                       in: log10(30)...log10(6_000))
                    .disabled(animator.instant)
            }
            Divider()
        }
    }

    private func counter(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            Text(label).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12).monospacedDigit()).fixedSize()
        }
    }
}
