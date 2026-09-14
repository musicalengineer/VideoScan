// ConfirmPersonSheet.swift
// The UNIFIED Review session (feature/unified-review, Rick-approved
// 2026-07-27 — docs/design/unified-review.md). One "Review <name>" entry
// point walks a single session in two phases:
//
//   PHASE 1 — HOLDOUT (blind): the sealed holdout rows, presented with
//   NO prediction machinery — no candidate scoring (prepareSetup does
//   not run), no signalsView, no scores, no detected-person data. The
//   pane renders ONLY from HoldoutReviewRow, a struct that structurally
//   cannot carry a model opinion (pinned by HoldoutReviewQueueTests'
//   blindness sensor). Yes/no answers write ONLY to the queue CSV
//   (write-through per answer, atomic). Rick's eyes are the
//   uncontaminated ground truth — POI-leakage contract, team-channel
//   2026-07-25-1115. Resume: opening lands on the first unanswered
//   actionable row; answered rows are revisitable via Back WITHIN the
//   phase only.
//
//   TRANSITION — when no actionable holdout row remains (all answered,
//   or the rest skipped/hidden), the session moves to the candidate
//   setup pane: an understated holdout-status banner (same honest
//   states the old done pane had) above the existing round-size picker.
//   Candidate scoring runs HERE, lazily — never earlier (blindness
//   gate, ReviewSessionPolicy.mayLoadCandidates; design note D1).
//   "Continue Reviewing" back into skipped holdout rows PURGES all
//   candidate state first (loaded-but-hidden is not allowed near blind
//   rows).
//
//   PHASE 2 — CANDIDATES: pfConfirmRound output with signals + Score
//   and the 4-tier Definitely/Likely/Cameo/No ratings. Each rating
//   persists to ValidationLabelStore and the positive tiers write back
//   to the catalog (Definitely → confirmedByUserPeople, Likely →
//   suspectedPeople) so search lights up immediately. Back never
//   crosses from here into the holdout rows (design note D2).
//
// WRITE-SINK CUSTODY: both answer handlers route through
// ReviewWriteRouting.sink(item:answer:) — holdout yes/no may only reach
// the sealed CSV, candidate ratings may only reach the validation
// store + catalog, and a mismatched pairing is dropped with a fault
// log, never coerced (UnifiedReviewSessionTests pins both directions).
//
// Sessions opened with no pending holdout queue (e.g. from
// ConfirmationsView's "Confirm more") start directly at the setup pane
// — the pre-unification Confirm flow, unchanged.
//
// Layout reference: CombineSheet / DeleteConfirmedJunkConfirmSheet —
// modal sheet, fixed width, primary content on the left, action
// affordances on the right. Rick 2026-06-16.
//
// FILE SPLIT (2026-09-13): this file keeps the session's shared shape —
// stored state, init, body, header/footer, the candidate-phase views and
// the derived counts. Each phase's machinery lives beside it:
//   • ConfirmPersonSheet+Holdout.swift    — phase 1 (blind): the pane,
//     the filmstrip surface, the status banner, the offline/unrenderable
//     prefilter, navigation, set-aside, and the answer write-chain.
//   • ConfirmPersonSheet+Candidates.swift — phase 2: round lifecycle,
//     rating write-back, thumbnail loading, open/reveal helpers.
// A cross-file `extension` cannot see `private` members, so the members
// those files share with this one are internal here. (Swift extension ≈
// C++ partial class: no new stored state, methods share the same `self`;
// `private` means file-private to ONE of these files.) Same discipline
// as PersonFinderView+People.swift.
//
// HDD PERFORMANCE (fix/review-sheet-performance, 2026-07-26): review
// media lives on the LaCie USB HDD. Three changes keep the pane usable
// there (now serving BOTH phases — one thumbnail + read-ahead path):
//   • Thumbnails go through the ROUTED renderer (ReviewThumbnailRenderer
//     → shared PreviewFrameRouter decision + AVF watchdog + ffmpeg
//     fallback, midpoint framing when the catalog knows the duration).
//     Catalog media metadata (container/codec/duration) is allowed under
//     the blind contract — it is not detection/scoring data.
//   • NO blocking I/O on the main actor: the per-navigation fileExists
//     stat and the per-answer CSV reload+rewrite both run in background
//     tasks; answers are optimistic (advance immediately) with writes
//     STRICTLY serialized in click order via a task chain, and each
//     write still merges onto fresh disk state inside
//     HoldoutReviewQueue.recordAnswer (QA-gated semantic, unchanged).
//   • Read-ahead + spindle keepalive (HoldoutReadAhead.swift) warm the
//     next items and keep the LaCie from parking its heads between
//     answers — in the candidate phase too (same prefetcher, same
//     one-reader-at-a-time discipline).

