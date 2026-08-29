// FamilyTreeCanvasFocus.swift
// Pure geometry behind "scroll the tree canvas to the focused card"
// (2026-08-29). Kept out of the view so the arithmetic has a unit test.
//
// The canvas draws the laid-out scene (unscaled, `scene.size`) inside a
// frame of `scene.size * zoom` with `.scaleEffect(zoom, anchor: .center)`.
// scaleEffect is a paint-time transform (layout frames stay unscaled), so
// the scroll target must be placed OUTSIDE the scaled view, at the point
// the card is actually drawn. With the scaled view centred in the zoom
// frame that point works out to `position * zoom` — the centring offset
// and the anchor-centred scale cancel exactly.

import CoreGraphics

enum FamilyTreeCanvasFocus {

    /// On-screen point (in the post-zoom scroll content) of a card laid out
    /// at `cardPosition` in the unscaled scene.
    static func anchorPoint(cardPosition: CGPoint, zoom: Double) -> CGPoint {
        CGPoint(x: cardPosition.x * zoom, y: cardPosition.y * zoom)
    }
}
