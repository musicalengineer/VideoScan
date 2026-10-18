// CatalogRecordDTO+Derived.swift
// The derived values of one row — every one imported `unverified` (contract
// §e.8, §10b "Derived — regenerable"), keyed (kind, seq) — and the regen
// context. A sound print is not here: a `sha256:` stamp is bound
// (`soundPrint`), a `v1:` stamp is not imported (§b).
//
// The kinds are a TABLE (`derivedSources`, in emission order): each entry
// says which raw keys make the value and which make its stamp. Adding a
// derived kind is one table row, not one more branch.
//
// (For Rick: a `static const` descriptor table driving one small reader,
// instead of a dozen hand-written `if` blocks.)

import Foundation

extension CatalogRecordDTO {

    /// How one derived kind is read out of the raw row.
    enum DerivedSource: Sendable {
        /// Each element of a JSON array is one row (seq = its index); the
        /// stamp is these sibling keys of the row.
        case list(key: String, stampKeys: [String])
        /// Scalar sibling keys gathered into one object; a row when any is present.
        case gathered(keys: [String])
        /// One key verbatim; the stamp is sibling keys of the row plus keys
        /// read from inside the value itself.
        case value(key: String, stampKeys: [String], innerStampKeys: [String])
        /// A status word with its note and date; a row when the status is non-empty.
        case check(statusKey: String, noteKey: String, dateKey: String)
    }

    static let captionStampKeys = ["sceneCaptionModel", "sceneCaptionDate"]

    /// The contract's derived kinds, in the order the rows are emitted.
    static let derivedSources: [(kind: CatalogDDL.DerivedKind, source: DerivedSource)] = [
        (.scene, .list(key: "sceneCaptions", stampKeys: captionStampKeys)),
        (.ocrDate, .list(key: "ocrDateCandidates", stampKeys: captionStampKeys)),
        (.ocrText, .list(key: "ocrText", stampKeys: captionStampKeys)),
        (.captionRun, .gathered(keys: captionStampKeys)),
        (.transcript, .value(key: "audioTranscript", stampKeys: ["audioTranscriptModel", "audioTranscriptDate"],
                             innerStampKeys: [])),
        (.dossier, .gathered(keys: ["dossierProcessedAt", "dossierProcessedBy"])),
        (.inferredDate, .gathered(keys: ["inferredRecordDate", "inferredDateConfidence", "inferredDateSource",
                                         "inferredDateRange", "inferredDateReason"])),
        (.audioCheck, .check(statusKey: "audioVerifyStatus", noteKey: "audioVerifyNote", dateKey: "audioVerifyDate")),
        (.videoCheck, .check(statusKey: "videoVerifyStatus", noteKey: "videoVerifyNote", dateKey: "videoVerifyDate")),
        (.reportCard, .value(key: "mediaReportCard", stampKeys: [], innerStampKeys: ["fileSizeBytes", "checkedAt"])),
        (.perceptualPrint, .value(key: "perceptualFingerprint", stampKeys: [], innerStampKeys: ["sizeBytes"])),
        (.footageMembership, .value(key: "footage", stampKeys: [], innerStampKeys: [])),
        (.detectedPerson, .list(key: "detectedPeople", stampKeys: [])),
        (.suspectedPerson, .list(key: "suspectedPeople", stampKeys: [])),
    ]

    /// `derived_unverified` rows for one occurrence, in table order.
    public static func derivedValueRows(raw: [String: CatalogJSONValue]) -> [DerivedValueRow] {
        derivedSources.flatMap { rows(of: $0.kind, from: $0.source, raw: raw) }
    }

