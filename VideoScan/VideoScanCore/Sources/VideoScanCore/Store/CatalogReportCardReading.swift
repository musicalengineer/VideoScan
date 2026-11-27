// CatalogReportCardReading.swift (VideoScanCore/Store)
// The ONE stored Check Media report card of a content (`media_checks`,
// kind 'reportCard', keyed by digest), as its JSON text. Re-measure Sound
// Levels (GH #516, Codex cycle #373 P0-1) compares it with the card it is
// about to replace: cards are stored per DIGEST, so rewriting one record's
// card replaces every copy's — a newer card a copy holds must never be lost.
//
// And the content's stored sound verdict (kind 'audio', GH #518 Codex round
// 2): a withdrawal of a stale "ok" is a CONTENT decision, and measured damage
// the store holds must never be withdrawn — so the deciding step reads it.
// Read only; no schema change. Memory: one card's text, or one short row.

import Foundation
import GRDB

/// The content's bound sound-verdict row (`media_checks`, kind 'audio').
public struct StoredAudioCheck: Sendable, Equatable {
    public var status: String
    public var note: String
    /// `checked_at`, whole seconds; nil when the row carries none.
    public var checkedAt: Date?

    public init(status: String, note: String, checkedAt: Date?) {
        self.status = status
        self.note = note
        self.checkedAt = checkedAt
    }
}

public protocol CatalogReportCardReading {
    /// The stored card's JSON for `digest` (lowercased hex), or nil.
    func storedReportCardJSON(digest: String) throws -> String?
    /// The content's bound sound verdict for `digest`, or nil when it has
    /// none (an imported, unverified value is not a bound row).
    func storedAudioCheck(digest: String) throws -> StoredAudioCheck?
}

extension GRDBRecordHandle {
    func storedReportCardJSON(digest: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT card FROM media_checks WHERE digest = ? AND kind = 'reportCard'",
                            arguments: [digest.lowercased()])
    }

    func storedAudioCheck(digest: String) throws -> StoredAudioCheck? {
        guard let row = try Row.fetchOne(db, sql: "SELECT status, note, checked_at FROM media_checks WHERE digest = ? AND kind = 'audio'",
                                         arguments: [digest.lowercased()]) else { return nil }
        let seconds: Int64? = row["checked_at"]
        return StoredAudioCheck(status: row["status"], note: row["note"],
                                checkedAt: seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) })
    }
}

extension GRDBReader: CatalogReportCardReading {}
