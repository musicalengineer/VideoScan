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
//       alreadyBack         a regular file is at the recorded path AND the
//                           live record there has the row's whole-file
//                           SHA-256 (content identity — never the path alone)
//       pathTaken           a regular file is at the recorded path and a
//                           live record has that path, but its stored
//                           SHA-256 is not the row's (or one is missing):
//                           "another catalogued file is at that path"
//       onDiskNotCatalogued a regular file is there; no live record there
//       goneLikelyMoved     lstat says ENOENT / ENOTDIR on a connected drive,
//                           and a live record has the same name and size
//                           (a CANDIDATE only — never shown as "moved")
//       goneNoMatch         the same absence, no name + size lead
//       couldNotCheck       the drive is connected but lstat failed for
//                           another reason (EACCES, EIO…) or found a link,
//                           a folder, a device: "couldn't check (why)"
//       driveNotConnected   the recorded drive is not mounted: nothing is
//                           said about the file (never "gone")
//   * WHICH proof a candidate gets — `HeldBackProver`. The proof binds to
//     the DESTINATION: the candidate's catalog row must have a stored
//     whole-file SHA-256 (else no offer), and every byte of the file read
//     NOW must hash to it (else "not the content its row records", no
//     offer). Then the link to the held-back row: that same digest equal to
//     the row's stored one (proven), else the `v1:` sampled hash read now
//     equal to the row's (LIKELY the same file — the bytes between the
//     samples are not compared, and every word says so); else no offer.
//     Never the path or the name alone.
//   * WHAT may be carried — `HeldBackFields.evaluate`, per field against the
//     CONTENT as it is now (tag, date and place are stored per content and
//     every copy shows them): carry (no copy has one), already (the copies
//     have this value), conflict (a copy has another value — shown, never
//     overwritten), archived (a date never goes on while ANY copy of the
//     content is archived; Update… only). `HeldBackBatch.resolve`: two
//     selected rows offering different values for one content carry
//     neither (batchConflict).
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

/// Live records by path, by name + size and by content. Built once per load / plan.
struct HeldBackLiveIndex: Sendable {
    private(set) var byPath: [String: UUID] = [:]
    private(set) var byNameSize: [String: [HeldBackLive]] = [:]
    private(set) var byID: [UUID: HeldBackLive] = [:]
    private(set) var byDigest: [String: [HeldBackLive]] = [:]

    init(_ live: [HeldBackLive]) {
        for l in live {
            byPath[Self.pathKey(l.fullPath)] = l.id
            byNameSize[Self.nameSizeKey(l.filename, l.sizeBytes), default: []].append(l)
            byID[l.id] = l
            if let d = l.digest { byDigest[d, default: []].append(l) }
        }
    }

    /// The OTHER live copies of `live`'s content (same whole-file digest).
    func copies(of live: HeldBackLive) -> [HeldBackLive] {
        guard let d = live.digest else { return [] }
        return (byDigest[d] ?? []).filter { $0.id != live.id }
    }

    /// One pass over `records` on the main actor: live rows only (no removal
    /// marker). A copy's date is read-only when ANY record of its content is
    /// (removed ones too — the stricter reading): dates are stored per
    /// content, so writing one copy's dates them all (Codex #385 #3).
    @MainActor
    static func project(_ records: [VideoRecord], dateReadOnly: (VideoRecord) -> Bool) -> HeldBackLiveIndex {
        var archived: Set<String> = []
        var live: [HeldBackLive] = []
        live.reserveCapacity(records.count)
        for r in records {
            let readOnly = dateReadOnly(r)
            if readOnly, let d = CatalogCommit.digest(of: r) { archived.insert(d) }
            if r.removal == nil { live.append(HeldBackLive(r, dateReadOnly: readOnly)) }
        }
        for i in live.indices where !live[i].dateReadOnly {
            if let d = live[i].digest, archived.contains(d) { live[i].dateReadOnly = true }
        }
        return HeldBackLiveIndex(live)
    }

    /// Paths compare case-insensitively (APFS / HFS+ default).
    static func pathKey(_ path: String) -> String { path.lowercased() }
    static func nameSizeKey(_ name: String, _ size: Int64) -> String { name.lowercased() + "|" + String(size) }
}

