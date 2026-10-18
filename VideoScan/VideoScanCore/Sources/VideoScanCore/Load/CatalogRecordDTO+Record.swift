// CatalogRecordDTO+Record.swift
// `CatalogRecordDTO.init(record: VideoRecord)` — the DTO of a LIVE record
// (cutover B1, docs/design/catalog_cutover_f_prime_2026_10_17.md §2/§3):
// the same table-shaped values the importer builds from that record's
// catalog.json row, with no JSON text in between.
//
// How: the app's ONE encoder (`VideoRecordDTO.encode(to:)`, the byte-identity
// source of catalog.json) writes the row's tree through
// `CatalogJSONValueEncoder`; the importer's OWN reader
// (`VideoRecordJSON.init(from:)`) reads that tree through
// `CatalogJSONValueDecoder`; the importer's mapping
// (`CatalogRecordDTO.init(record: VideoRecordJSON)`) does the rest. No
// second mapping of the 129 keys exists to drift — the pin
// (CatalogRecordDTORecordTests) holds DTO(JSON row) == DTO(record decoded
// from that row) for every field the contract keeps.
//
// The record must be read where it lives (the app keeps records on the
// main actor); the result is a Sendable value.
//
// (For Rick: "serialise through the real writer, parse with the real
// reader" — one pair of functions, so the two directions cannot disagree.)

import Foundation

extension VideoRecordJSON {

    /// The importer's reading of what the app would write for `record`.
    public init(record: VideoRecord) throws {
        try self.init(snapshot: VideoRecordDTO(record))
    }

    /// The same from the record's Sendable snapshot (cutover B2: a commit
    /// takes the snapshot on the main actor and maps it on the store's queue).
    public init(snapshot: VideoRecordDTO) throws {
        let tree = try CatalogJSONValueEncoder().encode(snapshot)
        self = try CatalogJSONValueDecoder().decode(VideoRecordJSON.self, from: tree)
    }
}

extension CatalogRecordDTO {

    /// The DTO of a live record. `migrationLoadedAt` as for the JSON init
    /// (it only matters for a label-only "deleted" row, which a live record
    /// never is: the app's decoder already migrated it to a marker).
    public init(record: VideoRecord, migrationLoadedAt: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        self.init(record: try VideoRecordJSON(record: record), migrationLoadedAt: migrationLoadedAt)
    }

    /// The DTO of a record's snapshot (no main-actor object needed).
    public init(snapshot: VideoRecordDTO, migrationLoadedAt: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        self.init(record: try VideoRecordJSON(snapshot: snapshot), migrationLoadedAt: migrationLoadedAt)
    }
}
