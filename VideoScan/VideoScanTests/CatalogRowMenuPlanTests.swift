import Foundation
import Testing
@testable import VideoScan

// R1 refactor (GH #281): the Catalog row context menu's decisions — which
// menu a right-click gets, which rows each item acts on, the counts in
// its labels — moved out of the SwiftUI builder into CatalogRowMenuPlan.
// These tests pin the behaviour the builder had at fa56f078. Pure: no
// model, no volume, no file.

@MainActor
enum RowMenuFixture {
    enum State { case active, purged, setAside, superseded, purgedAndSetAside, setAsideAndSuperseded }

    static func record(_ state: State, _ i: Int = 0) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/T/clip\(i).mov"
        r.filename = "clip\(i).mov"
        switch state {
        case .active: break
        case .purged: r.purgedAt = Date()
        case .setAside: r.setAsideReason = "photo"
        case .superseded: r.supersededByID = UUID()
        case .purgedAndSetAside: r.purgedAt = Date(); r.setAsideReason = "photo"
        case .setAsideAndSuperseded: r.setAsideReason = "photo"; r.supersededByID = UUID()
        }
        return r
    }
}

@MainActor
@Suite("Catalog row menu — selection split and menu shape")
struct CatalogRowMenuSelectionTests {
    typealias F = RowMenuFixture

    @Test func subsetsAreDisjointAndPurgeWins() {
        let recs = [F.record(.active, 0), F.record(.purged, 1), F.record(.setAside, 2),
                    F.record(.superseded, 3), F.record(.purgedAndSetAside, 4),
                    F.record(.setAsideAndSuperseded, 5)]
        let s = CatalogRowMenuSelection(selected: recs)
        #expect(s.active.map(\.filename) == ["clip0.mov"])
        #expect(s.purged.map(\.filename) == ["clip1.mov", "clip4.mov"], "removed wins over set aside")
        #expect(s.setAside.map(\.filename) == ["clip2.mov", "clip5.mov"], "set aside wins over superseded")
        #expect(s.superseded.map(\.filename) == ["clip3.mov"])
        #expect(s.selected.count == 6)
        #expect(!s.pureActive)
    }

    @Test func pureActiveOnlyWithoutInertRows() {
        #expect(CatalogRowMenuSelection(selected: [F.record(.active, 0), F.record(.active, 1)]).pureActive)
        #expect(CatalogRowMenuSelection(selected: []).pureActive, "vacuously pure — no menu is shown anyway")
        for inert: F.State in [.purged, .setAside, .superseded] {
            let s = CatalogRowMenuSelection(selected: [F.record(.active, 0), F.record(inert, 1)])
            #expect(!s.pureActive, "\(inert) rode along — active-only actions must be gated off")
        }
    }

    @Test func pureInertSelectionsGetTheirMinimalMenus() {
        let cases: [(F.State, CatalogRowMenuSelection.Shape)] =
            [(.purged, .purged), (.setAside, .setAside), (.superseded, .superseded)]
        for (state, shape) in cases {
            let a = F.record(state, 0), b = F.record(state, 1)
            #expect(CatalogRowMenuSelection(selected: [a, b]).shape(anchor: a) == shape)
        }
    }

    @Test func anyActiveRowGivesTheFullMenuWhateverTheAnchor() {
        let active = F.record(.active, 0)
        for inert: F.State in [.purged, .setAside, .superseded] {
            let other = F.record(inert, 1)
            let s = CatalogRowMenuSelection(selected: [other, active])
            #expect(s.shape(anchor: other) == .full, "mixed selection anchored on \(inert)")
            #expect(s.shape(anchor: active) == .full)
        }
    }

    /// The old if-chain checked purged, then set-aside, then superseded —
    /// a removed AND set-aside anchor gets the removed menu.
    @Test func anchorPrecedenceFollowsTheOldIfChain() {
        let both = F.record(.purgedAndSetAside, 0)
        #expect(CatalogRowMenuSelection(selected: [both]).shape(anchor: both) == .purged)
        let sas = F.record(.setAsideAndSuperseded, 1)
        #expect(CatalogRowMenuSelection(selected: [sas]).shape(anchor: sas) == .setAside)
    }

    /// Mixed inert states with no active row: the anchor decides.
    @Test func mixedInertSelectionFollowsTheAnchor() {
        let p = F.record(.purged, 0), s = F.record(.setAside, 1)
        let sel = CatalogRowMenuSelection(selected: [p, s])
        #expect(sel.shape(anchor: p) == .purged)
        #expect(sel.shape(anchor: s) == .setAside)
    }

    /// An active anchor that is not in the selection subsets (cannot happen
    /// from the table, but the function must not invent a menu).
    @Test func activeAnchorWithNoActiveRowsGetsNoMenu() {
        let sel = CatalogRowMenuSelection(selected: [F.record(.purged, 0)])
        #expect(sel.shape(anchor: F.record(.active, 9)) == nil)
    }

    /// SCALE: O(selection) — a 100k-row select-all splits well inside budget.
    @Test func hundredThousandRowSelectionSplitsFast() {
        let recs = (0..<100_000).map { F.record($0 % 10 == 0 ? .purged : .active, $0) }
        let clock = ContinuousClock()
        var s: CatalogRowMenuSelection?
        let elapsed = clock.measure { s = CatalogRowMenuSelection(selected: recs) }
        #expect(s?.active.count == 90_000)
        #expect(s?.purged.count == 10_000)
        #expect(elapsed < .seconds(2), "100k split took \(elapsed)")
    }
}
