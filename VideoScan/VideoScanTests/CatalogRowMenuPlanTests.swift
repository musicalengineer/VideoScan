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

// MARK: - Labels and rules (golden strings = the literals at fa56f078)

@Suite("Catalog row menu — labels count what the action touches")
struct CatalogRowMenuTextTests {
    typealias T = CatalogRowMenuText

    @Test func singularLabelsCarryNoCount() {
        #expect(T.analyze(count: 1) == "Analyze")
        #expect(T.removeFromCatalog(count: 1) == "Remove from Catalog")
        #expect(T.deleteFiles(count: 1) == "Delete File")
        #expect(T.restoreToCatalog(count: 1) == "Restore to Catalog")
        #expect(T.putBackInCatalog(count: 1) == "Put Back in Catalog")
        #expect(T.restoreOriginals(count: 1) == "Restore Original (Un-supersede)")
        #expect(T.repairDamagedAudio(count: 1) == "Repair Damaged Audio")
        #expect(T.confirmRepairs(count: 1) == "Sounds Good — Confirm Repair")
    }

    @Test func pluralLabelsCountExactly() {
        #expect(T.analyze(count: 3) == "Analyze 3 Files")
        #expect(T.removeFromCatalog(count: 2) == "Remove 2 from Catalog")
        #expect(T.deleteFiles(count: 12) == "Delete 12 Files")
        #expect(T.restoreToCatalog(count: 4) == "Restore 4 to Catalog")
        #expect(T.putBackInCatalog(count: 5) == "Put 5 Back in Catalog")
        #expect(T.restoreOriginals(count: 6) == "Restore 6 Originals (Un-supersede)")
        #expect(T.repairDamagedAudio(count: 7) == "Repair Damaged Audio (7 Files)")
        #expect(T.confirmRepairs(count: 8) == "Sounds Good — Confirm 8 Repairs")
    }

    /// The builders only show these items for a non-empty set; zero keeps
    /// the old `count > 1` behaviour (no count) rather than "0 Files".
    @Test func zeroReadsLikeOne() {
        #expect(T.analyze(count: 0) == "Analyze")
        #expect(T.deleteFiles(count: 0) == "Delete File")
    }

    /// Hide-the-row and delete-from-disk must never read alike.
    @Test func removeIsNeverWordedAsDelete() {
        for n in [1, 2, 50] {
            #expect(!T.removeFromCatalog(count: n).contains("Delete"))
            #expect(T.deleteFiles(count: n).hasPrefix("Delete"))
        }
    }

    @Test func permanentDeleteConfirmationWording() {
        #expect(T.permanentDeleteQuestion(count: 1, firstFilename: "tape 3.mov")
                == "Delete \u{201C}tape 3.mov\u{201D} permanently?")
        #expect(T.permanentDeleteQuestion(count: 4, firstFilename: "ignored.mov")
                == "Delete 4 files permanently?")
        #expect(T.permanentDeleteWarning(count: 1)
                == "This cannot be undone \u{2014} the file is removed from disk immediately, not moved to Trash.")
        #expect(T.permanentDeleteWarning(count: 2)
                == "This cannot be undone \u{2014} the files are removed from disk immediately, not moved to Trash.")
    }
}

@MainActor
@Suite("Catalog row menu — enable / show rules")
struct CatalogRowMenuRulesTests {
    typealias R = CatalogRowMenuRules
    static let allStreams: [StreamType] = [.videoAndAudio, .videoOnly, .audioOnly, .noStreams, .ffprobeFailed]

    private func rec(_ st: StreamType, _ i: Int = 0) -> VideoRecord {
        let r = RowMenuFixture.record(.active, i)
        r.streamTypeRaw = st.rawValue
        return r
    }

    @Test func transcodeBlockedTruthTable() {
        #expect(!R.transcodeBlocked(reachable: true, running: false))
        #expect(R.transcodeBlocked(reachable: false, running: false))
        #expect(R.transcodeBlocked(reachable: true, running: true))
        #expect(R.transcodeBlocked(reachable: false, running: true))
    }

    @Test func cleanupNeedsAPictureAnOnlineVolumeAndNoRunningJob() {
        for st in Self.allStreams {
            let hasPicture = st == .videoAndAudio || st == .videoOnly
            #expect(R.cleanupBlocked(reachable: true, running: false, streamType: st) == !hasPicture, "\(st)")
            #expect(R.cleanupBlocked(reachable: false, running: false, streamType: st), "offline \(st)")
            #expect(R.cleanupBlocked(reachable: true, running: true, streamType: st), "running \(st)")
        }
    }

    @Test func hasAudioOnlyForAudioBearingStreams() {
        for st in Self.allStreams {
            #expect(R.hasAudio(st) == (st == .videoAndAudio || st == .audioOnly), "\(st)")
        }
    }

    // (familyMusicMarkable / familyMusicMarked retired with the Mark as
    // Family Music… item, 2026-10-07.)

    /// Renamed from "Check Media…" 2026-10-08.
    @Test func verifyLabelCountsTheRowsItRuns() {
        #expect(CatalogRowMenuText.verify(count: 1) == "Verify\u{2026}")
        #expect(CatalogRowMenuText.verify(count: 3) == "Verify 3 Files\u{2026}")
    }

    @Test func damagedAudioIsExactlyTheDamagedVerdicts() {
        let ok = rec(.videoAndAudio, 0), bad = rec(.videoAndAudio, 1), unchecked = rec(.audioOnly, 2)
        ok.audioVerifyStatus = "ok"
        bad.audioVerifyStatus = "damaged"
        #expect(R.damagedAudio([ok, bad, unchecked]).map(\.id) == [bad.id])
    }

    /// SCALE: the selection-wide rules stay O(selection) at a 100k select-all.
    @Test func selectionRulesAtHundredThousand() {
        let recs = (0..<100_000).map { i -> VideoRecord in
            let r = rec(i % 5 == 0 ? .noStreams : .audioOnly, i)
            if i % 5 == 1 { r.audioVerifyStatus = "damaged" }
            return r
        }
        let clock = ContinuousClock()
        var n = 0
        let elapsed = clock.measure {
            n = R.damagedAudio(recs).count
        }
        #expect(n == 20_000)
        #expect(elapsed < .seconds(2), "100k rule pass took \(elapsed)")
    }
}
