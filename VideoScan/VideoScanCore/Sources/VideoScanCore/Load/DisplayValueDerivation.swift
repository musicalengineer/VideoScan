// DisplayValueDerivation.swift
// The display choice per content, derived from the verbatim evidence — the
// pure half of the one-time display pass (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2 and §10 decision 1, Rick's go
// 2026-10-17).
//
// After the import, every curated value sits in `knowledge_sources`, one row
// per catalog.json occurrence; the per-content display tables (`stars`,
// `user_dates`, …) are empty. This function decides what each content SHOWS:
//   * sets (`tags`, `backupAttestations`): the union of every copy's values —
//     nothing to lose, never a conflict;
//   * people: the union of confirmed names (earliest confirmation date) and
//     the union of rejected names; a name confirmed on one copy and rejected
//     on another keeps BOTH rows, each with `conflict = 1`;
//   * scalars (`starRating`, `userNotes`, `mediaDisposition`, `userDate` +
//     its confidence, `userPlace` + its confidence, `familyMusic`): every
//     copy that carries one agrees → that value; otherwise NO value and
//     `conflict = 1` (the DDL allows exactly that shape). A copy that
//     carries nothing does not vote.
// No "known beats estimated", no recency pick, no archive-copy preference:
// those are Rick's call (§h.2); adding one later is a change to THIS
// function and a re-run of the pass.
//
// A value the DDL could not hold (a star of 7, a date "summer 1990", a
// confirmation without a date) is never invented into something it is not:
// in a scalar it makes the field a conflict (shown empty, counted), in a set
// it is left out; both are counted in `unreadable`. The original stays in
// `knowledge_sources`.
//
// Pure: no I/O, no SQL. The Store fills the tables from `Rows`.
//
// (For Rick: a GROUP BY digest with a hand-written aggregate per column —
// UNION for sets, "all equal or NULL" for scalars.)

import Foundation

public enum DisplayValueDerivation {

    /// One `knowledge_sources` occurrence of a curated field on a digest.
    /// `occurrence` names the catalog.json row it came from (it pairs a date
    /// with its confidence, a place with its own).
    public struct Source: Sendable, Equatable {
        public var digest: String
        public var occurrence: String
        public var field: CatalogDDL.KnowledgeField
        public var value: CatalogJSONValue

        public init(digest: String, occurrence: String, field: CatalogDDL.KnowledgeField, value: CatalogJSONValue) {
            self.digest = digest
            self.occurrence = occurrence
            self.field = field
            self.value = value
        }
    }

    /// One scalar display row: the shown value, or nil with `conflict`.
    public struct Scalar<Value: Sendable & Equatable>: Sendable, Equatable {
        public var digest: String
        public var value: Value?
        public var conflict: Bool
    }

    public struct Tag: Sendable, Equatable {
        public var digest: String
        public var tag: String
    }

    public struct Person: Sendable, Equatable {
        public var digest: String
        public var name: String
        public var kind: CatalogDDL.PeopleTagKind
        public var confirmedAt: Int64?
        public var conflict: Bool
    }

    public struct Attestation: Sendable, Equatable {
        public var digest: String
        public var row: CatalogRecordDTO.BackupAttestationRow
    }

    /// What the pass writes, table by table.
    public struct Rows: Sendable, Equatable {
        public var stars: [Scalar<Int>] = []
        public var userNotes: [Scalar<String>] = []
        public var dispositions: [Scalar<String>] = []
        public var userDates: [Scalar<CatalogRecordDTO.UserDateRow>] = []
        public var userPlaces: [Scalar<CatalogRecordDTO.UserPlaceRow>] = []
        public var familyMusic: [Scalar<CatalogRecordDTO.FamilyMusicRow>] = []
        public var workflowTags: [Tag] = []
        public var people: [Person] = []
        public var backupAttestations: [Attestation] = []
        /// Values the DDL could not hold (kept only in knowledge_sources).
        public var unreadable = 0

        public init() {}

        public var rowCount: Int {
            stars.count + userNotes.count + dispositions.count + userDates.count + userPlaces.count
                + familyMusic.count + workflowTags.count + people.count + backupAttestations.count
        }

        /// Rows shown EMPTY because the copies disagree (people: both sides).
        public var conflictCount: Int {
            stars.filter(\.conflict).count + userNotes.filter(\.conflict).count + dispositions.filter(\.conflict).count
                + userDates.filter(\.conflict).count + userPlaces.filter(\.conflict).count
                + familyMusic.filter(\.conflict).count + people.filter(\.conflict).count
        }
    }

    /// The `knowledge_sources` fields the display tables are made from.
    public static let fields: [CatalogDDL.KnowledgeField] = [
        .starRating, .userNotes, .mediaDisposition, .userDate, .userDateConfidence, .userPlace,
        .userPlaceConfidence, .familyMusic, .tags, .confirmedByUserPeople, .rejectedPeople, .backupAttestations,
    ]

