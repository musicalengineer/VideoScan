// FamilyTreePalette.swift
// The Family Tree canvas painted its surfaces with nine hard-coded near-
// black literals, and the whole view was pinned with
// `.preferredColorScheme(.dark)`. That was fine while dark was the only
// option; it is not fine now that Donna wants to read a line under a lamp
// (2026-08-30). This file is the one place those surface colours live, in
// a dark set and a light set, so a mode switch is a palette swap rather
// than a hunt through a 1,900-line view.
//
// Only SURFACES are here. Text, icons and accents already use semantic
// styles (.primary, .secondary, the per-sex accents), which adapt on their
// own once the scheme is no longer forced — that is why this file is short.
//
// The dark values are exactly the ones the view used before, so "Dark"
// looks identical to what shipped. The light values are the same surfaces
// inverted in role rather than in arithmetic: near-white grounds with the
// separation carried by small steps of grey, because a literal inversion
// of a 0.06 ground gives a 0.94 glare that is worse to read than the dark
// original.

import SwiftUI

struct FamilyTreePalette: Sendable {
    /// The root window ground behind everything.
    let window: Color
    /// The zoomable canvas, drawn as a top-to-bottom gradient.
    let canvasTop: Color
    let canvasBottom: Color
    /// The horizontal strip holding zoom and fit controls.
    let controlBar: Color
    /// Sidebar / list container.
    let sidebar: Color
    /// Inspector and detail panels.
    let panel: Color
    /// A raised tile: person cards and the line-chain cards.
    let card: Color
    /// Translucent fill used for the many small inset panels. Kept as an
    /// overlay rather than a solid so it works over both the canvas
    /// gradient and the flat panels.
    let panelOverlay: Color
    /// The tint those "lift this surface" overlays are made from. The view
    /// picks the opacity; only the hue flips with the scheme. White-on-dark
    /// lightens; black-on-light darkens. Getting this wrong is why a naive
    /// light mode shows a page of invisible panels.
    let overlayInk: Color
    /// Connector lines between generations, and the line-to highlight.
    /// These are the ones that vanish outright if the scheme flips and the
    /// stroke stays white.
    let connector: Color

    static let dark = FamilyTreePalette(
        window:       Color(red: 0.06,  green: 0.07,  blue: 0.08),
        canvasTop:    Color(red: 0.055, green: 0.065, blue: 0.075),
        canvasBottom: Color(red: 0.075, green: 0.08,  blue: 0.095),
        controlBar:   Color(red: 0.075, green: 0.08,  blue: 0.09),
        sidebar:      Color(red: 0.085, green: 0.09,  blue: 0.10),
        panel:        Color(red: 0.09,  green: 0.10,  blue: 0.11),
        card:         Color(red: 0.12,  green: 0.13,  blue: 0.145),
        panelOverlay: Color.white.opacity(0.065),
        overlayInk:   Color.white,
        connector:    Color.white.opacity(0.28)
    )

    /// Warm-neutral rather than pure white. A page of pure #FFF under a
    /// desk lamp is the glare complaint that starts every "can we have a
    /// light mode" conversation, and these greys also print without laying
    /// down a solid background if anyone screen-caps the canvas.
    static let light = FamilyTreePalette(
        window:       Color(red: 0.94,  green: 0.94,  blue: 0.945),
        canvasTop:    Color(red: 0.975, green: 0.975, blue: 0.98),
        canvasBottom: Color(red: 0.925, green: 0.93,  blue: 0.94),
        controlBar:   Color(red: 0.90,  green: 0.905, blue: 0.915),
        sidebar:      Color(red: 0.915, green: 0.92,  blue: 0.93),
        panel:        Color(red: 0.955, green: 0.958, blue: 0.965),
        card:         Color.white,
        panelOverlay: Color.black.opacity(0.05),
        overlayInk:   Color.black,
        connector:    Color.black.opacity(0.32)
    )

    static func palette(for scheme: FamilyTreeEffectiveScheme) -> FamilyTreePalette {
        scheme == .dark ? .dark : .light
    }
}