import AVKit
import AppKit
import SwiftUI
import os

/// File-scope (not a member) so escaped write-chain tasks can log after
/// the view is gone. Same category as the queue itself — one trail for
/// the whole holdout pipeline. Internal rather than file-private because
/// the two split files log into the same trail.
let holdoutSheetLog = Logger(subsystem: "Rick-Breen.VideoScan",
                             category: "poi.holdout-review")

/// Identifiable wrapper so `.sheet(item:)` can drive the sheet from
/// PersonFinderView. The id is per-presentation, not per-profile, so
/// re-opening the sheet for the same profile produces a fresh round.
struct ConfirmSheetTarget: Identifiable {
    let id = UUID()
    let profile: POIProfile
    /// Non-nil → the session begins with the blind holdout phase on
    /// this queue (falls straight through to candidates if nothing is
    /// actionable).
    let holdoutQueue: HoldoutReviewQueue?

    init(profile: POIProfile, holdoutQueue: HoldoutReviewQueue? = nil) {
        self.profile = profile
        self.holdoutQueue = holdoutQueue
    }
}

struct ConfirmPersonSheet: View {

    let profile: POIProfile
    /// Present ⇒ the session has a holdout portion. Used for mode
    /// detection, initial display state, and the CSV location — the
    /// mutable working copy in `holdout` is reloaded FRESH from disk in
    /// startHoldout(), never seeded from this snapshot (stale-snapshot
    /// clobber, QA 2026-07-25).
    var holdoutQueue: HoldoutReviewQueue? = nil
    /// Summary-pane affordance: dismisses this sheet and opens the View
    /// Confirmations dashboard (wired by PersonFinderView+People).
    var onViewConfirmations: (() -> Void)? = nil

    @EnvironmentObject var personFinderModel: PersonFinderModel
    // Read as `catalogModel.records` in ConfirmPersonSheet+Candidates.swift
    // (the held-out identity matcher and the round assembly) and in
    // +HoldoutNavigation.swift (the media-metadata pass). The lint hook is
    // per-file, so those uses are invisible to it — same situation as
    // CatalogHelpers.swift. The subscription is real work, not a leftover.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var catalogModel: VideoScanModel
    /// The badge center — outlives this sheet, so background write
    /// failures reported to it survive dismissal (QA 2026-07-26 🟠).
    // Read in +Holdout.swift (clearAnswerWriteFailure, clearedReviewIds) and
    // +HoldoutNavigation.swift (the write-chain's failure report); per-file
    // lint can't see across the 2026-09-13 split.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var holdoutCenter: HoldoutReviewCenter
    @Environment(\.dismiss) private var dismiss

    @State var candidates: [PersonCandidateScore] = []
    @State var currentIndex: Int = 0
    /// Local round state — paths the user has labeled THIS session.
    /// Used so the in-sheet summary at the end is for this round only,
    /// not the cumulative store. The store has every label across
    /// sessions; this captures the slice the user just produced.
    @State var roundStart: Date = Date()
    @State var roundLabels: [(path: String, rating: ConfirmRating, signals: [String])] = []
    @State var thumbnail: NSImage?
    @State var thumbnailLoadTask: Task<Void, Never>?
    @State private var showSummary: Bool = false
    @State var loadError: String?

    /// Unified session phase. `.holdout` is the blind pane; `.setup` is
    /// the transition/setup pane (holdout status banner + round-size
    /// picker — candidate scoring runs on ENTRY here, never earlier);
    /// `.labeling` is the per-candidate review; `.summary` is the
    /// end-of-session report. Maps 1:1 onto ReviewSessionPhase (the
    /// pure policy layer the sensors test) via `policyPhase`.
    @State var phase: Phase = .setup
    enum Phase { case holdout, setup, labeling, summary }

