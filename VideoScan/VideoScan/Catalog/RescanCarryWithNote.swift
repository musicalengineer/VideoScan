// RescanCarryWithNote.swift
// GH #478, Rick's ruling DECISIONS 2026-11-27 (1): when a rescan finds a
// DIFFERENT file at a path whose record held Rick's values, the values are
// CARRIED onto the new file's record with a visible provenance note, the
// earlier record stays in the catalog as history, and the carry is ONE
// undoable action.
//
// What "carried" means here. `RescanPreservedFields` (keyed by path) already
// copies the earlier record's preserved set onto the fresh probe — the
// snapshot at scan start, then the live re-read at the merge. This door runs
// AFTER that, inside both merges (complete and partial), and only asks what
// the old code never asked: is the file now at this path a different file?
// Evidence only (`bytesDiffer`): two whole-file SHA-256 digests that differ;
// else a size change (both sides known); else two partialMD5s that disagree.
// No evidence either way is the same file — carried quietly, as before.
//
// When it IS a different file and the earlier record is ACTIVE, not archived
// itself, and holds any of Rick's curated values (`RescanCuratedGroup`):
//   * the earlier record is stamped `replacedAtPath` (a disk fact: that path no
//     longer holds those bytes; the B2.4 shape `placeRecord` uses) and KEPT —
//     never purged — so the values it held stay in the catalog's history; the
//     next rescan keeps it beside its successor (`historyRowsKeptAtReseenPaths`);
//   * the new record gets one File Journey line in `notes` (machine text, shown
//     in the Inspector's Notes and in its "Copied From an Earlier File" section):
//       Carry <ISO>: Copied from the earlier file <name> (SHA-256 <12 hex>…) at
//       this path on <yyyy-MM-dd>; review if this is not the same footage.
//       Earlier record <UUID>.
//     ("SHA-256 not computed" when the earlier record had no whole-file
//     digest — never a sample passed off as one.)
//   * a new file that is a copy of ARCHIVED content (GH #528, the date seam)
//     keeps the date that content was filed under — Rick's date and the five
//     inferred fields — never the earlier file's;
//   * ONE summary line per merge, in plain words, five names then a count.
// An archived earlier record is out of scope (its file changing in place is a
// fixity failure the preservation pass already reports); it is left as before.
//
// Undo ("Undo Carry" in the Inspector, `undoCarry`): the carry's stored marker
// is the note itself (machine_notes — no schema change). Undo finds the
// earlier record named by the newest Carry line, and for each curated group
// whose value on the new record is STILL the value carried from it, puts back
// the new record's prior value — blank: a fresh probe carries none of Rick's
// values. A group Rick changed since is left as he set it (said in the log). A
// date the seam fixes (archived, or a copy of archived content) is never
// written. The Carry line is rewritten in place to say it was undone, so the
// Inspector stops offering the undo and the history stays readable. The earlier
// record is not touched: it still holds the values. One log line. Refused
// (nothing touched) in a read-only session (`CuratedEditGuard`) and when the
// earlier record is not in the catalog.
//
// Cost: the merge pass is O(records under the root + fresh) with an O(1) test
// per row, no I/O and no await (it runs inside the merge's atomic section).
// Memory (worst case): one dictionary entry per fresh record (path → reference,
// ≈ 100 B) — ≈ 10 MB for a 100k-file rescan, freed when the merge returns —
// plus the kept-row set (one 8-byte identity per carried row). Undo is O(lines
// in one record's notes) plus one id lookup.
//
// (For Rick: `RescanCarryWithNote` is a small value type holding a reference to
// the model — ≈ a C++ helper struct with a `Model&` member, like
// CuratedRecordEdits; `@MainActor` = "UI thread only". It adds no state to the
// model and no `extension VideoScanModel`.)

import Foundation
import VideoScanCore

// MARK: - Rick's curated values, by group

/// One group of Rick's curated values — the ones the catalog keys by content
/// (`CatalogCommit.shareCurated`). The carry's trigger is "any group is not
/// blank"; undo works group by group. (For Rick: an enum whose `switch`es are
/// the per-field tables — ≈ a C++ enum class with free functions.)
enum RescanCuratedGroup: CaseIterable {
    case date, place, disposition, tags, userNotes, people, stars, familyMusic, attestations

    /// Blank = what a fresh scan probe carries.
    @MainActor
    func isBlank(_ r: VideoRecord) -> Bool {
        switch self {
        case .date: return r.userDate == nil && r.userDateConfidence == nil
        case .place: return r.userPlace == nil && r.userPlaceConfidence == nil
        case .disposition: return r.mediaDisposition == .unreviewed
        case .tags: return r.tags.isEmpty
        case .userNotes: return r.userNotes.isEmpty
        case .people: return r.confirmedByUserPeople.isEmpty && r.rejectedPeople.isEmpty
        case .stars: return r.starRating == 0
        case .familyMusic: return r.familyMusic == nil
        case .attestations: return r.backupAttestations.isEmpty
        }
    }

