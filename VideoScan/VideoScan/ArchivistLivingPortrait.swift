//
//  ArchivistLivingPortrait.swift
//  VideoScan
//
//  A still portrait that quietly LIVES: slow breathing, a drifting
//  micro-tilt, a lean toward the input while the user types ("she's
//  listening"), a soft glow while she's thinking, and a small nod when an
//  answer arrives. Rick 2026-08-17: "animate a bit the archivist to make
//  it look like she's listening — nothing too distracting, just a mild
//  turning and looking."
//
//  One image is enough for this. A real head-turn needs 2–3 more stills
//  of the same restoration (head slightly left / right); pass them as
//  `frames` and the view crossfades between them by gaze target.
//
//  Rick 2026-08-18: Hallie Mae now has FOUR stills of her from different
//  angles (HallieMaeAngles-1..4). "More animated (movement, not cartoon)
//  — like a real caring respectable librarian archivist." So the view
//  also takes `angleFrames` and slowly cycles through them: ~10.5 s on
//  each, a 1.4 s crossfade, and a barely-there Ken Burns drift/zoom per
//  dwell. While she's listening to you type or thinking she HOLDS on the
//  front-facing frame (she's paying attention), and resumes wandering
//  ~3 s after she answers. The cycle math lives in `ArchivistAngleCycle`
//  (a pure struct) so it is testable without a view.
//
//  Time-driven (TimelineView), NOT implicit repeatForever animations —
//  macOS drops those on re-render. Honors Reduce Motion: static portrait,
//  and for the angle cycle a static FRONT frame (no crossfade, no swap —
//  someone who asked for less motion gets stillness, not slideshow).
//
//  Memory: the angle frames are decoded once by the caller (four 619×619
//  PNGs ≈ 6 MB of bitmap, worst case) and only re-drawn per tick; nothing
//  is decoded on the main thread per frame.
//

import SwiftUI

struct ArchivistLivingPortrait: View {
    /// Primary portrait (front-facing).
    let image: NSImage
    /// Optional extra stills for gaze: [.left: NSImage, .right: NSImage].
    var frames: [Gaze: NSImage] = [:]
    /// Optional stills of her from different angles (Rick 2026-08-18);
    /// ≥ 2 turns on the slow cycle, otherwise `image` is shown as before.
    var angleFrames: [NSImage] = []
    /// Which of `angleFrames` faces the viewer most directly (0-based; the
    /// default 2 is HallieMaeAngles-3, "smiling down front"). She holds on
    /// this one while listening/thinking and starts the cycle from it.
    var frontFrameIndex: Int = 2
    /// The user is typing / the input has focus.
    var isListening: Bool
    /// A translation/execution is in flight.
    var isThinking: Bool
    /// The user has words in the input box right now. The angle cycle holds
    /// on the front frame while this is true (a librarian looks AT you while
    /// you're asking). Focus alone (`isListening`) is not enough — the input
    /// is focused nearly all the time, so holding on it would never cycle.
    var isComposing: Bool = false
    /// Bumped by the caller when a new answer bubble lands → one nod.
    var answerCount: Int = 0
    /// Where the input field is relative to the portrait (she leans that way).
    var inputSide: Side = .right

    enum Gaze: Hashable { case center, left, right }
    enum Side { case left, right }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nodStart: Date?
    @State private var lastAnswerCount = 0
    // Angle-cycle clock state. `cycleOrigin` is when the cycle (re)started
    // — on appear, or resumeDelay after a hold ends; `holdSince` is set
    // while she's holding on the front frame.
    // Swift's `@State` ≈ a member the framework owns across re-renders
    // (the View struct itself is a value type, rebuilt every body pass).
    @State private var cycleOrigin: Date = Date()
    @State private var holdSince: Date?

