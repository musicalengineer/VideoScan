// HeldBackPlan.swift — GH #339 (DECISIONS 2026-11-25 evening, item 3): the
// PURE half of "Held back at import". No SwiftUI, no store, no model.
//
// One sentence (Rick's): "show me what the import held back and where those
// files are now; when a moved copy is proven, let me carry my tag, date and
// place onto it."
//
// What it decides, from evidence only (CLAUDE.md rule 1):
//   * WHERE each held-back row's file is now — `classify`:
//       resolved            the row was closed (its note says how)
//       alreadyBack         a stat finds a file at the recorded path AND a
//                           live record sits at that path
//       onDiskNotCatalogued a stat finds the file; no live record there
//       goneLikelyMoved     its drive is connected, the stat finds nothing,
//                           and a live record has the same name and size
//                           (a CANDIDATE only — never shown as "moved")
//       goneNoMatch         its drive is connected, the stat finds nothing,
//                           no live record has its name and size
//       driveNotConnected   the recorded drive is not mounted: nothing is
//                           said about the file (never "gone")
//   * WHICH proof a candidate gets — `HeldBackProver`: whole-file SHA-256 of
//     the candidate read NOW against the row's stored digest; else the `v1:`
//     sampled hash computed NOW against the row's stored one (weaker, and
//     the UI says so); else no proof and no offer. Never the path or the
//     name alone.
//   * WHAT may be carried — `HeldBackFields.evaluate`, per field against the
//     live record AS IT IS NOW: carry (live has none), already (same value),
//     conflict (Rick set something else — shown, never overwritten),
//     archived (a date never goes onto an archived record; Update… only).
//
// Memory (worst case, 100k live records + 2,110 rows): the live index holds
// one `HeldBackLive` per live record (≈ 200 B with its strings ≈ 20 MB) for
// the length of a load or a plan, then it is dropped; each entry ≈ 1 KB.
//
// (For Rick: plain value types and free functions — the "model" in MVC with
// no I/O except through the two probe closures, so tests drive it with
// invented paths.)

import Foundation
import VideoScanCore

// MARK: - The live catalog, projected once

/// One live record, as the plan needs it (a value copy taken on the main actor).
struct HeldBackLive: Sendable, Equatable {
    var id: UUID
    var filename: String
    var sizeBytes: Int64
    var fullPath: String
    /// The record's whole-file SHA-256 (its `files` row identity); nil = it
    /// is still held in pending_rows and cannot be the resolved file.
    var digest: String?
    var disposition: MediaDisposition
    var userDate: String?
    var userDateConfidence: String?
    var userPlace: String?
    var userPlaceConfidence: String?
    /// `VideoScanModel.isDateReadOnly` — archived: no writer but Update… dates it.
    var dateReadOnly: Bool

    @MainActor
    init(_ r: VideoRecord, dateReadOnly: Bool) {
        id = r.id
        filename = r.filename
        sizeBytes = r.sizeBytes
        fullPath = r.fullPath
        digest = CatalogCommit.digest(of: r)
        disposition = r.mediaDisposition
        userDate = r.userDate
        userDateConfidence = r.userDateConfidence
        userPlace = r.userPlace
        userPlaceConfidence = r.userPlaceConfidence
        self.dateReadOnly = dateReadOnly
    }

    init(id: UUID, filename: String, sizeBytes: Int64, fullPath: String, digest: String?,
         disposition: MediaDisposition = .unreviewed, userDate: String? = nil, userDateConfidence: String? = nil,
         userPlace: String? = nil, userPlaceConfidence: String? = nil, dateReadOnly: Bool = false) {
        self.id = id
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.fullPath = fullPath
        self.digest = digest
        self.disposition = disposition
        self.userDate = userDate
        self.userDateConfidence = userDateConfidence
        self.userPlace = userPlace
        self.userPlaceConfidence = userPlaceConfidence
        self.dateReadOnly = dateReadOnly
    }
}

/// Live records by path and by name + size. Built once per load / plan.
struct HeldBackLiveIndex: Sendable {
    private(set) var byPath: [String: UUID] = [:]
    private(set) var byNameSize: [String: [HeldBackLive]] = [:]
    private(set) var byID: [UUID: HeldBackLive] = [:]

    init(_ live: [HeldBackLive]) {
        for l in live {
            byPath[Self.pathKey(l.fullPath)] = l.id
            byNameSize[Self.nameSizeKey(l.filename, l.sizeBytes), default: []].append(l)
            byID[l.id] = l
        }
    }