    var policyPhase: ReviewSessionPhase {
        switch phase {
        case .holdout:  return .holdout
        case .setup:    return .candidateSetup
        case .labeling: return .candidateLabeling
        case .summary:  return .summary
        }
    }

    /// Inverse mapping — lets the sheet land on a phase the POLICY layer
    /// chose (e.g. the fail-closed load-failure landing), keeping the
    /// decision in the testable pure layer.
    func sheetPhase(_ p: ReviewSessionPhase) -> Phase {
        switch p {
        case .holdout:           return .holdout
        case .candidateSetup:    return .setup
        case .candidateLabeling: return .labeling
        case .summary:           return .summary
        }
    }

    /// Stats from round assembly — shown in the setup pane.
    @State var stats: ConfirmRoundStats?

    /// User's pick from the round-size picker. Default 25; bumped to
    /// 100 if the user picks the long-round option.
    @State var roundSize: Int = 25

    /// Held during setup so we don't re-score the catalog on every
    /// roundSize tick. Recomputed when the setup phase is entered; the
    /// picker just slices off the front. PURGED whenever the session
    /// re-enters the holdout phase (blindness gate, design note D1).
    @State var fullCandidatePool: [PersonCandidateScore] = []

    let controlK: Int = 5

    // MARK: Holdout-mode state

    /// Mutable working copy of the queue — every answer writes through
    /// to the CSV via recordAnswer, so this mirrors disk at all times.
    @State var holdout: HoldoutReviewQueue?
    @State var holdoutIndex: Int = 0
    /// Notes draft for the CURRENT row — prefilled from the row when
    /// navigating so Back-and-edit round-trips cleanly.
    @State var holdoutNotes: String = ""
    /// stat() result for the current row's file. Computed in a BACKGROUND
    /// task on navigation (never in the view body, never on the main
    /// actor — a stat against a spun-down USB HDD can stall for seconds).
    /// Optimistically true while the stat is in flight.
    @State var holdoutReachable: Bool = true
    @State var holdoutSaveError: String?
    @State var holdoutAnsweredThisSession: Int = 0

    // MARK: HDD-performance state (fix/review-sheet-performance)

    /// True when thumbnail generation FAILED for the current item — shows
    /// the placeholder instead of an eternal spinner.
    @State var thumbnailFailed: Bool = false
    /// Background stat() for the current row (cancelled on navigation).
    @State var reachabilityTask: Task<Void, Never>?
    /// Tail of the serialized answer-write chain. Each new answer chains
    /// onto the previous task, so CSV read-modify-writes execute strictly
    /// one at a time, in click order — two quick answers can never
    /// interleave. Deliberately NOT cancelled on dismiss: queued answers
    /// must reach the CSV.
    @State var holdoutWriteChain: Task<Void, Never>?
    /// reviewIds of WAS-PENDING answers whose background write hasn't
    /// committed yet. Used to (a) keep navigation from revisiting a row
    /// the user just answered, (b) show optimistic answered/pending
    /// counts. The in-memory queue itself is only mutated after the
    /// durable write succeeds (WAL discipline, QA 2026-07-25 minor 1).
    @State var inFlightAnswerIds: Set<String> = []
    /// Catalog MEDIA metadata (container/codec/duration) by fullPath for
    /// the rows/candidates of this session — routing input for the
    /// thumbnail renderer. Built once per phase entry (one pass over
    /// records), never in the view body. Media facts only — no
    /// detection/scoring data crosses into the blind pane.
    @State var mediaMetaByPath: [String: HoldoutMediaMeta] = [:]
    // MARK: Filmstrip review (feature/holdout-review-explain-clear)
    //
    // AVFoundation cannot decode FFV1/Matroska, so those rows used to be
    // hidden from the review entirely. They are now REVIEWED AS FRAMES:
    // ~16 ffmpeg-ripped stills auto-playing at ~1.5 fps (the same
    // FilmstripPreviewView the catalog preview pane uses), and Rick
    // answers yes/no exactly as he would from a played video.
    //
    // Memory: ONE strip at a time — ≤16 CGImages at ≤480 px wide ≈ 8 MB —
    // released on every navigation (the task is cancelled and the state
    // reset in holdoutGo). The rip itself is bounded by
    // renderPreviewFilmstrip's own concurrency window.