// MARK: - Where the file is now

enum HeldBackWhere: Sendable, Equatable {
    case resolved(note: String)
    case alreadyBack(recordID: UUID)
    /// A live record has the path, but not the row's content (or it cannot be compared).
    case pathTaken(recordID: UUID, candidates: [UUID])
    case onDiskNotCatalogued
    case goneLikelyMoved(candidates: [UUID])
    case goneNoMatch
    /// The drive is connected but the path could not be inspected (the words say why).
    case couldNotCheck(reason: String)
    case driveNotConnected(drive: String)

    var group: HeldBackGroup {
        switch self {
        case .resolved: return .resolved
        case .alreadyBack: return .alreadyBack
        case .pathTaken: return .pathTaken
        case .onDiskNotCatalogued: return .onDiskNotCatalogued
        case .goneLikelyMoved: return .goneLikelyMoved
        case .goneNoMatch: return .goneNoMatch
        case .couldNotCheck: return .couldNotCheck
        case .driveNotConnected: return .driveNotConnected
        }
    }
}

/// The list's groups, in the order the sheet shows them.
enum HeldBackGroup: String, CaseIterable, Sendable, Identifiable {
    case alreadyBack, pathTaken, onDiskNotCatalogued, goneLikelyMoved, goneNoMatch, couldNotCheck, driveNotConnected, resolved
    var id: String { rawValue }

    var title: String {
        switch self {
        case .alreadyBack: return "On disk, and already back in the catalog"
        case .pathTaken: return "On disk — another catalogued file is at that path"
        case .onDiskNotCatalogued: return "On disk, not in the catalog"
        case .goneLikelyMoved: return "Gone from that path — a file with the same name and size is in the catalog"
        case .goneNoMatch: return "Gone from that path — no file with the same name and size"
        case .couldNotCheck: return "Drive connected — couldn't check the path"
        case .driveNotConnected: return "Drive not connected — not checked"
        case .resolved: return "Carried onto a live file (kept as history)"
        }
    }

    /// What the evidence behind the group is, in words (the truth line).
    var evidence: String {
        switch self {
        case .alreadyBack: return "A file exists at the recorded path now, and the live catalog row at that path has this row's whole-file SHA-256."
        case .pathTaken: return "A file exists at the recorded path now and a live catalog row has that path, but its stored SHA-256 is not this row's (or one of them has none), so it is not called the same file. Find Moved Copies checks same-name, same-size files by content."
        case .onDiskNotCatalogued: return "A file exists at the recorded path now; no live catalog row has that path."
        case .goneLikelyMoved: return "Nothing at the recorded path now (its drive is connected). Same name and size is a lead, not proof — Find Moved Copies checks the content."
        case .goneNoMatch: return "Nothing at the recorded path now (its drive is connected)."
        case .couldNotCheck: return "The drive is connected, but the recorded path could not be checked (each row says why), so nothing is said about the file."
        case .driveNotConnected: return "The drive the path names is not mounted, so nothing is said about the file."
        case .resolved: return "You confirmed a carry; the row stays in the catalog as history."
        }
    }
}

/// What one `lstat` of a recorded path found (Codex #385 #8: only ENOENT /
/// ENOTDIR is absence; every other failure, and anything but a regular
/// file, is "couldn't check").
enum HeldBackProbe: Sendable, Equatable {
    case regularFile
    case absent
    case notRegular(String)
    case couldNotCheck(String)

    /// The one live probe: `lstat` (links are never followed).
    static func lstatPath(_ path: String) -> HeldBackProbe {
        var info = stat()
        if lstat(path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFREG: return .regularFile
            case S_IFLNK: return .notRegular("a symbolic link is at that path (links are not followed)")
            case S_IFDIR: return .notRegular("a folder is at that path")
            default: return .notRegular("something other than a regular file is at that path")
            }
        }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return .absent }
        return .couldNotCheck("\(String(cString: strerror(code))) (errno \(code))")
    }
}

