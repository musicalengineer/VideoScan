// ArchiveAngelAssessmentPanel.swift
// Archive tab — the always-on Archive Angel Assessment, where the batches
// are reviewed. Rick 2026-09-10: "the assessment should continually run
// over the catalog … then the user can scroll thru AAA files in the
// catalog or look in the Archive window to see files that can be batch
// archived using AA."
//
// One line of grades + freshness + the sweep's live status, an "Assess
// now" link, a "Prepare batch…" button (the existing start sheet), a
// "Show candidates in Catalog" jump, and a chevron turndown listing the
// recommended files.
//
// Rick 2026-09-24 (senior-friendly redesign): the turndown is
// ArchiveAngelRecommendationList — ten large rows at a time with status
// words ("Ready to archive" / "Needs a date"…) instead of a letter grade and
// a score, and Hallie-style buttons (Play, Show in Catalog, Show in Finder,
// Promote/Prepare to Archive, Archive Readiness). The row models are built
// OUTSIDE body (task keyed on the recommendations revision and the page
// size): O(rows shown) record lookups, never O(records) per render.

import SwiftUI

struct ArchiveAngelAssessmentPanel: View {
    @EnvironmentObject var model: VideoScanModel
    /// The façade: Assess Now / Assess Continuously and Show in Catalog go
    /// through it (S2); observed for the Assess Continuously state.
    @ObservedObject var angel: ArchiveAngel
    @ObservedObject var store: ArchiveAngelEvidenceStore
    @ObservedObject var sweep: ArchiveAngelSweep
    /// Opens the Archive Angel start sheet (pick 10/25/35/50 → prepare).
    let prepare: () -> Void
    /// Prepared batches waiting for review: (rows ready in the newest,
    /// number of batches). nil = nothing to review → no chip.
    var review: (ready: Int, batches: Int)? = nil
    var openReview: () -> Void = {}
    /// Archive Angel's Prepare for exactly these records — a row's
    /// "Prepare to Archive" (the strip owns the MFO center).
    var prepareRecords: ([UUID]) -> Void = { _ in }
    /// An Archive Angel or Promote job is running (QA P3: a row's Prepare
    /// is off meanwhile). The strip reads it from the MFO center.
    var angelJobRunning = false

    @State private var isOpen = false
    @State private var rows: [ArchiveAngelListRow] = []
    @State private var shownCount = ArchiveAngelAssessmentPanel.pageSize
    /// Rows per page (Rick 2026-09-24: ten, clearly, beats twenty-five).
    static let pageSize = 10

    /// ONE strip in the Archive pane (Rick 2026-09-22: the sidebar had
    /// three overlapping Angel entries). Left: the grades, click to open
    /// the top-25 list. Right: the review chip (when a batch is waiting),
    /// the two actions, and a ⋯ menu for the sweep controls.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Image(systemName: "sparkles").foregroundStyle(Color.orange)
                        Text("Archive Angel")
                            .font(.system(size: 17, weight: .semibold))
                        Text(headline)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive.angelAssessment")
                .help(statusHelp)
                .layoutPriority(1)

                Spacer(minLength: 8)

