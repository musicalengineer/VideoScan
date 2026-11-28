// AVSyncTimingLine.swift
// "Sound & picture timing: …" — the one line Media Info (Get Info) and the
// Inspector show for a file Check A/V Sync measured this session (design
// docs/design/av_sync_analysis.md §6). It observes the store itself, so a
// result that lands while the sheet or the Inspector is open appears without
// a re-select.
//
// TRUTH (rule 1): the lookup is by the file's CURRENT whole-file digest and
// the current policy (AVSyncResultStore.entry) — no digest, changed bytes or
// an older rule show nothing, never a stale verdict. O(1) per render.

import SwiftUI
import VideoScanCore

struct AVSyncTimingLine: View {
    @ObservedObject var store: AVSyncResultStore
    /// The selected file's whole-file digest (CatalogCommit.digest), nil = none.
    let digest: String?
    var font: Font = .callout

    var body: some View {
        if let entry = store.entry(forProcessedDigest: digest) {
            Label {
                Text("**Sound & picture timing:** \(AVSyncResultStore.line(for: entry))")
            } icon: {
                Image(systemName: Self.symbol(entry.report.verdict))
            }
            .font(font)
            .foregroundStyle(Self.tint(entry.report.verdict))
            .textSelection(.enabled)
            .help("Measured by Check A/V Sync against \(entry.original.filename) — policy \(entry.key.policyIdentity), "
                  + "\(entry.report.measuredWindows) of \(entry.report.windows.count) windows measured.")
            .accessibilityIdentifier("avSync.timingLine")
        }
    }

    static func symbol(_ verdict: AVSyncVerdict) -> String {
        if verdict.isInSync { return "checkmark.circle" }
        return verdict.needsReview ? "exclamationmark.triangle" : "questionmark.circle"
    }

    static func tint(_ verdict: AVSyncVerdict) -> Color {
        if verdict.isInSync { return .green }
        return verdict.needsReview ? .orange : .secondary
    }
}