    /// Same value on both records. People and the music mark compare by what
    /// Rick sees (names, performer, title), not by their click timestamps: a
    /// stored row and a held row round-trip those differently.
    @MainActor
    func same(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        switch self {
        case .date: return a.userDate == b.userDate && a.userDateConfidence == b.userDateConfidence
        case .place: return a.userPlace == b.userPlace && a.userPlaceConfidence == b.userPlaceConfidence
        case .disposition: return a.mediaDisposition == b.mediaDisposition
        case .tags: return a.tags == b.tags
        case .userNotes: return a.userNotes == b.userNotes
        case .people:
            return a.confirmedByUserPeople.map(\.name) == b.confirmedByUserPeople.map(\.name)
                && a.rejectedPeople == b.rejectedPeople
        case .stars: return a.starRating == b.starRating
        case .familyMusic: return Self.musicKey(a) == Self.musicKey(b)
        case .attestations: return a.backupAttestations == b.backupAttestations
        }
    }

    /// The music mark as Rick sees it (performer, title); nil = no mark.
    @MainActor
    private static func musicKey(_ r: VideoRecord) -> [String?]? {
        r.familyMusic.map { [$0.performer, $0.title] }
    }

    /// Put the group back to blank.
    @MainActor
    func clear(_ r: VideoRecord) {
        switch self {
        case .date: r.userDate = nil; r.userDateConfidence = nil
        case .place: r.userPlace = nil; r.userPlaceConfidence = nil
        case .disposition: r.mediaDisposition = .unreviewed
        case .tags: r.tags = []
        case .userNotes: r.userNotes = ""
        case .people: r.confirmedByUserPeople = []; r.rejectedPeople = []
        case .stars: r.starRating = 0
        case .familyMusic: r.familyMusic = nil
        case .attestations: r.backupAttestations = []
        }
    }

    @MainActor
    static func holdsAny(_ r: VideoRecord) -> Bool { allCases.contains { !$0.isBlank(r) } }
}

// MARK: - The note (the carry's stored marker)

/// The Carry line: writing it, finding the active one, marking it undone. Pure.
enum RescanCarryNote {

    /// The File Journey verb (`UserNotesMigration.journeyStampVerbs`, lock-step).
    static let verb = "Carry"
    static let copiedPhrase = "Copied from the earlier file "
    static let earlierPrefix = "Earlier record "

    /// What the Inspector shows and Undo needs from an active Carry line.
    struct Active: Equatable {
        /// The sentence for a person (no stamp, no record id).
        let sentence: String
        let earlierID: UUID
        /// Index of the line in `notes.split(separator: "\n")`.
        let lineIndex: Int
    }

    /// When the carry happened, formatted ONCE per merge (a formatter per row
    /// costs seconds at 100k).
    struct Stamp {
        let iso: String
        let day: String
        init(_ now: Date) {
            iso = ISO8601DateFormatter().string(from: now)
            day = RescanCarryNote.dayText(now)
        }
    }

    static func line(earlierFilename: String, digest: String?, stamp: Stamp) -> (line: String, sentence: String) {
        let sha = digest.map { "SHA-256 \($0.prefix(12))…" } ?? "SHA-256 not computed"
        let sentence = "\(copiedPhrase)\(earlierFilename) (\(sha)) at this path on \(stamp.day); "
            + "review if this is not the same footage."
        return ("\(verb) \(stamp.iso): \(sentence)", sentence)
    }

    static func withEarlierID(_ line: String, _ id: UUID) -> String { "\(line) \(earlierPrefix)\(id.uuidString)." }