                if let review {
                    // Nag-button pattern: the badge performs the action.
                    Button(action: openReview) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(review.batches == 1
                                 ? "\(review.ready) to review"
                                 : "\(review.ready) to review (+\(review.batches - 1) more)")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("archive.angelReview")
                    .help("Archive Angel prepared a batch. Review the recommendations, rename or deselect, then Promote.")
                }
                Button("Prepare Batch…") { prepare() }
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("archive.angelPrepare")
                    .help("Pick how many to prepare (10/25/35/50); the Angel takes the top-graded candidates, verifies audio and makes access copies in the buffer, then asks for review. Nothing reaches the archive until you press Promote.")
                Button("Show in Catalog") { showCandidatesInCatalog() }
                    .controlSize(.large)
                    .fixedSize()
                    .disabled(angel.candidateIDs.isEmpty)
                    .help("Focus the Catalog on every Ready, Needs a date and Worth a look record. Show ▸ Archive Candidates keeps the same view as a filter.")
                Menu {
                    Button("Assess Now") { angel.assessNow() }
                        .disabled(sweep.status.isRunning || !angel.sweepEnabled)
                        .accessibilityIdentifier("archive.angelAssessNow")
                    Toggle("Assess Continuously", isOn: Binding(
                        get: { angel.sweepEnabled },
                        set: { angel.setContinuous($0) }))
                    // Angel Checks (docs/archive_angel_wise_design.md §4).
                    Toggle("Check Sound in the Background", isOn: Binding(
                        get: { angel.checksEnabled },
                        set: { angel.setChecks($0) }))
                        .accessibilityIdentifier("archive.angelChecks")
                    Toggle("Keep Footage Groups Current", isOn: Binding(
                        get: { angel.footageAutoEnabled },
                        set: { angel.setFootageAuto($0) }))
                        .accessibilityIdentifier("archive.angelFootageAuto")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Assess now re-scores every record (a few seconds). Assess continuously scores catalog fields and Spotlight play counts only — never media bytes — and parks whenever you are working or a job is running. Check Sound in the Background runs Verify Audio on the top of the list, one file at a time, only while you are not using the app (at most 12 an hour); it writes the verdict on the record and changes nothing else. Keep Footage Groups Current re-runs Find Similar Footage (catalog metadata only) when its groups are a day old.")
            }
            if isOpen {
                ArchiveAngelRecommendationList(
                    rows: rows,
                    totalCount: angel.recommendations.ranked.count,
                    isAssessed: angel.recommendations.isAssessed,
                    checkingCount: angel.checkingIDs.count,
                    isReadOnly: model.isReadOnly,
                    angelJobRunning: angelJobRunning,
                    actions: ArchiveAngelListActions(model: model, angel: angel, prepare: prepareRecords),
                    showMore: { shownCount += Self.pageSize })
                    .padding(.leading, 16)
                    .padding(.top, 4)
            }
        }
        .task(id: RebuildKey(revision: angel.recommendations.revision, shown: shownCount,
                             checking: angel.checkingIDs)) { await rebuildRows() }
    }

    /// The list is rebuilt when the recommendations change, a page is
    /// added, or Angel Checks picks up / finishes a file (≤ 21 ids).
    private struct RebuildKey: Equatable {
        let revision: Int
        let shown: Int
        let checking: Set<UUID>
    }

    // MARK: Headline

    /// "12 ready · 30 need a date · 10 prepared · assessed 5 min ago" —
    /// the façade's ONE set of numbers (S3b), the same the nudge and the
    /// catalog filter read. O(1): the counts are computed off the body.
    private var headline: String {
        let summary = angel.recommendations
        var s: String
        if summary.isAssessed {
            s = summary.headline
            if let at = store.computedAt {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .abbreviated
                s += " · assessed " + f.localizedString(for: at, relativeTo: Date())
            }
        } else {
            s = "not assessed yet"
        }
        switch sweep.status {
        case .scoring(let done, let total): s += " · assessing \(done.formatted()) of \(total.formatted())…"
        case .paused(let r): s += " · paused — \(r)"
        case .disabled: s += " · assessment off"
        default: break
        }
        let checking = angel.checkingIDs.count
        if checking > 0 { s += " · \(checking) being checked" }
        return s
    }

    private var statusHelp: String {
        let r = angel.recommendations
        return "Ready: passes the floors, you vouched (Important, ★★+, stage Ready/Master) or it grades A, and it has at least a year. "
        + "Needs a date: the same, undated. Worth a look (\(r.count(.worthALook).formatted())): grade B nobody vouched. "
        + "Prepared: waiting for your review. Rules: Archive Angel policy (policy.json). "
        + "Re-scored at launch, a minute after any catalog edit, and every 15 minutes while the app is open. "
        + "Check Sound in the Background verifies the sound of the top recommendations while you are away, so a row is Ready or Needs repair instead of unchecked. "
        + sweep.status.line + ". " + angel.checks.status.line
    }

    // MARK: Turndown rows

    /// The façade's ranked recommendations (Ready, then Needs a date, then
    /// Worth a look — each by score) → row models; stop at `shownCount`
    /// before touching more records. O(shownCount) O(1) lookups.
    private func rebuildRows() async {
        var facts: [ArchiveAngelRowFacts] = []
        facts.reserveCapacity(shownCount)
        for id in angel.recommendations.ranked {
            guard facts.count < shownCount else { break }
            guard let rec = model.record(forID: id) else { continue }
            facts.append(ArchiveAngelRowFacts.make(record: rec, evidence: store.record(for: id),
                                                   kind: angel.recommendationClass(for: id) ?? .notNow,
                                                   isBeingChecked: angel.checkingIDs.contains(id)))
        }
        rows = ArchiveAngelListRowBuilder.rows(facts)
        // Then say which files are missing from a connected drive — the
        // stats run off the main actor (QA P2-2), O(rows shown).
        let probed = await ArchiveAngelRowFacts.probeExistence(facts)
        guard !Task.isCancelled else { return }
        rows = ArchiveAngelListRowBuilder.rows(probed)
    }

    private func showCandidatesInCatalog() {
        let ids = store.candidateIDs
        guard !ids.isEmpty else { return }
        angel.navigator?.showInCatalog(focus: ids, label: "Archive Angel candidates")
    }
}
