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
// top-ranked A/B candidates with Show in Catalog / Show in Finder per row.
// The ranked list is built OUTSIDE body (task keyed on computedAt): the
// ranking is O(eligible log eligible), never O(records) per render.

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

    @State private var isOpen = false
    @State private var top: [Row] = []
    static let topCount = 25

    struct Row: Identifiable, Equatable {
        let id: UUID
        let filename: String
        let path: String
        let durationSeconds: Double
        let grade: ArchiveAngelGrade
        let score: Int
        let why: String
    }

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
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Image(systemName: "sparkles").foregroundStyle(Color.orange)
                        Text("Archive Angel")
                            .font(.system(size: 14, weight: .semibold))
                        Text(headline)
                            .font(.system(size: 13))
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
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(Color.orange)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityIdentifier("archive.angelReview")
                    .help("Archive Angel prepared a batch. Review the recommendations, rename or deselect, then Promote.")
                }
                Button("Prepare Batch…") { prepare() }
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("archive.angelPrepare")
                    .help("Pick how many to prepare (10/25/35/50); the Angel takes the top-graded candidates, verifies audio and makes access copies in the buffer, then asks for review. Nothing reaches the archive until you press Promote.")
                Button("Show in Catalog") { showCandidatesInCatalog() }
                    .controlSize(.small)
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Assess now re-scores every record (a few seconds). Assess continuously scores catalog fields and Spotlight play counts only — never media bytes — and parks whenever you are working or a job is running.")
            }
            if isOpen {
                list
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }
        }
        .task(id: angel.recommendations.revision) { rebuildTop() }
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
        return s
    }

    private var statusHelp: String {
        let r = angel.recommendations
        return "Ready: passes the floors, you vouched (Important, ★★+, stage Ready/Master) or it grades A, and it has at least a year. "
        + "Needs a date: the same, undated. Worth a look (\(r.count(.worthALook).formatted())): grade B nobody vouched. "
        + "Prepared: waiting for your review. Rules: Archive Angel policy (policy.json). "
        + "Re-scored at launch, a minute after any catalog edit, and every 15 minutes while the app is open. "
        + sweep.status.line
    }

    // MARK: Turndown

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if top.isEmpty {
                Text(angel.recommendations.isAssessed ? "Nothing is recommended yet." : "Waiting for the first assessment…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            ForEach(top) { row in
                HStack(spacing: 8) {
                    Text(row.grade.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(row.grade == .a ? Color.green.opacity(0.25) : Color.orange.opacity(0.22)))
                        .help("Grade \(row.grade.rawValue) — \(row.grade.label)")
                    Text(row.filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ArchiveAngelScorer.durationText(row.durationSeconds))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(row.why)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ArchiveAngelRowActions(recordID: row.id, filename: row.filename, sourcePath: row.path)
                    Text("\(row.score)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                Divider()
            }
            if angel.candidateIDs.count > top.count {
                Text("Top \(top.count) of \(angel.candidateIDs.count.formatted()) — Show in Catalog lists them all.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The façade's ranked recommendations (Ready, then Needs a date, then
    /// Worth a look — each by score) → rows; stop at topCount before
    /// touching records.
    private func rebuildTop() {
        var rows: [Row] = []
        rows.reserveCapacity(Self.topCount)
        for id in angel.recommendations.ranked {
            guard rows.count < Self.topCount else { break }
            guard let ev = store.record(for: id),
                  let rec = model.record(forID: id) else { continue }
            rows.append(Row(id: id, filename: rec.filename, path: rec.fullPath,
                            durationSeconds: rec.durationSeconds, grade: ev.grade, score: ev.score,
                            why: ev.lines.first?.line ?? ""))
        }
        top = rows
    }

    private func showCandidatesInCatalog() {
        let ids = store.candidateIDs
        guard !ids.isEmpty else { return }
        angel.navigator?.showInCatalog(focus: ids, label: "Archive Angel candidates")
    }
}
