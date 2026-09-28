// PromoteDateChoice.swift
// "When I promote a file, use the date I already gave its copies" (Rick
// 2026-09-27). Two pure pieces and one gatherer:
//
//   • `PromoteCopyDates.gather` — for files with NO hand-entered date of
//     their own, the dates Rick entered on (a) byte-identical copies (the
//     same whole-file SHA-256 on both records) and (b) members of its Find
//     Similar Footage group when the group's confidence is at least
//     `likely`. Existing catalog data only — nothing is read from disk.
//     Machine dates (embedded, inferred, filename) NEVER count: a copy
//     lends only its `userDate`.
//   • `PromoteCopyDates.decide` — the rule:
//       no copy dates                         → nothing to ask;
//       exactly one distinct date, and at
//       least one copy says it is KNOWN       → pre-selected, one line
//                                               "dated 1984 (known) from 2 copies";
//       dates disagree, or all are estimated  → ASK (list each; the person
//                                               picks, types, or declines).
//   • `PromoteToArchiveJob.dateDecision` — the ONE value (GH #219) used for
//     placement, the manifest's record_date / date_confidence and the
//     archived copy's record.
//
// Cost: `gather` is ONE pass over the catalog per gesture (the Promote sheet
// opening, Angel Review appearing) — O(records + selection), never in a view
// body. 100k records ≈ a few ms (pinned by the scale test).
//
// (For Rick: an `enum` with associated values ≈ std::variant; the static
// functions are free functions in a namespace.)

import Foundation
import VideoScanCore

/// Whose date a Promote override is. Absent = a machine proposal
/// (placement only; never written as a user date).
enum ArchiveDateSource: Equatable, Sendable {
    /// Rick typed it at Promote (the sheet or Angel Review) — estimated.
    case typed
    /// Rick's hand-entered date on another copy of this footage.
    case copy(filename: String, known: Bool)

    /// The manifest's date_confidence cell for this source.
    var manifestConfidence: String {
        switch self {
        case .typed: return "user-estimated"
        case .copy(_, let known): return known ? "user-known" : "user-estimated"
        }
    }

    var isKnown: Bool {
        if case .copy(_, true) = self { return true }
        return false
    }

    /// The provenance note on the archived record.
    var provenance: String {
        switch self {
        case .typed: return "typed at Promote"
        case .copy(let name, _): return "from copy \(name)"
        }
    }
}

/// One copy's hand-entered date, as the prompt lists it.
struct PromoteCopyDate: Equatable, Sendable, Identifiable {
    enum Via: Equatable, Sendable {
        /// Same whole-file SHA-256 (byte-identical).
        case sameBytes
        /// Find Similar Footage group at this confidence (≥ likely).
        case footage(FootageConfidence)
    }
    var id: UUID { recordID }
    let recordID: UUID
    let filename: String
    let volume: String
    /// Canonical reduced-ISO user date ("1984" / "1984-11" / "1984-11-14").
    let date: String
    let known: Bool
    let via: Via
    /// When Rick set it (latest `dateSet` ledger line), if known.
    var setAt: Date? = nil

    var confidenceWord: String { known ? "known" : "estimated" }
    var hint: ArchiveDateHint? { ArchiveRefile.hint(fromUserDate: date) }
}

/// What the Promote surfaces do with a file's copy dates.
enum PromoteCopiesDateChoice: Equatable, Sendable {
    /// No copy carries a hand-entered date — nothing to show.
    case noCopyDates
    /// One distinct date, known by at least one copy: pre-selected.
    case preselected(PromoteCopyDate, copies: Int)
    /// Disagreement, or estimated only: the person must choose.
    case ask([PromoteCopyDate])

    /// "dated 1984 (known) from 2 copies" — the one line.
    var line: String? {
        guard case .preselected(let d, let n) = self else { return nil }
        return "dated \(UserDateEntry.friendlyDisplay(d.date)) (known) from \(n) cop\(n == 1 ? "y" : "ies")"
    }
}

enum PromoteCopyDates {

    /// The rule (see the file header). Pure.
    static func decide(_ copies: [PromoteCopyDate]) -> PromoteCopiesDateChoice {
        let usable = copies.filter { $0.hint != nil }
        guard !usable.isEmpty else { return .noCopyDates }
        let distinct = Set(usable.map(\.date))
        if distinct.count == 1, let known = usable.first(where: \.known) {
            return .preselected(known, copies: usable.count)
        }
        // Stable order: known first, then by date, then by filename.
        let sorted = usable.sorted {
            ($0.known ? 0 : 1, $0.date, $0.filename) < ($1.known ? 0 : 1, $1.date, $1.filename)
        }
        return .ask(sorted)
    }

