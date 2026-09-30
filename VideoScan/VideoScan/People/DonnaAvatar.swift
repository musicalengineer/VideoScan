// DonnaAvatar.swift
// A vector caricature of Donna for the Family Archivist (Rick
// 2026-08-07, drawn from a late-80s photo he provided plus two style
// references). What the photo says the caricature must capture:
//   - BIG voluminous curly sandy-blonde hair, wider than the face,
//     shoulder length, darker at the roots
//   - a slim face and a genuinely radiant open toothy smile
//   - blue-gray eyes
//   - the white tank with purple/magenta stripes she wore in the
//     photo — the costume the family will recognize
// Style: the clean-shape language of Rick's flat reference avatar
// with the bigger expressive eyes of his 3D-librarian reference.
// No glasses — likeness beats librarian iconography.
//
// She's alive like Hallie Mae: gentle bob + brighter eyes while the
// archivist composes a reply, idle blinks, and — hers alone — a tiny
// sway in the curls, half a beat behind the bob, like real hair.
//
// Vectors, not found art: license-free, crisp at any size, animated
// forever. The photo itself never enters the repo (privacy policy);
// only this drawing-as-code does.

import SwiftUI

struct DonnaAvatar: View {
    /// True while the archivist is composing a reply.
    var isTalking: Bool

    @State private var bobPhase = false
    @State private var blinking = false

    private let blonde = Color(red: 0.91, green: 0.75, blue: 0.45)
    private let blondeDeep = Color(red: 0.80, green: 0.60, blue: 0.32)
    private let root = Color(red: 0.72, green: 0.53, blue: 0.28)
    private let skin = Color(red: 0.99, green: 0.88, blue: 0.79)
    private let cheek = Color(red: 0.99, green: 0.62, blue: 0.55).opacity(0.40)
    private let eyeBlue = Color(red: 0.38, green: 0.48, blue: 0.56)
    private let line = Color(red: 0.40, green: 0.30, blue: 0.22)
    private let stripe = Color(red: 0.62, green: 0.22, blue: 0.48)

    /// Curl cluster layout: (x, y, size, deep-shade?) in unit space —
    /// a mane wider than the face, ragged like real curls.
    private static let curls: [(x: CGFloat, y: CGFloat, r: CGFloat, deep: Bool)] = [
        (-0.30, -0.28, 0.24, false), (0.30, -0.28, 0.24, false),
        (-0.38, -0.12, 0.22, true),  (0.38, -0.12, 0.22, true),
        (-0.40,  0.06, 0.21, false), (0.40,  0.06, 0.21, false),
        (-0.36,  0.22, 0.20, true),  (0.36,  0.22, 0.20, true),
        (-0.16, -0.38, 0.24, false), (0.16, -0.38, 0.24, false),
        ( 0.00, -0.42, 0.26, true),
        (-0.28,  0.32, 0.16, false), (0.28,  0.32, 0.16, false),
    ]

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // The striped tank (the photo's costume) peeking from
                // the bottom of the circle.
                ZStack {
                    Ellipse().fill(.white)
                        .frame(width: s * 0.88, height: s * 0.46)
                    VStack(spacing: s * 0.035) {
                        ForEach(0..<4, id: \.self) { _ in
                            Rectangle().fill(stripe)
                                .frame(height: s * 0.035)
                        }
                    }
                    .frame(width: s * 0.88, height: s * 0.40)
                    .clipShape(Ellipse())
                }
                .frame(width: s * 0.88, height: s * 0.46)
                .offset(y: s * 0.42)

                // The mane — curls sway half a beat behind the bob.
                ZStack {
                    ForEach(Array(Self.curls.enumerated()), id: \.offset) { _, curl in
                        Circle()
                            .fill(curl.deep ? blondeDeep : blonde)
                            .frame(width: s * curl.r, height: s * curl.r)
                            .offset(x: s * curl.x, y: s * curl.y)
                    }
                    // Darker roots at the crown.
                    Ellipse()
                        .fill(root.opacity(0.55))
                        .frame(width: s * 0.30, height: s * 0.14)
                        .offset(y: -s * 0.36)
                }
                .offset(x: isTalking && bobPhase ? s * 0.012 : 0,
                        y: isTalking && bobPhase ? -s * 0.012 : 0)

                // Slim face.
                Ellipse()
                    .fill(skin)
                    .frame(width: s * 0.52, height: s * 0.62)
                    .offset(y: -s * 0.01)

                // Soft fringe over the forehead.
                Ellipse()
                    .fill(blonde)
                    .frame(width: s * 0.54, height: s * 0.22)
                    .offset(y: -s * 0.26)

                // Eyes — blue-gray, bigger when talking; brows.
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule()
                        .fill(line.opacity(0.7))
                        .frame(width: s * 0.10, height: s * 0.016)
                        .rotationEffect(.degrees(side * -6))
                        .offset(x: side * s * 0.105, y: -s * 0.115)
                    Circle()
                        .fill(eyeBlue)
                        .frame(width: s * (isTalking ? 0.062 : 0.054))
                        .scaleEffect(y: blinking ? 0.12 : 1)
                        .offset(x: side * s * 0.105, y: -s * 0.045)
                    Circle()
                        .fill(.white)
                        .frame(width: s * 0.018)
                        .scaleEffect(y: blinking ? 0.12 : 1)
                        .offset(x: side * s * 0.105 + s * 0.012,
                                y: -s * 0.055)
                }

                // Rosy cheeks.
                Circle().fill(cheek)
                    .frame(width: s * 0.085)
                    .offset(x: -s * 0.155, y: s * 0.055)
                Circle().fill(cheek)
                    .frame(width: s * 0.085)
                    .offset(x: s * 0.155, y: s * 0.055)

                // THE smile — open and toothy, her signature.
                ZStack {
                    OpenSmile()
                        .fill(Color(red: 0.72, green: 0.32, blue: 0.32))
                        .frame(width: s * 0.24, height: s * 0.13)
                    OpenSmile()
                        .fill(.white)
                        .frame(width: s * 0.20, height: s * 0.065)
                        .offset(y: -s * 0.012)
                    OpenSmile()
                        .stroke(line.opacity(0.8), lineWidth: s * 0.012)
                        .frame(width: s * 0.24, height: s * 0.13)
                }
                .offset(y: s * 0.15)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .offset(y: isTalking && bobPhase ? -s * 0.028 : 0)
        }
        .onAppear { scheduleBlink() }
        .onChange(of: isTalking) {
            if isTalking {
                withAnimation(.easeInOut(duration: 0.6)
                    .repeatForever(autoreverses: true)) { bobPhase = true }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { bobPhase = false }
            }
        }
    }

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

/// A wide-open smile: flat-ish top lip, deep curved lower lip.
private struct OpenSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.2),
            control: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.2),
            control: CGPoint(x: rect.midX, y: rect.maxY * 1.4))
        return path
    }
}
