// BackupAttestation.swift
// The user's word about copies the app cannot see (Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md, stage 1):
//
//   "The app has to take the word of the user on cloud copies and offsite
//    copies … cloud and off-site are the user's call, three ways: yes /
//    no / n-a, never just a checkbox."
//
//   - `BackupAttestation`  — one answer: kind (cloud / off-site / a named
//     drive), answer (yes / no / not applicable), an optional label ("which
//     cloud", "where"), when, and by whom. Stored per record in
//     `VideoRecord.backupAttestations` (additive, Codable, default empty),
//     preserved on rescan and by every same-footage inheritance path the
//     hand-entered date and place already ride, and written into the
//     archive manifest's `backup_attestations` column as JSON so a copy of
//     the archive on another Mac knows the family said "there is a cloud
//     copy".
//   - The pure helpers: latest answer per kind, the inheritance MERGE
//     (union by kind, latest `attestedAt` wins, never drop a "no" / "n/a"
//     in favour of nothing), the JSON string codec for the manifest
//     column, and the one-line summary token shared by the journal line,
//     the CSV export and the protection line.
//   - `ProtectionSummary` — the fact the app SHOWS, not a guess: what it
//     can verify (archive copy with fixity; other catalog copies, on which
//     volumes, online / offline) plus what the user attested, rendered as
//     the design's one protection line:
//       Archive ✓verified · 2 working copies (LaCie, Projects) · cloud: none · off-site: none
//     Computed per Promote BATCH (families of same-content copies), never
//     per table row.
//
// Foundation-only on purpose so it lives in the VideoScanCore package
// beside VideoRecordUserPlace.swift. The app never verifies cloud or
// off-site copies: an attestation is remembered, never checked.
//
// TIMESTAMP RULE (codex #1414, 2026-09-12): `attestedAt` is the ORDERING
// key for latest-per-kind and the inheritance merge, so its in-memory
// value must equal its own round trip through every store — catalog
// JSON, the manifest column, the archive journal. The type therefore
// owns its representation: millisecond precision, quantized at `init`,
// and encoded/decoded by `BackupAttestation.Timestamp` as an ISO-8601
// string WITH fractional seconds ("2026-09-12T20:00:00.123Z") no matter
// which `dateEncodingStrategy` the surrounding encoder uses. Before this
// rule the manifest/journal wrote whole seconds while the catalog held a
// full-precision `Date()`, so a newer "no" that had been through the
// manifest (t) lost to an older "yes" still in memory (t + 0.2 s). The
// decoder is tolerant of the whole-second strings written before the
// rule, so no attestation is lost on upgrade.
//
// (For Rick: `BackupAttestation` is a small immutable POD; the helpers are
// free functions in a namespace — `static func` on the struct — with no
// globals, so every rule is table-testable.)

import Foundation

// MARK: - The attestation

public struct BackupAttestation: Codable, Equatable, Hashable, Sendable {

    /// What kind of extra copy the user is talking about. Raw values are
    /// the on-disk vocabulary (catalog.json + manifest JSON) — never
    /// rename them; add cases at the end.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case cloud
        case offsite
        /// A named drive the app does not catalog ("the drive at Tim's").
        case drive