    /// The source for a choice the person made (or the pre-selection).
    static func source(for d: PromoteCopyDate) -> ArchiveDateSource {
        .copy(filename: d.filename, known: d.known)
    }

    /// Copy dates for each of `targets` that has NO user date of its own.
    /// ONE pass over `records`. Excludes the target itself, purged records,
    /// and records whose own `userDate` does not parse.
    @MainActor
    static func gather(for targets: [VideoRecord], records: [VideoRecord]) -> [UUID: [PromoteCopyDate]] {
        let wanted = targets.filter { $0.userDate == nil }
        guard !wanted.isEmpty else { return [:] }
        var digestsWanted = Set<String>()
        var groupsWanted = Set<UUID>()
        for t in wanted {
            digestsWanted.formUnion(digestKeys(t))
            if let f = t.footage, f.confidence >= .likely { groupsWanted.insert(f.groupID) }
        }
        guard !digestsWanted.isEmpty || !groupsWanted.isEmpty else { return [:] }
        // One pass: dated records by digest key and by footage group.
        var byDigest: [String: [VideoRecord]] = [:]
        var byGroup: [UUID: [VideoRecord]] = [:]
        for r in records where r.userDate != nil && !r.isPurged {
            for k in digestKeys(r) where digestsWanted.contains(k) { byDigest[k, default: []].append(r) }
            if let g = r.footage?.groupID, groupsWanted.contains(g) { byGroup[g, default: []].append(r) }
        }
        var out: [UUID: [PromoteCopyDate]] = [:]
        for t in wanted {
            var seen = Set<UUID>([t.id])
            var list: [PromoteCopyDate] = []
            func add(_ r: VideoRecord, via: PromoteCopyDate.Via) {
                guard seen.insert(r.id).inserted, let ud = r.userDate,
                      let canonical = UserDateEntry.canonicalize(ud) else { return }
                list.append(PromoteCopyDate(recordID: r.id, filename: r.filename, volume: r.volumeName,
                                            date: canonical, known: r.userDateStatus == .known, via: via))
            }
            for k in digestKeys(t) { for r in byDigest[k] ?? [] { add(r, via: .sameBytes) } }
            if let f = t.footage, f.confidence >= .likely {
                for r in byGroup[f.groupID] ?? [] { add(r, via: .footage(f.confidence)) }
            }
            if !list.isEmpty { out[t.id] = list }
        }
        return out
    }

    /// Whole-file identity keys: the record's own whole-file SHA-256 (its
    /// ContentFixity, or an archive copy's fixity) with the byte count.
    @MainActor
    static func digestKeys(_ r: VideoRecord) -> [String] {
        var keys: [String] = []
        if let f = r.contentFixity, !f.digest.isEmpty, f.byteCount > 0, f.byteCount == r.sizeBytes {
            keys.append("sha256:\(f.digest.lowercased()):\(f.byteCount)")
        }
        if let a = r.archiveFixity, !a.digest.isEmpty, a.sizeBytes > 0, a.sizeBytes == r.sizeBytes {
            let k = "sha256:\(a.digest.lowercased()):\(a.sizeBytes)"
            if !keys.contains(k) { keys.append(k) }
        }
        return keys
    }