    private var isCycling: Bool { angleFrames.count >= 2 }
    private var holdsFront: Bool { isThinking || isComposing }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let motion = reduceMotion ? Motion.still : motion(at: t, now: ctx.date)
            ZStack {
                if isCycling {
                    angleStack(at: t)
                        .scaleEffect(motion.scale)
                        .rotationEffect(.degrees(motion.tilt))
                        .offset(x: motion.dx, y: motion.dy)
                } else {
                    portrait(for: motion.gaze)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(motion.scale)
                        .rotationEffect(.degrees(motion.tilt))
                        .offset(x: motion.dx, y: motion.dy)
                }
            }
            .overlay(
                Circle().stroke(Color.purple.opacity(isThinking ? 0.25 + 0.35 * motion.glow : 0.0),
                                lineWidth: 3)
                    .blur(radius: 2)
            )
        }
        .onChange(of: answerCount) { _, new in
            if new != lastAnswerCount { lastAnswerCount = new; nodStart = Date() }
        }
        .onChange(of: holdsFront, initial: true) { _, holding in
            guard isCycling else { return }
            if holding {
                if holdSince == nil { holdSince = Date() }
            } else if holdSince != nil {
                // She answered / you stopped typing: linger on the front
                // frame for resumeDelay, then wander again from the front.
                holdSince = nil
                cycleOrigin = Date().addingTimeInterval(cycle.resumeDelay)
            }
        }
    }

    // MARK: Angle cycle

    private var cycle: ArchivistAngleCycle {
        ArchivistAngleCycle(frameCount: angleFrames.count, frontFrameIndex: frontFrameIndex)
    }

    /// Two layers (outgoing under incoming) so the crossfade is a plain
    /// opacity blend — no image work per tick, just compositing.
    @ViewBuilder
    private func angleStack(at t: TimeInterval) -> some View {
        let sample = reduceMotion
            ? cycle.stillFront()
            : cycle.sample(at: t,
                           origin: cycleOrigin.timeIntervalSinceReferenceDate,
                           holdSince: holdSince?.timeIntervalSinceReferenceDate)
        // GeometryReader is needed only to turn the ≤2% drift into points.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                angleLayer(sample.bottom, side: side)
                angleLayer(sample.top, side: side)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func angleLayer(_ layer: ArchivistAngleCycle.Layer, side: CGFloat) -> some View {
        Image(nsImage: angleFrames[min(max(layer.index, 0), angleFrames.count - 1)])
            .resizable()
            .scaledToFill()
            .scaleEffect(layer.scale)
            .offset(x: layer.dx * side, y: layer.dy * side)
            .opacity(layer.opacity)
    }

    // MARK: Motion model

    struct Motion {
        var scale = 1.0, tilt = 0.0, dx = 0.0, dy = 0.0, glow = 0.0
        var gaze: Gaze = .center
        static let still = Motion()
    }

    /// All curves are slow sines out of phase; amplitudes are deliberately
    /// tiny (an 84 pt circle: ±1.5° tilt, ±2% scale, ±2.5 pt lean).
    /// While the angle cycle is running its Ken Burns drift already supplies
    /// slow movement, so breathing and tilt are halved — otherwise the two
    /// stack up and she looks restless rather than alive.
    func motion(at t: TimeInterval, now: Date) -> Motion {
        var m = Motion()
        let calm = isCycling ? 0.5 : 1.0
        // Breathing: 5.2 s cycle, ±1.5% (±0.75% while cycling).
        m.scale = 1.0 + 0.015 * calm * sin(t * 2 * .pi / 5.2)
        // Drifting tilt: two incommensurate periods → never quite repeats.
        m.tilt = calm * (1.2 * sin(t * 2 * .pi / 9.7) + 0.6 * sin(t * 2 * .pi / 23.0 + 1.3))
        // Listening lean toward the input, eased in/out by a slow sine so it breathes too.
        if isListening {
            let lean = 2.5 * (0.7 + 0.3 * sin(t * 2 * .pi / 3.1))
            m.dx = inputSide == .right ? lean : -lean
            m.dy = 0.8
            m.tilt += inputSide == .right ? 1.0 : -1.0
            m.gaze = inputSide == .right ? .right : .left
        }
        // Thinking glow pulse.
        if isThinking { m.glow = 0.5 + 0.5 * sin(t * 2 * .pi / 1.6) }
        // Nod: a single 0.7 s dip when an answer arrives.
        if let start = nodStart {
            let p = now.timeIntervalSince(start) / 0.7
            if p < 1 { m.dy += 3.0 * sin(p * .pi) }
        }
        return m
    }

    private func portrait(for gaze: Gaze) -> Image {
        if let f = frames[gaze] { return Image(nsImage: f) }
        return Image(nsImage: image)
    }
}

// MARK: - ArchivistAngleCycle (pure math)

