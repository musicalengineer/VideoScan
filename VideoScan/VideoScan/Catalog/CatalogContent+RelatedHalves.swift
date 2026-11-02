// CatalogContent+RelatedHalves.swift
// The row menu's "Select Related Halves" (DECISIONS 2026-11-01): select
// every half of a recovered audio/video clip in one gesture, so Delete
// Selected Files… can move the pair whole. Only rows on screen are
// selected (the ⌘⌫ rule: a hidden row is never a target); a half the
// filter or the folder view hides is NAMED on the console line, never
// silently left out. The rule and the words are `CatalogPairGroups
// .relatedSelection` (pure, tested); this is only the gesture.
// Cost: one O(records) index pass per click — an event handler, never a
// view body.

import SwiftUI

extension CatalogContent {
    func selectRelatedHalves(of rec: VideoRecord) {
        let pick = CatalogPairGroups.relatedSelection(of: rec, catalog: model.records,
                                                      shown: { displayedIDs(among: $0) })
        if !pick.select.isEmpty { selectedIDs = pick.select }
        model.log(pick.line)
    }
}