/// How the plan looks at the disk (tests inject invented answers).
struct HeldBackDisk: Sendable {
    /// True when the volume holding `path` is mounted (never "file exists").
    var driveOnline: @Sendable (String) -> Bool
    /// What is at `path` (lstat; links refused).
    var probe: @Sendable (String) -> HeldBackProbe

    static let live = HeldBackDisk(
        driveOnline: { VolumeReachability.isVolumeReachable(path: $0) },
        probe: { HeldBackProbe.lstatPath($0) })
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
        switch disk.probe(row.fullPath) {
        case .notRegular(let why), .couldNotCheck(let why):
            return .couldNotCheck(reason: why)
        case .regularFile:
            guard let id = live.byPath[HeldBackLiveIndex.pathKey(row.fullPath)] else { return .onDiskNotCatalogued }
            if let occupant = live.byID[id], sameContent(row.digest, occupant.digest) { return .alreadyBack(recordID: id) }
            return .pathTaken(recordID: id, candidates: leads(row, live: live))
        case .absent:
            let candidates = leads(row, live: live)
            return candidates.isEmpty ? .goneNoMatch : .goneLikelyMoved(candidates: candidates)
        }
    }

    /// Both are whole-file SHA-256 digests and equal (content identity).
    static func sameContent(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased(),
              CatalogRecordDTO.isWholeFileDigest(a), CatalogRecordDTO.isWholeFileDigest(b) else { return false }
        return a == b
    }

    /// Live records with the row's file name and size (a lead, never proof).
    private static func leads(_ row: CatalogRow.HeldBackRow, live: HeldBackLiveIndex) -> [UUID] {
        let name = (row.fullPath as NSString).lastPathComponent
        guard let size = row.sizeBytes, size > 0 else { return [] }
        return (live.byNameSize[HeldBackLiveIndex.nameSizeKey(name, size)] ?? []).map(\.id)
    }

    /// Entries per group (the sheet's sections), group order kept.
    static func grouped(_ entries: [HeldBackEntry]) -> [(group: HeldBackGroup, entries: [HeldBackEntry])] {
        let by = Dictionary(grouping: entries, by: { $0.whereNow.group })
        return HeldBackGroup.allCases.compactMap { g in by[g].map { (g, $0) } }
    }
}

// MARK: - The proof

/// Which evidence links a live file to a held-back row (the UI names it, rule 1).
enum HeldBackEvidence: String, Sendable, Equatable {
    /// Every byte of the live file read now; equal to the row's stored SHA-256
    /// (and to the live file's own catalog row's).
    case wholeFileSHA256
    /// The `v1:` sampled hash (three 1 MiB windows + size) computed now;
    /// equal to the row's stored one. It can say "different" for sure,
    /// "same" only LIKELY: two files that differ only between the windows
    /// share it (HeldBackReviewTests.sampledCollisionIsReal).
    case sampledHash

    /// The proof line on an offer.
    var words: String {
        switch self {
        case .wholeFileSHA256: return "whole-file SHA-256 (every byte read now) — proven the same content"
        case .sampledHash: return "likely the same file (sampled check) — 3 × 1 MiB + size read now; the bytes between the samples were not compared"
        }
    }

    /// The short form for log lines, the carry lines and the resolution note.
    var label: String {
        switch self {
        case .wholeFileSHA256: return "proven by whole-file SHA-256"
        case .sampledHash: return "likely the same file (sampled check)"
        }
    }
}

enum HeldBackProofResult: Sendable, Equatable {
    /// `stamp`: the live file as it was when proven (the carry re-checks it).
    case proven(HeldBackEvidence, stamp: FileIdentityStamp)
    case differs(HeldBackEvidence)
    /// The live file's catalog row has no whole-file SHA-256: nothing to bind to.
    case noDestinationDigest
    /// Every byte read now does not hash to the live file's own catalog row.
    case notTheRecordedContent
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

