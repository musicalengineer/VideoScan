// SoundLevelsRemeasure.swift — the rules of "Re-measure sound levels" (GH #516;
// DECISIONS 2026-11-25 "When a measurement improves, the old results are
// re-measured in the background, never patched in the UI").
//
// One sentence: a Check Media card saved by code older than 2441ceb42 may
// carry, on its Sound row, the LAST filter graph's Left/Right levels for a
// sound track whose sample rate, format or layout changes partway — so the
// job measures each such file again with today's sound pass and rewrites
// that one row as today's Check Media would write it; a file it cannot
// measure has its old levels WITHDRAWN (row "not checked", saying why) until
// it can.
//
// Which cards are "pre-fix" — evidence already stored, no schema change:
//   * the card's own `checkedAt` against a CUTOFF kept in a small marker file
//     beside the catalog (`sound-levels-remeasure.json`). The cutoff is the
//     moment this build first looked (the scheduler's attach at launch on the
//     master). Every card saved before it may come from older code; every
//     card after it was saved by this build, which has the fix. Over-select
//     is the safe direction: a card saved between the fix's merge and that
//     first look is simply measured again and confirmed.
//   * the Sound row holds channel-level evidence (CheckMediaRules.channelName's
//     labels: Sound / Left / Right / Channel N). A row with no levels has
//     nothing to correct.
//   * a row this job withdrew carries `withdrawnLead` in its not-run reason,
//     so a later run (or Tidy Catalog's Run) finds it again by its own words.
//
// Resume: cards are walked in record-id order; the marker keeps the last id
// whose result is SAVED (`cursor`), so Stop / quit / a failed save resumes
// there. `completedAt` is the done marker: once set, only withdrawn rows are
// candidates (they wait for their drive), and the scheduler never starts
// the job again — Tidy Catalog's Run still does, by hand.
//
// Memory: a plan item is ~300 B (ids, path, the Sound row, the date) —
// ~30 MB at 100k pre-fix cards, the worst case; the marker is < 1 KB.
//
// (For Rick: the marker ≈ a tiny journal file; the cursor ≈ "last LSN
// applied", so a restart replays nothing that was already made durable.)

import Foundation
import VideoScanCore

// MARK: - The marker (beside the catalog)

/// The job's whole persistent state. Written atomically; never in the catalog.
struct SoundLevelsRemeasureMarker: Codable, Sendable, Equatable {
    /// Cards checked before this moment may hold pre-fix levels. Set once.
    var cutoff: Date
    /// The last pre-fix card (record id, uuidString order) whose result is
    /// saved in the catalog; nil = from the start.
    var cursor: String?
    /// When a run walked every pre-fix card to the end. nil = not yet (the
    /// scheduler will start it).
    var completedAt: Date?
    /// The last finished run's one-line count.
    var lastSummary: String?

    static let fileName = "sound-levels-remeasure.json"

    var isDone: Bool { completedAt != nil }

