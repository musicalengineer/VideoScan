// HallieModePillTests.swift
// Design §3.6 step 7 — the header pill's view-model is a plain value:
// label and tint per mode, a held (forced) mode visually distinct, and
// the technical-details suffix. No SwiftUI rendering is needed to pin it.

import SwiftUI
import Testing
@testable import VideoScan

@Suite("Mode pill view-model (design §3.6 step 7)")
struct HallieModePillTests {
    typealias Model = HallieModePillModel

    @Test func labelAndTintFollowTheMode() {
        #expect(Model(mode: .unknown, forced: false).label == "Listening")
        #expect(Model(mode: .catalog, forced: false).label == "Catalog")
        #expect(Model(mode: .tree, forced: false).label == "Family tree")
        #expect(Model(mode: .unknown, forced: false).tint == .secondary)
        #expect(Model(mode: .catalog, forced: false).tint == .blue)
        #expect(Model(mode: .tree, forced: false).tint == .green)
        // Holding a mode changes the fill, never the words or the colour.
        #expect(Model(mode: .tree, forced: true).label == "Family tree")
        #expect(Model(mode: .tree, forced: true).tint == .green)
    }

    @Test func aHeldModeIsVisuallyAndVerballyDistinct() {
        let held = Model(mode: .catalog, forced: true)
        let automatic = Model(mode: .catalog, forced: false)
        #expect(held.isFilled)
        #expect(!automatic.isFilled)
        #expect(held.accessibilityLabel == "Mode: Catalog, held")
        #expect(automatic.accessibilityLabel == "Mode: Catalog")
        #expect(held.help.contains("held until you pick Automatic"))
        #expect(automatic.help.contains("Click to hold a mode"))
        #expect(Model(mode: .unknown, forced: false).help.hasPrefix("Listening — the next question decides"))
        #expect(held != automatic)
    }

    @Test func technicalDetailsSuffixNamesTheFamily() {
        #expect(Model.detailsSuffix(for: .tree) == " · family tree")
        #expect(Model.detailsSuffix(for: .catalog) == " · catalog")
        #expect(Model.detailsSuffix(for: .unknown) == "")
    }
}
