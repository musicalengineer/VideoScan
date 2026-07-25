// ConfirmPersonSheet.swift
// Interactive UI for the Confirm-Person workflow. The user is shown
// one candidate at a time — a thumbnail, the catalog signals that
// surfaced it, and four rating buttons (Definitely / Likely / Unsure /
// Unlikely). Each rating persists to ValidationLabelStore, and the
// "positive" ratings (Definitely → confirmedByUserPeople, Likely →
// suspectedPeople) also write back to the catalog so search lights up
// immediately.
//
// Layout reference: CombineSheet / DeleteConfirmedJunkConfirmSheet —
// modal sheet, fixed width, primary content on the left, action
// affordances on the right.
//
// Rick 2026-06-16.
//
// HOLDOUT MODE (Rick 2026-07-25): the same sheet also hosts the blind
// holdout review — the Review badge on a PersonCard opens it with a
// non-nil holdoutQueue. In holdout mode the sheet is a different animal
// under the same roof:
//   • BLIND — none of the prediction machinery runs or renders. No
//     candidate scoring (prepareSetup is never called), no signalsView,
//     no scores, no detected-person data. The pane renders ONLY from
//     HoldoutReviewRow, a struct that structurally cannot carry a model
//     opinion (pinned by HoldoutReviewQueueTests' blindness sensor).
//     Rick's eyes are the uncontaminated ground truth — POI-leakage
//     contract, team-channel 2026-07-25-1115.
//   • Output goes ONLY to the queue CSV (write-through per answer,
//     atomic). ValidationLabelStore and catalogWriteback are skipped
//     entirely — holdout answers must never touch model/candidate state.
//   • Resume — opening lands on the first unanswered row; answered rows
//     are skipped (Back can revisit/edit them).

import AVKit
import AppKit
import SwiftUI

/// Identifiable wrapper so `.sheet(item:)` can drive the sheet from
/// PersonFinderView. The id is per-presentation, not per-profile, so
/// re-opening the sheet for the same profile produces a fresh round.
struct ConfirmSheetTarget: Identifiable {
    let id = UUID()
    let profile: POIProfile
    /// Non-nil → open in blind holdout-review mode on this queue.
    let holdoutQueue: HoldoutReviewQueue?

    init(profile: POIProfile, holdoutQueue: HoldoutReviewQueue? = nil) {
        self.profile = profile
        self.holdoutQueue = holdoutQueue
    }
}

struct ConfirmPersonSheet: View {

    let profile: POIProfile
    /// Present ⇒ holdout mode. The sheet takes a mutable working copy
    /// into `holdout` on appear (value semantics — the copy + its CSV
    /// are the source of truth while the sheet is up).
    var holdoutQueue: HoldoutReviewQueue? = nil

    @EnvironmentObject var personFinderModel: PersonFinderModel
    @EnvironmentObject var catalogModel: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [PersonCandidateScore] = []
    @State private var currentIndex: Int = 0
    /// Local round state — paths the user has labeled THIS session.
    /// Used so the in-sheet summary at the end is for this round only,
    /// not the cumulative store. The store has every label across
    /// sessions; this captures the slice the user just produced.
    @State private var roundStart: Date = Date()
    @State private var roundLabels: [(path: String, rating: ConfirmRating, signals: [String])] = []
    @State private var thumbnail: NSImage?
    @State private var thumbnailLoadTask: Task<Void, Never>?
    @State private var showSummary: Bool = false
    @State private var loadError: String?

    /// Sheet phase. .setup shows the round-size picker and availability
    /// stats; .labeling is the existing per-candidate review; .summary
    /// is the end-of-round report. Rick 2026-06-16. Holdout mode never
    /// enters .setup — it starts straight in .labeling (or .summary if
    /// nothing is pending) since there is no scoring to configure.
    @State private var phase: Phase = .setup
    enum Phase { case setup, labeling, summary }

    /// Stats from round assembly — shown in the setup pane.
    @State private var stats: ConfirmRoundStats?

    /// User's pick from the round-size picker. Default 25; bumped to
    /// 100 if the user picks the long-round option.
    @State private var roundSize: Int = 25

