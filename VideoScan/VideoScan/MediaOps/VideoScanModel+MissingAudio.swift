// VideoScanModel+MissingAudio.swift
// Model glue for "Find Missing Audio" (GH #111, Rick 2026-09-11): snapshot
// the catalog on the main actor, run MissingAudioFinder off it, and turn
// the chosen candidate into a recorded pair through the NORMAL Correlate.
//
// Pair is atomic from the catalog's point of view: a hidden record is
// restored (the same field flips "Put Back in Catalog" performs) or an
// on-disk file is probed and appended, then `correlate(selectedIDs:)`
// runs over exactly the two ids. If Correlate declines, everything is
// put back the way it was — no half-adopted audio left for the next
// rescan's scope gate to drop. Nothing is muxed or moved; Combine is a
// separate, unchanged step.

import Foundation
import os

extension VideoScanModel {

    /// What Pair did. `.paired` is the only success.
    enum MissingAudioPairOutcome: Equatable {
        case paired(audioID: UUID, confidence: String)
        /// Correlate's own scorer/gate declined the pair — catalog restored.
        case correlateDeclined
        /// The file probed as something other than audio-only.
        case notAudioOnly(streamType: String)
        case unreadable(detail: String)
        case videoUnavailable
        case readOnly

        var message: String {
            switch self {
            case .paired(_, let c):
                return "Paired (\(c) confidence). The pair is recorded exactly like a Correlate result — use Combine when you want a single file."
            case .correlateDeclined:
                return "Correlate declined this pair (its duration gate or score floor), so nothing was changed."
            case .notAudioOnly(let t):
                return "That file is \(t), not the audio half of a pair. Nothing was changed."
            case .unreadable(let d):
                return "ffprobe could not read that file (\(d)). Nothing was changed."
            case .videoUnavailable:
                return "The video is no longer an unpaired, active video-only record."
            case .readOnly:
                return "Pair refused — read-only viewer mode."
            }
        }
    }

    // MARK: Snapshots (main actor, cheap value capture)

    func missingAudioConfig() -> MissingAudioFinder.Config {
        MissingAudioFinder.Config.standard(modelAudioExtensions: audioExtensions,
                                           skipDirNames: skipDirsSnapshot())
    }

    /// Tier-a input: every hidden (set-aside or purged) audio-only record
    /// that is not already someone's pair.
    func missingAudioHiddenRecords() -> [MissingAudioFinder.HiddenAudio] {
        var out: [MissingAudioFinder.HiddenAudio] = []
        for r in records where r.streamType == .audioOnly && (r.isSetAside || r.isPurged) {
            guard r.pairedWith == nil else { continue }
            let state: MissingAudioFinder.CatalogState = r.isPurged
                ? .purged
                : .setAside(reason: r.setAsideReason ?? "")
            out.append(.init(snap: CorrelationScorer.snap(r), fullPath: r.fullPath, state: state))
        }
        return out
    }

