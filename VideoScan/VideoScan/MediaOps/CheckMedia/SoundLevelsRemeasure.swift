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
// Which cards — evidence stored IN the card (Codex cycle #373 P0-2/P0-3/P1-4:
// a cutoff date and a marker beside the catalog could hide stale cards or
// repeat finished work; no clock and no outside file decide anything now):
//   * `MediaReportCard.soundLevels` (additive, optional, inside the card's
//     JSON — `media_checks.card` is a JSON TEXT column, so no DDL) names the
//     pass that wrote the Sound row. Today's Check Media stamps every card it
//     makes (`CheckMediaRules.card`); this job stamps every card it rewrites:
//     `.measured`, or `.withdrawn` when it could not measure the file.
//   * candidate = a full card whose Sound row holds channel-level evidence
//     and carries no current `.measured` stamp, or a `.withdrawn` card.
//     A restored older catalog is simply found again; "nothing to do" is a
//     candidate count of 0.
//   * waiting for a drive = withdrawn because the file's DRIVE was not
//     connected (the row's pinned words); the scheduler re-runs the job when
//     that drive is connected. Withdrawn for any other reason (moved,
//     changed size, unmeasurable) stays a candidate for a run by hand only,
//     so nothing repeats by itself forever.
//
// The only file beside the catalog, `sound-levels-remeasure.json`, holds the
// scheduler's last unattended start (one per night, a Stop holds until the
// next — Codex P2-6). Losing it can at worst start one extra run that night;
// it never hides or repeats a card.
//
// Memory: a plan item is ~400 B (ids of the copies, paths, the Sound row) —
// ~40 MB at 100k candidate cards, the worst case.
//
// (For Rick: the stamp ≈ a schema-version number inside each record's blob,
// so "which rows still need the migration" is a property of the data.)

import CryptoKit
import Foundation
import VideoScanCore

// MARK: - The scheduler's one remembered fact (beside the catalog)

/// When the scheduler last started the job by itself. An optimisation and a
/// courtesy (Stop holds until the next night), never a correctness input.
struct SoundLevelsRemeasureSchedule: Codable, Sendable, Equatable {
    var lastUnattendedStart: Date?
    /// Contents the job left alone because their copies' cards differ:
    /// key → fingerprint of those cards (P1-3). Not due again by itself
    /// until a card changes. Losing it costs at most one extra run.
    var leftAlone: [String: String] = [:]

    init(lastUnattendedStart: Date? = nil, leftAlone: [String: String] = [:]) {
        self.lastUnattendedStart = lastUnattendedStart
        self.leftAlone = leftAlone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastUnattendedStart = try c.decodeIfPresent(Date.self, forKey: .lastUnattendedStart)
        leftAlone = try c.decodeIfPresent([String: String].self, forKey: .leftAlone) ?? [:]
    }

    static let fileName = "sound-levels-remeasure.json"

    static func url(catalogFile: String) -> URL {
        URL(fileURLWithPath: (catalogFile as NSString).deletingLastPathComponent, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Absent or unreadable → no remembered start.
    static func load(catalogFile: String) -> SoundLevelsRemeasureSchedule {
        guard let data = try? Data(contentsOf: url(catalogFile: catalogFile)) else { return .init() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Self.self, from: data)) ?? .init()
    }

    func save(catalogFile: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(catalogFile: catalogFile), options: .atomic)
    }
}

// MARK: - Which cards (pure)

enum SoundLevelsRemeasureRules {

    /// Why a card is in the plan.
    enum Need: Sendable, Equatable {
        /// Channel levels on the Sound row from a pass with no current stamp.
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

    /// A row withdrawn because the file's drive was not connected.
    static func isWaitingForDrive(_ row: MediaCheck) -> Bool {
        guard isWithdrawnRow(row), case .notRun(let reason) = row.verdict else { return false }
        return reason.hasSuffix(NotMeasured.offlineWords)
    }

    /// The drive a path lives on, for "waiting for N drives": "/Volumes/X",
    /// else "/" (the internal disk). Pure.
    static func driveKey(_ path: String) -> String {
        let c = (path as NSString).pathComponents
        return c.count >= 3 && c[1] == "Volumes" ? "/Volumes/\(c[2])" : "/"
    }

    static func isWithdrawnRow(_ row: MediaCheck) -> Bool {
        guard row.kind == .sound, case .notRun(let reason) = row.verdict else { return false }
        return reason.hasPrefix(withdrawnLead)
    }

    /// The card's Sound row was withdrawn by this job (stamp, else its words).
    static func isWithdrawn(_ card: MediaReportCard) -> Bool {
        card.soundLevels?.state == .withdrawn || (card.check(.sound).map(isWithdrawnRow) ?? false)
    }

    /// Waiting for its drive: withdrawn because the drive was not connected.
    static func isWaitingForDrive(_ card: MediaReportCard) -> Bool {
        isWithdrawn(card) && (card.check(.sound).map(isWaitingForDrive) ?? false)
    }

