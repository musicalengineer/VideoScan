// ConfirmPersonSheet+Candidates.swift
// PHASE 2 of the unified Review session — the candidate half, extracted
// verbatim from ConfirmPersonSheet.swift (2026-09-13) when that file
// passed 2,000 lines and its view body passed SwiftLint's type-body
// limit. Behaviour is unchanged; only the file boundary moved.
//
// What lives here: the round lifecycle (prepareSetup / startRound /
// advance / goBack), rating application with its ValidationLabelStore +
// catalog write-back, the routed thumbnail loader both phases share, and
// the open-in-QuickTime / reveal-in-Finder helpers.
//
// The blindness gate is unchanged: prepareSetup refuses to run while the
// session is in the holdout phase, and scores that land after a re-entry
// are discarded (design note D1) — both logged through holdoutSheetLog.
//
// A cross-file `extension` cannot see `private` members, so the members
// this code shares with ConfirmPersonSheet.swift are internal there;
// `private` here is file-private to THIS file. (Swift extension ≈ C++
// partial class via free member functions: no new stored state allowed,
// methods share the same `self`.)

import AVKit
import AppKit
import SwiftUI
import os

extension ConfirmPersonSheet {

    // MARK: - Candidate round lifecycle (phase 2)

    func prepareSetup() {
        // BLINDNESS GATE (design note D1): candidate scoring may not run
        // while any blind row can still be presented. This guard bites in
        // production — a future caller wiring prepareSetup into the
        // holdout phase gets a refusal + fault log, not a quiet leak.
        guard ReviewSessionPolicy.mayLoadCandidates(in: policyPhase) else {
            holdoutSheetLog.fault("blindness gate: prepareSetup refused during the holdout phase")
            return
        }
        roundStart = Date()
        // Score in the background — for 16k records this is ~1-2 sec.
        // Keep the @MainActor scope clean by hopping out and back.
        Task { @MainActor in
            // Second gate INSIDE the task (QA 2026-07-27 🟡 C): between
            // scheduling and execution the user can click "Continue
            // Reviewing" — without this, the scorer would still RUN
            // during the blind phase (its result discarded below, but
            // the work itself is forbidden, not just the storage).
            guard ReviewSessionPolicy.mayLoadCandidates(in: policyPhase) else {
                holdoutSheetLog.info("blindness gate: candidate scoring skipped — session re-entered the holdout phase before the scorer started")
                return
            }
            let already = Set(personFinderModel.validationLabels
                .labeledByPath(for: profile.name).keys)
            // FULL-QUEUE blindness exclusion by CONTENT IDENTITY
            // (blocker fixes 2026-07-27 — codex #35 applied strictly,
            // codex #39): every row of the ACTIVE holdout queue — any
            // answer state — is barred from the round, positives and
            // controls, along with every catalog record that is the
            // SAME MEDIA at a different path (partialMD5 / dup group /
            // stem+size). Queue-path union covers the in-memory session
            // copy (optimistic in-flight answers), a fresh disk load
            // (external edits; tiny local CSV, same as startHoldout),
            // and the badge center's discovered queue (candidates-only
            // sessions where the queue is fully answered and
            // pendingQueue returned nil).
            let heldOut = ReviewSessionPolicy.heldOutIdentityMatcher(
                sessionQueue: holdout,
                diskQueue: holdoutQueue.flatMap { try? $0.freshCopyFromDisk() },
                discoveredQueue: holdoutCenter.queue,
                records: catalogModel.records)
            var rng = SystemRandomNumberGenerator()
            let result = pfConfirmRound(
                name: profile.name,
                records: catalogModel.records,
                topN: 100,   // upper bound; the roundSize picker trims
                controlK: controlK,
                alreadyLabeled: already,
                heldOut: heldOut,
                rng: &rng
            )
            // The user may have clicked "Continue Reviewing" while the
            // scorer ran — candidate state is forbidden near blind rows,
            // so a late-landing result is discarded, not stored.
            guard ReviewSessionPolicy.mayLoadCandidates(in: policyPhase) else {
                holdoutSheetLog.info("blindness gate: discarded candidate scores that landed after re-entering the holdout phase")
                return
            }
            self.fullCandidatePool = result.candidates
            self.stats = result.stats
            // Default to a sensible round size if 25 isn't reachable.
            let availOnline = result.candidates.filter { $0.reachable }.count
            if availOnline < self.roundSize {
                self.roundSize = max(min(availOnline, 25), 1)
            }
        }
    }