    /// Current row's filmstrip: idle / loading(progress) / ready(frames).
    /// Carries the path so a late-landing task can never paint another
    /// row's frames.
    @State var holdoutFilmstrip: PreviewFilmstripState = .idle
    /// The in-flight rip, cancelled on navigation and on disappear.
    @State var holdoutFilmstripTask: Task<Void, Never>?
    /// Set when the rip produced nothing — the pane says so plainly and
    /// offers the way out instead of spinning forever.
    @State var holdoutFilmstripError: String?

    /// Read-ahead: warms the next files (head+tail bytes) and
    /// pre-generates the next thumbnail, one file at a time. Serves BOTH
    /// phases. Created lazily (not at property init) so its render
    /// closure can consult the model's shared negative cache — a
    /// known-bad NEXT item must not re-attempt a full render on every
    /// navigation (QA 2026-07-26 🟡 2).
    @State var prefetcher: HoldoutReviewPrefetcher?
    /// Keeps the LaCie spindle from head-parking between answers/ratings.
    @State var keepalive = HoldoutSpindleKeepalive()

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
    @State var offlineExcludedPaths: Set<String> = []
    /// Rows NOTHING can draw a frame from, decided ZERO-I/O from catalog
    /// facts (HoldoutNavigation.unrenderablePaths — today: the catalog
    /// names a container but no video stream). Rows with no catalog
    /// record are presented: unknown ≠ unplayable. Computed once per
    /// open; catalog facts don't change mid-session.
    ///
    /// NARROWED 2026-09-13: this used to hold every PreviewFrameRouter
    /// `.ffmpegDirect` row — which hid Donna's FFV1 Matroska master from
    /// the sheet while the badge still counted it pending. Those rows are
    /// now reviewed through the filmstrip (see `holdoutFilmstrip`), so
    /// only the truly unrenderable stay excluded.
    @State var unplayableExcludedPaths: Set<String> = []
    /// reviewIds Rick set aside for this queue (HoldoutClearStore). Not
    /// an answer and NEVER written to the CSV — just out of the pending
    /// counts and out of navigation until an undo brings it back.
    /// Snapshotted from the store at open and after each clear, so the
    /// pure navigation helpers get a plain Set.
    @State var clearedReviewIds: Set<String> = []
    /// Derived hidden-pending counts, stored (not computed per render —
    /// the 100k-row scale test says no O(rows) work in view bodies).
    /// Recomputed via recomputeHiddenCounts() whenever the sets or the
    /// queue's pending flags change.
    @State var offlineHiddenPending: Int = 0
    @State var unplayableHiddenPending: Int = 0
    /// One background reachability sweep per open (and per "Continue
    /// Reviewing" click). No polling.
    @State var offlineSweepTask: Task<Void, Never>?
    /// Backstop insertions made AFTER the current sweep launched. The
    /// sweep completion REPLACES the offline set (so a reconnected
    /// volume's rows come back) — but a wholesale replace would drop a
    /// row the backstop excluded mid-sweep (sweep statted X present →
    /// X vanished → backstop caught it → sweep lands without X), letting
    /// navigation return to it once (QA 2026-07-26 minor 1). The
    /// completion therefore merges: sweep result ∪ THIS set. Reset at
    /// each sweep launch — never unioned across sweeps, or a
    /// reconnected volume could never come back.
    @State var backstopInsertsSinceSweep: Set<String> = []