    /// Whether this card is a candidate, and why — from the card alone (its
    /// stamp and its Sound row). O(rows). Pure.
    /// `live` = the catalog row has no removal marker: a withdrawn row on a
    /// removed file is not waited for (its file is not coming back).
    static func need(_ card: MediaReportCard?, live: Bool) -> Need? {
        guard let card, card.tier == .full, let row = card.check(.sound) else { return nil }
        if isWithdrawn(card) { return live ? .withdrawn : nil }
        guard card.soundLevels?.isCurrentMeasurement != true,
              row.evidence.contains(where: isChannelLevel) else { return nil }
        return .prefix
    }

    /// A stable fingerprint of a content's copies' cards (P1-3): the cards'
    /// JSON (sorted keys, dates to the second) in record-id order, SHA-256.
    @MainActor
    static func fingerprint(_ copies: [VideoRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        var bytes = Data()
        for copy in copies.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            var card = copy.mediaReportCard
            if let c = card { card?.checkedAt = Date(timeIntervalSince1970: c.checkedAt.timeIntervalSince1970.rounded(.down)) }
            bytes.append(Data(copy.id.uuidString.utf8))
            bytes.append((try? encoder.encode(card)) ?? Data())
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// Two copies' cards are the same card (a stored card's date is whole
    /// seconds: compared to the second). Pure.
    static func sameCard(_ a: MediaReportCard, _ b: MediaReportCard) -> Bool {
        var a2 = a, b2 = b
        a2.checkedAt = Date(timeIntervalSince1970: a.checkedAt.timeIntervalSince1970.rounded(.down))
        b2.checkedAt = Date(timeIntervalSince1970: b.checkedAt.timeIntervalSince1970.rounded(.down))
        if let ra = a2.repairedCopy, let rb = b2.repairedCopy {
            a2.repairedCopy?.repairedAt = Date(timeIntervalSince1970: ra.repairedAt.timeIntervalSince1970.rounded(.down))
            b2.repairedCopy?.repairedAt = Date(timeIntervalSince1970: rb.repairedAt.timeIntervalSince1970.rounded(.down))
        }
        return a2 == b2
    }

    // MARK: What one file's pass produced

    /// Why a file could not be measured again.
    enum NotMeasured: Sendable, Equatable {
        /// The file's DRIVE is not connected: waits for it (the scheduler
        /// re-runs when it is back).
        case offline
        /// The drive is connected but the file is not at its path.
        case notFound
        /// The file on disk is not the size the card was checked at.
        case changed
        case failed(String)

        static let offlineWords = SoundLevelsRemeasureRules.offlineWordsPinned

        var words: String {
            switch self {
            case .offline: return Self.offlineWords
            case .notFound: return "the file is not at its path on a connected drive"
            case .changed: return "the file on disk is no longer the size it was checked at"
            case .failed(let why): return "the sound could not be measured (\(why))"
            }
        }
    }

    /// Persisted at the end of a withdrawn row's reason: how "waiting for its
    /// drive" is found again. Never reword.
    static let offlineWordsPinned = "its drive is not connected"

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

        var isWithdrawn: Bool { if case .withdrawn = self { return true }; return false }
    }

    static func result(of r: Remeasured) -> Result {
        switch r {
        case .measured(let d) where d.shape.audioStreams == 0:
            return .withdrawn(noSoundTrack)
        case .measured(let d) where d.balanceAnalysis == nil:
            // The pass ran but measured nothing (an undecodable codec, a
            // reference movie): unmeasurable — stays withdrawn for a retry,
            // never `.measured` (Codex closing pass P2-6).
            if case .notChecked(let why) = d.verdict { return .withdrawn(.failed(why)) }
            return .withdrawn(.failed("the sound track could not be decoded"))
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
        switch (r, result(of: r)) {
        case (_, .withdrawn(let why)):
            silent = nil
            row = .notRun(.sound, because: "\(withdrawnLead) — \(why.words)")
        case (.measured(let d), _):
            silent = d.balanceAnalysis?.measuredSilent
            var rows = [CheckMediaRules.soundRow(d)]
            if silent == true {
                rows = CheckMediaRules.applyingSilentTrack(rows, hasPicture: d.shape.videoCodec != nil, context: context)
            }
            row = rows[0]
        case (.notMeasured(let why), _):
            silent = nil
            row = .notRun(.sound, because: "\(withdrawnLead) — \(why.words)")
        }
        var out = card
        out.checks = card.checks.map { $0.kind == .sound ? row : $0 }
        out.soundMeasuredSilent = silent
        out.soundLevels = result(of: r).isWithdrawn ? .withdrawn : .measured
        if card.check(.sound)?.verdict != row.verdict {
            let timing = card.checks.contains { $0.verdict == .problem && CheckMediaRules.timingKinds.contains($0.kind) }
                ? card.headline : nil
            out.headline = CheckMediaRules.headline(checks: out.checks, tier: card.tier, hasSound: true, timing: timing)
        }
        return out
    }
}