    /// The proof, made now. It binds to the DESTINATION first (Codex #385
    /// #1): `destinationDigest` — the live file's catalog row's stored
    /// whole-file SHA-256 — must exist, and every byte at `path` must hash to
    /// it. Only then is the link to the held-back row judged: that digest
    /// equal to the row's (proven), else the sampled hash read now equal to
    /// the row's, between the same stamp (likely). A row digest that is not
    /// the destination's differs without a read.
    func prove(rowDigest: String?, rowSampled: String?, candidatePath path: String, destinationDigest: String?) -> HeldBackProofResult {
        guard let destination = destinationDigest?.lowercased(), CatalogRecordDTO.isWholeFileDigest(destination) else {
            return .noDestinationDigest
        }
        let rowWhole = rowDigest?.lowercased()
        let wholeRow = rowWhole.map(CatalogRecordDTO.isWholeFileDigest) ?? false
        let sampledRow = rowSampled?.hasPrefix("v1:") ?? false
        guard wholeRow || sampledRow else { return .noEvidence }
        if wholeRow, rowWhole != destination { return .differs(.wholeFileSHA256) }
        let fixity: ContentFixity
        switch wholeFile(path) {
        case .fixity(let f): fixity = f
        case .unavailable: return .couldNotRead("the file could not be opened (drive asleep or gone?)")
        case .unreadable: return .couldNotRead("the file could not be read to the end")
        case .changedDuringRead: return .couldNotRead("the file changed while it was read")
        case .cancelled: return .couldNotRead("stopped")
        }
        guard fixity.digest.lowercased() == destination else { return .notTheRecordedContent }
        if wholeRow { return .proven(.wholeFileSHA256, stamp: fixity.stamp) }
        let now = sampled(path)
        guard let stamp = now.stamp, stamp == fixity.stamp, !now.hash.isEmpty else {
            return .couldNotRead("the file could not be read (or changed while it was read)")
        }
        return now.hash == rowSampled ? .proven(.sampledHash, stamp: stamp) : .differs(.sampledHash)
    }
}

// MARK: - What may be carried

/// One field of an offer, judged against the content as it is now.
enum HeldBackFieldOffer: Sendable, Equatable {
    case carry(String)
    case already(String)
    /// A copy of the content has a different value: shown, never overwritten.
    case conflict(old: String, live: String)
    /// A date never goes on while any copy of the content is archived (Update… only).
    case archived(String)
    /// Another selected row offers a different value for the same content:
    /// neither is carried (Codex #385 #4).
    case batchConflict(String, others: [String])

    var carries: Bool { if case .carry = self { return true } else { return false } }
    var isBatchConflict: Bool { if case .batchConflict = self { return true } else { return false } }
}

struct HeldBackFields: Sendable, Equatable {
    var tag: HeldBackFieldOffer?
    var date: HeldBackFieldOffer?
    var place: HeldBackFieldOffer?

    var all: [HeldBackFieldOffer] { [tag, date, place].compactMap { $0 } }
    var carriesAny: Bool { all.contains { $0.carries } }
    var hasBatchConflict: Bool { all.contains { $0.isBatchConflict } }
    /// Nothing left to write, but every value the old row had is already
    /// on the content: confirming only closes the held-back row.
    var allAlready: Bool {
        !all.isEmpty && all.allSatisfy { if case .already = $0 { return true } else { return false } }
    }
    var setsConfirmedJunk: Bool { tag == .carry(MediaDisposition.confirmedJunk.rawValue) }

    /// `copies`: the other live records of the destination's content — they
    /// show the same stored values, so any value on any of them counts as
    /// "set" (never overwritten). `live.dateReadOnly` is content-wide
    /// (HeldBackLiveIndex.project); a copy's flag counts too.
    static func evaluate(old: HeldBackCurated, live: HeldBackLive, copies: [HeldBackLive] = []) -> HeldBackFields {
        var out = HeldBackFields()
        let all = [live] + copies
        if let tag = old.disposition, tag != .unreviewed {
            let mine = live.disposition != .unreviewed ? live.disposition.rawValue : nil
            out.tag = judge(tag.rawValue, mine: mine, values: all.map(\.disposition).filter { $0 != .unreviewed }.map(\.rawValue))
        }
        if let date = old.userDate {
            if all.contains(where: \.dateReadOnly) { out.date = .archived(date) }
            else { out.date = judge(date, mine: live.userDate, values: all.compactMap(\.userDate)) }
        }
        if let place = old.userPlace {
            out.place = judge(place, mine: live.userPlace, values: all.compactMap(\.userPlace))
        }
        return out
    }