    /// One pass over `records` on the main actor: live rows only (no removal marker).
    @MainActor
    static func project(_ records: [VideoRecord], dateReadOnly: (VideoRecord) -> Bool) -> HeldBackLiveIndex {
        HeldBackLiveIndex(records.lazy.filter { $0.removal == nil }.map { HeldBackLive($0, dateReadOnly: dateReadOnly($0)) })
    }

    /// Paths compare case-insensitively (APFS / HFS+ default).
    static func pathKey(_ path: String) -> String { path.lowercased() }
    static func nameSizeKey(_ name: String, _ size: Int64) -> String { name.lowercased() + "|" + String(size) }
}

// MARK: - Where the file is now

enum HeldBackWhere: Sendable, Equatable {
    case resolved(note: String)
    case alreadyBack(recordID: UUID)
    case onDiskNotCatalogued
    case goneLikelyMoved(candidates: [UUID])
    case goneNoMatch
    case driveNotConnected(drive: String)

    var group: HeldBackGroup {
        switch self {
        case .resolved: return .resolved
        case .alreadyBack: return .alreadyBack
        case .onDiskNotCatalogued: return .onDiskNotCatalogued
        case .goneLikelyMoved: return .goneLikelyMoved
        case .goneNoMatch: return .goneNoMatch
        case .driveNotConnected: return .driveNotConnected
        }
    }
}

/// The list's groups, in the order the sheet shows them.
enum HeldBackGroup: String, CaseIterable, Sendable, Identifiable {
    case alreadyBack, onDiskNotCatalogued, goneLikelyMoved, goneNoMatch, driveNotConnected, resolved
    var id: String { rawValue }

    var title: String {
        switch self {
        case .alreadyBack: return "On disk, and already back in the catalog"
        case .onDiskNotCatalogued: return "On disk, not in the catalog"
        case .goneLikelyMoved: return "Gone from that path — a file with the same name and size is in the catalog"
        case .goneNoMatch: return "Gone from that path — no file with the same name and size"
        case .driveNotConnected: return "Drive not connected — not checked"
        case .resolved: return "Carried onto a live file (kept as history)"
        }
    }

    /// What the evidence behind the group is, in words (the truth line).
    var evidence: String {
        switch self {
        case .alreadyBack: return "A file exists at the recorded path now, and a live catalog row has that path."
        case .onDiskNotCatalogued: return "A file exists at the recorded path now; no live catalog row has that path."
        case .goneLikelyMoved: return "Nothing at the recorded path now (its drive is connected). Same name and size is a lead, not proof — Find Moved Copies checks the content."
        case .goneNoMatch: return "Nothing at the recorded path now (its drive is connected)."
        case .driveNotConnected: return "The drive the path names is not mounted, so nothing is said about the file."
        case .resolved: return "You confirmed a carry; the row stays in the catalog as history."
        }
    }
}

/// How the plan looks at the disk (tests inject invented answers).
struct HeldBackDisk: Sendable {
    /// True when the volume holding `path` is mounted (never "file exists").
    var driveOnline: @Sendable (String) -> Bool
    /// True when a regular file is at `path` (lstat; links refused).
    var fileExists: @Sendable (String) -> Bool

    static let live = HeldBackDisk(
        driveOnline: { VolumeReachability.isVolumeReachable(path: $0) },
        fileExists: { path in
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        })
}

/// One held-back row, classified, as the list shows it.
struct HeldBackEntry: Sendable, Identifiable, Equatable {
    var qid: Int64
    var reasonCode: String
    var words: String
    var fullPath: String
    var sizeBytes: Int64?
    var digest: String?
    var sampledHash: String?
    var findingsCount: Int
    var curated: HeldBackCurated.Parsed
    var whereNow: HeldBackWhere
    var id: Int64 { qid }

    var filename: String { (fullPath as NSString).lastPathComponent }
    var drive: String { HeldBackWords.drive(of: fullPath) }
    var curatedRead: HeldBackCurated? { if case .read(let c) = curated { return c } else { return nil } }
}

enum HeldBackClassifier {

    /// Every row → its entry. Rows in qid order; the disk is asked once per
    /// open row (a stat), never for a row whose drive is not connected.
    /// O(rows) with O(1) index lookups.
    static func classify(_ rows: [CatalogRow.HeldBackRow], live: HeldBackLiveIndex, disk: HeldBackDisk) -> [HeldBackEntry] {
        rows.map { row in
            HeldBackEntry(qid: row.qid, reasonCode: row.reasonCode, words: row.words, fullPath: row.fullPath,
                          sizeBytes: row.sizeBytes, digest: row.digest, sampledHash: row.sampledHash,
                          findingsCount: row.findingsCount, curated: HeldBackCurated.parse(row.rawRowText),
                          whereNow: whereNow(row, live: live, disk: disk))
        }
    }