        /// The word used in the protection line and the journal.
        public var displayName: String {
            switch self {
            case .cloud:   return "cloud"
            case .offsite: return "off-site"
            case .drive:   return "drive"
            }
        }
    }

    /// The three-way answer. "no" and "n/a" are ANSWERS — remembered —
    /// not the absence of one (Rick's amendment).
    public enum Answer: String, Codable, Sendable {
        case yes
        case no
        case notApplicable

        /// Short form for tokens and lines: "yes" / "no" / "n/a".
        public var token: String {
            switch self {
            case .yes:           return "yes"
            case .no:            return "no"
            case .notApplicable: return "n/a"
            }
        }
    }

    public let kind: Kind
    public let answer: Answer
    /// "which cloud" / "where" — free text, nil when the user gave none.
    public let label: String?
    public let attestedAt: Date
    /// Who said so. "rick" today; the field exists so a family member's
    /// word can be told apart later.
    public let by: String

    public init(kind: Kind, answer: Answer, label: String? = nil,
                attestedAt: Date = Date(), by: String = "rick") {
        self.kind = kind
        self.answer = answer
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmed.isEmpty ? nil : trimmed
        // Quantized so the value equals its own round trip (see the
        // TIMESTAMP RULE in the header).
        self.attestedAt = Timestamp.quantized(attestedAt)
        self.by = by
    }

    // Explicit Codable so `label` is written only when present and a
    // future additive key never breaks an old reader (same discipline as
    // VideoRecord's own keys). `attestedAt` is written as the Timestamp
    // string — NOT through the encoder's date strategy — so catalog.json,
    // the manifest column and the journal all carry the same bytes.
    private enum CodingKeys: String, CodingKey { case kind, answer, label, attestedAt, by }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        answer = try c.decode(Answer.self, forKey: .answer)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        attestedAt = try Timestamp.decode(from: c, forKey: .attestedAt)
        by = try c.decodeIfPresent(String.self, forKey: .by) ?? "rick"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(answer, forKey: .answer)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(Timestamp.string(attestedAt), forKey: .attestedAt)
        try c.encode(by, forKey: .by)
    }

    /// "cloud=yes 'iCloud'" / "offsite=no" / "offsite=n/a". The kind's RAW
    /// value (not its display name) so the token is grep-able and stable.
    public var token: String {
        var t = "\(kind.rawValue)=\(answer.token)"
        if let label { t += " '\(label)'" }
        return t
    }

    /// The archive-journal line: "attestation cloud=yes 'iCloud' by rick".
    public var journalLine: String { "attestation \(token) by \(by)" }
}

// MARK: - Timestamp representation (millisecond ISO-8601, everywhere)

extension BackupAttestation {

    /// The ONE representation of `attestedAt` (header: TIMESTAMP RULE).
    ///
    /// Precision is whole milliseconds: `quantized` rounds a `Date` to
    /// the nearest ms, `string` writes "YYYY-MM-DDTHH:MM:SS.mmmZ" (always
    /// three fractional digits, always UTC, byte-stable), and `date`
    /// reads that back — or, tolerantly, a whole-second "…SS Z" string
    /// from a pre-rule writer, 1–2 fractional digits, or 4+ digits
    /// (rounded to ms). Both directions compute the same integer
    /// millisecond count and build the `Date` from it the same way, so
    /// `date(string(d)) == quantized(d)` holds bit-for-bit — no
    /// floating-point drift between what the catalog holds and what the
    /// manifest gives back.
    ///
    /// (For Rick: think of the stored value as an int64 of epoch
    /// milliseconds that happens to be carried in a `Date`; the string is
    /// its printf/scanf pair.)
    public enum Timestamp {

        /// Epoch milliseconds, rounded to nearest.
        public static func milliseconds(_ d: Date) -> Int64 {
            Int64((d.timeIntervalSince1970 * 1000).rounded())
        }

        /// The `Date` for an epoch-millisecond count — the single
        /// construction path both `quantized` and `date(_:)` use.
        public static func date(milliseconds ms: Int64) -> Date {
            Date(timeIntervalSince1970: Double(ms) / 1000)
        }

        /// `d` rounded to whole milliseconds. Idempotent.
        public static func quantized(_ d: Date) -> Date {
            date(milliseconds: milliseconds(d))
        }

        /// "2026-09-12T20:00:00.123Z" — always three fractional digits.
        public static func string(_ d: Date) -> String {
            let ms = milliseconds(d)
            // Floor division so a (theoretical) pre-1970 value still
            // splits into a whole second plus 0…999 ms.
            let secs = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
            let frac = Int(ms - secs * 1000)
            let base = Date(timeIntervalSince1970: Double(secs)).formatted(wholeSecondStyle)
            var digits = String(frac)
            while digits.count < 3 { digits = "0" + digits }
            guard base.hasSuffix("Z") else { return base + "." + digits }
            return String(base.dropLast()) + "." + digits + "Z"
        }

        /// Inverse of `string`, tolerant (see the type note). nil when
        /// the text is not an ISO-8601 instant at all.
        public static func date(_ text: String) -> Date? {
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            // Split the fractional digits out of the time part; whatever
            // follows them (the zone designator) is re-attached to the
            // whole-second text so the base parser sees a plain instant.
            var base = s
            var fracDigits = ""
            if let t = s.firstIndex(of: "T"), let dot = s[t...].firstIndex(of: ".") {
                let after = s[s.index(after: dot)...]
                let digits = after.prefix(while: { $0.isASCII && $0.isNumber })
                fracDigits = String(digits)
                base = String(s[..<dot]) + String(after.dropFirst(digits.count))
            }
            guard let whole = parseWholeSecond(base) else { return nil }
            var ms = Int64(whole.timeIntervalSince1970.rounded()) * 1000
            if !fracDigits.isEmpty {
                // First three digits are the milliseconds (right-padded
                // with zeros: ".5" is 500 ms); a fourth digit ≥ 5 rounds up.
                var three = String(fracDigits.prefix(3))
                while three.count < 3 { three += "0" }
                ms += Int64(three) ?? 0
                if fracDigits.count > 3, let fourth = fracDigits.dropFirst(3).first, fourth >= "5" { ms += 1 }
            }
            return date(milliseconds: ms)
        }