    /// Tier-c roots: reachable scan targets only (both the target's own
    /// flag and the live mount table must agree — an unmounted volume
    /// is never walked).
    func missingAudioSearchRoots() -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for t in scanTargets where t.isReachable && !t.searchPath.isEmpty {
            guard VolumeReachability.isReachable(path: t.searchPath),
                  seen.insert(t.searchPath).inserted else { continue }
            roots.append(t.searchPath)
        }
        return roots
    }

    // MARK: Search

    /// Run the three-tier hunt for one video-only record. Returns nil
    /// when the record is not an unpaired, active video-only file.
    /// `fileSystem` / `probe` are injectable for tests; production uses
    /// the FileManager lister and ffprobe through ProcessRunner.
    func findMissingAudio(
        for videoID: UUID,
        roots: [String]? = nil,
        fileSystem: MissingAudioFileSystem = FileManagerMissingAudioFileSystem(),
        probe: MissingAudioDurationProbe = FFprobeMissingAudioDurationProbe(),
        progress: (@Sendable (MissingAudioFinder.Progress) -> Void)? = nil
    ) async -> MissingAudioFinder.Result? {
        guard let rec = record(forID: videoID), rec.streamType == .videoOnly,
              !rec.isPurged, !rec.isSetAside else { return nil }
        let video = MissingAudioFinder.VideoTarget(snap: CorrelationScorer.snap(rec),
                                                   fullPath: rec.fullPath)
        let hidden = missingAudioHiddenRecords()
        let searchRoots = roots ?? missingAudioSearchRoots()
        let config = missingAudioConfig()
        let started = Date()
        appLog.write("Find Missing Audio: start for \(rec.filename) — \(hidden.count) hidden audio record(s), \(searchRoots.count) reachable root(s), probe cap \(config.maxFilesProbed)")

        let result = await MissingAudioFinder.search(
            video: video, hidden: hidden, roots: searchRoots, config: config,
            fileSystem: fileSystem, probe: probe, progress: progress)

        // One line per tier (project convention), then a summary.
        for r in result.reports {
            appLog.write("Find Missing Audio [\(r.tier.logName)]: examined=\(r.examined) probed=\(r.probed) matched=\(r.matched) durationRefused=\(r.durationRefused)\(r.truncated ? " TRUNCATED(cap)" : "")")
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        appLog.write("Find Missing Audio: \(result.candidates.count) candidate(s) for \(rec.filename) in \(elapsed)s (\(result.filesProbed) ffprobe run(s))\(result.cancelled ? " — cancelled" : "")")
        missingAudioLog.info("search video=\(rec.filename, privacy: .public) candidates=\(result.candidates.count) probed=\(result.filesProbed) cancelled=\(result.cancelled)")
        return result
    }

    // MARK: Pair

    /// Put the chosen candidate in the catalog (restore or ingest) and
    /// record the pair through `correlate(selectedIDs:)`. Atomic: on a
    /// Correlate refusal the restore/ingest is undone.
    func pairMissingAudio(videoID: UUID,
                          candidate: MissingAudioFinder.Candidate) async -> MissingAudioPairOutcome {
        guard !isReadOnly else { return .readOnly }
        guard let video = record(forID: videoID), video.streamType == .videoOnly,
              !video.isPurged, !video.isSetAside, video.pairedWith == nil else {
            return .videoUnavailable
        }

        // Resolve the audio record: existing (by id, then by path) or a
        // fresh single-file probe. `undo` puts the catalog back exactly.
        let audio: VideoRecord
        let undo: () -> Void
        if let existing = candidate.catalogRecordID.flatMap({ record(forID: $0) })
                        ?? record(forPath: candidate.path) {
            let priorReason = existing.setAsideReason
            let priorPurged = existing.purgedAt
            if existing.isPurged { _ = restoreRecord(id: existing.id) }
            if existing.isSetAside { _ = restoreSetAsideRecords(ids: [existing.id]) }
            audio = existing
            undo = {
                existing.setAsideReason = priorReason
                existing.purgedAt = priorPurged
            }
        } else {
            let probed = await probeFile(url: URL(fileURLWithPath: candidate.path))
            guard probed.streamType != .ffprobeFailed else {
                return .unreadable(detail: probed.isPlayable.isEmpty ? "ffprobe failed" : probed.isPlayable)
            }
            guard probed.streamType == .audioOnly else {
                return .notAudioOnly(streamType: probed.streamType.rawValue)
            }
            // The catalog may have moved during the probe.
            guard let v = record(forID: videoID), v.pairedWith == nil,
                  !v.isPurged, !v.isSetAside else { return .videoUnavailable }
            if let raced = record(forPath: candidate.path) {
                audio = raced
                undo = {}
            } else {
                records.append(probed)
                audio = probed
                undo = { [weak self] in
                    self?.records.removeAll { $0.id == probed.id }
                }
            }
        }

        await correlate(selectedIDs: [videoID, audio.id])

        if let v = record(forID: videoID), let partner = v.pairedWith, partner.id == audio.id {
            let confidence = v.pairConfidence?.rawValue ?? "unknown"
            saveCatalogDebounced()
            noteCatalogRecordsMutated()
            log("Find Missing Audio: paired \(v.filename)  \u{2194}  \(audio.filename) [\(confidence)] — recorded like a Correlate result; nothing muxed or moved.")
            appLog.write("Find Missing Audio: PAIRED \(v.fullPath) <-> \(audio.fullPath) [\(confidence)] via \(candidate.tier.logName) (\(candidate.reasons.joined(separator: "+")))")
            missingAudioLog.info("paired video=\(v.filename, privacy: .public) audio=\(audio.filename, privacy: .public) confidence=\(confidence, privacy: .public)")
            return .paired(audioID: audio.id, confidence: confidence)
        }

        undo()
        saveCatalogDebounced()
        noteCatalogRecordsMutated()
        appLog.write("Find Missing Audio: Correlate declined \(video.fullPath) <-> \(candidate.path) — catalog restored")
        missingAudioLog.info("correlate declined video=\(video.filename, privacy: .public) audio=\(candidate.filename, privacy: .public)")
        return .correlateDeclined
    }
}