    public static func derive(sources: [Source]) -> Rows {
        var rows = Rows()
        let byDigest = Dictionary(grouping: sources.filter { fields.contains($0.field) }, by: \.digest)
        for digest in byDigest.keys.sorted() {
            DigestKnowledge(digest: digest, sources: byDigest[digest] ?? []).append(to: &rows)
        }
        return rows
    }
}

// MARK: - One content's knowledge

/// Every occurrence's curated values for one digest, by occurrence.
private struct DigestKnowledge {
    let digest: String
    /// occurrence → field → value, occurrences in a stable order.
    let occurrences: [[CatalogDDL.KnowledgeField: CatalogJSONValue]]

    init(digest: String, sources: [DisplayValueDerivation.Source]) {
        self.digest = digest
        let grouped = Dictionary(grouping: sources, by: \.occurrence)
        occurrences = grouped.keys.sorted().map { key in
            Dictionary((grouped[key] ?? []).map { ($0.field, $0.value) }, uniquingKeysWith: { first, _ in first })
        }
    }

    func append(to rows: inout DisplayValueDerivation.Rows) {
        var unreadable = 0
        if let s = scalar(.starRating, &unreadable, DisplayParse.star) { rows.stars.append(s) }
        if let s = scalar(.userNotes, &unreadable, DisplayParse.note) { rows.userNotes.append(s) }
        if let s = scalar(.mediaDisposition, &unreadable, DisplayParse.disposition) { rows.dispositions.append(s) }
        if let s = pair(.userDate, .userDateConfidence, &unreadable, DisplayParse.userDate) { rows.userDates.append(s) }
        if let s = pair(.userPlace, .userPlaceConfidence, &unreadable, DisplayParse.userPlace) { rows.userPlaces.append(s) }
        if let s = scalar(.familyMusic, &unreadable, DisplayParse.familyMusic) { rows.familyMusic.append(s) }
        rows.workflowTags += members(.tags, &unreadable, DisplayParse.tag).map { DisplayValueDerivation.Tag(digest: digest, tag: $0) }
        rows.backupAttestations += attestations(&unreadable)
        rows.people += people(&unreadable)
        rows.unreadable += unreadable
    }

    /// "Every copy that carries one agrees → that value; else nil + conflict."
    private func agree<T: Equatable>(_ values: [T?], _ unreadable: inout Int) -> DisplayValueDerivation.Scalar<T>? {
        guard let first = values.first else { return nil }
        let bad = values.filter { $0 == nil }.count
        unreadable += bad
        let same = bad == 0 && values.allSatisfy { $0 == first }
        return DisplayValueDerivation.Scalar(digest: digest, value: same ? first : nil, conflict: !same)
    }

    private func scalar<T: Equatable>(_ field: CatalogDDL.KnowledgeField, _ unreadable: inout Int,
                                      _ parse: (CatalogJSONValue) -> T?) -> DisplayValueDerivation.Scalar<T>? {
        agree(occurrences.compactMap { $0[field] }.map(parse), &unreadable)
    }

    /// A value and its confidence, read from the SAME occurrence.
    private func pair<T: Equatable>(_ field: CatalogDDL.KnowledgeField, _ confidence: CatalogDDL.KnowledgeField,
                                    _ unreadable: inout Int,
                                    _ parse: (CatalogJSONValue?, CatalogJSONValue?) -> T?) -> DisplayValueDerivation.Scalar<T>? {
        let carried = occurrences.filter { $0[field] != nil || $0[confidence] != nil }
        return agree(carried.map { parse($0[field], $0[confidence]) }, &unreadable)
    }

    /// The union of a set field's elements, first-seen order, readable only.
    private func members<T: Hashable>(_ field: CatalogDDL.KnowledgeField, _ unreadable: inout Int,
                                      _ parse: (CatalogJSONValue) -> T?) -> [T] {
        var seen = Set<T>()
        var out: [T] = []
        for element in occurrences.compactMap({ $0[field]?.arrayValue }).joined() {
            guard let parsed = parse(element) else { unreadable += 1; continue }
            if seen.insert(parsed).inserted { out.append(parsed) }
        }
        return out
    }

    private func attestations(_ unreadable: inout Int) -> [DisplayValueDerivation.Attestation] {
        members(.backupAttestations, &unreadable, DisplayParse.attestation)
            .map { DisplayValueDerivation.Attestation(digest: digest, row: $0.row) }
    }

    /// Confirmed (earliest date per name) and rejected; a name on both sides → both rows in conflict.
    private func people(_ unreadable: inout Int) -> [DisplayValueDerivation.Person] {
        var confirmed: [String: Int64] = [:]
        for tag in members(.confirmedByUserPeople, &unreadable, DisplayParse.confirmed) {
            confirmed[tag.name] = min(confirmed[tag.name] ?? tag.at, tag.at)
        }
        let rejected = Set(members(.rejectedPeople, &unreadable, DisplayParse.name))
        let yes = confirmed.keys.sorted().map {
            DisplayValueDerivation.Person(digest: digest, name: $0, kind: .confirmed, confirmedAt: confirmed[$0],
                                          conflict: rejected.contains($0))
        }
        let no = rejected.sorted().map {
            DisplayValueDerivation.Person(digest: digest, name: $0, kind: .rejected, confirmedAt: nil,
                                          conflict: confirmed[$0] != nil)
        }
        return yes + no
    }
}