        /// Decode `attestedAt` from a keyed container: the Timestamp
        /// string (fractional or whole-second), or — should any writer
        /// ever have used Foundation's default `.deferredToDate` strategy
        /// — a number of seconds since the reference date. Throws only
        /// when the value is neither.
        public static func decode<K: CodingKey>(from c: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
            if let s = try? c.decode(String.self, forKey: key) {
                guard let d = date(s) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                           debugDescription: "attestedAt is not an ISO-8601 instant: \(s)")
                }
                return d
            }
            if let n = try? c.decode(Double.self, forKey: key) {
                return quantized(Date(timeIntervalSinceReferenceDate: n))
            }
            throw DecodingError.dataCorruptedError(forKey: key, in: c,
                                                   debugDescription: "attestedAt is neither a string nor a number")
        }

        // MARK: Base (whole-second) parse/format

        /// "2026-09-12T20:00:00Z" — Foundation's Sendable, allocation-
        /// free format style (macOS 12+); never a shared DateFormatter.
        static var wholeSecondStyle: Date.ISO8601FormatStyle { Date.ISO8601FormatStyle() }

        static func parseWholeSecond(_ s: String) -> Date? {
            if let d = try? Date(s, strategy: wholeSecondStyle) { return d }
            // Tolerance for a zone offset ("+00:00") or a space separator
            // that a hand edit or another tool might have written.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
            return f.date(from: s)
        }
    }
}

// MARK: - Pure helpers (latest per kind, merge, codec, summary)

extension BackupAttestation {

    /// Stable kind order for every list this file returns.
    static func kindIndex(_ k: Kind) -> Int { Kind.allCases.firstIndex(of: k) ?? Kind.allCases.count }

    /// The latest answer per kind: later `attestedAt` wins; on an exact
    /// tie the LATER element wins (a list is appended in time order, so
    /// the most recently recorded answer is the answer).
    public static func latestPerKind(_ list: [BackupAttestation]) -> [Kind: BackupAttestation] {
        var out: [Kind: BackupAttestation] = [:]
        for a in list {
            if let have = out[a.kind], have.attestedAt > a.attestedAt { continue }
            out[a.kind] = a
        }
        return out
    }

    /// One entry per kind, in kind order — the canonical shape a record
    /// carries after any write through these helpers.
    public static func normalized(_ list: [BackupAttestation]) -> [BackupAttestation] {
        latestPerKind(list).values.sorted { kindIndex($0.kind) < kindIndex($1.kind) }
    }

    /// The INHERITANCE rule (design: "wherever the date goes, this goes"):
    /// union by kind, latest `attestedAt` wins, and on an exact tie the
    /// record's OWN answer (`base`) wins. A kind present on only one side
    /// is always kept — a "no" or "n/a" is never dropped in favour of
    /// nothing. Returns the normalized list.
    public static func merged(_ base: [BackupAttestation],
                              with incoming: [BackupAttestation]) -> [BackupAttestation] {
        var out = latestPerKind(base)
        for (kind, a) in latestPerKind(incoming) {
            if let have = out[kind], have.attestedAt >= a.attestedAt { continue }
            out[kind] = a
        }
        return out.values.sorted { kindIndex($0.kind) < kindIndex($1.kind) }
    }

    /// Record a NEW answer: replaces the same kind, keeps the others, in
    /// kind order. (History lives in the journal, not on the record.)
    public static func replacing(_ list: [BackupAttestation],
                                 with attestation: BackupAttestation) -> [BackupAttestation] {
        var out = latestPerKind(list)
        out[attestation.kind] = attestation
        return out.values.sorted { kindIndex($0.kind) < kindIndex($1.kind) }
    }

    /// "cloud=yes 'iCloud'; offsite=no" — latest per kind, kind order.
    /// Empty string for an empty list. Used by the CSV export column.
    public static func summary(_ list: [BackupAttestation]) -> String {
        normalized(list).map(\.token).joined(separator: "; ")
    }

