import CoreGraphics
import Foundation
import Testing
@testable import VideoScan

// People → Show in Family Tree lands as `focus(onID:)` on a freshly
// installed model (2026-08-29, Rick's empty-canvas screenshot). These pin
// the model half of the contract: after install + focus the scene has
// cards and the focused person is the root. The view half (scroll the
// canvas to that card) is `FamilyTreeCanvasFocus.anchorPoint`, whose
// arithmetic is pinned below.
//
// Dimensions per the feature-test checklist: Logic only — no records
// iteration, no media, no global state (the model reads an injected,
// nonexistent directory and the graph is built from text).

private let focusGedcom = """
0 HEAD
1 SOUR VideoScanTests
0 @I1@ INDI
1 NAME John /Breen/
1 SEX M
1 BIRT
2 DATE 1900
1 FAMS @F1@
0 @I2@ INDI
1 NAME Mary /Lamb/
1 SEX F
1 FAMS @F1@
0 @I3@ INDI
1 NAME Richard Harding /Breen/
2 NSFX Sr
1 SEX M
1 BIRT
2 DATE 4 MAR 1929
1 FAMC @F1@
1 FAMS @F2@
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @F2@
0 @I5@ INDI
1 NAME Richard Harding /Breen/
2 NSFX Jr
1 SEX M
1 BIRT
2 DATE 1959
1 FAMC @F2@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I5@
"""

@Suite("Family Tree focus renders a scene")
struct FamilyTreeFocusSceneTests {

    @MainActor
    private func installedModel() -> FamilyTreeLiveModel {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        model.install(graph: GedcomFamilyGraph(gedcomText: focusGedcom))
        return model
    }

    @MainActor
    @Test func focusByIDAfterInstallProducesSceneWithFocusedRoot() throws {
        let model = installedModel()
        #expect(model.isLive)

        #expect(model.focus(onID: "@I3@"))

        #expect(model.selectedID == "@I3@")
        #expect(!model.scene.cards.isEmpty)
        #expect(model.scene.size != .zero)
        let root = try #require(model.scene.cards.first { $0.isRoot })
        #expect(root.person.id == "@I3@")
        // The focused card is the one the canvas scrolls to.
        #expect(model.scene.cards.contains { $0.person.id == model.selectedID })
        // Parents above, child below, all on the canvas.
        let ids = Set(model.scene.cards.map(\.person.id))
        #expect(ids.isSuperset(of: ["@I1@", "@I2@", "@I4@", "@I5@"]))
        #expect(model.focusMissNotice == nil)
    }

    @MainActor
    @Test func focusByIDTwiceInARowKeepsTheScene() {
        let model = installedModel()
        #expect(model.focus(onID: "@I5@"))
        #expect(model.focus(onID: "@I3@"))
        #expect(model.selectedID == "@I3@")
        #expect(model.scene.cards.first { $0.isRoot }?.person.id == "@I3@")
    }

    @MainActor
    @Test func focusOnUnknownIDIsRefusedAndLeavesTheSceneAlone() {
        let model = installedModel()
        #expect(model.focus(onID: "@I3@"))
        let before = model.scene.cards.map(\.id)
        #expect(!model.focus(onID: "@NOPE@"))
        #expect(model.selectedID == "@I3@")
        #expect(model.scene.cards.map(\.id) == before)
    }

    @Test func canvasAnchorPointIsTheDrawnPointOfTheCard() {
        // Unscaled scene position × zoom = where scaleEffect(anchor: .center)
        // inside a zoom-sized frame actually paints the card.
        let p = FamilyTreeCanvasFocus.anchorPoint(cardPosition: CGPoint(x: 1000, y: 300), zoom: 0.88)
        #expect(abs(p.x - 880) < 0.001)
        #expect(abs(p.y - 264) < 0.001)
        let unity = FamilyTreeCanvasFocus.anchorPoint(cardPosition: CGPoint(x: 120, y: 80), zoom: 1)
        #expect(unity == CGPoint(x: 120, y: 80))
    }
}