    static func whereNow(_ row: CatalogRow.HeldBackRow, live: HeldBackLiveIndex, disk: HeldBackDisk) -> HeldBackWhere {
        if row.isResolved { return .resolved(note: row.resolutionNote ?? row.resolution ?? "resolved") }
        guard disk.driveOnline(row.fullPath) else { return .driveNotConnected(drive: HeldBackWords.drive(of: row.fullPath)) }
        if disk.fileExists(row.fullPath) {
            if let id = live.byPath[HeldBackLiveIndex.pathKey(row.fullPath)] { return .alreadyBack(recordID: id) }
            return .onDiskNotCatalogued
        }
        let name = (row.fullPath as NSString).lastPathComponent
        guard let size = row.sizeBytes, size > 0,
              let candidates = live.byNameSize[HeldBackLiveIndex.nameSizeKey(name, size)], !candidates.isEmpty
        else { return .goneNoMatch }
        return .goneLikelyMoved(candidates: candidates.map(\.id))
    }

    /// Entries per group (the sheet's sections), group order kept.
    static func grouped(_ entries: [HeldBackEntry]) -> [(group: HeldBackGroup, entries: [HeldBackEntry])] {
        let by = Dictionary(grouping: entries, by: { $0.whereNow.group })
        return HeldBackGroup.allCases.compactMap { g in by[g].map { (g, $0) } }
    }
}

// MARK: - The proof

/// Which evidence proved a candidate (the UI names it, rule 1).
enum HeldBackEvidence: String, Sendable, Equatable {
    /// Every byte of the live file read now; equal to the row's stored SHA-256.
    case wholeFileSHA256
    /// The `v1:` sampled hash (three 1 MiB windows + size) computed now;
    /// equal to the row's stored one. Weaker: it can say "different" for
    /// sure, "same" only very likely.
    case sampledHash

    var words: String {
        switch self {
        case .wholeFileSHA256: return "whole-file SHA-256 (every byte read now)"
        case .sampledHash: return "sampled hash (3 × 1 MiB + size, read now) — weaker than a whole-file SHA-256"
        }
    }
}

enum HeldBackProofResult: Sendable, Equatable {
    /// `stamp`: the live file as it was when proven (the carry re-checks it).
    case proven(HeldBackEvidence, stamp: FileIdentityStamp)
    case differs(HeldBackEvidence)
    case noEvidence
    case couldNotRead(String)
}

/// The two reads a proof may make. Live: `SignatureVerification
/// .wholeFileFixity` (stamp before, every byte through a 1 MiB buffer, stamp
/// after) and `FileHasher.segmentedHash` between two stamps.
struct HeldBackProver: Sendable {
    var wholeFile: @Sendable (String) -> SignatureVerification.WholeFileFixity
    var sampled: @Sendable (String) -> (hash: String, stamp: FileIdentityStamp?)

    static func live(shouldCancel: @escaping @Sendable () -> Bool) -> HeldBackProver {
        HeldBackProver(
            wholeFile: { path in
                var hooks = SignatureVerification.Hooks.live
                hooks.shouldCancel = shouldCancel
                return SignatureVerification.wholeFileFixity(path: path, label: "moved copy", hooks: hooks)
            },
            sampled: { path in
                guard let before = FileIdentityStamp.capture(path: path) else { return ("", nil) }
                let hash = FileHasher.segmentedHash(path: path)
                guard let after = FileIdentityStamp.capture(path: path), after == before else { return ("", nil) }
                return (hash, after)
            })
    }

    /// The strongest proof the row's stored evidence allows, made now.
    func prove(rowDigest: String?, rowSampled: String?, candidatePath path: String) -> HeldBackProofResult {
        if let digest = rowDigest?.lowercased(), CatalogRecordDTO.isWholeFileDigest(digest) {
            switch wholeFile(path) {
            case .fixity(let f): return f.digest == digest ? .proven(.wholeFileSHA256, stamp: f.stamp) : .differs(.wholeFileSHA256)
            case .unavailable: return .couldNotRead("the file could not be opened (drive asleep or gone?)")
            case .unreadable: return .couldNotRead("the file could not be read to the end")
            case .changedDuringRead: return .couldNotRead("the file changed while it was read")
            case .cancelled: return .couldNotRead("stopped")
            }
        }
        if let stored = rowSampled, stored.hasPrefix("v1:") {
            let now = sampled(path)
            guard let stamp = now.stamp, !now.hash.isEmpty else { return .couldNotRead("the file could not be read (or changed while it was read)") }
            return now.hash == stored ? .proven(.sampledHash, stamp: stamp) : .differs(.sampledHash)
        }
        return .noEvidence
    }
}