/// The slow walk through Hallie Mae's angle stills — pure functions of the
/// clock so it is deterministic and unit-testable (Rick 2026-08-18).
///
/// Timeline: from `origin`, dwell k (k = 0, 1, 2 …) shows frame
/// `(frontFrameIndex + k) mod N`, i.e. she starts face-on and walks round.
/// The first `crossfade` seconds of each dwell (except the very first) blend
/// the previous frame out under the new one. Each dwell carries its own
/// Ken Burns: scale 1.00 → 1.03 across the dwell and a translate of at most
/// 2% of the frame, direction alternating so she never marches off one way.
///
/// Holding (`holdSince` non-nil): the frame that was showing at `holdSince`
/// freezes underneath, and the front frame fades in on top over
/// `crossfade`; Ken Burns eases back to neutral over the same window.
/// Before `origin` (the resume-delay window after a hold) she simply shows
/// the front frame, neutral. `stillFront()` is the Reduce Motion answer.
struct ArchivistAngleCycle: Equatable {
    var frameCount: Int
    var frontFrameIndex: Int = 2
    /// Seconds on each angle before she turns to the next. 10.5 sits in the
    /// asked-for 9–12 s window and is incommensurate with the 5.2 s breath.
    var dwell: TimeInterval = 10.5
    var crossfade: TimeInterval = 1.4
    /// How long she keeps facing you after a hold ends before wandering.
    var resumeDelay: TimeInterval = 3.0
    var maxZoom: Double = 0.03      // scale 1.00 → 1.03 per dwell
    var maxDrift: Double = 0.02     // ≤ 2% of the frame side

    /// One composited image layer: which still, how faded, how drifted.
    /// `dx`/`dy` are fractions of the frame side (the view converts to pt).
    struct Layer: Equatable {
        var index: Int
        var opacity: Double
        var scale: Double = 1.0
        var dx: Double = 0
        var dy: Double = 0
    }

    struct Sample: Equatable {
        var bottom: Layer   // outgoing (or the frozen frame under a hold)
        var top: Layer      // incoming / current
        /// The frame a viewer would say is "showing" (top once it dominates).
        var visibleIndex: Int { top.opacity >= 0.5 ? top.index : bottom.index }
        /// 0 = fully bottom, 1 = fully top.
        var alpha: Double { top.opacity }
    }

    private var front: Int { frameCount > 0 ? ((frontFrameIndex % frameCount) + frameCount) % frameCount : 0 }

    /// Frame shown during dwell `k` (k may be negative → wraps).
    func frameIndex(forDwell k: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        return (((front + k) % frameCount) + frameCount) % frameCount
    }

    /// Reduce Motion / degenerate: the front frame, fully opaque, neutral.
    func stillFront() -> Sample {
        let f = Layer(index: front, opacity: 1)
        return Sample(bottom: f, top: f)
    }

    func sample(at t: TimeInterval, origin: TimeInterval, holdSince: TimeInterval?) -> Sample {
        guard frameCount >= 2 else { return stillFront() }
        if let h = holdSince {
            // Freeze whatever dominated at the moment the hold began …
            let prior = cycling(at: min(h, t), origin: origin)
            var frozen = prior.top.opacity >= 0.5 ? prior.top : prior.bottom
            frozen.opacity = 1
            // … and bring the front frame in over it. Ken Burns eases home.
            let a = smoothstep(clamp((t - h) / crossfade))
            frozen.scale = lerp(frozen.scale, 1.0, a)
            frozen.dx = lerp(frozen.dx, 0, a)
            frozen.dy = lerp(frozen.dy, 0, a)
            let top = Layer(index: front, opacity: frozen.index == front ? 1 : a)
            return Sample(bottom: frozen, top: top)
        }
        if t < origin { return stillFront() }     // resume-delay window
        return cycling(at: t, origin: origin)
    }

    /// The free-running walk (no hold).
    private func cycling(at t: TimeInterval, origin: TimeInterval) -> Sample {
        let u = max(0, t - origin)
        let k = Int(floor(u / dwell))
        let phase = u - Double(k) * dwell
        let current = frameIndex(forDwell: k)
        let previous = frameIndex(forDwell: k - 1)
        // Crossfade at the head of every dwell but the first.
        let a = k == 0 ? 1.0 : smoothstep(clamp(phase / crossfade))
        var top = kenBurns(index: current, dwell: k, progress: phase / dwell)
        top.opacity = a
        // Outgoing frame sits at the END of its own drift, fully opaque
        // beneath (the incoming layer's opacity does the blend).
        var bottom = kenBurns(index: previous, dwell: k - 1, progress: 1)
        bottom.opacity = 1
        return Sample(bottom: bottom, top: top)
    }

    /// Slow push-in with a gentle sideways drift; direction alternates per
    /// dwell (left/right, and every other pair drifts a touch up/down).
    private func kenBurns(index: Int, dwell k: Int, progress p: Double) -> Layer {
        let q = clamp(p)
        let sx: Double = (k & 1) == 0 ? 1 : -1
        let sy: Double = (k & 2) == 0 ? 1 : -1
        return Layer(index: index,
                     opacity: 1,
                     scale: 1.0 + maxZoom * q,
                     dx: sx * maxDrift * (q - 0.5),
                     dy: sy * (maxDrift * 0.5) * (q - 0.5))
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    /// Ease-in-out so the fade never "clicks" at either end.
    private func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }
}
