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
//  `frames` and the view crossfades between them by gaze target — no
//  code changes needed later beyond supplying the images.
//
//  Time-driven (TimelineView), NOT implicit repeatForever animations —
//  macOS drops those on re-render. Honors Reduce Motion (static portrait).
//

import SwiftUI

struct ArchivistLivingPortrait: View {
    /// Primary portrait (front-facing).
    let image: NSImage
    /// Optional extra stills for gaze: [.left: NSImage, .right: NSImage].
    var frames: [Gaze: NSImage] = [:]
    /// The user is typing / the input has focus.
    var isListening: Bool
    /// A translation/execution is in flight.
    var isThinking: Bool
    /// Bumped by the caller when a new answer bubble lands → one nod.
    var answerCount: Int = 0
    /// Where the input field is relative to the portrait (she leans that way).
    var inputSide: Side = .right

    enum Gaze: Hashable { case center, left, right }
    enum Side { case left, right }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nodStart: Date?
    @State private var lastAnswerCount = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let motion = reduceMotion ? Motion.still : motion(at: t, now: ctx.date)
            ZStack {
                portrait(for: motion.gaze)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(motion.scale)
                    .rotationEffect(.degrees(motion.tilt))
                    .offset(x: motion.dx, y: motion.dy)
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
    }

    // MARK: Motion model

    struct Motion {
        var scale = 1.0, tilt = 0.0, dx = 0.0, dy = 0.0, glow = 0.0
        var gaze: Gaze = .center
        static let still = Motion()
    }

    /// All curves are slow sines out of phase; amplitudes are deliberately
    /// tiny (an 84 pt circle: ±1.5° tilt, ±2% scale, ±2.5 pt lean).
    func motion(at t: TimeInterval, now: Date) -> Motion {
        var m = Motion()
        // Breathing: 5.2 s cycle, ±1.5%.
        m.scale = 1.0 + 0.015 * sin(t * 2 * .pi / 5.2)
        // Drifting tilt: two incommensurate periods → never quite repeats.
        m.tilt = 1.2 * sin(t * 2 * .pi / 9.7) + 0.6 * sin(t * 2 * .pi / 23.0 + 1.3)
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