    // MARK: Manifest JSON column

    /// The manifest's `backup_attestations` column: a compact JSON array
    /// with Timestamp dates (millisecond ISO-8601 — the type's own
    /// Codable, so no date strategy is set here) and sorted keys (byte-
    /// stable for a given list), or "" for an empty list — never "[]", so
    /// an unattested row reads as an empty cell. The CSV layer quotes and
    /// doubles the embedded quotes; `fromJSONString` sees the original
    /// text back.
    public static func jsonString(_ list: [BackupAttestation]) -> String {
        let normalized = normalized(list)
        guard !normalized.isEmpty else { return "" }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(normalized),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Inverse of `jsonString`: "" / whitespace / malformed → [] (a
    /// manifest column is never allowed to fail a rebuild). Whole-second
    /// dates from a pre-rule manifest decode too (Timestamp tolerance).
    public static func fromJSONString(_ text: String) -> [BackupAttestation] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        guard let list = try? JSONDecoder().decode([BackupAttestation].self, from: data) else { return [] }
        return normalized(list)
    }
}

// MARK: - VideoRecord conveniences

extension VideoRecord {

    /// Latest answer per kind (a record normally carries one per kind).
    public var latestBackupAttestations: [BackupAttestation.Kind: BackupAttestation] {
        BackupAttestation.latestPerKind(backupAttestations)
    }

    public func backupAttestation(for kind: BackupAttestation.Kind) -> BackupAttestation? {
        latestBackupAttestations[kind]
    }

    /// Same-footage inheritance onto `self` from `other` (the merge rule
    /// above). Returns true when the list changed — callers use that to
    /// announce the mutation. Idempotent.
    @discardableResult
    public func inheritBackupAttestations(from other: VideoRecord) -> Bool {
        guard !other.backupAttestations.isEmpty else { return false }
        let merged = BackupAttestation.merged(backupAttestations, with: other.backupAttestations)
        guard merged != backupAttestations else { return false }
        backupAttestations = merged
        return true
    }
}

// MARK: - Protection summary (the line the app SHOWS)

/// What protects a family of copies, as verifiable facts plus the user's
/// attestations — design §"The three ideas" (1). Built from `CopyFacts`
/// values so the whole thing is pure; the model builds the facts.
///
/// Worst-case memory: one `CopyFacts` per catalog record in the families
/// touched by a batch (≈ 100 bytes + the volume-name string, which is
/// shared) — a 100k-record catalog is ~15 MB transiently, released when
/// the summary is built. Nothing is cached.
public struct ProtectionSummary: Equatable, Sendable {

    /// The facts about ONE copy of a recording.
    public struct CopyFacts: Equatable, Sendable {
        public var volumeName: String
        public var isOnline: Bool
        /// A promoted Master Archive copy (as opposed to a working copy).
        public var isArchiveCopy: Bool
        /// The archive copy carries a read-back fixity record.
        public var fixityVerified: Bool
        public var attestations: [BackupAttestation]

        public init(volumeName: String, isOnline: Bool, isArchiveCopy: Bool,
                    fixityVerified: Bool, attestations: [BackupAttestation] = []) {
            self.volumeName = volumeName
            self.isOnline = isOnline
            self.isArchiveCopy = isArchiveCopy
            self.fixityVerified = fixityVerified
            self.attestations = attestations
        }
    }

    public enum ArchiveState: Equatable, Sendable {
        /// No archive copy in the catalog.
        case none
        /// An archive copy exists but has no fixity record.
        case unverified
        /// An archive copy with a read-back fixity record.
        case verified
    }

    /// The batch-level view of one attestation kind.
    public enum Attested: Equatable, Sendable {
        case none
        case answer(BackupAttestation.Answer, label: String?)
        /// Families in the batch disagree.
        case mixed
    }

    public var archive: ArchiveState
    /// Working (non-archive) copies, online AND offline.
    public var workingCopyCount: Int
    /// Distinct volume names holding online working copies, sorted.
    public var workingVolumesOnline: [String]
    /// Distinct volume names holding only offline working copies, sorted.
    public var workingVolumesOffline: [String]
    public var cloud: Attested
    public var offsite: Attested
    public var drive: Attested
    /// How many same-content families the summary covers (1 per family;
    /// the batch count for a batch).
    public var familyCount: Int