    /// When each record's date was last set (the latest `dateSet` ledger
    /// line) — ONE ledger read, off the main actor. For the ask list only.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func dateSetTimes(ids: Set<UUID>, ledger: MediaLedger) async -> [UUID: Date] {
        guard !ids.isEmpty else { return [:] }
        var out: [UUID: Date] = [:]
        for e in ledger.allEvents() where e.event == .dateSet && ids.contains(e.recordID) {
            if let cur = out[e.recordID], cur >= e.at { continue }
            out[e.recordID] = e.at
        }
        return out
    }

    /// "Christmas.dv · LaCie · 1984 (known) · set 12 Mar 2026" — one ask row.
    static func askRowText(_ d: PromoteCopyDate) -> String {
        var parts = [d.filename]
        if !d.volume.isEmpty { parts.append(d.volume) }
        parts.append("\(UserDateEntry.friendlyDisplay(d.date)) (\(d.confidenceWord))")
        switch d.via {
        case .sameBytes: parts.append("same bytes")
        case .footage(let c): parts.append("same footage: \(c.label.lowercased())")
        }
        if let at = d.setAt {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            parts.append("set \(f.string(from: at))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The one date (GH #219)

/// The date a Promote files under, and where it goes. Built once per file.
struct PromoteDateDecision: Equatable, Sendable {
    /// Placement AND the manifest's record_date.
    let hint: ArchiveDateHint
    /// The manifest's date_confidence cell.
    let confidenceLabel: String
    /// Written on the archived copy's record when Rick's (nil = keep the
    /// source's own date fields).
    let recordUserDate: String?
    let recordKnown: Bool
    /// "typed at Promote" / "from copy X" — the record's note.
    let provenance: String?
    /// The filename on disk said something else (an interrupted earlier run
    /// placed it): the filename's date won so the three agree.
    let followedFilename: Bool
}

extension PromoteToArchiveJob {

    /// A manifest row's date as the archived record's user date: only when
    /// its date_confidence says it is Rick's (`user-known` / `user-estimated`);
    /// otherwise none. Pure.
    nonisolated static func userDate(fromManifestFields f: [String]) -> (date: String?, confidence: String?) {
        guard f.count >= ArchiveManifestCSV.columnCountLegacy, f[9].hasPrefix("user-"),
              let ud = ArchiveRefile.userDate(for: ArchiveRefile.hint(fromManifestDate: f[8])) else { return (nil, nil) }
        return (ud, (f[9] == "user-known" ? UserDateConfidence.known : .estimated).rawValue)
    }

    /// The date a file's PLACE says: the filename prefix when it carries a
    /// year; else the folder ("Undated" → unknown, "1940-1949" → the
    /// decade, ".../1984" → the year). nil = not a Promote-shaped path (no
    /// opinion). Pure.
    nonisolated static func placementHint(relPath: String) -> ArchiveDateHint? {
        let comps = relPath.split(separator: "/").map(String.init)
        guard comps.count >= 3 else { return nil }
        let stem = (comps[comps.count - 1] as NSString).deletingPathExtension
        let prefixed = ArchiveRefile.hint(fromManifestDate: String(stem.prefix(10)))
        if prefixed.year != nil { return prefixed }
        let folders = comps[1..<(comps.count - 1)]
        if folders.first == MasterArchiveLayout.undatedFolder { return .unknown }
        if folders.count >= 2, let y = Int(folders[folders.startIndex + 1]), folders[folders.startIndex + 1].count == 4 {
            return .year(y)
        }
        if let decade = folders.first, decade.count == 9, decade.dropFirst(4).first == "-",
           let start = Int(decade.prefix(4)), Int(decade.suffix(4)) == start + 9, start % 10 == 0 {
            return .decade(startYear: start)
        }
        return nil
    }

    /// ONE date for placement, manifest and record (GH #219). Pure.
    /// - `sourceFacts` / `sourceLabel`: the source's own resolved date and
    ///   its manifest confidence label (`dateConfidenceLabel`).
    /// - `override` / `source`: the Promote choice, if any.
    /// - `relPath`: where the file IS — its filename prefix is the final
    ///   word, so a file placed by an earlier (interrupted) run is indexed
    ///   under the date its name carries, never a different one.
    nonisolated static func dateDecision(sourceFacts: ArchivePathResolver.RecordFacts?, sourceLabel: String,
                                         override: ArchiveDateHint?, source: ArchiveDateSource?,
                                         relPath: String) -> PromoteDateDecision {
        let resolved = sourceFacts?.dateHint ?? .unknown
        var hint = override ?? resolved
        var label: String
        if let source, override != nil {
            label = source.manifestConfidence
        } else if override == nil || override == resolved {
            label = sourceLabel
        } else {
            label = ""   // a machine proposal that is not the source's own date
        }
        var write = source != nil && override != nil
        var followed = false
        // The placement ON DISK decides (codex r1 #3) — dated, decade-only
        // or Undated alike.
        if let placed = placementHint(relPath: relPath), placed != hint {
            hint = placed
            label = ""
            write = false
            followed = true
        }
        let userDate = write ? ArchiveRefile.userDate(for: hint) : nil
        return PromoteDateDecision(hint: hint, confidenceLabel: label,
                                   recordUserDate: userDate,
                                   recordKnown: userDate != nil && (source?.isKnown ?? false),
                                   provenance: userDate != nil ? source?.provenance : nil,
                                   followedFilename: followed)
    }
}

// MARK: - Model entry point (one gesture, one pass)

extension VideoScanModel {
    /// What each record's copies say about its date — `.noCopyDates` entries
    /// are omitted. ONE pass over `records` for the whole selection. Call
    /// from an event handler or a sheet's `.task`, never from a view body.
    func promoteCopyDateChoices(recordIDs: [UUID]) -> [UUID: PromoteCopiesDateChoice] {
        let targets = recordIDs.compactMap { record(forID: $0) }
        let gathered = PromoteCopyDates.gather(for: targets, records: records)
        var out: [UUID: PromoteCopiesDateChoice] = [:]
        for (id, list) in gathered {
            let choice = PromoteCopyDates.decide(list)
            if choice != .noCopyDates { out[id] = choice }
        }
        return out
    }
}
