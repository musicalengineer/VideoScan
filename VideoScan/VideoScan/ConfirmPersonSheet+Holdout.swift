// ConfirmPersonSheet+Holdout.swift
// PHASE 1 of the unified Review session — the BLIND holdout half's PANES
// and lifecycle, extracted verbatim from ConfirmPersonSheet.swift
// (2026-09-13) when that file passed 2,000 lines and its view body passed
// SwiftLint's type-body limit. Behaviour is unchanged; only the file
// boundary moved.
//
// What lives here: the holdout pane (including the filmstrip surface for
// rows AVFoundation cannot decode), the copy-preview note, the answer
// view, the transition-pane status banner, and the phase lifecycle
// (startHoldout / transitionToCandidates / resumeHoldout).
//
// The machinery those panes drive — the offline + unrenderable prefilter
// and its background sweep, navigation, set-aside, and the serialized
// answer write-chain — is in ConfirmPersonSheet+HoldoutNavigation.swift.
//
// The blindness contract is unchanged and still stated in full in the
// main file's header: this pane renders ONLY from HoldoutReviewRow,
// answers reach ONLY the sealed CSV, and candidate scoring may not run
// while the session is in this phase.
//
// A cross-file `extension` cannot see `private` members, so the members
// this code shares with the other three files are internal there;
// `private` here is file-private to THIS file. (Swift extension ≈ C++
// partial class via free member functions: no new stored state allowed,
// methods share the same `self`.)

import AppKit
import SwiftUI
import os

extension ConfirmPersonSheet {

    // MARK: - Holdout pane (phase 1)

