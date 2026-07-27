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
//
// HDD PERFORMANCE (fix/review-sheet-performance, 2026-07-26): review
// media lives on the LaCie USB HDD. Three changes keep the pane usable
// there:
//   • Thumbnails go through the ROUTED renderer (ReviewThumbnailRenderer
//     → shared PreviewFrameRouter decision + AVF watchdog + ffmpeg
//     fallback, midpoint framing when the catalog knows the duration)
//     instead of the old private AVF-only generator. Catalog media
//     metadata (container/codec/duration) is allowed under the blind
//     contract — it is not detection/scoring data.
//   • NO blocking I/O on the main actor: the per-navigation fileExists
//     stat and the per-answer CSV reload+rewrite both run in background
//     tasks; answers are optimistic (advance immediately) with writes
//     STRICTLY serialized in click order via a task chain, and each
//     write still merges onto fresh disk state inside
//     HoldoutReviewQueue.recordAnswer (QA-gated semantic, unchanged).
//   • Read-ahead + spindle keepalive (HoldoutReadAhead.swift) warm the
//     next pending files and keep the LaCie from parking its heads
//     between answers.

import AVKit
import AppKit
import SwiftUI
import os

/// File-scope (not a member) so escaped write-chain tasks can log after
/// the view is gone. Same category as the queue itself — one trail for
/// the whole holdout pipeline.
private let holdoutSheetLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                     category: "poi.holdout-review")

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
    /// Present ⇒ holdout mode. Used for mode detection, initial display
    /// state, and the CSV location — the mutable working copy in
    /// `holdout` is reloaded FRESH from disk in startHoldout(), never
    /// seeded from this snapshot (stale-snapshot clobber, QA 2026-07-25).
    var holdoutQueue: HoldoutReviewQueue? = nil

    @EnvironmentObject var personFinderModel: PersonFinderModel
    @EnvironmentObject var catalogModel: VideoScanModel
    /// The badge center — outlives this sheet, so background write
    /// failures reported to it survive dismissal (QA 2026-07-26 🟠).
    @EnvironmentObject var holdoutCenter: HoldoutReviewCenter
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
    /// stat() result for the current row's file. Computed in a BACKGROUND
    /// task on navigation (never in the view body, never on the main
    /// actor — a stat against a spun-down USB HDD can stall for seconds).
    /// Optimistically true while the stat is in flight.
    @State private var holdoutReachable: Bool = true
    @State private var holdoutSaveError: String?
    @State private var holdoutAnsweredThisSession: Int = 0

    // MARK: HDD-performance state (fix/review-sheet-performance)

    /// True when thumbnail generation FAILED for the current row — shows
    /// the placeholder instead of an eternal spinner.
    @State private var thumbnailFailed: Bool = false
    /// Background stat() for the current row (cancelled on navigation).
    @State private var reachabilityTask: Task<Void, Never>?
    /// Tail of the serialized answer-write chain. Each new answer chains
    /// onto the previous task, so CSV read-modify-writes execute strictly
    /// one at a time, in click order — two quick answers can never
    /// interleave. Deliberately NOT cancelled on dismiss: queued answers
    /// must reach the CSV.
    @State private var holdoutWriteChain: Task<Void, Never>?
    /// reviewIds of WAS-PENDING answers whose background write hasn't
    /// committed yet. Used to (a) keep navigation from revisiting a row
    /// the user just answered, (b) show optimistic answered/pending
    /// counts. The in-memory queue itself is only mutated after the
    /// durable write succeeds (WAL discipline, QA 2026-07-25 minor 1).
    @State private var inFlightAnswerIds: Set<String> = []
    /// Catalog MEDIA metadata (container/codec/duration) by fullPath for
    /// the rows/candidates of this session — routing input for the
    /// thumbnail renderer. Built once per session (one pass over
    /// records), never in the view body. Media facts only — no
    /// detection/scoring data crosses into the blind pane.
    @State private var mediaMetaByPath: [String: HoldoutMediaMeta] = [:]
    /// Read-ahead: warms the next pending files (head+tail bytes) and
    /// pre-generates the next thumbnail, one file at a time. Created in
    /// startHoldout (not at property init) so its render closure can
    /// consult the model's shared negative cache — a known-bad NEXT row
    /// must not re-attempt a full render on every navigation
    /// (QA 2026-07-26 🟡 2).
    @State private var prefetcher: HoldoutReviewPrefetcher?
    /// Keeps the LaCie spindle from head-parking between answers.
    @State private var keepalive = HoldoutSpindleKeepalive()

    // MARK: Prefilter state (fix/review-offline-prefilter)
    //
    // Rick 2026-07-26: "if a video is offline, don't present it" and
    // "the prefilter should check that these are even playable." Two
    // SEPARATE exclusion sets — different facts, different remedies —
    // both keyed by fullPath. Excluded rows stay pending in the CSV
    // (hidden ≠ answered); navigation just never lands on them and the
    // counts call the hiding out explicitly.

    /// Rows whose file is unreachable: volume unmounted (sweep stage 1),
    /// file missing on a mounted volume (sweep stage 2), or vanished
    /// after the sweep (per-row backstop). Rebuilt by each sweep.
    @State private var offlineExcludedPaths: Set<String> = []
    /// Rows QuickTime can't play, decided ZERO-I/O from catalog facts
    /// (PreviewFrameRouter .ffmpegDirect — QT's boundary IS AVF's).
    /// Rows with no catalog record are presented: unknown ≠ unplayable.
    /// Computed once per open; catalog facts don't change mid-session.
    @State private var unplayableExcludedPaths: Set<String> = []
    /// Derived hidden-pending counts, stored (not computed per render —
    /// the 100k-row scale test says no O(rows) work in view bodies).
    /// Recomputed via recomputeHiddenCounts() whenever the sets or the
    /// queue's pending flags change.
    @State private var offlineHiddenPending: Int = 0
    @State private var unplayableHiddenPending: Int = 0
    /// One background reachability sweep per open (and per "Continue
    /// Reviewing" click). No polling.
    @State private var offlineSweepTask: Task<Void, Never>?

    private var isHoldout: Bool { holdoutQueue != nil }

    /// Pending/answered counts adjusted for in-flight background writes,
    /// so the header and done pane tick immediately on an answer (the
    /// authoritative queue state follows when the write commits).
    private var holdoutEffectivePending: Int {
        max(0, (holdout?.pendingCount ?? 0) - inFlightAnswerIds.count)
    }
    private var holdoutEffectiveAnswered: Int {
        guard let q = holdout else { return 0 }
        return q.rows.count - holdoutEffectivePending
    }
    /// Pending rows the user can actually be shown right now.
    private var holdoutActionablePending: Int {
        max(0, holdoutEffectivePending - offlineHiddenPending - unplayableHiddenPending)
    }
    /// " · 3 offline, 2 unplayable hidden" — empty when nothing is hidden.
    private var holdoutHiddenSuffix: String {
        var parts: [String] = []
        if offlineHiddenPending > 0 { parts.append("\(offlineHiddenPending) offline") }
        if unplayableHiddenPending > 0 { parts.append("\(unplayableHiddenPending) unplayable") }
        guard !parts.isEmpty else { return "" }
        return " \u{00B7} " + parts.joined(separator: ", ") + " hidden"
    }

    /// Seeds holdout-mode display state at construction so the FIRST
    /// body evaluation already renders the right pane — with the old
    /// onAppear-only initialization, phase started at .setup and the
    /// first holdout render fell through to the done pane ("No review
    /// queue found" flash). QA 2026-07-25 minor 3.
    ///
    /// The snapshot here is display-only; the authoritative working copy
    /// is reloaded from disk in startHoldout() (onAppear fires before
    /// any interaction is possible, so no answer can ever hit the
    /// snapshot). The reload is NOT done in init because SwiftUI may
    /// re-run a view's init on every parent render — file I/O belongs in
    /// onAppear, which runs once per presentation.
    init(profile: POIProfile, holdoutQueue: HoldoutReviewQueue? = nil) {
        self.profile = profile
        self.holdoutQueue = holdoutQueue
        guard let snapshot = holdoutQueue else { return }
        // `_holdout` is the property wrapper's backing storage — writing
        // `State(initialValue:)` here ≈ a C++ member-initializer list;
        // after init you go through the wrapped property instead.
        _holdout = State(initialValue: snapshot)
        if let idx = snapshot.firstPendingIndex {
            _phase = State(initialValue: .labeling)
            _holdoutIndex = State(initialValue: idx)
            _holdoutNotes = State(initialValue: snapshot.rows[idx].notes)
        } else {
            _phase = State(initialValue: .summary)
        }
    }

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
        .onDisappear {
            thumbnailLoadTask?.cancel()
            reachabilityTask?.cancel()
            offlineSweepTask?.cancel()
            prefetcher?.cancelAll()
            keepalive.stop()
            // holdoutWriteChain is NOT cancelled: any queued answers
            // still land in the CSV (each write is a self-contained
            // merge-onto-fresh-disk snapshot — nothing here references
            // dismantled view state).
        }
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
                // Effective counts: an optimistically advanced answer
                // ticks the header immediately even while its serialized
                // background write is still in flight. Hidden rows are
                // called out, never silently swallowed — e.g.
                // "12 of 36 answered · 3 offline, 2 unplayable hidden".
                Text("\(holdoutEffectiveAnswered) of \(q.rows.count) answered\(holdoutHiddenSuffix)")
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
                } else if thumbnailFailed {
                    // Generation failed (routed AVF + ffmpeg both struck
                    // out) — show a static placeholder, never an eternal
                    // spinner. The video itself may still play fine in
                    // QuickTime below.
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.system(size: 28))
                        Text("No preview")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
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
                if holdoutReachable {
                    thumbnailView(path: row.fullPath, filename: row.filename)
                        .frame(width: 320)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 34))
                        Text("Video is offline")
                            .font(.headline)
                        Text(row.filename)
                            .font(.caption.monospaced())
                            .lineLimit(2)
                    }
                    .foregroundColor(.secondary)
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                }
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
                .disabled(!holdoutReachable)
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
                .disabled(!holdoutReachable)
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
        // Effective counts throughout: a just-answered last row shows
        // "all answered" immediately, even while its serialized write is
        // still committing in the background. But the COMPLETION claim
        // ("the CSV is complete") is only made once every in-flight
        // write has actually committed — until then the honest state is
        // "still saving" (QA 2026-07-26 🟠 c). Hidden (offline/
        // unplayable) rows get their own honest branch: they are still
        // pending in the CSV, so "complete" would be a lie.
        let fullyCommitted = holdoutEffectivePending == 0 && inFlightAnswerIds.isEmpty
        let allRemainingHidden = holdoutEffectivePending > 0 && holdoutActionablePending == 0
        return VStack(spacing: 10) {
            Image(systemName: fullyCommitted ? "checkmark.seal.fill"
                  : (allRemainingHidden ? "externaldrive.badge.exclamationmark" : "hourglass"))
                .font(.system(size: 36))
                .foregroundColor(fullyCommitted ? .green : .orange)
            if let q = holdout {
                if fullyCommitted {
                    Text("All \(q.rows.count) videos answered")
                        .font(.headline)
                    Text("The review CSV is complete \u{2014} nothing further to do here. The grading side takes it from the file; your answers never touch the model from this app.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                } else if holdoutEffectivePending == 0 {
                    Text("All \(q.rows.count) videos answered")
                        .font(.headline)
                    Text("Finishing saving \(inFlightAnswerIds.count) answer\(inFlightAnswerIds.count == 1 ? "" : "s")\u{2026} This view updates when the CSV write completes.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                } else if allRemainingHidden {
                    // All-hidden edge: every reachable, playable video is
                    // answered — what's left can't be presented.
                    Text("All reviewable videos answered")
                        .font(.headline)
                    Text(allHiddenExplanation)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                } else {
                    Text("\(holdoutActionablePending) still pending\(holdoutHiddenSuffix)")
                        .font(.headline)
                    Text("You skipped some \u{2014} the Review badge stays up until every row has an answer. Reopen anytime; you'll land on the first unanswered video.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                    Button("Continue Reviewing") {
                        // Fresh sweep per Continue click (a drive may have
                        // been reconnected while the pane sat open).
                        startOfflineSweep()
                        if let idx = firstActionableIndex() {
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

    /// Body copy for the all-hidden done pane, naming BOTH reasons with
    /// their remedies — offline is recoverable by reconnecting; unplayable
    /// needs conversion first.
    private var allHiddenExplanation: String {
        var parts: [String] = []
        if offlineHiddenPending > 0 {
            parts.append("\(offlineHiddenPending) pending row\(offlineHiddenPending == 1 ? " is" : "s are") on offline volumes \u{2014} reconnect those drives and reopen the review to finish them.")
        }
        if unplayableHiddenPending > 0 {
            parts.append("\(unplayableHiddenPending) pending row\(unplayableHiddenPending == 1 ? "" : "s") can't be played by QuickTime (legacy/archival formats) \u{2014} they need conversion before they can be reviewed.")
        }
        parts.append("The Review badge stays up until every row has an answer.")
        return parts.joined(separator: " ")
    }

    // MARK: - Holdout lifecycle

    /// Entry point in holdout mode (replaces prepareSetup). No scoring,
    /// no ValidationLabelStore, no catalog reads beyond nothing at all —
    /// reload the queue fresh from disk and position onto the first
    /// unanswered row.
    ///
    /// The working copy still comes from disk, not from the
    /// discovery-time snapshot in `holdoutQueue`, so the sheet shows the
    /// real pending rows/count (a snapshot can predate hand edits or a
    /// regenerated queue). Data safety no longer hinges on this open-time
    /// reload: recordAnswer merges each answer onto a fresh disk load
    /// (QA 2026-07-25 gate finding 1), so even a stale working copy
    /// cannot clobber external edits. On load failure we surface the
    /// error and show the done pane — never fall back to the snapshot.
    /// QA 2026-07-25 blocker; regression tests:
    /// regression_staleSnapshotOpenPreservesExternalAnswer,
    /// regression_externalEditDuringOpenSessionSurvivesRecordAnswer.
    private func startHoldout() {
        guard let snapshot = holdoutQueue else {
            phase = .summary
            return
        }
        do {
            let fresh = try snapshot.freshCopyFromDisk()
            holdout = fresh
            // A prior session's write failure has done its job once the
            // user is back in front of the (still-pending) row.
            holdoutCenter.clearAnswerWriteFailure()
            // Catalog MEDIA metadata for the queue's files, one pass over
            // records (media facts only — the blind pane never sees
            // detection/scoring data).
            buildMediaMeta(for: Set(fresh.rows.map(\.fullPath)))
            // Prefetch render closure guards on the shared negative
            // cache — same gate as the interactive path — but does NOT
            // record failures (best-effort; nil is not a fact about the
            // file). QA 2026-07-26 🟡 2.
            let failureStore = catalogModel.thumbnailFailureStore
            prefetcher = HoldoutReviewPrefetcher(
                renderThumbnail: { path, meta in
                    guard !failureStore.isKnownFailure(atPath: path) else { return nil }
                    return await ReviewThumbnailRenderer.renderOrNil(path: path, meta: meta)
                })
            // Prefilter (Rick 2026-07-26: never present offline or
            // unplayable videos). Unplayable: pure catalog facts, zero
            // I/O. Offline: a synchronous VOLUME-level precheck here —
            // VolumeReachability.isReachable is documented to never touch
            // the disk on the caller's thread (SWR cache + kernel mount
            // table) — so the very first landing already skips rows on
            // disconnected drives; the honest per-file sweep then runs in
            // the background and refines the set.
            unplayableExcludedPaths = HoldoutNavigation.unplayablePaths(
                rows: fresh.rows, meta: mediaMetaByPath)
            offlineExcludedPaths = Self.volumeLevelOfflinePaths(
                rows: fresh.rows.filter(\.isPending))
            recomputeHiddenCounts()
            startOfflineSweep()
            if let idx = firstActionableIndex() {
                phase = .labeling
                // Spindle keepalive for the whole labeling session — see
                // HoldoutSpindleKeepalive for the head-park rationale.
                keepalive.start()
                holdoutGo(to: idx)
            } else {
                phase = .summary
            }
        } catch {
            holdout = nil
            holdoutSaveError = "Could not reload review queue: \(error.localizedDescription)"
            phase = .summary
        }
    }

    // MARK: - Offline / unplayable prefilter

    /// VOLUME-level offline check, main-safe by construction: only
    /// consults VolumeReachability.isReachable (SWR cache / kernel mount
    /// table — never disk I/O on the caller's thread), one lookup per
    /// distinct volume. Internal (non-/Volumes) paths pass — the per-file
    /// sweep and the per-row backstop cover those.
    private nonisolated static func volumeLevelOfflinePaths(rows: [HoldoutReviewRow]) -> Set<String> {
        var verdictByVolume: [String: Bool] = [:]
        var offline = Set<String>()
        for row in rows {
            guard let key = HoldoutNavigation.volumeKey(forPath: row.fullPath) else { continue }
            let reachable = verdictByVolume[key] ?? {
                let v = VolumeReachability.isReachable(path: key)
                verdictByVolume[key] = v
                return v
            }()
            if !reachable { offline.insert(row.fullPath) }
        }
        return offline
    }

    /// ONE background reachability sweep over the pending rows — run per
    /// open and per "Continue Reviewing" click, no polling. Cheap ladder:
    /// volume reachability once per distinct volume (mount table — no
    /// disk touch for unmounted drives), then fileExists per row only on
    /// reachable volumes, strictly serialized at O(rows). Result REPLACES
    /// the offline set (a reconnected volume's rows come back); the
    /// per-row backstop re-inserts anything that vanishes afterwards.
    private func startOfflineSweep() {
        guard let q = holdout else { return }
        offlineSweepTask?.cancel()
        let pendingRows = q.rows.filter(\.isPending).map(\.fullPath)
        offlineSweepTask = Task { @MainActor in
            let offline = await Self.sweepOfflinePaths(paths: pendingRows)
            guard !Task.isCancelled else { return }
            offlineExcludedPaths = offline
            recomputeHiddenCounts()
            // If the row on screen just turned out to be offline, honor
            // "never present an offline video" — move along (or to the
            // done pane if nothing actionable remains).
            if phase == .labeling, let qq = holdout,
               qq.rows.indices.contains(holdoutIndex),
               offline.contains(qq.rows[holdoutIndex].fullPath),
               qq.rows[holdoutIndex].isPending {
                holdoutAdvance()
            }
        }
    }

    /// The blocking half of the sweep, off the main actor. Serialized —
    /// one stat at a time — so a spun-down HDD sees a polite sequential
    /// scan, not a seek storm.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func sweepOfflinePaths(paths: [String]) async -> Set<String> {
        var offline = Set<String>()
        var volumeReachable: [String: Bool] = [:]
        for path in paths {
            if Task.isCancelled { return offline }
            if let key = HoldoutNavigation.volumeKey(forPath: path) {
                let reachable = volumeReachable[key] ?? {
                    // Honest one-shot answer: the kernel mount table
                    // (getmntinfo MNT_NOWAIT — in-kernel state, never
                    // spins up a disk), not the SWR cache, so a just-
                    // yanked drive can't answer stale-true.
                    let v = VolumeReachability.currentMountedRoots().contains(key)
                    volumeReachable[key] = v
                    return v
                }()
                if !reachable {
                    offline.insert(path)
                    continue
                }
            }
            // Mounted volume or internal path → the file itself decides.
            if !FileManager.default.fileExists(atPath: path) {
                offline.insert(path)
            }
        }
        return offline
    }

    /// Refresh the stored hidden-pending counts (never computed in view
    /// bodies — the queue can be arbitrarily large per the scale test).
    private func recomputeHiddenCounts() {
        guard let q = holdout else {
            offlineHiddenPending = 0
            unplayableHiddenPending = 0
            return
        }
        let counts = HoldoutNavigation.hiddenPendingCounts(
            rows: q.rows,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths)
        offlineHiddenPending = counts.offline
        unplayableHiddenPending = counts.unplayable
    }

    /// Navigate to a row: reset the thumbnail, prefill the notes draft,
    /// and kick off the background stat + thumbnail load. NO synchronous
    /// file I/O here — a fileExists against a spun-down USB HDD can
    /// stall the main thread for seconds, which was navigation bug #2 of
    /// the LaCie review slowness (2026-07-26).
    private func holdoutGo(to idx: Int) {
        guard let q = holdout, q.rows.indices.contains(idx) else { return }
        thumbnailLoadTask?.cancel()
        reachabilityTask?.cancel()
        thumbnail = nil
        thumbnailFailed = false
        holdoutIndex = idx
        holdoutNotes = q.rows[idx].notes
        let path = q.rows[idx].fullPath
        keepalive.setCurrentPath(path)

        // Optimistic: render as reachable immediately; the background
        // stat corrects to the offline pane if the file is gone. The
        // thumbnail load starts right away — on a spun-up disk it wins;
        // on a missing file it fails fast and the stat verdict lands.
        holdoutReachable = true
        reachabilityTask = Task { @MainActor in
            let exists = await Self.statFileExists(path)
            guard !Task.isCancelled, holdoutIndex == idx else { return }
            holdoutReachable = exists
            if !exists {
                thumbnailLoadTask?.cancel()
                thumbnail = nil
                // Backstop feeds the prefilter: a file can vanish AFTER
                // the open-time sweep — exclude it so navigation never
                // returns here (the sweep is once-per-open, no polling).
                offlineExcludedPaths.insert(path)
                recomputeHiddenCounts()
            }
        }
        loadThumbnail(path: path)
    }

    /// stat() off the main actor (house convention: @concurrent so the
    /// blocking call can't inherit the caller's actor).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func statFileExists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// Record yes/no + notes for the current row. Still write-through —
    /// every answer is durably in the CSV moments after the click — but
    /// the CSV reload+rewrite now runs OFF the main actor (bug #2:
    /// synchronous Data(contentsOf:) + atomic rewrite per answer stalled
    /// the UI on slow disks). The UI advances optimistically; writes are
    /// chained so they execute strictly one at a time in click order
    /// (two quick answers can never interleave the read-modify-write),
    /// and each write STILL merges onto a fresh disk load inside
    /// HoldoutReviewQueue.recordAnswer — the QA-gated semantic (commit
    /// 65fbfcf) is untouched, only the executor changed.
    private func holdoutAnswer(_ confirm: String) {
        guard let q = holdout, q.rows.indices.contains(holdoutIndex) else { return }
        let row = q.rows[holdoutIndex]
        let notes = holdoutNotes
        let snapshot = q          // Sendable value copy for the writer
        let wasPending = row.isPending
        let filename = row.filename

        if wasPending { inFlightAnswerIds.insert(row.reviewId) }
        holdoutSaveError = nil

        // Captured HERE (view installed, wrapper resolved) so the escaped
        // task holds the center CLASS REFERENCE — a failure landing after
        // dismissal must not go through dead @EnvironmentObject storage.
        let center = holdoutCenter
        let previous = holdoutWriteChain
        holdoutWriteChain = Task { @MainActor in
            _ = await previous?.value   // strict FIFO across answers
            let result = await Self.performAnswerWrite(
                queue: snapshot, reviewId: row.reviewId,
                confirm: confirm, notes: notes)
            // Commit-after-write, on the main actor: memory only ever
            // reflects what is durably on disk (WAL discipline).
            switch result {
            case .success(let updated):
                holdout = updated
                if wasPending { holdoutAnsweredThisSession += 1 }
                // Pending flags changed — keep the hidden counts honest.
                recomputeHiddenCounts()
            case .failure(let error):
                // Three surfaces, because the sheet may already be gone
                // (QA 2026-07-26 🟠): the in-sheet banner, the log trail,
                // and the badge center the gallery watches. The row is
                // still pending on disk — nothing was written — so the
                // badge count stays honest too.
                holdoutSheetLog.error("holdout answer write FAILED — file: \(filename, privacy: .public), reviewId: \(row.reviewId, privacy: .public), error: \(error.localizedDescription, privacy: .public)")
                holdoutSaveError = "Could not save answer for \(filename): \(error.localizedDescription) \u{2014} the row is still pending; use Back to re-answer."
                center.reportAnswerWriteFailure(
                    "The answer for \(filename) was not saved (\(error.localizedDescription)). Its row is still pending \u{2014} reopen the review to answer it again.")
            }
            if wasPending { inFlightAnswerIds.remove(row.reviewId) }
        }
        holdoutAdvance()
    }

    /// The CSV read-modify-write, off the main actor. Delegates entirely
    /// to HoldoutReviewQueue.recordAnswer, which reloads the CSV fresh
    /// from disk as the merge base — the snapshot's staleness cannot
    /// clobber external edits (QA 2026-07-25 gate finding 1; regression
    /// tests pin it).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func performAnswerWrite(
        queue: HoldoutReviewQueue, reviewId: String,
        confirm: String, notes: String
    ) async -> Result<HoldoutReviewQueue, any Error> {
        var q = queue
        do {
            try q.recordAnswer(reviewId: reviewId, confirm: confirm, notes: notes)
            return .success(q)
        } catch {
            return .failure(error)
        }
    }

    /// Navigation goes through the PURE decision in HoldoutNavigation:
    /// pending, minus in-flight answers, minus offline-excluded, minus
    /// unplayable-excluded. The user is simply never shown a hidden row.
    private func nextActionableIndex(after idx: Int, in q: HoldoutReviewQueue) -> Int? {
        HoldoutNavigation.nextActionableIndex(
            after: idx, rows: q.rows,
            inFlight: inFlightAnswerIds,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths)
    }

    private func firstActionableIndex() -> Int? {
        guard let q = holdout else { return nil }
        return HoldoutNavigation.firstActionableIndex(
            rows: q.rows,
            inFlight: inFlightAnswerIds,
            offlineExcluded: offlineExcludedPaths,
            unplayableExcluded: unplayableExcludedPaths)
    }

    /// Called right after an answer is enqueued (or a Skip) — the current
    /// row is either in flight or deliberately left pending; move to the
    /// next actionable one.
    private func holdoutAdvance() {
        guard let q = holdout else { return }
        if let next = nextActionableIndex(after: holdoutIndex, in: q) {
            holdoutGo(to: next)
        } else {
            phase = .summary
        }
    }

    private func holdoutSkip() {
        guard let q = holdout else { return }
        if let next = nextActionableIndex(after: holdoutIndex, in: q) {
            holdoutGo(to: next)
        } else {
            // Nothing else pending — show the "still pending" done pane
            // (this row remains unanswered by choice).
            phase = .summary
        }
    }

    /// Build the fullPath → media-metadata map for this session's files
    /// in ONE pass over the catalog (never per navigation, never in a
    /// view body). Files not in the catalog simply have no entry — the
    /// renderer then takes the shared default (AVF watchdog + ffmpeg
    /// fallback) path.
    private func buildMediaMeta(for paths: Set<String>) {
        guard !paths.isEmpty else {
            mediaMetaByPath = [:]
            return
        }
        var map: [String: HoldoutMediaMeta] = [:]
        map.reserveCapacity(paths.count)
        for rec in catalogModel.records where paths.contains(rec.fullPath) {
            map[rec.fullPath] = HoldoutMediaMeta(
                container: rec.container,
                videoCodec: rec.videoCodec,
                durationSeconds: rec.durationSeconds,
                likelyUnanalyzable: rec.isLikelyUnanalyzable)
        }
        mediaMetaByPath = map
    }

    /// Queue read-ahead for the next few pending rows (holdout mode
    /// only). Called from the thumbnail-load completion so the disk sees
    /// strictly one reader at a time — the prefetcher additionally
    /// serializes its own batches internally.
    private func scheduleHoldoutPrefetch() {
        guard isHoldout, let q = holdout, phase == .labeling else { return }
        var entries: [HoldoutReviewPrefetcher.Entry] = []
        let n = q.rows.count
        guard n > 0 else { return }
        var i = holdoutIndex
        for _ in 0..<max(n - 1, 0) {
            i = (i + 1) % n
            let r = q.rows[i]
            // Only warm rows the user can actually be shown — hidden
            // (offline/unplayable) rows would waste the HDD's time.
            guard HoldoutNavigation.isActionable(
                r, inFlight: inFlightAnswerIds,
                offlineExcluded: offlineExcludedPaths,
                unplayableExcluded: unplayableExcludedPaths) else { continue }
            entries.append(HoldoutReviewPrefetcher.Entry(
                path: r.fullPath,
                meta: mediaMetaByPath[r.fullPath],
                // Pre-decode a thumbnail only for the NEXT item; bytes
                // warming covers the rest of the window.
                wantsThumbnail: entries.isEmpty))
            if entries.count >= HoldoutReviewPrefetcher.lookahead { break }
        }
        if !entries.isEmpty { prefetcher?.schedule(entries: entries) }
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
        // Media metadata for thumbnail routing (confirm mode reads the
        // catalog anyway, so this leaks nothing new).
        buildMediaMeta(for: Set(candidates.map(\.recordPath)))
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
    //
    // ROUTED (fix/review-sheet-performance, 2026-07-26). The old private
    // generator here was AVF-only with NO routing/deadline/fallback and
    // — worse — awaited asset.load(.duration) first, which on an
    // AVF-hostile or moov-at-end file on the LaCie meant minutes of
    // container grinding before the midpoint request even started. Now:
    // catalog metadata routes the decoder up front, AVF runs under the
    // shared watchdog, ffmpeg is the fallback, failures show a
    // placeholder and land in the model's negative cache.

    private func loadThumbnail(path: String) {
        thumbnailFailed = false
        // Read-ahead may have pre-decoded this exact frame — instant.
        if let cg = prefetcher?.cachedThumbnail(for: path) {
            thumbnail = NSImage(cgImage: cg, size: .zero)
            scheduleHoldoutPrefetch()
            return
        }
        let meta = mediaMetaByPath[path]
        // Captured on the main actor; the store itself is the shared
        // lock-guarded negative cache (same instance the catalog preview
        // pane uses, so a file that failed THERE skips the retry HERE).
        let failureStore = catalogModel.thumbnailFailureStore
        thumbnailLoadTask = Task { @MainActor in
            let img = await Self.loadRoutedThumbnail(path: path, meta: meta,
                                                     failureStore: failureStore)
            guard !Task.isCancelled else { return }
            if let img {
                self.thumbnail = NSImage(cgImage: img, size: .zero)
            } else {
                self.thumbnail = nil
                self.thumbnailFailed = true
            }
            // Start read-ahead only once the current item's disk work is
            // done — one reader at a time keeps the HDD sequential.
            scheduleHoldoutPrefetch()
        }
    }

    /// Negative-cache check + routed render + failure recording, all off
    /// the main actor (isKnownFailure stats the file).
    #if compiler(>=6.2)
    @concurrent
    #endif
    private nonisolated static func loadRoutedThumbnail(
        path: String, meta: HoldoutMediaMeta?,
        failureStore: ThumbnailFailureStore
    ) async -> CGImage? {
        if failureStore.isKnownFailure(atPath: path) { return nil }
        do {
            return try await ReviewThumbnailRenderer.render(path: path, meta: meta)
        } catch {
            // Same exclusions as the catalog path (QA 2026-07-26):
            // cancellation says nothing about the file, and a missing
            // ffmpeg binary is an environment failure — neither may
            // poison the negative cache against a good file.
            if !(error is CancellationError), !Task.isCancelled,
               (error as? PreviewFrameError) != .ffmpegUnavailable {
                failureStore.recordFailure(forPath: path)
            }
            return nil
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
