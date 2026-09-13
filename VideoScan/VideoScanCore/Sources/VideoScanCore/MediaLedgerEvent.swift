// MediaLedgerEvent.swift
// One line of the Media Ledger (Rick's amendment 2, 2026-09-12,
// docs/promote_and_prune_workflow_design.md — promote-and-prune stage 2):
//
//   "Audit-grade memory of what happened to every file … ask the app or
//    Hallie 'what happened to MyFavoriteVideo.mov?' and get the answer,
//    with dates."
//
// The ledger is ONE append-only JSONL file (App Support/VideoScan/ledger/
// media-ledger.jsonl, mirrored into the archive's 00_Index/ on every
// promote so it travels with the archive — GH #170). This file is the
// pure model of one line: the event vocabulary, the actor vocabulary, the
// content key that ties copies of the same footage together, and the
// byte-stable JSON codec. The writer/reader with the off-main worker is
// app-side (MediaLedger.swift); the dated sentences are LedgerNarrator.
//
// Existing journals (archive journal, attestation journal, Find-and-Tag
// journal, catalog.log) keep writing; the ledger is ADDITIVE and is the
// one place a human question is answered from.
//
// TIMESTAMP: `at` rides BackupAttestation.Timestamp — millisecond
// ISO-8601 with fractional seconds, quantized at init, so a line equals
// its own round trip and two writers never disagree about "when".
//
// (For Rick: an immutable POD with an explicit Codable so the on-disk
// key set is frozen — add keys at the end, never rename; `Kind` and
// `Actor` raw values are the on-disk vocabulary.)

import Foundation

public struct MediaLedgerEvent: Codable, Equatable, Sendable {

    /// What happened. Raw values are the on-disk vocabulary — never
    /// rename; add cases at the end.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cataloged
        case setAside
        case putBack
        /// detail: fixity (sha256 hex), verified ("true"/"false"),
        /// archive (display name), relPath, sizeBytes.
        case archived
        case copyTrashed
        case copyDeleted
        case restored
        /// detail: place ("" = cleared), confidence.
        case placeSet
        /// detail: date ("" = cleared), confidence.
        case dateSet
        /// detail: kind (cloud/offsite/drive), answer (yes/no/n/a), label.
        case attestation
        /// "Rick approved N copies to Trash" — detail: count, bytes,
        /// files (newline-separated filenames), action.
        case approval
    }

    /// Who did it. "rick" for a human gesture; the app's own verbs are
    /// named so the narrator can say "Tidy set it aside" vs "You set it
    /// aside".
    public enum Actor: String, Codable, CaseIterable, Sendable {
        case rick
        case tidy
        case promote
        case angel
        case app
    }

    /// Detail dictionary keys — one vocabulary for writers and the
    /// narrator. Plain strings so a future key never breaks an old reader.
    public enum Detail {
        public static let reason = "reason"
        public static let fixity = "fixity"
        public static let verified = "verified"
        public static let archive = "archive"
        public static let relPath = "relPath"
        public static let sizeBytes = "sizeBytes"
        public static let volume = "volume"
        public static let place = "place"
        public static let date = "date"
        public static let confidence = "confidence"
        public static let kind = "kind"
        public static let answer = "answer"
        public static let label = "label"
        public static let count = "count"
        public static let bytes = "bytes"
        public static let files = "files"
        public static let action = "action"
        public static let mode = "mode"
        public static let protection = "protection"
    }

    public let at: Date
    public let event: Kind
    public let recordID: UUID
    /// Ties every copy of the same footage together (see `contentKey`).
    /// "" when the record was never hashed — the line is then found by
    /// record id or filename only.
    public let contentKey: String
    public let filename: String
    public let fullPath: String
    public let by: Actor
    /// One id per Promote batch / approval so "the 21 files archived on
    /// Sep 12" can be asked for as a group. nil for single-record edits.
    public let batchID: String?
    public let detail: [String: String]

    public init(at: Date = Date(), event: Kind, recordID: UUID, contentKey: String,
                filename: String, fullPath: String, by: Actor,
                batchID: String? = nil, detail: [String: String] = [:]) {
        self.at = BackupAttestation.Timestamp.quantized(at)
        self.event = event
        self.recordID = recordID
        self.contentKey = contentKey
        self.filename = filename
        self.fullPath = fullPath
        self.by = by
        let trimmed = batchID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.batchID = trimmed.isEmpty ? nil : trimmed
        self.detail = detail
    }

    // MARK: Content key

    /// The family key for copies of one recording: the segmented
    /// `contentHash` when the record has one ("h:v1:…"), else the
    /// partial-MD5 + size pair the ignore list already trusts
    /// ("p:<md5>:<size>"), else "" (unknown — never matches anything).
    public static func contentKey(contentHash: String, partialMD5: String, sizeBytes: Int64) -> String {
        if !contentHash.isEmpty { return "h:" + contentHash }
        if !partialMD5.isEmpty, sizeBytes > 0 { return "p:\(partialMD5):\(sizeBytes)" }
        return ""
    }

    // MARK: Codable (frozen key set; `at` as the Timestamp string)

    private enum CodingKeys: String, CodingKey {
        case at, event, recordID, contentKey, filename, fullPath, by, batchID, detail
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try BackupAttestation.Timestamp.decode(from: c, forKey: .at)
        event = try c.decode(Kind.self, forKey: .event)
        recordID = try c.decode(UUID.self, forKey: .recordID)
        contentKey = try c.decodeIfPresent(String.self, forKey: .contentKey) ?? ""
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        fullPath = try c.decodeIfPresent(String.self, forKey: .fullPath) ?? ""
        by = try c.decodeIfPresent(Actor.self, forKey: .by) ?? .app
        batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        detail = try c.decodeIfPresent([String: String].self, forKey: .detail) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(BackupAttestation.Timestamp.string(at), forKey: .at)
        try c.encode(event, forKey: .event)
        try c.encode(recordID, forKey: .recordID)
        try c.encode(contentKey, forKey: .contentKey)
        try c.encode(filename, forKey: .filename)
        try c.encode(fullPath, forKey: .fullPath)
        try c.encode(by, forKey: .by)
        try c.encodeIfPresent(batchID, forKey: .batchID)
        try c.encode(detail, forKey: .detail)
    }

    // MARK: JSONL codec

    /// One JSON object, sorted keys, NO trailing newline (the writer adds
    /// it so a batch is one contiguous buffer).
    public static func encodeLine(_ e: MediaLedgerEvent) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(e)
    }

    /// A whole batch as one buffer: each line newline-terminated.
    public static func encodeLines(_ events: [MediaLedgerEvent]) throws -> Data {
        var data = Data()
        for e in events {
            data.append(try encodeLine(e))
            data.append(0x0A)
        }
        return data
    }

    /// nil for a blank or unparseable line — a reader never fails on one
    /// bad line (the file is append-only and may end mid-write after a
    /// crash).
    public static func decodeLine(_ line: Substring) -> MediaLedgerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaLedgerEvent.self, from: d)
    }

    /// Every parseable line of `text`, in file order.
    public static func decodeLines(_ text: String) -> [MediaLedgerEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap(decodeLine)
    }
}
