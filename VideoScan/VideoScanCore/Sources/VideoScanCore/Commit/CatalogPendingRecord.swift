// CatalogPendingRecord.swift
// The payload of one `pending_rows` row (cutover B2.1, schema v1.8): a NEW
// record that has no whole-file digest yet, encoded by the app's ONE record
// encoder (`VideoRecordDTO`, the byte-identity source of catalog.json — ISO
// 8601 dates, as catalog.json writes them) and decoded by the record's own
// decoder (`VideoRecord.init(from:)`, the one catalog.json loads through).
// So a held record comes back exactly as the app had it, no new mapping.
// Keys sorted, so the same record encodes to the same text and an unchanged
// held row is not rewritten.
//
// (For Rick: serialise the object to a blob for the parking lot, and back.)

import Foundation

public enum CatalogPendingRecord {

    public static func json(_ snapshot: VideoRecordDTO) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let text = String(bytes: try encoder.encode(snapshot), encoding: .utf8) else { throw NotUTF8() }
        return text
    }

    /// JSONEncoder always writes UTF-8; kept as an error, not a crash.
    struct NotUTF8: Error, CustomStringConvertible {
        var description: String { "the record's payload was not UTF-8 text" }
    }

    public static func record(_ json: String) throws -> VideoRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(VideoRecord.self, from: Data(json.utf8))
    }
}
