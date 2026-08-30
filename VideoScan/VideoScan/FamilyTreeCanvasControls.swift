// FamilyTreeCanvasControls.swift
// The tree IS the primary view (Rick 2026-08-29): the sidebar hides so a
// long line fits, and the canvas zooms/fits. This file holds the two
// pieces the view needs that have nothing to do with SwiftUI — the
// persisted sidebar preference and the zoom arithmetic — so both are
// testable without a view.

import Foundation
import CoreGraphics

/// Whether the Family Tree sidebar is shown. Explicit load/save against an
/// injected `UserDefaults` (the settings-persistence rule: no @AppStorage,
/// no didSet magic; a test passes its own suite and never touches the real
/// prefs).
enum FamilyTreeSidebarPreference {
    static let key = "ftSidebarVisible"

    /// Default is SHOWN: a fresh install must not hide the search box.
    static func load(from defaults: UserDefaults) -> Bool {
        // `object(forKey:) == nil` distinguishes "never written" from
        // "written false" — `bool(forKey:)` alone returns false for both.
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }

    static func save(_ visible: Bool, to defaults: UserDefaults) {
        defaults.set(visible, forKey: key)
    }
}

/// How the Family Tree canvas is painted.
///
/// Dark is the default because that is how the tree shipped and how Rick
/// reads it. Light exists for two reasons Donna gave on 2026-08-30: a tree
/// printed from a dark screen costs a fortune in black ink, and a dark
/// canvas washes out under a room lamp when you are reading a line aloud
/// to someone.
///
/// (Note that "Print line…" already renders light-on-white regardless of
/// this setting — see FamilyTreeLineExport. This preference is about what
/// you LOOK at, not what comes out of the printer.)
enum FamilyTreeAppearance: String, CaseIterable, Identifiable, Sendable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark:   return "Dark"
        case .light:  return "Light"
        case .system: return "Match System"
        }
    }

    var symbol: String {
        switch self {
        case .dark:   return "moon.fill"
        case .light:  return "sun.max.fill"
        case .system: return "circle.lefthalf.filled"
        }
    }
}

/// What the canvas actually paints, once "Match System" has been resolved
/// against the current system appearance. Separate from
/// `FamilyTreeAppearance` so the resolution is a pure function a test can
/// drive without a view or a real system setting.
enum FamilyTreeEffectiveScheme: Sendable {
    case light
    case dark

    var isDark: Bool { self == .dark }
}

/// Persisted canvas appearance. Explicit load/save against an injected
/// `UserDefaults`, matching `FamilyTreeSidebarPreference` — no @AppStorage,
/// no didSet magic, so a test passes its own suite and never touches the
/// real prefs.
enum FamilyTreeAppearancePreference {
    static let key = "ftAppearance"

    /// Default is DARK: the tree has always looked this way, and a
    /// preference that silently changes an existing user's view on upgrade
    /// is a bug, not a feature.
    static func load(from defaults: UserDefaults) -> FamilyTreeAppearance {
        guard let raw = defaults.string(forKey: key),
              let value = FamilyTreeAppearance(rawValue: raw) else { return .dark }
        return value
    }

    static func save(_ appearance: FamilyTreeAppearance, to defaults: UserDefaults) {
        defaults.set(appearance.rawValue, forKey: key)
    }

    /// Resolve a stored preference against the system appearance.
    /// `systemIsDark` is whatever the environment reports; only `.system`
    /// consults it, which is the whole point of keeping this pure.
    static func resolve(_ appearance: FamilyTreeAppearance,
                        systemIsDark: Bool) -> FamilyTreeEffectiveScheme {
        switch appearance {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return systemIsDark ? .dark : .light
        }
    }
}

/// Pure zoom arithmetic for the canvas and the line chain. Everything is
/// O(1) — the layout is never re-run to zoom; the view scales a finished
/// scene with `scaleEffect`.
enum FamilyTreeZoomMath {
    /// Slider / shortcut range. 0.35 shows ~3× more tree than the old
    /// floor of 0.5; 2.0 is enough to read a card from across the room.
    static let range: ClosedRange<Double> = 0.35...2.0
    /// The comfortable default the Center/Home buttons return to.
    static let `default`: Double = 0.88
    /// One ⌘+ / ⌘− step (multiplicative, like every image viewer).
    static let step: Double = 1.15
    /// Breathing room kept around a fitted scene, in points per side.
    static let fitPadding: CGFloat = 40

    static func clamp(_ zoom: Double) -> Double {
        min(max(zoom, range.lowerBound), range.upperBound)
    }

    static func zoomIn(_ zoom: Double) -> Double { clamp(zoom * step) }
    static func zoomOut(_ zoom: Double) -> Double { clamp(zoom / step) }

    /// The scale at which `content` just fits inside `viewport` with
    /// `padding` on every side, clamped to `range`. A zero-sized content or
    /// viewport (nothing loaded yet / view not laid out) yields the default.
    static func fitScale(content: CGSize, viewport: CGSize,
                         padding: CGFloat = fitPadding) -> Double {
        guard content.width > 0, content.height > 0 else { return `default` }
        let availableWidth = viewport.width - padding * 2
        let availableHeight = viewport.height - padding * 2
        guard availableWidth > 0, availableHeight > 0 else { return `default` }
        let scale = min(availableWidth / content.width, availableHeight / content.height)
        return clamp(Double(scale))
    }

    /// Fit by width only — what "Fit line" wants for a tall chain: the
    /// strip fills the canvas width (up to the range's top) and scrolls
    /// vertically. Fitting a 30-generation chain by height would shrink the
    /// cards to unreadable confetti.
    static func fitWidthScale(content: CGSize, viewport: CGSize,
                              padding: CGFloat = fitPadding) -> Double {
        guard content.width > 0 else { return `default` }
        let availableWidth = viewport.width - padding * 2
        guard availableWidth > 0 else { return `default` }
        return clamp(Double(availableWidth / content.width))
    }
}
