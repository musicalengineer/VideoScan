// HallieMaeAvatar.swift
// The Family Archivist's face (Rick 2026-08-07: "an animated librarian
// with blonde hair, a cartoon avatar… that moves just a bit when
// typing back… we'll name her Hallie Mae after my great grandma").
//
// Drawn in SwiftUI vectors rather than found art: no licensing, crisp
// at any size, and — the part a static image can't do — she MOVES: a
// gentle bob + brighter eyes while she's composing a reply, and an
// occasional idle blink so she never feels frozen. Palette aims for
// warm-and-pleasant: honey-blonde bun, round librarian glasses, rosy
// cheeks, a little book-page collar.
//
// A real photo from the archive (identity header's photoPath) always
// overrides the cartoon — Hallie Mae is the default face, not the
// only one.

import SwiftUI

struct HallieMaeAvatar: View {
    /// True while the archivist is composing a reply — she bobs
    /// gently and her eyes brighten.
    var isTalking: Bool

    @State private var bobPhase = false
    @State private var blinking = false

    private let blonde = Color(red: 0.94, green: 0.78, blue: 0.42)
    private let blondeShade = Color(red: 0.85, green: 0.66, blue: 0.30)
    private let skin = Color(red: 0.99, green: 0.87, blue: 0.77)
    private let cheek = Color(red: 0.98, green: 0.63, blue: 0.58).opacity(0.45)
    private let frame = Color(red: 0.42, green: 0.30, blue: 0.22)
    private let blouse = Color(red: 0.45, green: 0.56, blue: 0.72)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Blouse + collar peeking from the circle's bottom.
                Ellipse()
                    .fill(blouse)
                    .frame(width: s * 0.86, height: s * 0.44)
                    .offset(y: s * 0.40)
                Ellipse()
                    .fill(.white.opacity(0.9))
                    .frame(width: s * 0.30, height: s * 0.14)
                    .offset(y: s * 0.30)

                // Back hair (behind the face).
                Ellipse()
                    .fill(blondeShade)
                    .frame(width: s * 0.74, height: s * 0.72)
                    .offset(y: -s * 0.06)

                // Face.
                Ellipse()
                    .fill(skin)
                    .frame(width: s * 0.62, height: s * 0.66)
                    .offset(y: -s * 0.02)

                // Fringe — two soft blonde arcs over the forehead.
                Ellipse()
                    .fill(blonde)
                    .frame(width: s * 0.66, height: s * 0.34)
                    .offset(y: -s * 0.26)
                Ellipse()
                    .fill(blonde)
                    .frame(width: s * 0.30, height: s * 0.20)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -s * 0.16, y: -s * 0.20)

                // The bun.
                Circle()
                    .fill(blonde)
                    .frame(width: s * 0.26, height: s * 0.26)
                    .offset(y: -s * 0.40)
                Circle()
                    .stroke(blondeShade, lineWidth: s * 0.015)
                    .frame(width: s * 0.17, height: s * 0.17)
                    .offset(y: -s * 0.40)

                // Round librarian glasses.
                glassesAndEyes(s: s)

                // Rosy cheeks.
                Circle().fill(cheek)
                    .frame(width: s * 0.09)
                    .offset(x: -s * 0.17, y: s * 0.08)
                Circle().fill(cheek)
                    .frame(width: s * 0.09)
                    .offset(x: s * 0.17, y: s * 0.08)

                // The warm smile.
                SmileArc()
                    .stroke(frame.opacity(0.85),
                            style: StrokeStyle(lineWidth: s * 0.022,
                                               lineCap: .round))
                    .frame(width: s * 0.20, height: s * 0.10)
                    .offset(y: s * 0.155)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: isTalking && bobPhase ? -s * 0.03 : 0)
        }
        .onAppear { scheduleBlink() }
        .onChange(of: isTalking) {
            if isTalking {
                withAnimation(.easeInOut(duration: 0.55)
                    .repeatForever(autoreverses: true)) { bobPhase = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { bobPhase = false }
            }
        }
    }

    @ViewBuilder
    private func glassesAndEyes(s: CGFloat) -> some View {
        let eyeOffsetY = -s * 0.015
        ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle()
                    .stroke(frame, lineWidth: s * 0.018)
                    .frame(width: s * 0.16, height: s * 0.16)
                    .offset(x: side * s * 0.115, y: eyeOffsetY)
                // Eyes — brighter while talking; blink squashes them.
                Circle()
                    .fill(frame)
                    .frame(width: s * (isTalking ? 0.045 : 0.038))
                    .scaleEffect(y: blinking ? 0.12 : 1)
                    .offset(x: side * s * 0.115, y: eyeOffsetY)
            }
            // Bridge.
            Rectangle()
                .fill(frame)
                .frame(width: s * 0.055, height: s * 0.014)
                .offset(y: -s * 0.045)
        }
    }

    /// Idle life: a quick blink every 3–5 seconds.
    private func scheduleBlink() {
        let delay = Double.random(in: 3...5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.easeInOut(duration: 0.09)) { blinking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.09)) { blinking = false }
                scheduleBlink()
            }
        }
    }
}

/// A gentle upward-curving smile.
private struct SmileArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