    /// The newest Carry line, when it is an active carry (not an undone one).
    static func active(in notes: String) -> Active? {
        let lines = notes.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.lastIndex(where: { isCarryLine($0) }) else { return nil }
        let line = lines[index]
        guard let copied = line.range(of: copiedPhrase), let earlier = line.range(of: earlierPrefix, options: .backwards),
              copied.upperBound <= earlier.lowerBound else { return nil }
        let idText = line[earlier.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard let id = UUID(uuidString: idText) else { return nil }
        let sentence = line[copied.lowerBound..<earlier.lowerBound].trimmingCharacters(in: .whitespaces)
        return Active(sentence: sentence, earlierID: id, lineIndex: index)
    }

    /// `notes` with the active line rewritten as undone (same position).
    static func markingUndone(_ notes: String, _ active: Active, earlierFilename: String, words: String, at now: Date) -> String {
        var lines = notes.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(active.lineIndex) else { return notes }
        lines[active.lineIndex] = "\(verb) \(ISO8601DateFormatter().string(from: now)): Undone — the values copied from "
            + "the earlier file \(earlierFilename) were taken off this record (\(words)); they stay on the earlier record "
            + "in the catalog's history. \(earlierPrefix.lowercased())\(active.earlierID.uuidString)."
        return lines.joined(separator: "\n")
    }

    static func isCarryLine(_ line: Substring) -> Bool {
        line.hasPrefix(verb + " ") && UserNotesMigration.isJourneyStampLine(line)
    }

    static func dayText(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
}

// MARK: - The door

@MainActor
struct RescanCarryWithNote {
    let model: VideoScanModel

    /// GH #478: is the file now at the path NOT the file `old` described?
    /// Definite disagreement only — both whole-file digests known and
    /// different (identity, rule 6; equal digests are the same file whatever
    /// else differs), else a size change with both sizes known, else two
    /// partialMD5s that differ. Either side unknown is "no evidence". Pure.
    nonisolated static func bytesDiffer(oldDigest: String?, freshDigest: String?,
                                        oldSizeBytes: Int64, freshSizeBytes: Int64,
                                        oldPartialMD5: String, freshPartialMD5: String) -> Bool {
        if let oldDigest, let freshDigest { return oldDigest != freshDigest }
        if oldSizeBytes > 0, freshSizeBytes > 0, oldSizeBytes != freshSizeBytes { return true }
        return !oldPartialMD5.isEmpty && !freshPartialMD5.isEmpty && oldPartialMD5 != freshPartialMD5
    }

    /// The size `old`'s bytes are KNOWN to have: a verified fixity's byte count
    /// (archive fixity, then the whole-file hash), else the last scan's stat.
    static func referenceSize(of old: VideoRecord) -> Int64 {
        old.archiveFixity?.sizeBytes ?? old.contentFixity?.byteCount ?? old.sizeBytes
    }

    static func isDifferentFile(_ old: VideoRecord, _ fresh: VideoRecord) -> Bool {
        bytesDiffer(oldDigest: CatalogCommit.digest(of: old), freshDigest: CatalogCommit.digest(of: fresh),
                    oldSizeBytes: referenceSize(of: old), freshSizeBytes: fresh.sizeBytes,
                    oldPartialMD5: old.partialMD5, freshPartialMD5: fresh.partialMD5)
    }

    /// Both merges call this after the live re-read and before their sweep.
    /// Returns the earlier records to KEEP (stamped `replacedAtPath`) and how
    /// many fresh records were carried with a note. `alreadyKept` = the
    /// history rows the merge keeps anyway (never re-judged).
    func carry(root: String, newPaths: Set<String>, fresh: [VideoRecord],
               alreadyKept: Set<ObjectIdentifier>, now: Date = Date()) -> (kept: Set<ObjectIdentifier>, carried: Int) {
        var freshByPath: [String: VideoRecord] = [:]
        freshByPath.reserveCapacity(fresh.count)
        for rec in fresh where freshByPath[rec.fullPath] == nil { freshByPath[rec.fullPath] = rec }
        // Pass 1 decides and notes, pass 2 stamps: a marker change moves the
        // archive-facts generation, so stamping inside pass 1 would rebuild
        // the archived-content index on every twin lookup (O(n²) at 100k).
        var pairs: [(old: VideoRecord, new: VideoRecord)] = []
        for old in model.records where newPaths.contains(old.fullPath) && PathScope.contains(old.fullPath, within: root) {
            guard old.removal == nil, !alreadyKept.contains(ObjectIdentifier(old)),
                  let new = freshByPath[old.fullPath], new !== old,
                  !model.isDateReadOnlyItself(old), RescanCuratedGroup.holdsAny(old),
                  Self.isDifferentFile(old, new) else { continue }
            pairs.append((old, new))
        }
        guard !pairs.isEmpty else { return ([], 0) }
        let stamp = RescanCarryNote.Stamp(now)
        for (old, new) in pairs {
            keepDateAsFiled(on: new, carriedFrom: old)
            let (line, _) = RescanCarryNote.line(earlierFilename: old.filename, digest: CatalogCommit.digest(of: old),
                                                 stamp: stamp)
            new.notes = MachineNote.append(RescanCarryNote.withEarlierID(line, old.id), to: new.notes)
        }
        var kept = Set<ObjectIdentifier>()
        let marker = RemovalMarker.removedFromCatalog(at: now, reason: .replacedAtPath)
        for (old, _) in pairs {
            // Refuse rather than guess (B2.3): when the earlier record's marker
            // cannot be stored first it is NOT kept beside the new row (two live
            // rows at one path); it is replaced as before — its values are on
            // the new record and the note says where they came from.
            if let why = VideoScanModel.stampRemoval(old, marker, kind: .diskFact) {
                model.log("  NOT RECORDED: \(old.filename) holds a different file now, but its earlier record could not be kept "
                          + "as history — \(why). Your values were copied onto the new record with a note.")
                continue
            }
            kept.insert(ObjectIdentifier(old))
        }
        sayCarried(pairs.count, names: pairs.prefix(5).map(\.old.filename), root: root)
        return (kept, pairs.count)
    }

    /// GH #528: a new file that is a copy of ARCHIVED content shows the date
    /// that content was filed under, never the earlier file's (the seam;
    /// the commit refuses it too — this keeps memory honest before then).
    private func keepDateAsFiled(on new: VideoRecord, carriedFrom old: VideoRecord) {
        guard let filed = model.archivedCopyFixingDate(of: new), filed !== new else { return }
        let declined = old.userDate
        new.userDate = filed.userDate
        new.userDateConfidence = filed.userDateConfidence
        ArchivedContentDateRefusal.InferredDate(filed).put(on: new)
        if let declined {
            model.noteDateLeftAsFiled(new, writer: "Rescan", declined: "\(declined) from the earlier file \(old.filename)")
        }
    }

    private func sayCarried(_ count: Int, names: [String], root: String) {
        let more = count > names.count ? " … and \(count - names.count) more" : ""
        let list = names.joined(separator: ", ") + more
        log("  ⚠ \(Self.summary(count)) (\(list))")
        appLog.write("Rescan carry: \(count) re-seen path(s) under \(root) hold a different file (size, fingerprint or "
                     + "SHA-256 changed); Rick's values were copied onto the new record(s) with a provenance note and the "
                     + "earlier record(s) kept as replacedAtPath history: \(list)")
    }

    /// The scan summary's line, in plain words (Rick's wording).
    static func summary(_ count: Int) -> String {
        count == 1
            ? "1 file at a known path had changed; your dates and notes were copied onto it with a note — review it"
            : "\(count) files at known paths had changed; your dates and notes were copied onto them with a note — review them"
    }

    private func log(_ line: String) { model.log(line) }

    // MARK: Undo

    enum UndoOutcome: Equatable {
        /// Nothing was touched; the words say why.
        case refused(String)
        /// `reset` groups put back to blank; `keptYours` left as Rick set them
        /// after the carry; `dateFixed` = the date was left as filed (archived).
        case undone(reset: Int, keptYours: Int, dateFixed: Bool)
    }

    /// "Undo Carry" on `rec`: see the header. One log line; the caller's
    /// debounced save persists it (the CuratedRecordEdits contract).
    @discardableResult
    func undoCarry(on rec: VideoRecord, now: Date = Date()) -> UndoOutcome {
        guard !CuratedEditGuard.refuses("undo carry", model: model) else {
            return .refused("this session is read-only")
        }
        guard let active = RescanCarryNote.active(in: rec.notes) else {
            return .refused("\(rec.filename) has no carry to undo")
        }
        guard let earlier = model.record(forID: active.earlierID), earlier !== rec else {
            let words = "the earlier record (\(active.earlierID.uuidString)) is not in the catalog, so what was copied "
                + "cannot be told apart from your own edits — nothing was changed"
            model.log("Undo Carry: \(rec.filename) — \(words).")
            return .refused(words)
        }
        let dateFixed = model.isDateReadOnly(rec)
        var reset = 0, keptYours = 0
        for group in RescanCuratedGroup.allCases where !group.isBlank(rec) {
            if group == .date && dateFixed { continue }
            if group.same(rec, earlier) { group.clear(rec); reset += 1 } else { keptYours += 1 }
        }
        let words = "\(reset) put back to blank, \(keptYours) you changed since left as you set them"
            + (dateFixed ? ", the date left as filed (archived)" : "")
        rec.notes = RescanCarryNote.markingUndone(rec.notes, active, earlierFilename: earlier.filename, words: words, at: now)
        model.log("Undo Carry: \(rec.filename) — \(words). The earlier record \(earlier.filename) keeps its values in the catalog's history.")
        appLog.write("Undo Carry: record \(rec.id.uuidString) — \(words); earlier record \(earlier.id.uuidString) untouched")
        model.saveCatalogDebounced()
        return .undone(reset: reset, keptYours: keptYours, dateFixed: dateFixed)
    }
}
