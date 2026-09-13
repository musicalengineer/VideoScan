// HoldoutReviewBadgePopover.swift
// What the purple "Review N" badge means, and the way out when a row
// can't be reviewed (feature/holdout-review-explain-clear, Rick
// 2026-09-13).
//
// THE CASE: Donna's badge sat at "Review 1" forever. Clicking it jumped
// straight into ConfirmPersonSheet, which immediately decided the one
// pending row was unreviewable and showed nothing — a badge that could
// not be satisfied and could not be dismissed. The click now opens this
// popover first: what the number is made of, then the actions.
//
// THE BREAKDOWN IS NOT COMPUTED HERE. It comes from
// HoldoutNavigation.breakdown — the same pure classifier the review
// sheet's prefilter uses — so the badge and the sheet can never form a
// second opinion about a row. This view only renders the result and
// calls back.
//
// PERFORMANCE RULES this file obeys:
//   • No O(rows) work in the body: the breakdown is computed once in a
//     `.task` and parked in @State; the body reads scalars.
//   • No blocking I/O on the main actor: the catalog metadata pass runs
//     on the main actor (it touches VideoScanModel.records, which lives
//     there) but is pure CPU, and the volume reachability verdict +
//     classification hop off via a @concurrent helper.
//
// Nothing here reads or writes the review CSV. "Clear" is app-side state
// in HoldoutClearStore; the CSV row keeps saying pending, which is what
// codex's grading tooling expects.

import SwiftUI

struct HoldoutReviewBadgePopover: View {

    let personName: String
    let queue: HoldoutReviewQueue
    /// Catalog records for the media-facts pass. A plain array of the
    /// model's records (class references) — passed in rather than reached
    /// for, so this view is previewable and testable.
    let records: [VideoRecord]
    @ObservedObject var center: HoldoutReviewCenter
    /// Dismiss the popover and open the review session.
    var onStartReview: () -> Void

    /// nil while the first classification is still running.
    @State private var breakdown: HoldoutNavigation.Breakdown?
    @State private var busy = false

    private var clearsRevision: Int { center.clears.revision }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if let breakdown {
                bodyLines(breakdown)
                Divider()
                actions(breakdown)
                footnote(breakdown)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking which ones are ready\u{2026}")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(width: 340)
        .accessibilityIdentifier("pf.holdout.popover")
        // Recompute when the queue changes or a clear/undo lands. The
        // task is cancelled and restarted by SwiftUI on an id change —
        // no manual invalidation to forget.
        .task(id: TaskKey(queueKey: queue.queueKey, clears: clearsRevision)) {
            await refreshBreakdown()
        }
    }