    public static let empty = ProtectionSummary(archive: .none, workingCopyCount: 0,
                                                workingVolumesOnline: [], workingVolumesOffline: [],
                                                cloud: .none, offsite: .none, drive: .none, familyCount: 0)

    // MARK: Build

    /// One family of same-content copies.
    public static func summarize(family: [CopyFacts]) -> ProtectionSummary {
        var archive = ArchiveState.none
        var working = 0
        var online = Set<String>()
        var offline = Set<String>()
        var attestations: [BackupAttestation] = []
        for c in family {
            if c.isArchiveCopy {
                if c.fixityVerified { archive = .verified }
                else if archive == .none { archive = .unverified }
            } else {
                working += 1
                let name = c.volumeName.isEmpty ? "unnamed" : c.volumeName
                if c.isOnline { online.insert(name) } else { offline.insert(name) }
            }
            attestations.append(contentsOf: c.attestations)
        }
        offline.subtract(online)   // a volume with any online copy is online
        let latest = BackupAttestation.latestPerKind(attestations)
        func attested(_ k: BackupAttestation.Kind) -> Attested {
            guard let a = latest[k] else { return .none }
            return .answer(a.answer, label: a.label)
        }
        return ProtectionSummary(archive: archive, workingCopyCount: working,
                                 workingVolumesOnline: online.sorted(), workingVolumesOffline: offline.sorted(),
                                 cloud: attested(.cloud), offsite: attested(.offsite), drive: attested(.drive),
                                 familyCount: family.isEmpty ? 0 : 1)
    }

    /// A Promote batch: several families, one line. Archive is verified
    /// only when EVERY family is; the working-copy count sums; volumes
    /// union; an attestation kind is an answer only when every family
    /// gives the same one (labels that differ are dropped, answers that
    /// differ are "mixed").
    public static func summarize(families: [[CopyFacts]]) -> ProtectionSummary {
        let parts = families.map { summarize(family: $0) }.filter { $0.familyCount > 0 }
        guard !parts.isEmpty else { return .empty }
        var archive = ArchiveState.verified
        for p in parts {
            if p.archive == .none { archive = .none; break }
            if p.archive == .unverified { archive = .unverified }
        }
        var online = Set<String>(), offline = Set<String>()
        var working = 0
        for p in parts {
            working += p.workingCopyCount
            online.formUnion(p.workingVolumesOnline)
            offline.formUnion(p.workingVolumesOffline)
        }
        offline.subtract(online)
        func combine(_ pick: (ProtectionSummary) -> Attested) -> Attested {
            var result: Attested?
            for p in parts {
                let v = pick(p)
                guard let have = result else { result = v; continue }
                if have == v { continue }
                switch (have, v) {
                case (.answer(let a, _), .answer(let b, _)) where a == b:
                    result = .answer(a, label: nil)   // same answer, different labels
                default:
                    return .mixed
                }
            }
            return result ?? .none
        }
        return ProtectionSummary(archive: archive, workingCopyCount: working,
                                 workingVolumesOnline: online.sorted(), workingVolumesOffline: offline.sorted(),
                                 cloud: combine(\.cloud), offsite: combine(\.offsite), drive: combine(\.drive),
                                 familyCount: parts.count)
    }

    // MARK: Display

    /// The design's protection line, exactly:
    ///   Archive ✓verified · 2 working copies (LaCie, Projects) · cloud: none · off-site: none
    /// Offline volumes are named with an "offline" suffix; the drive
    /// segment appears only when a drive was attested.
    public var displayLine: String {
        var parts: [String] = []
        switch archive {
        case .verified:   parts.append("Archive ✓verified")
        case .unverified: parts.append("Archive unverified")
        case .none:       parts.append("Archive none")
        }
        if workingCopyCount == 0 {
            parts.append("no working copies")
        } else {
            let names = workingVolumesOnline + workingVolumesOffline.map { "\($0) offline" }
            let noun = workingCopyCount == 1 ? "working copy" : "working copies"
            let where_ = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
            parts.append("\(workingCopyCount) \(noun)\(where_)")
        }
        parts.append("cloud: \(Self.render(cloud))")
        parts.append("off-site: \(Self.render(offsite))")
        if drive != .none { parts.append("drive: \(Self.render(drive))") }
        return parts.joined(separator: " · ")
    }

    static func render(_ a: Attested) -> String {
        switch a {
        case .none:                          return "none"
        case .mixed:                         return "mixed"
        case .answer(.yes, let label?):      return label
        case .answer(let answer, _):         return answer.token
        }
    }
}