// MARK: - What may be carried

/// One field of an offer, judged against the live record as it is now.
enum HeldBackFieldOffer: Sendable, Equatable {
    case carry(String)
    case already(String)
    /// Rick set a different value on the live record: shown, never overwritten.
    case conflict(old: String, live: String)
    /// A date never goes onto an archived record (only Update… changes it).
    case archived(String)

    var carries: Bool { if case .carry = self { return true } else { return false } }
}

struct HeldBackFields: Sendable, Equatable {
    var tag: HeldBackFieldOffer?
    var date: HeldBackFieldOffer?
    var place: HeldBackFieldOffer?

    var all: [HeldBackFieldOffer] { [tag, date, place].compactMap { $0 } }
    var carriesAny: Bool { all.contains { $0.carries } }
    /// Nothing left to write, but every value the old row had is already
    /// on the live record: confirming only closes the held-back row.
    var allAlready: Bool {
        !all.isEmpty && all.allSatisfy { if case .already = $0 { return true } else { return false } }
    }

    static func evaluate(old: HeldBackCurated, live: HeldBackLive) -> HeldBackFields {
        var out = HeldBackFields()
        if let tag = old.disposition, tag != .unreviewed {
            if live.disposition == .unreviewed { out.tag = .carry(tag.rawValue) }
            else if live.disposition == tag { out.tag = .already(tag.rawValue) }
            else { out.tag = .conflict(old: tag.rawValue, live: live.disposition.rawValue) }
        }
        if let date = old.userDate {
            if live.dateReadOnly { out.date = .archived(date) }
            else if let mine = live.userDate { out.date = mine == date ? .already(date) : .conflict(old: date, live: mine) }
            else { out.date = .carry(date) }
        }
        if let place = old.userPlace {
            if let mine = live.userPlace { out.place = mine == place ? .already(place) : .conflict(old: place, live: mine) }
            else { out.place = .carry(place) }
        }
        return out
    }
}

/// One proven (row, live file) pair Rick may confirm.
struct HeldBackOffer: Sendable, Identifiable, Equatable {
    var qid: Int64
    var recordID: UUID
    var liveName: String
    var livePath: String
    var oldName: String
    var oldPath: String
    var evidence: HeldBackEvidence
    var stamp: FileIdentityStamp
    var old: HeldBackCurated
    var fields: HeldBackFields
    /// Why this pair cannot be confirmed (nil = it can).
    var blocked: String?
    var id: String { "\(qid)-\(recordID.uuidString)" }

    var isSelectable: Bool { blocked == nil && (fields.carriesAny || fields.allAlready) }

    /// Build the offer for a proven pair, judged against `live` now.
    static func make(entry: HeldBackEntry, old: HeldBackCurated, live: HeldBackLive,
                     evidence: HeldBackEvidence, stamp: FileIdentityStamp) -> HeldBackOffer {
        let fields = HeldBackFields.evaluate(old: old, live: live)
        var blocked: String?
        if live.digest == nil { blocked = HeldBackWords.needsFullHash }
        else if !fields.carriesAny && !fields.allAlready { blocked = HeldBackWords.onlyConflicts }
        return HeldBackOffer(qid: entry.qid, recordID: live.id, liveName: live.filename, livePath: live.fullPath,
                             oldName: entry.filename, oldPath: entry.fullPath, evidence: evidence, stamp: stamp,
                             old: old, fields: fields, blocked: blocked)
    }
}

// MARK: - Which rows Find Moved Copies looks at

/// One gone row with its name+size candidates and something to carry.
struct HeldBackProofTask: Sendable, Equatable {
    var entry: HeldBackEntry
    var old: HeldBackCurated
    var candidates: [HeldBackLive]
}

struct HeldBackJobPlan: Sendable, Equatable {
    var tasks: [HeldBackProofTask] = []
    /// Gone-with-candidate rows left out, by reason (counted in the summary).
    var skippedNothingToCarry = 0
    var skippedFinding = 0
    var skippedUnreadable = 0

    var candidateCount: Int { tasks.reduce(0) { $0 + $1.candidates.count } }

