import Testing
import SwiftUI
import AppKit
@testable import VideoScan

// Layout regression for the Tidy Catalog sheet (Rick's screenshot,
// 2026-10-25): the sheet is `.padding(26).frame(width: 580)`, and the
// counts block must render inside the width the sheet proposes. A child
// that lays out wider is centered by the frame and CLIPPED on both sides —
// the text started mid-sentence and the buttons lost their leading edge.
//
// The probe hosts the sheet's real composition (VStack → padding → fixed
// frame) and reads the counts block's RENDERED width, because the block's
// `sizeThatFits` for a (528 × 10 000) proposal already wraps — the real
// sheet proposes no height, and that is the path that overflows.
@Suite("Tidy Catalog sheet layout")
@MainActor
struct TidyCatalogSheetLayoutTests {

    /// Width the sheet gives its children: 580 − 2 × 26 padding.
    private static let proposedWidth: CGFloat = 580 - 2 * 26

    @MainActor final class Measured { var width: CGFloat = 0 }

    private static func plan(choices: [String]) -> VideoScanModel.TidyCatalogPlan {
        var plan = VideoScanModel.TidyCatalogPlan()
        // Rick's shape: a real plan has rows, so the full tally block renders.
        plan.rows = (0..<16).map { i in
            VideoScanModel.TidyCatalogPlan.Row(id: UUID(), filename: "IMG_\(i).jpg",
                                               fullPath: "/Volumes/LaCieWorkspace/x/IMG_\(i).jpg",
                                               sizeBytes: 2_000_000, reason: .stillImage)
        }
        plan.stillCount = 12; plan.musicCount = 2; plan.unlinkedAudioCount = 1
        plan.livePhotoComplementCount = 1; plan.junkCameBackCount = 3
        plan.keptLinkedAudio = 4; plan.keptPairProtected = 2
        plan.archivedCopyCount = 7
        plan.archivedCopyBytes = 630 * 1_000_000_000
        plan.archivedNoObviousChoices = choices
        return plan
    }

    /// The counts block's rendered width inside the sheet's own layout.
    private static func renderedWidth(_ plan: VideoScanModel.TidyCatalogPlan) -> CGFloat {
        let measured = Measured()
        let root = VStack(alignment: .leading, spacing: 18) {
            Text("Tidy Catalog").font(.title2.weight(.semibold))
            TidyCatalogCountsGrid(plan: plan)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured.width = $0 }
            Divider()
        }
        .padding(26)
        .frame(width: 580)
        // Size the host from the content, as a presented sheet does: the
        // fixed-width frame then proposes NO height to the stack.
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = NSRect(origin: .zero, size: host.intrinsicContentSize)
        host.layoutSubtreeIfNeeded()
        // onGeometryChange delivers on the next run-loop turn.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        return measured.width
    }

    @Test func noObviousChoicesLineWrapsInsideTheSheetWidth() {
        let width = Self.renderedWidth(Self.plan(choices: [
            "2 the archive copy hasn't been verified yet",
            "1 a version, not the same bytes",
            "1 same name, different footage",
            "3 not hashed yet",
        ]))
        #expect(width > 0, "the probe must observe a layout")
        #expect(width <= Self.proposedWidth + 0.5,
                "the counts block must render inside the sheet: \(width) pt for a \(Self.proposedWidth) pt proposal")
    }

    @Test func withoutTheLineTheBlockAlreadyFits() {
        // Control: the same block minus the offending line fits today and
        // must keep fitting after the fix.
        let width = Self.renderedWidth(Self.plan(choices: []))
        #expect(width > 0)
        #expect(width <= Self.proposedWidth + 0.5, "control block rendered at \(width) pt")
    }
}