    // MARK: Offline-copy preview resolution (Rick 2026-07-30)
    //
    // When a pending row's ORIGINAL file is offline (its volume unmounted /
    // file gone) but a BYTE-IDENTICAL copy is live on a mounted volume,
    // the sweep resolves the copy and records it here: original fullPath →
    // live copy path. Preview surfaces (thumbnail, Open in QuickTime,
    // Reveal, reachability) then use the copy via previewPath(for:), while
    // the row's sealed identity (fullPath / reviewId) and the yes/no
    // write-back stay keyed on the ORIGINAL — the copy is preview-only, and
    // the review stays blind because the content is byte-identical (no
    // scores/predictions involved). A resolved original is REMOVED from the
    // offline set so navigation lands on it. Replaced wholesale by each
    // sweep, exactly like offlineExcludedPaths — so a reconnected original
    // stops showing the copy note.
    @State var resolvedPreviewPath: [String: String] = [:]
    /// Originals whose volume is offline BUT which have strong-identity
    /// copy candidates — so their offline/reviewable verdict is DEFERRED to
    /// the background sweep (which checks copy liveness) rather than the
    /// synchronous volume-level precheck or the per-row backstop. While an
    /// original sits here, holdoutGo shows its transient offline pane
    /// WITHOUT backstop-excluding it, so a live copy the sweep is about to
    /// resolve isn't pre-emptively hidden (Rick 2026-07-30). Populated at
    /// each sweep launch (keys of the candidate map), cleared at completion.
    @State var awaitingCopyResolution: Set<String> = []

    /// The session includes a holdout portion (regardless of the phase
    /// currently showing).
    var isHoldout: Bool { holdoutQueue != nil }

    /// Pending/answered counts adjusted for in-flight background writes,
    /// so the header and status banner tick immediately on an answer (the
    /// authoritative queue state follows when the write commits).
    /// Cleared rows are subtracted through HoldoutNavigation's ONE
    /// pending definition, not by a local `- clearedCount` — the badge,
    /// the popover, and this header must not be able to disagree.
    var holdoutEffectivePending: Int {
        guard let q = holdout else { return 0 }
        let pending = HoldoutNavigation.pendingCount(rows: q.rows, cleared: clearedReviewIds)
        return max(0, pending - inFlightAnswerIds.count)
    }
    /// Rows Rick set aside in THIS queue. Stored count would be O(rows)
    /// per render, so it reads the snapshot Set's size — O(1).
    private var clearedThisQueue: Int { clearedReviewIds.count }
    /// Rows this session is still accountable for — the denominator Rick
    /// sees. A set-aside row leaves the denominator rather than being
    /// counted as answered; claiming an answer that isn't in the CSV
    /// would be a lie in both directions.
    var holdoutAccountableTotal: Int {
        guard let q = holdout else { return 0 }
        return max(0, q.rows.count - clearedThisQueue)
    }
    private var holdoutEffectiveAnswered: Int {
        max(0, holdoutAccountableTotal - holdoutEffectivePending)
    }
    /// Pending rows the user can actually be shown right now.
    var holdoutActionablePending: Int {
        max(0, holdoutEffectivePending - offlineHiddenPending - unplayableHiddenPending)
    }
    /// Banner completion state — true only when a queue actually LOADED
    /// and every answer has durably committed. A load FAILURE has zero
    /// effective pending too, and must not paint the banner green
    /// (QA 2026-07-27 nit; also dedupes the expression).
    var holdoutFullyCommitted: Bool {
        holdout != nil && holdoutEffectivePending == 0 && inFlightAnswerIds.isEmpty
    }
    /// " · 3 offline, 2 unplayable hidden" — empty when nothing is hidden.
    var holdoutHiddenSuffix: String {
        var parts: [String] = []
        if offlineHiddenPending > 0 { parts.append("\(offlineHiddenPending) offline") }
        if unplayableHiddenPending > 0 { parts.append("\(unplayableHiddenPending) with no frames to show") }
        if clearedThisQueue > 0 { parts.append("\(clearedThisQueue) set aside") }
        guard !parts.isEmpty else { return "" }
        return " \u{00B7} " + parts.joined(separator: ", ") + " hidden"
    }