    /// The rows worth proving: gone, a name+size lead, an old record that
    /// reads and carries a tag / date / place, no integrity finding (the DDL
    /// lets only `resolvedByRule` close those — the row stays as history).
    static func make(entries: [HeldBackEntry], live: HeldBackLiveIndex) -> HeldBackJobPlan {
        var plan = HeldBackJobPlan()
        for e in entries {
            guard case .goneLikelyMoved(let ids) = e.whereNow else { continue }
            guard let old = e.curatedRead else { plan.skippedUnreadable += 1; continue }
            guard e.findingsCount == 0 else { plan.skippedFinding += 1; continue }
            let carriable = (old.disposition.map { $0 != .unreviewed } ?? false) || old.userDate != nil || old.userPlace != nil
            guard carriable else { plan.skippedNothingToCarry += 1; continue }
            let candidates = ids.compactMap { live.byID[$0] }
            guard !candidates.isEmpty else { continue }
            plan.tasks.append(HeldBackProofTask(entry: e, old: old, candidates: candidates))
        }
        return plan
    }
}

// MARK: - Words

enum HeldBackWords {
    static let statusTitle = "Held back at import"
    static let showButton = "Show…"
    static let sheetTitle = "Held Back at Import"
    static let findButton = "Find Moved Copies"
    static let jobTitle = "Find Moved Copies"
    static let carryButton = "Carry Selected…"
    static let needsFullHash = "the live file has no full SHA-256 yet, so its catalog row cannot hold the link — run Content Analysis ▸ Full Hashes, then Find Moved Copies again"
    static let onlyConflicts = "every value differs from what you already set on the live file — nothing is overwritten"

    /// "Held back at import: 2,110 — why"
    static func statusLine(_ open: Int) -> String {
        "\(statusTitle): \(open.formatted()) — why"
    }

    static let statusHelp = "Rows the October import could not vouch for (no full hash, never seen by the check, an integrity finding). Nothing was dropped; Show… lists them, read only, grouped by where each file is now."

    static let sheetLead = "These rows came from the October catalog but could not prove themselves at the import, so they are kept as history and are not records. This list only reads: each group says what was checked. Find Moved Copies looks for a moved copy of a gone file and proves it by content; then you choose what to carry."

    /// The drive a recorded path names ("/Volumes/X/…" → X).
    static func drive(of path: String) -> String {
        let parts = (path as NSString).pathComponents
        if parts.count >= 3, parts[1] == "Volumes" { return parts[2] }
        return "this Mac"
    }

    static func reason(_ code: String) -> String {
        switch code {
        case "removedNoDigest": return "removed from the catalog earlier, never fully hashed"
        case "auditNeverSeen": return "the October check never saw the file"
        case "auditCouldNotCheck": return "the October check could not read the file"
        case "auditChanged": return "the file changed after it was hashed"
        case "auditGone": return "the October check found the file gone"
        case "tier5Finding": return "an integrity finding at the import"
        case "noWholeFileDigest": return "no full hash at the import"
        case "referenceMovie": return "a reference movie (its media is in other files)"
        case "fixityDisagree": return "its two stored hashes disagree"
        case "duplicateId": return "two rows shared one id"
        default: return code
        }
    }

    /// "Important · 1992-06 · Cape Cod · ★2 · notes · 2 tags" (what it carried).
    static func curated(_ parsed: HeldBackCurated.Parsed) -> String {
        guard case .read(let c) = parsed else {
            if case .unreadable(let why) = parsed { return "the old record could not be read — \(why)" }
            return ""
        }
        var parts: [String] = []
        if let d = c.disposition, d != .unreviewed { parts.append(d.rawValue) }
        if let date = c.userDate { parts.append(date) }
        if let place = c.userPlace { parts.append(place) }
        if c.starRating > 0 { parts.append("★\(c.starRating)") }
        if c.hasUserNotes { parts.append("notes") }
        if c.tagCount > 0 { parts.append("\(c.tagCount) tag\(c.tagCount == 1 ? "" : "s")") }
        if !c.problems.isEmpty { parts.append("unreadable: " + c.problems.joined(separator: "; ")) }
        return parts.isEmpty ? "nothing curated" : parts.joined(separator: " · ")
    }

    static func field(_ name: String, _ f: HeldBackFieldOffer?) -> String? {
        guard let f else { return nil }
        switch f {
        case .carry(let v): return "\(name): \(v) → will be set"
        case .already(let v): return "\(name): \(v) — already on the live file"
        case .conflict(let old, let live): return "\(name): old \(old), yours \(live) — differs; yours is kept"
        case .archived(let v): return "\(name): \(v) — the live file is archived; change its date with Update…"
        }
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { Formatting.humanSize($0) } ?? "size unknown"
    }
}
