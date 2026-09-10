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
    @ObservedObject var store: ArchiveAngelEvidenceStore
    @ObservedObject var sweep: ArchiveAngelSweep
    /// Opens the Archive Angel start sheet (pick 10/25/35/50 → prepare).
    let prepare: () -> Void

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        Image(systemName: "sparkles").foregroundStyle(.secondary)
                        Text(headline)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("archive.angelAssessment")
                .help(statusHelp)
            }
            HStack(spacing: 14) {
                Button("Assess now") { sweep.rescoreNow() }
                    .disabled(sweep.status.isRunning || !model.archiveAngelSweepSettings.enabled)
                    .accessibilityIdentifier("archive.angelAssessNow")
                    .help("Re-score every record now. A full pass takes a few seconds; it runs on its own every 15 minutes and a minute after any edit.")
                Button("Show candidates in Catalog") { showCandidatesInCatalog() }
                    .disabled(store.candidateCount == 0)
                    .help("Focus the Catalog on every grade A and B record. Show ▸ Archive Candidates keeps the same view as a filter.")
                Button("Prepare batch…") { prepare() }
                    .disabled(model.isReadOnly)
                    .accessibilityIdentifier("archive.angelPrepare")
                    .help("Pick how many to prepare (10/25/35/50); the Angel takes the top-graded candidates, verifies audio and makes access copies in the buffer, then asks for review.")
                Toggle("Assess continuously", isOn: Binding(
                    get: { model.archiveAngelSweepSettings.enabled },
                    set: { model.setArchiveAngelSweepEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Scores catalog fields and Spotlight play counts only — never media bytes — and parks whenever you are working or a job is running.")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.leading, 16)
            if isOpen {
                list
                    .padding(.leading, 16)
                    .padding(.top, 2)
            }
        }
        .task(id: store.computedAt) { rebuildTop() }
    }

    // MARK: Headline

    private var headline: String {
        let g = store.gradeCounts()
        let a = g[.a] ?? 0, b = g[.b] ?? 0, c = g[.c] ?? 0
        var s: String
        if store.isLoaded {
            s = "Archive Angel Assessment: \(a.formatted()) ready · \(b.formatted()) nearly · \(c.formatted()) candidates"
                + " · of \(store.consideredCount.formatted())"
            if let at = store.computedAt {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .abbreviated
                s += " · " + f.localizedString(for: at, relativeTo: Date())
            }
        } else {
            s = "Archive Angel Assessment: not run yet"
        }
        switch sweep.status {
        case .scoring(let done, let total): s += " · assessing \(done.formatted()) of \(total.formatted())…"
        case .paused(let r): s += " · paused — \(r)"
        case .disabled: s += " · off"
        default: break
        }
        return s
    }

    private var statusHelp: String {
        "Grades: A ready · B nearly ready · C candidate · D weak · X excluded by the floor. "
        + "Re-scored at launch, a minute after any catalog edit, and every 15 minutes while the app is open. "
        + sweep.status.line
    }

    // MARK: Turndown

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if top.isEmpty {
                Text(store.isLoaded ? "No grade A or B candidates yet." : "Waiting for the first assessment…")
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
            if store.candidateCount > top.count {
                Text("Top \(top.count) of \(store.candidateCount.formatted()) — Show candidates in Catalog lists them all.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Ranked A/B ids → rows. `rankedEligibleIDs` already sorts by score;
    /// filter to candidates and stop at topCount before touching records.
    private func rebuildTop() {
        var rows: [Row] = []
        rows.reserveCapacity(Self.topCount)
        for id in store.rankedEligibleIDs() {
            guard rows.count < Self.topCount else { break }
            guard let ev = store.record(for: id), ev.isCandidate,
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
        model.focusedMediaIDs = ids
        model.pendingFocusLabel = "Archive Angel candidates"
        model.pendingCatalogSelection = nil
        model.pendingCatalogPairMode = false
        UserDefaults.standard.set(1, forKey: "selectedTab")
        MainWindowHelper.shared.openMainWindow()
    }
}
