// CatalogReportCardReading.swift (VideoScanCore/Store)
// The ONE stored Check Media report card of a content (`media_checks`,
// kind 'reportCard', keyed by digest), as its JSON text. Re-measure Sound
// Levels (GH #516, Codex cycle #373 P0-1) compares it with the card it is
// about to replace: cards are stored per DIGEST, so rewriting one record's
// card replaces every copy's — a newer card a copy holds must never be lost.
// Read only; no schema change. Memory: one card's text.

import Foundation
import GRDB

public protocol CatalogReportCardReading {
    /// The stored card's JSON for `digest` (lowercased hex), or nil.
    func storedReportCardJSON(digest: String) throws -> String?
}

extension GRDBRecordHandle {
    func storedReportCardJSON(digest: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT card FROM media_checks WHERE digest = ? AND kind = 'reportCard'",
                            arguments: [digest.lowercased()])
    }
}

extension GRDBReader: CatalogReportCardReading {}
