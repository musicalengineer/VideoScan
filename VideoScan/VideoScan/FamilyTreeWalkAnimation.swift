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
// none grey) and a person with a check gets a small amber mark. The
// counters beside the fan tick: visited, generation, checks, per line.
//
// HOW IT STAYS CHEAP (no O(people) work in a SwiftUI body):
//   • The walk itself ran in Core, off the main actor, before the
//     animation starts (~1 s for Rick's tree); this REPLAYS its layers at
//     the chosen pace (default 600 people/s, 30…6,000, or Instant).
//   • `TreeWalkFanLayout` computes every position once, off-main.
//   • Revealed dots are drawn once into an offscreen bitmap (the trail).
//     Each tick (≤ 30 Hz) draws only that tick's batch into it and
//     publishes a new `Frame`: the trail image + the batch (the "frontier"
//     glow) + counters. The Canvas draws one image and ≤ batch dots.
//   • Memory: the trail bitmap is 1,200 × 1,200 px × 4 B ≈ 5.8 MB, plus the
//     prepared layout (8 bytes × people visited).
//
// (For Rick: `Canvas` ≈ an immediate-mode paint callback like drawRect;
// `TimelineView(.animation)` ≈ a display-link timer that re-runs it.)

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
    }

    let size: CGSize
    /// In visit order (generation by generation) — the replay order.
    let placed: [Placed]
    let layerEnds: [Int]
    let maxGeneration: Int

    init(result: TreeWalk.Result, size: CGSize) {
        self.size = size
        let visits = result.layers.flatMap { $0 }
        let maxGen = max(1, result.layers.count - 1)
        maxGeneration = maxGen
        var ends: [Int] = []
        var running = 0
        for layer in result.layers { running += layer.count; ends.append(running) }
        layerEnds = ends
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let outer = min(size.width, size.height) / 2 - 12
        let ring = outer / CGFloat(maxGen)
        // Angular interval per ordinal (sparse: only visited people).
        var lo: [Int32: Double] = [:], hi: [Int32: Double] = [:]
        lo.reserveCapacity(visits.count); hi.reserveCapacity(visits.count)
        var point: [Int32: CGPoint] = [:]
        point.reserveCapacity(visits.count)
        var out: [Placed] = []
        out.reserveCapacity(visits.count)
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
            let g = CGFloat(v.generation)
            let p: CGPoint
            if v.from < 0 {
                let offset = startCount == 1 ? 0 : (v.slot == 0 ? -ring * 0.35 : ring * 0.35)
                p = CGPoint(x: center.x + offset, y: center.y)
            } else {
                let mid = (a0 + a1) / 2
                p = CGPoint(x: center.x + g * ring * CGFloat(cos(mid)), y: center.y - g * ring * CGFloat(sin(mid)))
            }
            point[v.ordinal] = p
            out.append(Placed(point: p, radius: max(1.2, 5.5 - 0.22 * g),
                              from: v.from < 0 ? nil : point[v.from], line: v.line,
                              hasCheck: v.hasCheck, generation: Int(v.generation)))
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
        /// size, never by the number of people.
        var recent: [TreeWalkFanLayout.Placed] = []
        var visited = 0
        var total = 0
        var generation = 0
        var checks = 0
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
        next.recent = Array(slice)
        next.visited = cursor
        for p in slice {
            next.byLine[p.line, default: 0] += 1
            if p.hasCheck { next.checks += 1 }
            next.generation = max(next.generation, p.generation)
        }
        next.trail = context?.makeImage()
        next.finished = cursor >= layout.placed.count
        frame = next
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

struct TreeWalkAnimationView: View {
    @ObservedObject var animator: TreeWalkAnimator

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            TimelineView(.animation(minimumInterval: 1 / TreeWalkAnimator.ticksPerSecond,
                                    paused: animator.frame.finished)) { timeline in
                let frame = animator.frame
                let pulse = 0.5 + 0.5 * sin(timeline.date.timeIntervalSinceReferenceDate * 6)
                Canvas { gc, size in
                    gc.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))
                    if let trail = frame.trail {
                        gc.draw(Image(decorative: trail, scale: 2), in: CGRect(origin: .zero, size: animator.layout.size))
                    }
                    // The frontier: this tick's people, haloed.
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
                .frame(width: animator.layout.size.width, height: animator.layout.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            counters
        }
    }

    private var counters: some View {
        let f = animator.frame
        return VStack(alignment: .leading, spacing: 8) {
            Text(f.finished ? "Walk complete" : (animator.paused ? "Paused" : "Walking…"))
                .font(.headline)
            counter("Visited", "\(f.visited.formatted()) of \(f.total.formatted())")
            counter("Generation", "\(f.generation)")
            counter("Checks", "\(f.checks.formatted())", color: TreeWalkPalette.check)
            ForEach(TreeWalk.Line.allCases, id: \.self) { line in
                if let n = f.byLine[line], n > 0 {
                    counter(TreeWalkPalette.lineName(line, names: animator.displayNames), n.formatted(),
                            color: TreeWalkPalette.color(line))
                }
            }
            Divider()
            if !f.finished {
                Toggle("Instant", isOn: $animator.instant).toggleStyle(.checkbox)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed: \(Int(animator.nodesPerSecond).formatted()) people/s").font(.system(size: 11))
                    // Log scale: 30 … 6,000 people per second.
                    Slider(value: Binding(get: { log10(animator.nodesPerSecond) },
                                          set: { animator.nodesPerSecond = pow(10, $0) }),
                           in: log10(30)...log10(6_000))
                        .disabled(animator.instant)
                        .frame(width: 180)
                }
                HStack {
                    Button(animator.paused ? "Resume" : "Pause") { animator.paused.toggle() }
                    Button("Skip to end") { animator.skipToEnd() }
                }
                .controlSize(.small)
            }
        }
        .frame(width: 220, alignment: .leading)
    }

    private func counter(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 8, height: 8) }
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value).font(.system(size: 12).monospacedDigit())
        }
    }
}