    /// Held during setup so we don't re-score the catalog on every
    /// roundSize tick. Recomputed when the sheet appears; the picker
    /// just slices off the front.
    @State private var fullCandidatePool: [PersonCandidateScore] = []

    private let controlK: Int = 5

    // MARK: Holdout-mode state

    /// Mutable working copy of the queue — every answer writes through
    /// to the CSV via recordAnswer, so this mirrors disk at all times.
    @State private var holdout: HoldoutReviewQueue?
    @State private var holdoutIndex: Int = 0
    /// Notes draft for the CURRENT row — prefilled from the row when
    /// navigating so Back-and-edit round-trips cleanly.
    @State private var holdoutNotes: String = ""
    /// stat() result for the current row's file, computed on navigation
    /// (not in the view body — no file I/O per render).
    @State private var holdoutReachable: Bool = true
    @State private var holdoutSaveError: String?
    @State private var holdoutAnsweredThisSession: Int = 0

    private var isHoldout: Bool { holdoutQueue != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 640)
        .onAppear {
            if isHoldout { startHoldout() } else { prepareSetup() }
        }
        .onDisappear { thumbnailLoadTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isHoldout ? "eye.circle" : "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(isHoldout ? "Review \(profile.name) — holdout" : "Confirm \(profile.name)")
                    .font(.headline)
                Text(isHoldout
                     ? "Blind review — watch each video and answer. No hints or scores are shown; your eyes are the ground truth."
                     : "Rate each candidate — your labels train the model and update the catalog.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isHoldout, let q = holdout {
                Text("\(q.answeredCount) of \(q.rows.count) answered")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if phase == .labeling && !candidates.isEmpty {
                Text("\(currentIndex + 1) of \(candidates.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isHoldout {
            // Holdout content deliberately bypasses the setup/scoring
            // panes and signalsView — see BLIND contract in the file
            // header comment.
            switch phase {
            case .labeling:
                holdoutPane
            default:
                holdoutDonePane
            }
        } else {
            switch phase {
            case .setup:
                ConfirmSetupPane(
                    personName: profile.name,
                    stats: stats,
                    availOnline: fullCandidatePool.filter { $0.reachable }.count,
                    roundSize: $roundSize
                )
            case .labeling:
                if candidates.isEmpty {
                    emptyState
                } else {
                    let candidate = candidates[currentIndex]
                    HStack(alignment: .top, spacing: 16) {
                        thumbnailView(path: candidate.recordPath, filename: candidate.filename)
                            .frame(width: 320)
                        signalsView(for: candidate)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            case .summary:
                let summary = personFinderModel.validationLabels.roundSummary(
                    for: profile.name, since: roundStart
                )
                ConfirmSummaryPane(personName: profile.name, summary: summary)
            }
        }
    }

    private func thumbnailView(path: String, filename: String) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(8)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    openInQuickTime(path)
                } label: {
                    Label("Open in QuickTime", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Watch the full video before rating")
                Button {
                    revealInFinder(path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
                Spacer()
            }
        }
    }

    private func signalsView(for candidate: PersonCandidateScore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why this candidate")
                .font(.subheadline.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(candidate.signals, id: \.self) { sig in
                    HStack(spacing: 6) {
                        Image(systemName: confirmSignalIcon(sig))
                            .foregroundColor(.accentColor)
                            .frame(width: 14)
                        Text(sig)
                            .font(.system(size: 12))
                    }
                }
            }
            Text("Score: \(candidate.score)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            if !candidate.reachable {
                Label("Volume offline — open won't work", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()
            ratingButtons(for: candidate)
        }
    }

    private func ratingButtons(for candidate: PersonCandidateScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Is \(profile.name) in this video?")
                .font(.system(size: 12).weight(.medium))
            ForEach(ConfirmRating.userFacing) { rating in
                Button {
                    apply(rating: rating, to: candidate)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: rating.symbol)
                            .foregroundColor(rating.color)
                        Text(rating.rawValue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(rating.keyboardKey)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .help(rating.hint)
            }
            HStack {
                Button("Back") { goBack() }
                    .buttonStyle(.borderless)
                    .disabled(currentIndex == 0)
                    .help("Return to the previous candidate (after an accidental skip or to re-rate)")
                Spacer()
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                    .help("Move to the next candidate without labeling this one")
            }
            .font(.caption)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No candidates")
                .font(.headline)
            Text("The catalog has no records with signal for \(profile.name). Run a scan with the Find Person verb first, then come back.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    private var footer: some View {
        HStack {
            if isHoldout {
                if let err = holdoutSaveError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                } else if holdoutAnsweredThisSession > 0 {
                    Text("\(holdoutAnsweredThisSession) answered this session \u{00B7} saved to CSV")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else if !roundLabels.isEmpty {
                // Roll-up of labels saved this round — present from the
                // first rating onward so the user always knows their
                // progress is real, even if they Cancel mid-round.
                Text("\(roundLabels.count) labeled this round \u{00B7} saved")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isHoldout {
                // Every answer is already on disk — Close never loses work.
                Button(phase == .summary ? "Done" : "Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(phase == .summary ? .defaultAction : .cancelAction)
            } else {
                switch phase {
                case .setup:
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Begin \u{2192}") { startRound() }
                        .buttonStyle(.borderedProminent)
                        .disabled(stats == nil || (stats?.candidatesSurfaced ?? 0) == 0)
                        .keyboardShortcut(.return, modifiers: [])
                case .labeling:
                    Button("Finish & Show Summary") { phase = .summary }
                        .disabled(roundLabels.isEmpty)
                    Button(roundLabels.isEmpty ? "Cancel" : "Save & Close") { dismiss() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                case .summary:
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Holdout panes

    /// The blind review pane. Renders ONLY from HoldoutReviewRow —
    /// thumbnail/open/reveal, a yes/no question, and notes. Nothing else.
    @ViewBuilder
    private var holdoutPane: some View {
        if let q = holdout, q.rows.indices.contains(holdoutIndex) {
            let row = q.rows[holdoutIndex]
            HStack(alignment: .top, spacing: 16) {
                thumbnailView(path: row.fullPath, filename: row.filename)
                    .frame(width: 320)
                holdoutAnswerView(for: row)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        } else {
            holdoutDonePane
        }
    }

    private func holdoutAnswerView(for row: HoldoutReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is \(profile.name) in this video?")
                .font(.system(size: 13).weight(.medium))
            Text("Watch as much as you need — answer from what you see, not from memory of the filename.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !row.isPending {
                // Reached via Back — show the saved answer; a new click
                // overwrites it in the CSV.
                Label("Currently answered: \(row.rickConfirm) \u{2014} answering again overwrites",
                      systemImage: "pencil.circle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if !holdoutReachable {
                Label("Volume offline — open won't work", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack(spacing: 10) {
                Button {
                    holdoutAnswer("yes")
                } label: {
                    Label("Yes", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .help("\(profile.name) is visible in this video")
                Button {
                    holdoutAnswer("no")
                } label: {
                    Label("No", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("\(profile.name) is not visible in this video")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes (optional)")
                    .font(.system(size: 11).weight(.medium))
                    .foregroundColor(.secondary)
                TextField("e.g. brief glimpse at 2:10, poor lighting", text: $holdoutNotes)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Button("Back") { holdoutGo(to: holdoutIndex - 1) }
                    .buttonStyle(.borderless)
                    .disabled(holdoutIndex == 0)
                    .help("Revisit the previous video (answered ones can be re-answered)")
                Spacer()
                Button("Skip") { holdoutSkip() }
                    .buttonStyle(.borderless)
                    .help("Leave this one unanswered for now and move on")
            }
            .font(.caption)
        }
    }

    private var holdoutDonePane: some View {
        VStack(spacing: 10) {
            Image(systemName: (holdout?.pendingCount ?? 0) == 0
                  ? "checkmark.seal.fill" : "hourglass")
                .font(.system(size: 36))
                .foregroundColor((holdout?.pendingCount ?? 0) == 0 ? .green : .orange)
            if let q = holdout {
                if q.pendingCount == 0 {
                    Text("All \(q.rows.count) videos answered")
                        .font(.headline)
                    Text("The review CSV is complete \u{2014} nothing further to do here. The grading side takes it from the file; your answers never touch the model from this app.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                } else {
                    Text("\(q.pendingCount) still pending")
                        .font(.headline)
                    Text("You skipped some \u{2014} the Review badge stays up until every row has an answer. Reopen anytime; you'll land on the first unanswered video.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("Continue Reviewing") {
                        if let idx = holdout?.firstPendingIndex {
                            holdoutGo(to: idx)
                            phase = .labeling
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("No review queue found")
                    .font(.headline)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Holdout lifecycle

    /// Entry point in holdout mode (replaces prepareSetup). No scoring,
    /// no ValidationLabelStore, no catalog reads beyond nothing at all —
    /// just position onto the first unanswered row.
    private func startHoldout() {
        holdout = holdoutQueue
        if let idx = holdoutQueue?.firstPendingIndex {
            phase = .labeling
            holdoutGo(to: idx)
        } else {
            phase = .summary
        }
    }

    /// Navigate to a row: reset the thumbnail, prefill the notes draft,
    /// and stat the file once (kept out of the view body).
    private func holdoutGo(to idx: Int) {
        guard let q = holdout, q.rows.indices.contains(idx) else { return }
        thumbnailLoadTask?.cancel()
        thumbnail = nil
        holdoutIndex = idx
        holdoutNotes = q.rows[idx].notes
        holdoutReachable = FileManager.default.fileExists(atPath: q.rows[idx].fullPath)
        if holdoutReachable {
            loadThumbnail(path: q.rows[idx].fullPath)
        }
    }

    /// Record yes/no + notes for the current row. Write-through: the CSV
    /// on disk is updated before we advance, so a crash loses nothing.
    private func holdoutAnswer(_ confirm: String) {
        guard var q = holdout, q.rows.indices.contains(holdoutIndex) else { return }
        let row = q.rows[holdoutIndex]
        do {
            try q.recordAnswer(reviewId: row.reviewId, confirm: confirm, notes: holdoutNotes)
            holdout = q
            holdoutSaveError = nil
            holdoutAnsweredThisSession += 1
            holdoutAdvance()
        } catch {
            // Leave the user on this row — nothing was recorded.
            holdoutSaveError = "Could not save answer: \(error.localizedDescription)"
        }
    }

    private func holdoutAdvance() {
        guard let q = holdout else { return }
        if let next = q.nextPendingIndex(after: holdoutIndex) {
            holdoutGo(to: next)
        } else if q.rows.indices.contains(holdoutIndex), q.rows[holdoutIndex].isPending {
            // Skipped the only remaining pending row — stay put.
        } else {
            phase = .summary
        }
    }

    private func holdoutSkip() {
        guard let q = holdout else { return }
        if let next = q.nextPendingIndex(after: holdoutIndex) {
            holdoutGo(to: next)
        } else {
            // Nothing else pending — show the "still pending" done pane
            // (this row remains unanswered by choice).
            phase = .summary
        }
    }

    // MARK: - Round lifecycle

    private func prepareSetup() {
        roundStart = Date()
        // Score in the background — for 16k records this is ~1-2 sec.
        // Keep the @MainActor scope clean by hopping out and back.
        Task { @MainActor in
            let already = Set(personFinderModel.validationLabels
                .labeledByPath(for: profile.name).keys)
            var rng = SystemRandomNumberGenerator()
            let result = pfConfirmRound(
                name: profile.name,
                records: catalogModel.records,
                topN: 100,   // upper bound; the roundSize picker trims
                controlK: controlK,
                alreadyLabeled: already,
                rng: &rng
            )
            self.fullCandidatePool = result.candidates
            self.stats = result.stats
            // Default to a sensible round size if 25 isn't reachable.
            let availOnline = result.candidates.filter { $0.reachable }.count
            if availOnline < self.roundSize {
                self.roundSize = max(min(availOnline, 25), 1)
            }
        }
    }

    private func startRound() {
        // Slice the pre-scored pool to the user's chosen round size.
        let onlineOnly = fullCandidatePool.filter { $0.reachable }
        candidates = Array(onlineOnly.prefix(roundSize))
        currentIndex = 0
        phase = .labeling
        if !candidates.isEmpty {
            loadThumbnail(path: candidates[0].recordPath)
        }
    }

    private func apply(rating: ConfirmRating, to candidate: PersonCandidateScore) {
        // Persist label
        personFinderModel.validationLabels.record(
            recordPath: candidate.recordPath,
            person: profile.name,
            rating: rating,
            signals: candidate.signals,
            score: candidate.score
        )
        roundLabels.append((candidate.recordPath, rating, candidate.signals))

        // Catalog writeback per rating tier
        catalogWriteback(rating: rating, candidate: candidate)

        advance()
    }

    private func catalogWriteback(rating: ConfirmRating, candidate: PersonCandidateScore) {
        guard let rec = catalogModel.records.first(where: { $0.id == candidate.recordID })
        else { return }
        let p = profile.name
        // Each writeback path enforces "this person belongs in EXACTLY
        // ONE tier" — confirmedByUserPeople, suspectedPeople, or
        // rejectedPeople — and cleans up the other two. This makes
        // re-rating (via the Back button) idempotent: the catalog
        // state always reflects the user's most recent decision.
        switch rating.writebackTier {
        case .confirmed:
            removePerson(p, from: &rec.suspectedPeople)
            removePerson(p, from: &rec.rejectedPeople)
            if !rec.confirmedByUserPeople.contains(where: {
                $0.name.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.confirmedByUserPeople.append(ConfirmedTag(name: p, confirmedAt: Date()))
            }
            catalogModel.saveCatalogDebounced()
        case .suspected:
            removeConfirmed(p, from: &rec.confirmedByUserPeople)
            removePerson(p, from: &rec.rejectedPeople)
            if !rec.suspectedPeople.contains(where: {
                $0.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.suspectedPeople.append(p)
            }
            catalogModel.saveCatalogDebounced()
        case .rejected:
            removeConfirmed(p, from: &rec.confirmedByUserPeople)
            removePerson(p, from: &rec.suspectedPeople)
            // Also remove from detectedPeople so a stale PF tag from
            // a prior scan doesn't keep this video showing up in
            // people:donna search after the user explicitly said No.
            removePerson(p, from: &rec.detectedPeople)
            if !rec.rejectedPeople.contains(where: {
                $0.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.rejectedPeople.append(p)
            }
            catalogModel.saveCatalogDebounced()
        case .none:
            // Legacy Unsure/Unlikely — no catalog mutation. Label is
            // still in the sidecar for training-data purposes.
            break
        }
    }

    private func removePerson(_ name: String, from arr: inout [String]) {
        arr.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func removeConfirmed(_ name: String, from arr: inout [ConfirmedTag]) {
        arr.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func advance() {
        thumbnailLoadTask?.cancel()
        thumbnail = nil
        if currentIndex + 1 < candidates.count {
            currentIndex += 1
            loadThumbnail(path: candidates[currentIndex].recordPath)
        } else {
            // Out of candidates — show the summary automatically
            phase = .summary
        }
    }

    private func goBack() {
        // Pure navigation — go back to the previous candidate whether
        // it was labeled or skipped (Rick 2026-06-16: an accidental
        // Skip needs to be recoverable, not just an accidental rating).
        // If the previous candidate WAS labeled this round, pop its
        // entry from roundLabels so the user can re-rate without
        // double-counting in the summary. The label sidecar's most-
        // recent-wins semantics handles the duplicate-label case
        // cleanly on the next .apply call.
        guard currentIndex > 0 else { return }
        let prevPath = candidates[currentIndex - 1].recordPath
        if let last = roundLabels.last, last.path == prevPath {
            roundLabels.removeLast()
        }
        thumbnailLoadTask?.cancel()
        currentIndex -= 1
        loadThumbnail(path: candidates[currentIndex].recordPath)
    }

    // MARK: - Thumbnail loading

    private func loadThumbnail(path: String) {
        thumbnailLoadTask = Task { @MainActor in
            let img = await Self.generateThumbnail(for: path)
            if !Task.isCancelled {
                self.thumbnail = img
            }
        }
    }

    private static func generateThumbnail(for path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let durationSeconds: Double
        do {
            durationSeconds = try await asset.load(.duration).seconds
        } catch {
            return nil
        }
        let midpoint = CMTime(seconds: max(durationSeconds * 0.5, 0.5), preferredTimescale: 600)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            generator.generateCGImageAsynchronously(for: midpoint) { cg, _, _ in
                if let cg {
                    cont.resume(returning: NSImage(cgImage: cg, size: .zero))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func openInQuickTime(_ path: String) {
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: qtURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

}
