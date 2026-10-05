//
//  GlassCompat.swift
//  VideoScan
//
//  ONE door to Liquid Glass (overnight 2026-10-05). The app targets macOS 26,
//  but CI builds and tests on macOS 15 runners with MACOSX_DEPLOYMENT_TARGET
//  =15.0 (.github/workflows/ci.yml), where every glass API is unavailable —
//  CI went red on the glass refresh. Every call site goes through these
//  wrappers: real Liquid Glass on macOS 26+, the closest older look below it
//  (frosted material, bordered buttons). On Rick's machines nothing changes.
//
//  (For Rick: `if #available(macOS 26, *)` ≈ a runtime OS-version check the
//  compiler also understands, so the newer API is only referenced inside it.)
//

import SwiftUI

extension View {

    /// A capsule of Liquid Glass behind/around this view; frosted material
    /// before macOS 26. `tint` colours the glass; `interactive` lets it
    /// react to presses (macOS 26+ only).
    @ViewBuilder
    func vsGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            switch (tint, interactive) {
            case (let tint?, true): glassEffect(.regular.tint(tint).interactive(), in: .capsule)
            case (let tint?, false): glassEffect(.regular.tint(tint), in: .capsule)
            case (nil, true): glassEffect(.regular.interactive(), in: .capsule)
            case (nil, false): glassEffect(.regular, in: .capsule)
            }
        } else {
            background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(tint ?? .clear))
            }
        }
    }

    /// `glassEffectID` on macOS 26+ (glass shapes with the same id morph
    /// into each other); a no-op before it.
    @ViewBuilder
    func vsGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// `.buttonStyle(.glass)` on macOS 26+, `.bordered` before it.
    @ViewBuilder
    func vsGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// `.buttonStyle(.glassProminent)` on macOS 26+, `.borderedProminent` before it.
    @ViewBuilder
    func vsGlassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}

/// `GlassEffectContainer` on macOS 26+ (nearby glass shapes blend and
/// morph); a plain pass-through before it.
struct VSGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}