    /// `.task(id:)` needs one Equatable value; a tiny struct beats
    /// stringly-concatenated keys. (For Rick: an aggregate with
    /// compiler-generated `operator==`.)
    private struct TaskKey: Equatable {
        let queueKey: String
        let clears: Int
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text("Review \(personName)")
                    .font(.system(size: 13, weight: .semibold))
                Text("Blind yes/no on videos picked before the app had an opinion.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func bodyLines(_ b: HoldoutNavigation.Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if b.pending == 0 && b.cleared == 0 {
                line("checkmark.circle.fill", muted: false,
                     "Everything in this queue has an answer.",
                     id: "pf.holdout.popover.done")
            } else {
                Text("\(b.pending) video\(b.pending == 1 ? "" : "s") still \(b.pending == 1 ? "needs" : "need") a yes or no from you.")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("pf.holdout.popover.pending")
            }
            if b.ready > 0 {
                line("play.circle", muted: false,
                     "\(b.ready) ready to watch now.",
                     id: "pf.holdout.popover.ready")
            }
            if b.needsFilmstrip > 0 {
                line("film", muted: false,
                     "\(b.needsFilmstrip) \(b.needsFilmstrip == 1 ? "is" : "are") in a format QuickTime can't play \u{2014} \(b.needsFilmstrip == 1 ? "it shows" : "they show") as frames instead, and you can still answer.",
                     id: "pf.holdout.popover.filmstrip")
            }
            if b.offline > 0 {
                line("externaldrive", muted: true,
                     "\(b.offline) \(b.offline == 1 ? "is" : "are") on \(volumePhrase(b.offlineVolumes)), which isn't connected right now.",
                     id: "pf.holdout.popover.offline")
            }
            if b.unrenderable > 0 {
                line("questionmark.square.dashed", muted: true,
                     "\(b.unrenderable) \(b.unrenderable == 1 ? "has" : "have") no video frames to show.",
                     id: "pf.holdout.popover.unrenderable")
            }
            if b.cleared > 0 {
                line("tray.and.arrow.down", muted: true,
                     "\(b.cleared) set aside, off the badge until you bring \(b.cleared == 1 ? "it" : "them") back.",
                     id: "pf.holdout.popover.cleared")
            }
        }
    }

    /// One breakdown line: icon + sentence. `muted` dims BOTH (the rows
    /// Rick can't act on right now) so the readable ones lead the eye.
    private func line(_ symbol: String, muted: Bool, _ text: String, id: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundColor(muted ? .secondary : .accentColor)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(muted ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func actions(_ b: HoldoutNavigation.Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if b.actionable > 0 {
                Button {
                    onStartReview()
                } label: {
                    Label("Start Review (\(b.actionable))", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Open the blind review on the \(b.actionable) video\(b.actionable == 1 ? "" : "s") that can be shown right now")
                .accessibilityIdentifier("pf.holdout.popover.start")
            }
            if b.blocked > 0 {
                Button {
                    setAsideBlocked(b)
                } label: {
                    Label("Set Aside the \(b.blocked) I Can't Review", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .help("Take them off the badge. Nothing is written to the review file, and Undo brings them back.")
                .accessibilityIdentifier("pf.holdout.popover.clear")
            }
            if b.cleared > 0 {
                HStack(spacing: 6) {
                    Button("Undo Last") { undoLast() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(busy)
                        .help("Bring the most recently set-aside video back onto the badge")
                        .accessibilityIdentifier("pf.holdout.popover.undo")
                    if b.cleared > 1 {
                        Button("Bring Back All \(b.cleared)") { undoAll() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                            .accessibilityIdentifier("pf.holdout.popover.undoAll")
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func footnote(_ b: HoldoutNavigation.Breakdown) -> some View {
        if b.cleared > 0 || b.blocked > 0 {
            Text("Setting one aside only hides it here \u{2014} its row in the review file still reads pending.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pf.holdout.popover.footnote")
        }
    }

    /// "MediaExpansion", "MediaExpansion and LaCie", "3 drives".
    private func volumePhrase(_ volumes: [String]) -> String {
        switch volumes.count {
        case 0:  return "a drive"
        case 1:  return volumes[0]
        case 2:  return "\(volumes[0]) and \(volumes[1])"
        default: return "\(volumes.count) drives"
        }
    }

    // MARK: - Work (never in the body)

    private func refreshBreakdown() async {
        let rows = queue.rows
        // One pass over the catalog for media facts. Main actor because
        // `records` lives there; pure CPU, no I/O.
        let meta = HoldoutNavigation.mediaMetaMap(
            paths: Set(rows.map(\.fullPath)), records: records)
        let cleared = center.clearedReviewIds(for: queue)
        // Reachability + classification off the main actor.
        let computed = await Self.classify(rows: rows, meta: meta, cleared: cleared)
        guard !Task.isCancelled else { return }
        breakdown = computed
    }

    /// The off-main half: one mount-table question per distinct volume
    /// (never a per-file stat — the popover must be instant, and the
    /// review sheet's own sweep does the honest per-file pass), then the
    /// pure classification.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func classify(
        rows: [HoldoutReviewRow],
        meta: [String: HoldoutMediaMeta],
        cleared: Set<String>
    ) async -> HoldoutNavigation.Breakdown {
        let mounted = VolumeReachability.currentMountedRoots()
        let offline = HoldoutNavigation.volumeLevelOfflinePaths(
            paths: rows.map(\.fullPath),
            isVolumeReachable: { mounted.contains($0) })
        return HoldoutNavigation.breakdown(rows: rows, meta: meta,
                                           cleared: cleared,
                                           offlinePaths: offline)
    }

    /// Bulk set-aside. Each row records the reason that actually applies
    /// to it — an offline row and a no-frames row are different facts,
    /// and the undo list says which was which.
    private func setAsideBlocked(_ b: HoldoutNavigation.Breakdown) {
        guard b.blocked > 0 else { return }
        busy = true
        let store = center.clears
        let key = queue.queueKey
        let filenameById = Dictionary(
            queue.rows.map { ($0.reviewId, $0.filename) },
            uniquingKeysWith: { first, _ in first })
        var changed = 0
        for (ids, reason) in [(b.offlineReviewIds, HoldoutClearReason.offline),
                              (b.unrenderableReviewIds, HoldoutClearReason.unrenderable)] {
            for id in ids where store.clear(queueKey: key, reviewId: id,
                                            filename: filenameById[id] ?? "",
                                            reason: reason) {
                changed += 1
            }
        }
        persist(changed: changed > 0)
    }

    private func undoLast() {
        busy = true
        persist(changed: center.clears.undoMostRecent(queueKey: queue.queueKey) != nil)
    }

    private func undoAll() {
        busy = true
        persist(changed: center.clears.undoAll(queueKey: queue.queueKey) > 0)
    }

    /// One durable write per action. The `.task(id:)` above re-runs on
    /// the store's revision, so the breakdown refreshes itself.
    private func persist(changed: Bool) {
        guard changed else { busy = false; return }
        let store = center.clears
        Task { @MainActor in
            await store.save()
            busy = false
        }
    }
}