// MARK: - Reading one value the way the DDL can hold it (nil = it cannot)

enum DisplayParse {

    static func star(_ v: CatalogJSONValue) -> Int? {
        guard let i = v.int64Value, (1...3).contains(i) else { return nil }
        return Int(i)
    }

    static func note(_ v: CatalogJSONValue) -> String? {
        guard let s = v.stringValue, !s.isEmpty else { return nil }
        return s
    }

    static func disposition(_ v: CatalogJSONValue) -> String? {
        guard let s = v.stringValue, CatalogDDL.Disposition(rawValue: s) != nil else { return nil }
        return s
    }

    static func name(_ v: CatalogJSONValue) -> String? {
        guard let s = v.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func tag(_ v: CatalogJSONValue) -> String? { name(v) }

    /// nil when absent; .some(nil) when present but unreadable.
    private static func confidence(_ v: CatalogJSONValue?) -> String?? {
        guard let v, v != .null else { return .some(nil) }
        guard let s = v.stringValue, CatalogDDL.DateConfidence(rawValue: s) != nil else { return nil }
        return .some(s)
    }

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD` with the DDL's digit classes.
    static func isUserDate(_ s: String) -> Bool {
        let b = Array(s.utf8)
        func digit(_ i: Int, _ range: ClosedRange<UInt8> = 48...57) -> Bool { range.contains(b[i]) }
        guard [4, 7, 10].contains(b.count), (0..<4).allSatisfy({ digit($0) }) else { return false }
        if b.count >= 7 { guard b[4] == 45, digit(5, 48...49), digit(6) else { return false } }
        if b.count == 10 { guard b[7] == 45, digit(8, 48...51), digit(9) else { return false } }
        return true
    }

    static func userDate(_ value: CatalogJSONValue?, _ confidence: CatalogJSONValue?) -> CatalogRecordDTO.UserDateRow? {
        guard let conf = self.confidence(confidence) else { return nil }
        let date: String?
        if let value, value != .null {
            guard let s = value.stringValue, isUserDate(s) else { return nil }
            date = s
        } else {
            date = nil
        }
        guard date != nil || conf != nil else { return nil }
        return CatalogRecordDTO.UserDateRow(value: date, confidence: conf)
    }

    static func userPlace(_ value: CatalogJSONValue?, _ confidence: CatalogJSONValue?) -> CatalogRecordDTO.UserPlaceRow? {
        guard let conf = self.confidence(confidence) else { return nil }
        let place: String?
        if let value, value != .null {
            guard let s = name(value) else { return nil }
            place = s
        } else {
            place = nil
        }
        guard place != nil || conf != nil else { return nil }
        return CatalogRecordDTO.UserPlaceRow(place: place, confidence: conf)
    }

    static func familyMusic(_ v: CatalogJSONValue) -> CatalogRecordDTO.FamilyMusicRow? {
        guard let at = v["markedAt"]?.stringValue.flatMap(CatalogJSONDate.parse) else { return nil }
        return CatalogRecordDTO.FamilyMusicRow(performer: v["performer"]?.stringValue, title: v["title"]?.stringValue, markedAt: at)
    }

    struct ConfirmedName: Hashable {
        let name: String
        let at: Int64
    }

    static func confirmed(_ v: CatalogJSONValue) -> ConfirmedName? {
        guard let n = v["name"].flatMap(name), let at = v["confirmedAt"]?.stringValue.flatMap(CatalogJSONDate.parse) else { return nil }
        return ConfirmedName(name: n, at: at)
    }

    /// Hashable on the table's primary key (digest, kind, attested_at, answer, by_whom).
    struct AttestationKey: Hashable {
        let row: CatalogRecordDTO.BackupAttestationRow
        static func == (a: AttestationKey, b: AttestationKey) -> Bool {
            a.row.kind == b.row.kind && a.row.attestedAt == b.row.attestedAt && a.row.answer == b.row.answer
                && a.row.byWhom == b.row.byWhom
        }
        func hash(into h: inout Hasher) {
            h.combine(row.kind); h.combine(row.attestedAt); h.combine(row.answer); h.combine(row.byWhom)
        }
    }

    static func attestation(_ v: CatalogJSONValue) -> AttestationKey? {
        guard let kind = v["kind"]?.stringValue, CatalogDDL.AttestationKind(rawValue: kind) != nil,
              let answer = v["answer"]?.stringValue, CatalogDDL.AttestationAnswer(rawValue: answer) != nil,
              let at = v["attestedAt"]?.stringValue.flatMap(CatalogJSONDate.parse),
              let by = v["by"]?.stringValue else { return nil }
        return AttestationKey(row: CatalogRecordDTO.BackupAttestationRow(kind: kind, answer: answer, label: v["label"]?.stringValue,
                                                                           attestedAt: at, byWhom: by))
    }
}