    /// Seeds display state at construction so the FIRST body evaluation
    /// already renders the right pane — with onAppear-only
    /// initialization, phase started at .setup and the first holdout
    /// render flashed the wrong pane (QA 2026-07-25 minor 3).
    ///
    /// The snapshot here is display-only; the authoritative working copy
    /// is reloaded from disk in startHoldout() (onAppear fires before
    /// any interaction is possible, so no answer can ever hit the
    /// snapshot). The reload is NOT done in init because SwiftUI may
    /// re-run a view's init on every parent render — file I/O belongs in
    /// onAppear, which runs once per presentation.
    init(profile: POIProfile, holdoutQueue: HoldoutReviewQueue? = nil,
         onViewConfirmations: (() -> Void)? = nil) {
        self.profile = profile
        self.holdoutQueue = holdoutQueue
        self.onViewConfirmations = onViewConfirmations
        guard let snapshot = holdoutQueue else { return }
        // `_holdout` is the property wrapper's backing storage — writing
        // `State(initialValue:)` here ≈ a C++ member-initializer list;
        // after init you go through the wrapped property instead.
        _holdout = State(initialValue: snapshot)
        if let idx = snapshot.firstPendingIndex {
            _phase = State(initialValue: .holdout)
            _holdoutIndex = State(initialValue: idx)
            _holdoutNotes = State(initialValue: snapshot.rows[idx].notes)
        }
        // No pending rows in the snapshot → stay at .setup; the status
        // banner explains and the candidate phase begins immediately.
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
            holdoutFilmstripTask?.cancel()
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
            Image(systemName: phase == .holdout ? "eye.circle" : "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review \(profile.name)")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if phase == .holdout, holdout != nil {
                // Effective counts: an optimistically advanced answer
                // ticks the header immediately even while its serialized
                // background write is still in flight. Hidden rows are
                // called out, never silently swallowed. The candidate
                // COUNT is deliberately absent — knowing it would require
                // running the scorer during the blind phase (design note
                // D3), so the header only promises "candidates next".
                Text("Holdout: \(holdoutEffectiveAnswered) of \(holdoutAccountableTotal) answered\(holdoutHiddenSuffix)\(candidatePhaseFollows ? " \u{00B7} candidates next" : "")")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            } else if phase == .labeling && !candidates.isEmpty {
                Text("Candidate \(currentIndex + 1) of \(candidates.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        switch phase {
        case .holdout:
            return "Blind review — watch each video and answer. No hints or scores are shown; your eyes are the ground truth."
        case .setup, .labeling, .summary:
            return "Rate each candidate — your labels train the model and update the catalog."
        }
    }

    /// Whether a candidate phase is still ahead of the blind phase —
    /// true unless the catalog can't offer candidates at all (it always
    /// can; kept as a seam for future gating).
    private var candidatePhaseFollows: Bool { true }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .holdout:
            // Blind pane — deliberately bypasses the setup/scoring panes
            // and signalsView; see the phase-1 contract in the file
            // header comment.
            holdoutPane
        case .setup:
            VStack(alignment: .leading, spacing: 0) {
                holdoutStatusBanner
                ConfirmSetupPane(
                    personName: profile.name,
                    stats: stats,
                    availOnline: fullCandidatePool.filter { $0.reachable }.count,
                    roundSize: $roundSize
                )
            }
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

    func thumbnailView(path: String, filename: String) -> some View {
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
                // BACK-ACROSS-PHASES rule (design note D2): the policy
                // layer says candidate index 0 has no Back — it must NOT
                // cross into the answered holdout rows.
                Button("Back") { goBack() }
                    .buttonStyle(.borderless)
                    .disabled(!ReviewSessionPolicy.canGoBack(in: .candidateLabeling,
                                                             index: currentIndex))
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
            // Errors show in EVERY phase (QA 2026-07-27 🟡 E): a
            // serialized CSV write can fail after the user has already
            // moved into the candidate phase — the failure must not be
            // silenced by the phase switch. (The badge center still gets
            // the durable copy for post-dismissal failures.)
            if let err = holdoutSaveError ?? loadError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else if phase == .holdout || (isHoldout && phase == .setup) {
                if holdoutAnsweredThisSession > 0 {
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
            switch phase {
            case .holdout:
                // Every answer is already on disk — Close never loses
                // work; reopening resumes at the first unanswered row.
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
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
                if onViewConfirmations != nil {
                    // Completion-screen path to the cumulative dashboard
                    // (design note D7) — "N confirmed this session" is
                    // the summary pane above; this jumps to the totals.
                    Button("View Confirmations\u{2026}") {
                        dismiss()
                        onViewConfirmations?()
                    }
                    .buttonStyle(.bordered)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