    private static func rows(of kind: CatalogDDL.DerivedKind, from source: DerivedSource,
                             raw: [String: CatalogJSONValue]) -> [DerivedValueRow] {
        switch source {
        case .list(let key, let stampKeys):
            let stamp = object(raw, stampKeys)
            return (raw[key]?.arrayValue ?? []).enumerated().map {
                DerivedValueRow(kind: kind, seq: $0.offset, valueJSON: $0.element, stampJSON: stamp)
            }
        case .gathered(let keys):
            let value = object(raw, keys)
            guard nonEmpty(value) else { return [] }
            return [DerivedValueRow(kind: kind, seq: 0, valueJSON: value, stampJSON: .object([:]))]
        case .value(let key, let stampKeys, let innerKeys):
            guard let value = raw[key], value != .null else { return [] }
            var stamp = object(raw, stampKeys).objectValue ?? [:]
            for k in innerKeys {
                if let v = value[k] { stamp[k] = v }
            }
            return [DerivedValueRow(kind: kind, seq: 0, valueJSON: value, stampJSON: .object(stamp))]
        case .check(let statusKey, let noteKey, let dateKey):
            guard let s = raw[statusKey]?.stringValue, !s.isEmpty else { return [] }
            return [DerivedValueRow(kind: kind, seq: 0, valueJSON: object(raw, [statusKey, noteKey, dateKey]),
                                    stampJSON: object(raw, [dateKey]))]
        }
    }

    // MARK: The inverse (cutover B1): rows → the raw members they came from

    /// The raw row members a set of derived rows came from — the exact
    /// inverse of `derivedValueRows` over the same descriptor table, so a
    /// SQLite load gives the record back the keys the JSON row carried.
    /// Rows of one kind are taken in `seq` order; a `.value` kind's inner
    /// stamp keys stay inside its value (only its sibling keys come back).
    public static func rawMembers(of rows: [DerivedValueRow]) -> [String: CatalogJSONValue] {
        var raw: [String: CatalogJSONValue] = [:]
        for (kind, source) in derivedSources {
            let mine = rows.filter { $0.kind == kind }.sorted { $0.seq < $1.seq }
            guard let first = mine.first else { continue }
            switch source {
            case .list(let key, _):
                raw[key] = .array(mine.map(\.valueJSON))
                merge(first.stampJSON, keys: nil, into: &raw)
            case .gathered, .check:
                merge(first.valueJSON, keys: nil, into: &raw)
            case .value(let key, let stampKeys, _):
                raw[key] = first.valueJSON
                merge(first.stampJSON, keys: stampKeys, into: &raw)
            }
        }
        return raw
    }

    /// Copy an object's members (all, or only `keys`) into `raw`.
    private static func merge(_ object: CatalogJSONValue, keys: [String]?, into raw: inout [String: CatalogJSONValue]) {
        for (k, v) in object.objectValue ?? [:] where keys?.contains(k) ?? true {
            raw[k] = v
        }
    }

    /// The present, non-null members of `raw` named by `keys`, as one object.
    private static func object(_ raw: [String: CatalogJSONValue], _ keys: [String]) -> CatalogJSONValue {
        var o: [String: CatalogJSONValue] = [:]
        for k in keys {
            if let v = raw[k], v != .null { o[k] = v }
        }
        return .object(o)
    }

    private static func nonEmpty(_ v: CatalogJSONValue) -> Bool {
        if case .object(let o) = v { return !o.isEmpty }
        return true
    }

    /// `regen_context` (§e.8): 'folder-year' → folderDate, 'propagated from
    /// <uuid>' → donorDate (the donor row id stays verbatim in the value).
    public static func regenContextRows(raw: [String: CatalogJSONValue]) -> [RegenContextRow] {
        guard let source = raw["inferredDateSource"]?.stringValue else { return [] }
        let kind: CatalogDDL.RegenKind
        if source == "folder-year" {
            kind = .folderDate
        } else if source.hasPrefix("propagated from ") {
            kind = .donorDate
        } else {
            return []
        }
        let value = object(raw, ["inferredDateSource", "inferredRecordDate", "inferredDateRange"])
        return [RegenContextRow(kind: kind, valueJSON: value, reason: raw["inferredDateReason"]?.stringValue)]
    }
}