    func startRound() {
        // Slice the pre-scored pool to the user's chosen round size.
        let onlineOnly = fullCandidatePool.filter { $0.reachable }
        candidates = Array(onlineOnly.prefix(roundSize))
        currentIndex = 0
        phase = .labeling
        // Media metadata for thumbnail routing (confirm mode reads the
        // catalog anyway, so this leaks nothing new). Merged so the
        // holdout rows' entries survive for a later "Continue Reviewing".
        buildMediaMeta(for: Set(candidates.map(\.recordPath)), merge: true)
        ensurePrefetcher()
        keepalive.start()
        if !candidates.isEmpty {
            keepalive.setCurrentPath(candidates[0].recordPath)
            loadThumbnail(path: candidates[0].recordPath)
        }
    }

    func apply(rating: ConfirmRating, to candidate: PersonCandidateScore) {
        // WRITE-SINK CUSTODY: a candidate rating may only route to the
        // validation store + catalog — never the sealed CSV. Same drop-
        // loudly contract as the holdout side.
        guard ReviewWriteRouting.sink(for: .candidate(candidate),
                                      answer: .rating(rating)) == .validationStoreAndCatalog else {
            holdoutSheetLog.fault("custody: candidate rating refused a non-validation sink — dropped")
            // Visible to Rick, not just Console (QA 2026-07-27 🟡 D).
            loadError = "Internal safety check refused to save this rating (nothing was written). Please tell Claude — this is a wiring bug."
            return
        }
        // Persist label. The sink refuses a short name two profiles share
        // (a namesake may have appeared while this sheet was open).
        do {
            try personFinderModel.validationLabels.record(
                recordPath: candidate.recordPath,
                person: profile.name,
                rating: rating,
                signals: candidate.signals,
                score: candidate.score
            )
        } catch {
            loadError = "Not saved — \(error.localizedDescription)"
            return
        }
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
            // Cameo / legacy Unsure/Unlikely — no catalog mutation.
            // Label is still in the sidecar for training-data purposes.
            break
        }
    }

    private func removePerson(_ name: String, from arr: inout [String]) {
        arr.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func removeConfirmed(_ name: String, from arr: inout [ConfirmedTag]) {
        arr.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func advance() {
        thumbnailLoadTask?.cancel()
        thumbnail = nil
        // Same LINEAR walk the prefetcher and the pure core use — a
        // skipped candidate does not come back around (pre-unification
        // semantic, pinned by nav_linearPolicyNeverWraps).
        if let next = HoldoutNavigation.nextIndex(
            after: currentIndex, count: candidates.count, wraps: false,
            isActionable: { _ in true }) {
            currentIndex = next
            keepalive.setCurrentPath(candidates[next].recordPath)
            loadThumbnail(path: candidates[next].recordPath)
        } else {
            // Out of candidates — show the summary automatically
            phase = .summary
        }
    }

    func goBack() {
        // Pure navigation — go back to the previous candidate whether
        // it was labeled or skipped (Rick 2026-06-16: an accidental
        // Skip needs to be recoverable, not just an accidental rating).
        // If the previous candidate WAS labeled this round, pop its
        // entry from roundLabels so the user can re-rate without
        // double-counting in the summary. The label sidecar's most-
        // recent-wins semantics handles the duplicate-label case
        // cleanly on the next .apply call.
        //
        // NEVER crosses into the holdout rows — canGoBack is false at
        // index 0 regardless of holdout history (design note D2).
        guard ReviewSessionPolicy.canGoBack(in: .candidateLabeling,
                                            index: currentIndex) else { return }
        let prevPath = candidates[currentIndex - 1].recordPath
        if let last = roundLabels.last, last.path == prevPath {
            roundLabels.removeLast()
        }
        thumbnailLoadTask?.cancel()
        currentIndex -= 1
        keepalive.setCurrentPath(prevPath)
        loadThumbnail(path: prevPath)
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

    func loadThumbnail(path: String) {
        thumbnailFailed = false
        // Read-ahead may have pre-decoded this exact frame — instant.
        if let cg = prefetcher?.cachedThumbnail(for: path) {
            thumbnail = NSImage(cgImage: cg, size: .zero)
            schedulePrefetch()
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
            schedulePrefetch()
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

    func openInQuickTime(_ path: String) {
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: qtURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