    /// carry when no copy has a value; already when every value is `old`;
    /// else conflict, naming the destination's own value (or a copy's).
    private static func judge(_ old: String, mine: String?, values: [String]) -> HeldBackFieldOffer {
        guard !values.isEmpty else { return .carry(old) }
        if values.allSatisfy({ $0 == old }) { return .already(old) }
        return .conflict(old: old, live: mine.flatMap { $0 == old ? nil : $0 } ?? values.first { $0 != old } ?? old)
    }
}

/// Codex #385 #4: the selected rows judged TOGETHER before anything is
/// written. Rows whose destinations share a content (the key: its whole-file
/// digest — tag, date and place are stored per content) and offer DIFFERENT
/// values to carry for one field carry neither: each becomes
/// `.batchConflict` naming the others. Equal values carry once. Pure.
enum HeldBackBatch {
    static func resolve(_ items: [(key: String, fields: HeldBackFields)]) -> [HeldBackFields] {
        var out = items.map(\.fields)
        let paths: [WritableKeyPath<HeldBackFields, HeldBackFieldOffer?>] = [\.tag, \.date, \.place]
        for path in paths {
            var values: [String: Set<String>] = [:]
            for item in items { if case .carry(let v)? = item.fields[keyPath: path] { values[item.key, default: []].insert(v) } }
            for (i, item) in items.enumerated() {
                guard case .carry(let v)? = item.fields[keyPath: path], let all = values[item.key], all.count > 1 else { continue }
                out[i][keyPath: path] = .batchConflict(v, others: all.subtracting([v]).sorted())
            }
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
    /// The live file's catalog row's stored whole-file SHA-256 when the proof
    /// read it (Codex #385 #1): the carry refuses unless the record still
    /// stores exactly this, and the closure checks the store's row too.
    var destinationDigest: String?
    var old: HeldBackCurated
    var fields: HeldBackFields
    /// Why this pair cannot be confirmed (nil = it can).
    var blocked: String?
    var id: String { "\(qid)-\(recordID.uuidString)" }

    var isSelectable: Bool { blocked == nil && (fields.carriesAny || fields.allAlready) }

    /// Build the offer for a proven pair, judged against `live` (and its copies) now.
    static func make(entry: HeldBackEntry, old: HeldBackCurated, live: HeldBackLive, copies: [HeldBackLive] = [],
                     evidence: HeldBackEvidence, stamp: FileIdentityStamp) -> HeldBackOffer {
        HeldBackOffer(qid: entry.qid, recordID: live.id, liveName: live.filename, livePath: live.fullPath,
                      oldName: entry.filename, oldPath: entry.fullPath, evidence: evidence, stamp: stamp,
                      destinationDigest: live.digest, old: old, fields: HeldBackFields(), blocked: nil)
            .rejudged(live: live, copies: copies)
    }

    /// The same pair with its fields judged against `live` as it is now.
    func rejudged(live: HeldBackLive, copies: [HeldBackLive]) -> HeldBackOffer {
        var o = self
        o.fields = HeldBackFields.evaluate(old: old, live: live, copies: copies)
        if destinationDigest == nil { o.blocked = HeldBackWords.needsFullHash }
        else if live.digest != destinationDigest { o.blocked = HeldBackWords.identityChanged }
        else if !o.fields.carriesAny && !o.fields.allAlready { o.blocked = HeldBackWords.onlyConflicts }
        else { o.blocked = nil }
        return o
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

    /// The rows worth proving: gone (or their path taken by other content),
    /// a name+size lead, an old record that reads and carries a tag / date /
    /// place, no integrity finding (the DDL lets only `resolvedByRule` close
    /// those — the row stays as history).
    static func make(entries: [HeldBackEntry], live: HeldBackLiveIndex) -> HeldBackJobPlan {
        var plan = HeldBackJobPlan()
        for e in entries {
            let ids: [UUID]
            switch e.whereNow {
            case .goneLikelyMoved(let c): ids = c
            case .pathTaken(_, let c) where !c.isEmpty: ids = c
            default: continue
            }
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
    static let identityChanged = "the live file's catalog row no longer records the content that was checked — run Find Moved Copies again"
    static let batchOnly = "its values differ from another selected row's for the same content — neither is carried, and the row stays open"

    /// "Held back at import: 2,110 — why"
    static func statusLine(_ open: Int) -> String {
        "\(statusTitle): \(open.formatted()) — why"
    }

    static let statusHelp = "Rows the October import could not vouch for (no full hash, never seen by the check, an integrity finding). Nothing was dropped; Show… lists them, read only, grouped by where each file is now."

    static let sheetLead = "These rows came from the October catalog but could not prove themselves at the import, so they are kept as history and are not records. This list only reads: each group says what was checked. Find Moved Copies looks for a moved copy of a gone file and checks it by content (a whole-file SHA-256 proves it; a sampled check says only likely); then you choose what to carry."

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
        case .archived(let v): return "\(name): \(v) — a copy of this content is archived; its date changes only with Update…"
        case .batchConflict(let v, let others):
            return "\(name): \(v) — another selected row offers \(others.joined(separator: ", ")) for the same content; neither is carried"
        }
    }

    // MARK: Offers (Codex #385 #6: "proven" only when every offer in view is whole-file proven)

    static func offersTitle(_ offers: [HeldBackOffer]) -> String {
        let n = offers.count, sampled = offers.filter { $0.evidence == .sampledHash }.count
        if sampled == 0 { return "Moved copies proven by whole-file SHA-256 — \(n.formatted())" }
        if sampled == n { return "Moved copies, likely the same file (sampled check) — \(n.formatted())" }
        return "Moved copies — \((n - sampled).formatted()) proven by whole-file SHA-256 · \(sampled.formatted()) likely the same file (sampled check)"
    }

    static func offersLead(_ offers: [HeldBackOffer]) -> String {
        let tail = " Tick the ones to carry; nothing is written until you confirm."
        if offers.allSatisfy({ $0.evidence == .wholeFileSHA256 }) {
            return "Each pair below was proven the same content: every byte of the live file was read just now and hashes to the held-back row's SHA-256." + tail
        }
        return "Pairs marked “whole-file SHA-256” were proven the same content, every byte read just now. Pairs marked “likely the same file (sampled check)” "
            + "matched on three 1 MiB samples and the size only — the bytes between the samples were not compared." + tail
    }

    // MARK: Confirmation (Codex #385 #2: what will be written NOW)

    static func confirmTitle(_ p: HeldBackCarryPreview) -> String {
        let n = p.destinationCount
        return "Carry onto \(n) file\(n == 1 ? "" : "s")?"
    }

    /// Shown in the confirmation: the junk warning first, then each pair as it
    /// would be written now (at most `limit` lines; the rest are logged).
    static func confirmMessage(_ p: HeldBackCarryPreview, changed: Bool, limit: Int = 12) -> String {
        var lines: [String] = []
        if changed { lines.append("What would be written changed since you looked — this is what would be written now.") }
        let junk = p.items.filter(\.setsConfirmedJunk).count
        if junk > 0 {
            lines.append("Confirmed Junk will be set on \(junk) file\(junk == 1 ? "" : "s"): Delete Junk may then offer \(junk == 1 ? "it" : "them") for the Trash.")
        }
        for item in p.items.prefix(limit) { lines.append(previewLine(item)) }
        if p.items.count > limit { lines.append("… and \(p.items.count - limit) more (each is named in the log when carried)") }
        lines.append("Nothing you already set is changed, and no date is written while any copy of the content is archived. "
                     + "Each held-back row whose values are then in the catalog is closed and kept as history.")
        return lines.joined(separator: "\n")
    }

    static func previewLine(_ i: HeldBackCarryPreview.Item) -> String {
        if let why = i.skipped { return "\(i.oldName) → \(i.liveName): not carried — \(why)" }
        return "\(i.oldName) → \(i.liveName) [\(i.evidence.label)]: " + HeldBackStore.fieldsLine(i.fields)
            + (i.closesRow ? "" : " — the row stays open")
    }

    static func size(_ bytes: Int64?) -> String {
        bytes.map { Formatting.humanSize($0) } ?? "size unknown"
    }
}