    static func url(catalogFile: String) -> URL {
        URL(fileURLWithPath: (catalogFile as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// nil when absent. An unreadable marker throws (the caller decides).
    static func load(catalogFile: String) throws -> SoundLevelsRemeasureMarker? {
        let url = url(catalogFile: catalogFile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SoundLevelsRemeasureMarker.self, from: data)
    }

    /// The marker, made now when there is none. An unreadable one is
    /// replaced by a fresh one with the cutoff NOW (over-select: every card
    /// with levels is measured again — never fewer), and `replaced` says so.
    static func loadOrCreate(catalogFile: String, now: Date) -> (marker: SoundLevelsRemeasureMarker, created: Bool, replaced: Bool) {
        do {
            if let m = try load(catalogFile: catalogFile) { return (m, false, false) }
            return (SoundLevelsRemeasureMarker(cutoff: now), true, false)
        } catch {
            return (SoundLevelsRemeasureMarker(cutoff: now), true, true)
        }
    }

    func save(catalogFile: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(catalogFile: catalogFile), options: .atomic)
    }
}

// MARK: - Which cards (pure)

enum SoundLevelsRemeasureRules {

    /// Why a card is in the plan.
    enum Need: Sendable, Equatable {
        /// Saved before the cutoff with channel levels on its Sound row.
        case prefix
        /// Its levels were withdrawn by an earlier run; waiting to be measured.
        case withdrawn
    }

    /// The not-run reason's first words on a withdrawn Sound row — how a later
    /// run finds it again. Persisted on cards: never reword.
    static let withdrawnLead = "the sound levels saved here came from an earlier version of VideoScan and are withdrawn until the sound can be measured again"

    /// A Sound-row evidence item that is a channel level (the labels
    /// `CheckMediaRules.channelName` writes). "Dated", "Sound tracks" and
    /// "Sound partner" are not levels.
    static func isChannelLevel(_ e: MediaEvidence) -> Bool {
        e.label == "Sound" || e.label == "Left" || e.label == "Right" || e.label.hasPrefix("Channel ")
    }

    static func isWithdrawnRow(_ row: MediaCheck) -> Bool {
        guard row.kind == .sound, case .notRun(let reason) = row.verdict else { return false }
        return reason.hasPrefix(withdrawnLead)
    }

    /// Whether this card is a candidate, and why. O(rows). Pure.
    /// `live` = the catalog row has no removal marker: a withdrawn row on a
    /// removed file is not waited for (its file is not coming back).
    /// A card dated after `now` (+ slack) cannot have been saved by this
    /// build: a clock that stepped back or a copied record — its levels are
    /// no better proven than a pre-fix card's, so it is measured too.
    static func need(_ card: MediaReportCard?, recordID: UUID, live: Bool,
                     marker: SoundLevelsRemeasureMarker, now: Date) -> Need? {
        guard let card, card.tier == .full, let row = card.check(.sound) else { return nil }
        if isWithdrawnRow(row) { return live ? .withdrawn : nil }
        let suspectDate = card.checkedAt < marker.cutoff
            || card.checkedAt > now.addingTimeInterval(CatalogRealityPolicy.futureSlack)
        guard !marker.isDone, suspectDate,
              row.evidence.contains(where: isChannelLevel) else { return nil }
        if let cursor = marker.cursor, recordID.uuidString <= cursor { return nil }
        return .prefix
    }

    // MARK: What one file's pass produced

    /// Why a file could not be measured again.
    enum NotMeasured: Sendable, Equatable {
        case offline
        /// The file on disk is not the size the card was checked at.
        case changed
        case failed(String)

        var words: String {
            switch self {
            case .offline: return "the file was not found (its drive is not connected)"
            case .changed: return "the file on disk is no longer the size it was checked at"
            case .failed(let why): return "the sound could not be measured (\(why))"
            }
        }
    }

    enum Remeasured: Sendable {
        case measured(AudioVerifyDiagnosis)
        case notMeasured(NotMeasured)
    }

    /// What became of one card, for the tally and the log.
    enum Result: Sendable, Equatable {
        /// Today's pass measured it: the row now carries today's levels.
        case refreshed
        /// Today's pass found the sound changes partway: no levels kept.
        case reconfigured
        case withdrawn(NotMeasured)
    }

    static func result(of r: Remeasured) -> Result {
        switch r {
        case .measured(let d) where d.shape.audioStreams == 0:
            return .withdrawn(noSoundTrack)
        case .measured(let d):
            return d.balanceAnalysis?.shortDecode?.graphReconfigured == true ? .reconfigured : .refreshed
        case .notMeasured(let why):
            return .withdrawn(why)
        }
    }

    /// Today's probe finds no sound track where the card measured one.
    static let noSoundTrack = NotMeasured.failed("the file no longer shows a sound track")

    // MARK: The rewrite (pure)

    /// The card with its Sound row as today's Check Media writes it for this
    /// pass (or withdrawn), `soundMeasuredSilent` to match, and the headline
    /// rebuilt only when the row's verdict changed. Every other row, the
    /// date checked and the repaired-copy link are kept: only the sound was
    /// measured again.
    static func rewrite(_ card: MediaReportCard, with r: Remeasured,
                        context: SoundPresenceContext) -> MediaReportCard {
        let row: MediaCheck
        let silent: Bool?
        switch r {
        case .measured(let d) where d.shape.audioStreams > 0:
            silent = d.balanceAnalysis?.measuredSilent
            var rows = [CheckMediaRules.soundRow(d)]
            if silent == true {
                rows = CheckMediaRules.applyingSilentTrack(rows, hasPicture: d.shape.videoCodec != nil, context: context)
            }
            row = rows[0]
        case .measured:
            silent = nil
            row = .notRun(.sound, because: "\(withdrawnLead) — \(noSoundTrack.words)")
        case .notMeasured(let why):
            silent = nil
            row = .notRun(.sound, because: "\(withdrawnLead) — \(why.words)")
        }
        var out = card
        out.checks = card.checks.map { $0.kind == .sound ? row : $0 }
        out.soundMeasuredSilent = silent
        if card.check(.sound)?.verdict != row.verdict {
            let timing = card.checks.contains { $0.verdict == .problem && CheckMediaRules.timingKinds.contains($0.kind) }
                ? card.headline : nil
            out.headline = CheckMediaRules.headline(checks: out.checks, tier: card.tier, hasSound: true, timing: timing)
        }
        return out
    }
}