    /// The blind review pane. Renders ONLY from HoldoutReviewRow —
    /// thumbnail/open/reveal, a yes/no question, and notes. Nothing else.
    @ViewBuilder
    var holdoutPane: some View {
        if let q = holdout, q.rows.indices.contains(holdoutIndex) {
            let row = q.rows[holdoutIndex]
            HStack(alignment: .top, spacing: 16) {
                if holdoutReachable {
                    VStack(spacing: 6) {
                        // Preview surfaces (thumbnail/open/reveal) use the
                        // resolved live copy when the original is offline;
                        // the answer write-back still keys on row.fullPath
                        // (Rick 2026-07-30).
                        if HoldoutNavigation.playback(
                            meta: mediaMetaByPath[row.fullPath]) == .filmstrip {
                            holdoutFilmstripView(row: row)
                        } else {
                            thumbnailView(path: previewPath(for: row.fullPath),
                                          filename: row.filename)
                        }
                        holdoutCopyNote(for: row.fullPath)
                    }
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
            // Defensive only — navigation always lands on a valid index
            // or transitions to the setup pane. Render the status banner
            // so a broken queue still explains itself.
            VStack { holdoutStatusBanner; Spacer() }
        }
    }

    /// Subtle two-line transparency note shown when the previewed media is
    /// a live byte-identical copy standing in for an offline original
    /// (Rick 2026-07-30). Neutral by design — byte-identical content, no
    /// scores/predictions — so it does not break the blind contract.
    @ViewBuilder
    private func holdoutCopyNote(for original: String) -> some View {
        if let copy = resolvedPreviewPath[original] {
            VStack(alignment: .leading, spacing: 1) {
                Label("Previewing verified copy on \(VolumeReachability.volumeName(forPath: copy))",
                      systemImage: "doc.on.doc")
                    .font(.caption2)
                Text("original offline on \(VolumeReachability.volumeName(forPath: original))")
                    .font(.caption2)
                    .padding(.leading, 18)
            }
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The frames-instead-of-playback surface for a row AVFoundation
    /// can't decode (Rick's live case: FFV1 + pcm_s32le in Matroska).
    /// Says plainly why, then behaves like any other row — the yes/no
    /// buttons beside it are untouched.
    @ViewBuilder
    private func holdoutFilmstripView(row: HoldoutReviewRow) -> some View {
        let meta = mediaMetaByPath[row.fullPath]
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                switch holdoutFilmstrip {
                case .ready(_, let frames):
                    FilmstripPreviewView(frames: frames,
                                         videoCodec: meta?.videoCodec ?? "",
                                         container: meta?.container ?? "",
                                         explanation: filmstripExplanation(meta: meta))
                        .accessibilityIdentifier("pf.holdout.filmstrip")
                case .loading(_, let done, let total):
                    VStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(done > 0
                             ? "Reading frame \(done) of \(total)\u{2026}"
                             : "Reading frames\u{2026}")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                case .idle:
                    if let err = holdoutFilmstripError {
                        VStack(spacing: 6) {
                            Image(systemName: "film")
                                .font(.system(size: 28))
                            Text(err)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("pf.holdout.filmstrip.failed")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            if case .ready = holdoutFilmstrip {} else {
                Text(filmstripExplanation(meta: meta))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(row.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                // No "Open in QuickTime" here on purpose — QuickTime shows
                // the crossed-out play glyph for these files, and a dead
                // button is worse than no button.
                Button {
                    revealInFinder(previewPath(for: row.fullPath))
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show this file in Finder")
                Spacer()
            }
        }
    }

    /// "QuickTime can't play FFV1 — showing frames instead." Names the
    /// actual codec when the catalog knows it.
    private func filmstripExplanation(meta: HoldoutMediaMeta?) -> String {
        let codec = (meta?.videoCodec ?? "").trimmingCharacters(in: .whitespaces)
        let label = codec.isEmpty ? "this format" : codec.uppercased()
        return "QuickTime can't play \(label) \u{2014} showing frames instead."
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
                    .disabled(!ReviewSessionPolicy.canGoBack(in: .holdout, index: holdoutIndex))
                    .help("Revisit the previous video (answered ones can be re-answered)")
                Spacer()
                // The way out for a row Rick looks at and decides not to
                // judge. App-side and reversible — the CSV still reads
                // pending; the Review badge's popover has the undo.
                Button("Set Aside") { holdoutClearCurrentRow() }
                    .buttonStyle(.borderless)
                    .disabled(!row.isPending)
                    .help("Take this one off the Review badge without answering. Nothing is written to the review file, and you can bring it back from the badge.")
                    .accessibilityIdentifier("pf.holdout.setAside")
                Button("Skip") { holdoutSkip() }
                    .buttonStyle(.borderless)
                    .help("Leave this one unanswered for now and move on")
            }
            .font(.caption)
        }
    }

    // MARK: - Holdout status banner (transition pane, design note D6)

    /// Understated banner shown above the candidate setup pane when the
    /// session had a holdout portion. Reuses the honest states the old
    /// done pane had — a just-answered last row shows "done" immediately,
    /// but the COMPLETION claim ("saved to the review file") is only made
    /// once every in-flight write has committed (QA 2026-07-26 🟠 c);
    /// hidden (offline/unplayable) rows get their own honest branch.
    @ViewBuilder
    var holdoutStatusBanner: some View {
        if isHoldout {
            let fullyCommitted = holdoutFullyCommitted
            let allRemainingHidden = holdoutEffectivePending > 0 && holdoutActionablePending == 0
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: fullyCommitted ? "checkmark.seal.fill"
                      : (allRemainingHidden ? "externaldrive.badge.exclamationmark" : "hourglass"))
                    .font(.system(size: 18))
                    .foregroundColor(fullyCommitted ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    if holdout != nil {
                        if fullyCommitted {
                            Text("Holdout review done \u{2014} all \(holdoutAccountableTotal) answered and saved to the review file.")
                                .font(.system(size: 12).weight(.medium))
                            Text("Continuing with new candidates below. Your blind answers never touch the model from this app.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else if holdoutEffectivePending == 0 {
                            Text("Holdout review done \u{2014} finishing saving \(inFlightAnswerIds.count) answer\(inFlightAnswerIds.count == 1 ? "" : "s")\u{2026}")
                                .font(.system(size: 12).weight(.medium))
                            Text("Continuing with new candidates below; this note updates when the save completes.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else if allRemainingHidden {
                            Text("All reviewable holdout videos answered\(holdoutHiddenSuffix).")
                                .font(.system(size: 12).weight(.medium))
                            Text(allHiddenExplanation)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(holdoutActionablePending) holdout video\(holdoutActionablePending == 1 ? "" : "s") still pending\(holdoutHiddenSuffix).")
                                .font(.system(size: 12).weight(.medium))
                            Text("The Review badge stays up until every row has an answer \u{2014} finish now, or continue with new candidates below and come back anytime.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button("Continue Reviewing") { resumeHoldout() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    } else {
                        // FAIL-CLOSED landing (load failure): candidates
                        // are NOT offered — retry or close only.
                        Text("No review queue could be loaded.")
                            .font(.system(size: 12).weight(.medium))
                        if let err = holdoutSaveError {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Button("Try Again") { startHoldout() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .padding(.top, 2)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill((holdoutFullyCommitted ? Color.green : Color.orange).opacity(0.10))
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }

    /// Banner copy for the all-hidden state, naming BOTH reasons with
    /// their remedies — offline is recoverable by reconnecting; a row with
    /// no frames at all can be set aside from the badge's popover.
    private var allHiddenExplanation: String {
        var parts: [String] = []
        if offlineHiddenPending > 0 {
            parts.append("\(offlineHiddenPending) pending row\(offlineHiddenPending == 1 ? " is" : "s are") on offline volumes \u{2014} reconnect those drives and reopen the review to finish them.")
        }
        if unplayableHiddenPending > 0 {
            parts.append("\(unplayableHiddenPending) pending row\(unplayableHiddenPending == 1 ? " has" : "s have") no video frames to show \u{2014} you can set \(unplayableHiddenPending == 1 ? "it" : "them") aside from the Review badge.")
        }
        parts.append("The Review badge stays up until every row has an answer or is set aside.")
        return parts.joined(separator: " ")
    }

    // MARK: - Holdout lifecycle

    /// Entry point when the session has a holdout portion. No scoring,
    /// no ValidationLabelStore — reload the queue fresh from disk and
    /// position onto the first unanswered actionable row. If nothing is
    /// actionable, fall straight through to the candidate transition.
    ///
    /// The working copy still comes from disk, not from the
    /// discovery-time snapshot in `holdoutQueue`, so the sheet shows the
    /// real pending rows/count (a snapshot can predate hand edits or a
    /// regenerated queue). Data safety no longer hinges on this open-time
    /// reload: recordAnswer merges each answer onto a fresh disk load
    /// (QA 2026-07-25 gate finding 1), so even a stale working copy
    /// cannot clobber external edits. On load failure we surface the
    /// error and move to the transition pane — never fall back to the
    /// snapshot. QA 2026-07-25 blocker; regression tests:
    /// regression_staleSnapshotOpenPreservesExternalAnswer,
    /// regression_externalEditDuringOpenSessionSurvivesRecordAnswer.
    func startHoldout() {
        guard let snapshot = holdoutQueue else {
            transitionToCandidates()
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
            ensurePrefetcher()
            // Prefilter (Rick 2026-07-26: never present offline or
            // unplayable videos). Unplayable: pure catalog facts, zero
            // I/O. Offline: a synchronous VOLUME-level precheck here —
            // VolumeReachability.isReachable is documented to never touch
            // the disk on the caller's thread (SWR cache + kernel mount
            // table) — so the very first landing already skips rows on
            // disconnected drives; the honest per-file sweep then runs in
            // the background and refines the set.
            // Rick's set-aside rows, narrowed to reviewIds THIS CSV still
            // has (a regenerated queue or a hand-edited sidecar must not
            // shrink the accountable total).
            clearedReviewIds = HoldoutNavigation.clearedReviewIds(
                rows: fresh.rows,
                storeCleared: holdoutCenter.clearedReviewIds(for: fresh))
            // Only rows nothing can render are excluded now — an
            // AVF-hostile row is reviewed as a filmstrip instead.
            unplayableExcludedPaths = HoldoutNavigation.unrenderablePaths(
                rows: fresh.rows, meta: mediaMetaByPath)
            // Offline-copy preview resolution (Rick 2026-07-30): DEFER the
            // synchronous volume-level offline verdict for any pending row
            // that has strong-identity copy candidates. Otherwise Rick's
            // 5 rows — all on the unmounted RicksBackups — would be marked
            // offline here, firstActionableIndex() would be nil, and the
            // session would transition to candidates BEFORE the background
            // sweep could resolve their live LaCieWorkspace copies. Deferred
            // rows stay actionable (shown optimistically); the sweep then
            // either resolves a live copy (→ preview) or confirms offline.
            // Set-aside rows go through the ONE pending definition here
            // too, so the sweep and the copy resolver never spend a stat
            // on a row Rick already excused.
            let clearedNow = clearedReviewIds
            let pending = fresh.rows.filter {
                HoldoutNavigation.isPending($0, cleared: clearedNow)
            }
            // Build the strong-identity copy-candidate map ONCE (one O(records)
            // OnlineCopyFinder index pass) and reuse it for both the deferral
            // set here and the sweep launched below — no double build.
            let candidateMap = buildCopyCandidateMap(forPending: pending.map(\.fullPath))
            offlineExcludedPaths = Self.volumeLevelOfflinePaths(rows: pending)
                .subtracting(candidateMap.keys)
            recomputeHiddenCounts()
            startOfflineSweep(precomputedCandidates: candidateMap)
            if let idx = firstActionableIndex() {
                phase = .holdout
                // Spindle keepalive for the whole session — see
                // HoldoutSpindleKeepalive for the head-park rationale.
                keepalive.start()
                holdoutGo(to: idx)
            } else {
                transitionToCandidates()
            }
        } catch {
            // FAIL CLOSED (blocker fix 2026-07-27): a load failure must
            // NEVER hand the session to the candidate phase — with the
            // queue unreadable we cannot know which paths are sealed for
            // blind review, so candidate scoring cannot be allowed to
            // run. Land on the error pane; Try Again / Close only.
            holdout = nil
            holdoutSaveError = "Could not reload review queue: \(error.localizedDescription)"
            phase = sheetPhase(ReviewSessionPolicy.phaseAfterQueueLoadFailure)
        }
    }

    // MARK: - Phase transitions (unified session)

    /// The holdout → candidates handoff: enters the setup pane and runs
    /// the candidate scorer THERE, lazily — the blindness gate's one
    /// legal loading point (design note D1). Also the entry path for
    /// sessions with no holdout portion at all (startHoldout falls
    /// through here on empty/failed queues).
    func transitionToCandidates() {
        phase = .setup
        prepareSetup()
    }

    /// "Continue Reviewing" — back into the skipped holdout rows. PURGES
    /// candidate state first (ReviewSessionPolicy.mustPurgeCandidates):
    /// loaded-but-hidden prediction data is not allowed to coexist with
    /// presentable blind rows; the ~1–2 s re-score on the next
    /// transition is the price of the hard guarantee.
    private func resumeHoldout() {
        // Re-read the set-aside rows: the store is the authority and may
        // have changed (an undo from the badge popover) while the
        // transition pane sat open.
        if let q = holdout {
            clearedReviewIds = HoldoutNavigation.clearedReviewIds(
                rows: q.rows, storeCleared: holdoutCenter.clearedReviewIds(for: q))
            recomputeHiddenCounts()
        }
        // Fresh sweep per Continue click (a drive may have been
        // reconnected while the pane sat open).
        startOfflineSweep()
        guard let idx = firstActionableIndex() else { return }
        if ReviewSessionPolicy.mustPurgeCandidates(entering: .holdout) {
            fullCandidatePool = []
            stats = nil
            candidates = []
            currentIndex = 0
            // REBUILD the media-metadata map from the queue rows alone
            // (QA 2026-07-27 🟠 A): the candidate-phase entries' KEYS —
            // which files the scorer surfaced — are themselves
            // model-derived state, and retaining them into the blind
            // phase would violate the never-LOADED bar. merge:false
            // resets the map before refilling from holdout rows only.
            if let q = holdout {
                buildMediaMeta(for: Set(q.rows.map(\.fullPath)))
            }
        }
        phase = .holdout
        keepalive.start()
        holdoutGo(to: idx)
    }
}
