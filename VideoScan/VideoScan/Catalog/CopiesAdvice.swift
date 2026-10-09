// CopiesAdvice.swift
// "Copies & Advice…" — one file, fully explained (Rick 2026-10-09; design
// docs/design/triage_delete_streamline_2026_10_09.md §10).
//
// Rick: "Right-click one file in Triage and see, on one card, how many
// copies exist, which one is kept and why, whether the archive has it, what
// other footage is the same event, and why it was flagged, so I can delete
// with confidence."
//
// SHAPE. This file is the PURE half: Sendable values in, one `CopiesAdvice`
// value out, no SwiftUI, no model, no disk. The main actor projects the
// record and its group into a `CopiesAdviceInput` (CopiesAdvice+Projection
// .swift, O(group) plus one id-compare pass); `CopiesAdviceDisk.gather`
// asks the disk (one stat per copy, no reads) off the main actor; then
// `CopiesAdviceAssessor.assess` decides. Every step is table-testable.
//
// NO NEW ANALYSIS. The card re-uses the engines that already exist:
//   exact copies ........ the duplicate engine's groups (duplicateGroupID)
//                         + the archive's promote link / digest index
//                         (VideoScanModel.archivedCopy(of:))
//   same bytes, proven .. whole-file sha256 (ContentFixity, current by
//                         `describesFileNow`; ArchiveFixity for the archive)
//   same bytes, sampled . the segmented signature (contentHash) or the
//                         head+tail hash + size (partialMD5) — never proof
//   keeper + why ........ DuplicateKeeperPolicy.ElectionKey (the election
//                         DuplicateDetector.electKeeper runs) and
//                         StewardKeeperReason.words (the steward's wording)
//   same footage ........ FootageMembership (Find Similar Footage)
//   why flagged ......... mediaDisposition + junkReasons, the duplicate
//                         engine's disposition, and the Content Steward's
//                         live cases
//
// READ-ONLY. Nothing here moves, deletes or writes anything. The card's one
// delete button hands the record to the existing ⌘⌫ routine
// (VideoScanModel.trashSelectedRecords) with its refusals, and only after
// this advice has been re-derived at click time and still says Safe.
//
// (For Rick: the rule list is an enum whose CASE ORDER is the spec — the
// first case that answers wins, like a C++ chain of early returns written
// as a table you can read top to bottom. `Sendable` ≈ "safe to hand to
// another thread by value".)

import Foundation
import VideoScanCore

// MARK: - Input (projected on the main actor)

/// One copy of the file as the card sees it — a value, so it can leave the
/// main actor. Built from a `VideoRecord` by CopiesAdvice+Projection.
struct CopiesAdviceCandidate: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    /// The drive's display name ("LaCie_8TB").
    var volume: String
    var sizeBytes: Int64
    /// A file of the Master Archive (a promoted copy, or inside its tree).
    var isArchiveCopy: Bool
    /// The archive's verified full-file sha256 (lowercase), archive copies only.
    var archiveDigest: String?
    /// When that digest was last verified (Promote's read-back / Verify Copies).
    var archiveCheckedAt: Date?
    /// The stored whole-file digest, if any; it counts only while it still
    /// describes the file on disk (`CopiesAdviceDisk.currentDigests`).
    var contentFixity: ContentFixity?
    /// Segmented signature ("v1:…"); "" = not computed.
    var contentHash: String
    /// Head+tail hash; "" = not computed.
    var partialMD5: String
    /// The keeper election's key for this copy (DuplicateKeeperPolicy).
    var electionKey: DuplicateKeeperPolicy.ElectionKey
}

/// One member of the file's footage group (not the same bytes).
struct CopiesAdviceFootageMember: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    /// "re-encode", "access copy", "possible copy"…
    var role: String
    /// "HEVC · 1:12:04 · Likely — same name + length as …"
    var detail: String
}

/// How current a piece of knowledge is. The card never guesses: it says
/// "as of <time>" or "not computed yet — Refresh".
enum CopiesFreshness: Sendable, Equatable {
    case notComputed
    case asOf(Date)
    /// Computed, but something it depends on has changed since (the drive
    /// order for keepers).
    case outOfDate(Date)

    var needsRefresh: Bool {
        switch self {
        case .asOf: return false
        case .notComputed, .outOfDate: return true
        }
    }

    /// "Copies as of 9 Oct 2026 at 14:02" / "Copies: not computed yet — Refresh".
    func line(_ subject: String) -> String {
        switch self {
        case .notComputed:
            return "\(subject): not computed yet — Refresh"
        case .asOf(let d):
            return "\(subject) as of \(Self.when(d))"
        case .outOfDate(let d):
            return "\(subject) as of \(Self.when(d)) — the drive order has changed since; Refresh"
        }
    }

    static func when(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
}

/// What the main actor hands the off-main assessor.
struct CopiesAdviceInput: Sendable {
    struct Header: Sendable, Equatable {
        var filename: String
        var size: String
        var codec: String
        var duration: String

        /// "Brockton_Xmas_1994.mov · 41 GB · DNXHD · 1:12:04"
        var line: String { [filename, size, codec, duration].filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    var header: Header
    var this: CopiesAdviceCandidate
    /// Every other record the duplicate engine or the archive link puts
    /// beside this one. The assessor decides which are the same bytes.
    var others: [CopiesAdviceCandidate]
    /// The footage group, likely original first (this file excluded).
    var footage: [CopiesAdviceFootageMember]
    /// Why the ⌘⌫ routine would leave this file alone, worded ("lives on
    /// SanDisk, which you marked Read only"), or nil.
    var hold: String?
    var duplicates: CopiesFreshness
    var footageFreshness: CopiesFreshness
    /// "Why it was flagged", already worded (CopiesAdviceWhy).
    var flagged: [String]
}

// MARK: - Disk facts (off the main actor)

/// What one stat per copy says. No file is read.
struct CopiesAdviceDisk: Sendable, Equatable {
    enum Presence: Sendable, Equatable {
        case present
        /// The drive is connected but the file is not at its path.
        case fileMissing
        /// The drive is not connected.
        case driveAway
    }

    var presence: [UUID: Presence] = [:]
    /// Device + inode now — two paths with the same identity are ONE file.
    var identity: [UUID: FileIdentityStamp] = [:]
    /// Copies whose stored ContentFixity still describes the file
    /// (`ContentFixity.describesFileNow`).
    var currentDigests: Set<UUID> = []

    func presence(of id: UUID) -> Presence { presence[id] ?? .driveAway }

    /// One `FileIdentityStamp.capture` per copy (O_NONBLOCK open + fstat;
    /// a drive that is away fails fast with ENOENT). Worst case O(group)
    /// stats; memory is three small dictionaries per group.
    nonisolated static func gather(_ input: CopiesAdviceInput) -> CopiesAdviceDisk {
        var disk = CopiesAdviceDisk()
        for c in [input.this] + input.others {
            if Task.isCancelled { break }
            guard let stamp = FileIdentityStamp.capture(path: c.fullPath) else {
                disk.presence[c.id] = driveIsConnected(forPath: c.fullPath) ? .fileMissing : .driveAway
                continue
            }
            disk.presence[c.id] = .present
            disk.identity[c.id] = stamp
            if let f = c.contentFixity, f.describesFileNow(stamp) { disk.currentDigests.insert(c.id) }
        }
        return disk
    }

    /// "/Volumes/X/…" is on a connected drive when /Volumes/X exists;
    /// anything else (the boot drive, a home folder) always is.
    nonisolated static func driveIsConnected(forPath path: String) -> Bool {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 3, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }
}

// MARK: - Output

/// How strongly a listed copy is known to hold THIS file's bytes.
enum CopiesMatch: Sendable, Equatable {
    /// Whole-file sha256 on both sides, each still describing its file.
    case verified
    /// A sampled signature only (segmented hash, or head+tail hash + size).
    case sampled
}

/// One line of EXACT COPIES.
struct CopiesAdviceRow: Sendable, Equatable, Identifiable {
    enum Fate: Sendable, Equatable {
        case keeps
        case canGo
        /// Stays, and why ("archive copy", "drive not connected").
        case stays(String)
        /// Matches by sample only — check before letting it go.
        case checkFirst
    }

    var id: UUID
    var filename: String
    var fullPath: String
    var volume: String
    var sizeBytes: Int64
    var isThis: Bool
    var presence: CopiesAdviceDisk.Presence
    var isRetired: Bool
    var isArchiveCopy: Bool
    /// nil for THIS file.
    var match: CopiesMatch?
    /// "fixity checked 2 Oct 2026" / "full-file digest 2 Oct 2026", or nil.
    var fixity: String?
    var fate: Fate

    /// What it means for THIS file not to be on disk: not found where the
    /// catalog says → check first; its drive away → connect it. nil when present.
    var absenceVerdict: CopiesAdviceVerdict? {
        switch presence {
        case .present: return nil
        case .fileMissing: return .checkFirst(.notFound)
        case .driveAway: return .connect(volume)
        }
    }
}

/// The ONE plain sentence at the top of the card.
enum CopiesAdviceVerdict: Sendable, Equatable {
    enum Tone: Sendable, Equatable { case safe, keep, attention }
    enum CheckReason: Sendable, Equatable { case sampleOnly, notFound }

    case safe(String)
    case keepArchiveCopy
    /// The ⌘⌫ routine would leave it alone (a drive marked Read only, the
    /// archive's drive, half of a recovered A/V pair) — the reason.
    case keepHeld(String)
    /// `known` = the duplicate engine has looked at this file.
    case keepOnlyCopy(known: Bool)
    /// This file IS the copy the keeper election keeps — the reason.
    case keepKeeper(String)
    case checkFirst(CheckReason)
    case connect(String)

    var sentence: String {
        switch self {
        case .safe(let why): return "Safe to move to Trash — \(why)"
        case .keepArchiveCopy: return "Keep — this is the archive copy"
        case .keepHeld(let why): return "Keep — this file \(why)"
        case .keepOnlyCopy(let known):
            return known ? "Keep — this is the only copy"
                         : "Keep — this is the only copy we know of; copies have not been checked yet"
        case .keepKeeper(let why): return "Keep — this is the copy to keep. \(why)"
        case .checkFirst(.sampleOnly): return "Check first — the copies match by sample only"
        case .checkFirst(.notFound): return "Check first — this file is not where the catalog says it is"
        case .connect(let volume): return "Connect \(volume) to decide"
        }
    }

    var tone: Tone {
        switch self {
        case .safe: return .safe
        case .keepArchiveCopy, .keepHeld, .keepOnlyCopy, .keepKeeper: return .keep
        case .checkFirst, .connect: return .attention
        }
    }

    /// The card offers "Move This Copy to Trash…" for Safe ONLY.
    var offersTrash: Bool { tone == .safe }
}

/// The card.
struct CopiesAdvice: Sendable, Equatable {
    var recordID: UUID
    var header: CopiesAdviceInput.Header
    var verdict: CopiesAdviceVerdict
    /// The rule that answered (tests, the log line).
    var rule: CopiesAdviceRule
    var keeperID: UUID
    var keeperReason: String
    /// Keeper first, then this file, then the rest by drive.
    var rows: [CopiesAdviceRow]
    /// Extra lines under EXACT COPIES (another name for the same file…).
    var notes: [String]
    var sameFootage: [CopiesAdviceFootageMember]
    /// Same-footage members beyond `CopiesAdviceAssessor.maxFootageRows`.
    var sameFootageHidden: Int
    var duplicates: CopiesFreshness
    var footageFreshness: CopiesFreshness
    var flagged: [String]

    var offersTrash: Bool { verdict.offersTrash }
    /// Copies in all, this one included.
    var copyCount: Int { rows.count }
}

// MARK: - The rules (ORDER IS THE SPEC — safety first)

/// What the rules read: the decided rows and a few facts about them.
struct CopiesAdviceFacts: Sendable {
    var this: CopiesAdviceRow
    /// The exact copies, this file excluded.
    var copies: [CopiesAdviceRow]
    var keeper: CopiesAdviceRow
    var keeperReason: String
    var hold: String?
    var duplicatesKnown: Bool
    /// A drive that is not connected and holds a copy the election would
    /// rank ABOVE the keeper it can see — the decision waits for it.
    var decidingDriveAway: String?

    var keeperIsThis: Bool { keeper.id == this.id }
    /// A keeper is only proof while it is on disk AND proven the same bytes;
    /// anything less is "check first", never "safe".
    var keeperIsProof: Bool { keeper.match == .verified && keeper.presence == .present }
}

/// The ordered rule list. `CaseIterable` order = evaluation order: the
/// first rule that answers decides. The archive copy, a held file and the
/// only copy come before anything that could say "Safe".
enum CopiesAdviceRule: String, CaseIterable, Sendable {
    case archiveCopy
    case held
    /// This file is not on disk: not found → check first; drive away → connect.
    case thisUnreachable
    case onlyCopy
    case decidingDriveAway
    case thisIsKeeper
    case sampleOnly
    case safe

    func verdict(_ f: CopiesAdviceFacts) -> CopiesAdviceVerdict? {
        switch self {
        case .archiveCopy: return f.this.isArchiveCopy ? .keepArchiveCopy : nil
        case .held: return f.hold.map { .keepHeld($0) }
        case .thisUnreachable: return f.this.absenceVerdict
        case .onlyCopy: return f.copies.isEmpty ? .keepOnlyCopy(known: f.duplicatesKnown) : nil
        case .decidingDriveAway: return f.decidingDriveAway.map { .connect($0) }
        case .thisIsKeeper: return f.keeperIsThis ? .keepKeeper(f.keeperReason) : nil
        case .sampleOnly: return f.keeperIsProof ? nil : .checkFirst(.sampleOnly)
        case .safe: return .safe(CopiesAdviceAssessor.safeReason(keeper: f.keeper, copies: f.copies))
        }
    }

    /// The first rule that answers. `.safe` always answers, so this never
    /// falls through.
    static func decide(_ f: CopiesAdviceFacts) -> (rule: CopiesAdviceRule, verdict: CopiesAdviceVerdict) {
        for rule in allCases {
            if let v = rule.verdict(f) { return (rule, v) }
        }
        return (.safe, .safe(CopiesAdviceAssessor.safeReason(keeper: f.keeper, copies: f.copies)))
    }
}

// MARK: - Assessor

enum CopiesAdviceAssessor {

    /// SAME FOOTAGE rows shown on the card; the rest are counted.
    static let maxFootageRows = 50

    /// What a listed record is to THIS file.
    enum Pairing: Sendable, Equatable {
        case copy(CopiesMatch)
        /// Stored evidence says the bytes differ.
        case differentBytes
        /// Another path to the very same file (hard link, alias).
        case sameFile
        /// Grouped by name / length / timecode only — not checked.
        case unproven
    }

    // MARK: Entry points

    /// Off the main actor: ask the disk, then decide. (`@concurrent` ≈
    /// "really run on a worker thread"; under approachable concurrency a
    /// plain nonisolated async func would run on the caller's actor.)
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func assessOffMain(_ input: CopiesAdviceInput) async -> CopiesAdvice {
        assess(input, disk: CopiesAdviceDisk.gather(input))
    }

    /// Pure: the card for `input` given what the disk said.
    nonisolated static func assess(_ input: CopiesAdviceInput, disk: CopiesAdviceDisk) -> CopiesAdvice {
        let sorted = sortOthers(input, disk: disk)
        let exact = sorted.copies
        let election = elect(this: input.this, copies: exact.map(\.candidate), disk: disk)
        let keeperID = election.keeper.id

        var copyRows = exact.map { row($0.candidate, match: $0.match, disk: disk, isThis: false, keeperID: keeperID) }
        var thisRow = row(input.this, match: nil, disk: disk, isThis: true, keeperID: keeperID)
        let keeperRow = keeperID == input.this.id ? thisRow : (copyRows.first { $0.id == keeperID } ?? thisRow)

        let facts = CopiesAdviceFacts(
            this: thisRow, copies: copyRows, keeper: keeperRow, keeperReason: election.reason,
            hold: input.hold, duplicatesKnown: input.duplicates != .notComputed,
            decidingDriveAway: decidingDriveAway(this: input.this, keeper: election.keeper,
                                                 copies: exact.map(\.candidate), disk: disk))
        let decision = CopiesAdviceRule.decide(facts)
        // THIS file's fate is the advice's, unless it is the keeper.
        if keeperID != input.this.id {
            thisRow.fate = decision.verdict.offersTrash ? .canGo : .stays("")
        }
        copyRows.sort { ($0.fate == .keeps ? 0 : 1, $0.volume, $0.fullPath) < ($1.fate == .keeps ? 0 : 1, $1.volume, $1.fullPath) }
        let rows = keeperID == input.this.id ? [thisRow] + copyRows
                                              : Array(copyRows.prefix(1)) + [thisRow] + copyRows.dropFirst()
        let footage = sameFootage(input.footage, possible: sorted.possible, excluding: Set(rows.map(\.id)))
        return CopiesAdvice(
            recordID: input.this.id, header: input.header, verdict: decision.verdict, rule: decision.rule,
            keeperID: keeperID, keeperReason: election.reason, rows: rows, notes: sorted.notes,
            sameFootage: Array(footage.prefix(maxFootageRows)),
            sameFootageHidden: max(0, footage.count - maxFootageRows),
            duplicates: input.duplicates, footageFreshness: input.footageFreshness, flagged: input.flagged)
    }

    // MARK: Pairing (what a listed record is to this file)

    /// Proof first (whole-file digests), then the sampled signatures.
    nonisolated static func pairing(_ c: CopiesAdviceCandidate, with t: CopiesAdviceCandidate,
                                    disk: CopiesAdviceDisk) -> Pairing {
        if let a = disk.identity[c.id], let b = disk.identity[t.id], a.device == b.device, a.inode == b.inode {
            return .sameFile
        }
        if let proof = digestPairing(c, t, disk: disk) { return proof }
        return signaturePairing(c, t)
    }

    /// The whole-file digest each side can stand behind right now: the
    /// archive's verified digest for an archive file (read-only, fixity
    /// checked), else a stored ContentFixity that still describes the file.
    nonisolated static func provenDigest(_ c: CopiesAdviceCandidate, disk: CopiesAdviceDisk) -> String? {
        if c.isArchiveCopy, let a = c.archiveDigest { return a.lowercased() }
        guard let f = c.contentFixity, disk.currentDigests.contains(c.id) else { return nil }
        return f.digest.lowercased()
    }

    /// The digest stored for a copy, current or not (a copy on a drive that
    /// is away cannot be stat'ed, so its digest cannot be confirmed).
    nonisolated static func storedDigest(_ c: CopiesAdviceCandidate) -> String? {
        (c.archiveDigest ?? c.contentFixity?.digest)?.lowercased()
    }

    /// Both sides proven: equal = verified, different = different bytes.
    /// Stored digests that agree but cannot both be confirmed now (a drive
    /// is away, a file changed since) are a likely copy — sampled, never
    /// proof. nil when the digests cannot say.
    nonisolated static func digestPairing(_ c: CopiesAdviceCandidate, _ t: CopiesAdviceCandidate,
                                          disk: CopiesAdviceDisk) -> Pairing? {
        if let a = provenDigest(c, disk: disk), let b = provenDigest(t, disk: disk) {
            return a == b ? .copy(.verified) : .differentBytes
        }
        if let a = storedDigest(c), let b = storedDigest(t), a == b { return .copy(.sampled) }
        return nil
    }

    /// Sampled signatures: the segmented hash first, then head+tail + size.
    /// A signature that DIFFERS proves different bytes; one that matches
    /// proves nothing beyond "likely".
    nonisolated static func signaturePairing(_ c: CopiesAdviceCandidate, _ t: CopiesAdviceCandidate) -> Pairing {
        if !c.contentHash.isEmpty, !t.contentHash.isEmpty {
            return c.contentHash == t.contentHash ? .copy(.sampled) : .differentBytes
        }
        guard !c.partialMD5.isEmpty, !t.partialMD5.isEmpty else { return .unproven }
        return c.partialMD5 == t.partialMD5 && c.sizeBytes == t.sizeBytes ? .copy(.sampled) : .differentBytes
    }

    /// The listed records, sorted into exact copies, possible copies (for
    /// SAME FOOTAGE) and notes.
    struct Sorted: Sendable {
        var copies: [(candidate: CopiesAdviceCandidate, match: CopiesMatch)] = []
        var possible: [CopiesAdviceFootageMember] = []
        var notes: [String] = []
    }

    nonisolated static func sortOthers(_ input: CopiesAdviceInput, disk: CopiesAdviceDisk) -> Sorted {
        var out = Sorted()
        for c in input.others where c.id != input.this.id {
            switch pairing(c, with: input.this, disk: disk) {
            case .copy(let m):
                out.copies.append((c, m))
            case .sameFile:
                out.notes.append("\(c.filename) on \(c.volume) is another name for this same file, not a second copy.")
            case .differentBytes:
                out.possible.append(possibleCopy(c, why: "same name and length, but the bytes differ"))
            case .unproven:
                out.possible.append(possibleCopy(c, why: "matched by name and length only — not checked byte for byte"))
            }
        }
        return out
    }

    nonisolated static func possibleCopy(_ c: CopiesAdviceCandidate, why: String) -> CopiesAdviceFootageMember {
        CopiesAdviceFootageMember(id: c.id, filename: c.filename, fullPath: c.fullPath,
                                  role: "possible copy", detail: "\(c.volume) — \(why)")
    }

    // MARK: Keeper (the duplicate engine's election, availability from the disk)

    /// The election key with availability as the disk says it is NOW:
    /// retired stays 0 (policy), else present 2 · drive away 1 · missing 0.
    /// The rest of the key (precedence › your marks › quality › path) is the
    /// policy's own, so the keeper here is the one DuplicateDetector would
    /// elect among these copies with the drives as they are.
    nonisolated static func liveKey(_ c: CopiesAdviceCandidate, disk: CopiesAdviceDisk) -> DuplicateKeeperPolicy.ElectionKey {
        let k = c.electionKey
        let availability: Int
        if k.availability == 0 {
            availability = 0
        } else {
            switch disk.presence(of: c.id) {
            case .present: availability = 2
            case .driveAway: availability = 1
            case .fileMissing: availability = 0
            }
        }
        return DuplicateKeeperPolicy.ElectionKey(availability: availability, precedence: k.precedence,
                                                 humanMetadata: k.humanMetadata, technical: k.technical,
                                                 path: k.path)
    }

    /// Keeper = lexicographic max of the live keys (DuplicateDetector
    /// .electKeeper's rule) among this file and its exact copies; the reason
    /// in the steward's words.
    nonisolated static func elect(this: CopiesAdviceCandidate, copies: [CopiesAdviceCandidate],
                                  disk: CopiesAdviceDisk) -> (keeper: CopiesAdviceCandidate, reason: String) {
        let all = [this] + copies
        let keyed = all.map { (c: $0, k: liveKey($0, disk: disk)) }
        let best = keyed.dropFirst().reduce(keyed[0]) { $1.k > $0.k ? $1 : $0 }
        let reason = StewardKeeperReason.words(keeper: best.k,
                                               others: keyed.filter { $0.c.id != best.c.id }.map(\.k),
                                               keeperDrive: best.c.volume,
                                               keeperIsInArchive: best.c.isArchiveCopy)
        return (best.c, reason)
    }

    /// The drive the decision waits for: the keeper's, when it is away; or,
    /// when this file is the keeper only because better-ranked copies are
    /// away, the best of those drives (by the policy's own precedence).
    nonisolated static func decidingDriveAway(this: CopiesAdviceCandidate, keeper: CopiesAdviceCandidate,
                                              copies: [CopiesAdviceCandidate], disk: CopiesAdviceDisk) -> String? {
        if keeper.id != this.id {
            return disk.presence(of: keeper.id) == .driveAway ? keeper.volume : nil
        }
        let outranking = copies.filter {
            disk.presence(of: $0.id) == .driveAway && $0.electionKey.availability > 0
                && $0.electionKey.precedence > this.electionKey.precedence
        }
        return outranking.max { $0.electionKey.precedence < $1.electionKey.precedence }?.volume
    }

    // MARK: Rows

    nonisolated static func row(_ c: CopiesAdviceCandidate, match: CopiesMatch?, disk: CopiesAdviceDisk,
                                isThis: Bool, keeperID: UUID) -> CopiesAdviceRow {
        var r = CopiesAdviceRow(id: c.id, filename: c.filename, fullPath: c.fullPath, volume: c.volume,
                                sizeBytes: c.sizeBytes, isThis: isThis, presence: disk.presence(of: c.id),
                                isRetired: c.electionKey.availability == 0, isArchiveCopy: c.isArchiveCopy,
                                match: match, fixity: fixityLine(c, disk: disk), fate: .keeps)
        r.fate = fate(of: r, keeperID: keeperID)
        return r
    }

    /// What happens to a listed copy (THIS file's own fate follows the
    /// advice and is set by `assess`).
    nonisolated static func fate(of r: CopiesAdviceRow, keeperID: UUID) -> CopiesAdviceRow.Fate {
        if r.id == keeperID { return .keeps }
        if r.isArchiveCopy { return .stays("archive copy") }
        switch r.presence {
        case .driveAway: return .stays("drive not connected")
        case .fileMissing: return .stays("not found")
        case .present: break
        }
        return r.match == .verified ? .canGo : .checkFirst
    }

    nonisolated static func fixityLine(_ c: CopiesAdviceCandidate, disk: CopiesAdviceDisk) -> String? {
        let day: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) }
        if c.isArchiveCopy, let at = c.archiveCheckedAt { return "fixity checked \(day(at))" }
        guard let f = c.contentFixity else { return nil }
        return disk.currentDigests.contains(c.id) ? "full-file digest \(day(f.computedAt))"
                                                  : "digest out of date"
    }

    // MARK: Words

    /// "the archive holds a verified copy, and 2 more copies exist" /
    /// "a verified copy stays on RAID_A".
    nonisolated static func safeReason(keeper: CopiesAdviceRow, copies: [CopiesAdviceRow]) -> String {
        let archive = copies.first { $0.isArchiveCopy && $0.match == .verified && $0.presence == .present }
        let named = archive ?? keeper
        let more = copies.filter { $0.id != named.id }.count
        let head = archive != nil ? "the archive holds a verified copy" : "a verified copy stays on \(keeper.volume)"
        guard more > 0 else { return head }
        return head + ", and \(more) more cop\(more == 1 ? "y exists" : "ies exist")"
    }

    /// The footage group (rank order) then the possible copies, without
    /// anything already listed as an exact copy.
    nonisolated static func sameFootage(_ footage: [CopiesAdviceFootageMember],
                                        possible: [CopiesAdviceFootageMember],
                                        excluding listed: Set<UUID>) -> [CopiesAdviceFootageMember] {
        var seen = listed
        var out: [CopiesAdviceFootageMember] = []
        for m in footage + possible where seen.insert(m.id).inserted { out.append(m) }
        return out
    }
}

// MARK: - Why it was flagged (pure wording)

/// The record's flags, as values.
struct CopiesFlagFacts: Sendable, Equatable {
    var disposition: MediaDisposition = .unreviewed
    var junkReasons: [String] = []
    var duplicateDisposition: DuplicateDisposition = .none
    var duplicateReasons: String = ""
    var duplicateBestMatch: String = ""
    var duplicateCheckedAt: Date?
    /// "Tidy suggestions: Reclaim space — …", one per live steward case.
    var stewardLines: [String] = []
}

enum CopiesAdviceWhy {

    static let nothing = "Nothing has flagged this file."

    nonisolated static func lines(_ f: CopiesFlagFacts) -> [String] {
        let out = [dispositionLine(f), duplicateLine(f)].compactMap { $0 } + f.stewardLines
        return out.isEmpty ? [nothing] : out
    }

    /// The person's (or the junk scorer's) mark.
    nonisolated static func dispositionLine(_ f: CopiesFlagFacts) -> String? {
        let why = f.junkReasons.isEmpty ? "" : " — " + f.junkReasons.joined(separator: " · ")
        switch f.disposition {
        case .unreviewed: return nil
        case .confirmedJunk: return "You marked it as junk" + why
        case .suspectedJunk: return "Suspected junk" + why
        case .important: return "You marked it Important"
        case .recoverable: return "Marked Needs Repair"
        }
    }

    /// The duplicate engine's verdict, with what matched and when.
    nonisolated static func duplicateLine(_ f: CopiesFlagFacts) -> String? {
        let other = f.duplicateBestMatch.isEmpty ? "another file" : f.duplicateBestMatch
        let head: String
        switch f.duplicateDisposition {
        case .none: return nil
        case .extraCopy: head = "Duplicate check: an extra copy of \(other)"
        case .review: head = "Duplicate check: may be a copy of \(other) — not certain"
        case .keep: head = "Duplicate check: the copy kept in its set"
        }
        let matched = matchedWords(f.duplicateReasons)
        let when = f.duplicateCheckedAt.map { " (\($0.formatted(date: .abbreviated, time: .omitted)))" } ?? ""
        return head + (matched.isEmpty ? "" : " — matched on \(matched)") + when
    }

    /// DuplicateDetector's reason tags ("hash+filename+duration") in plain words.
    nonisolated static func matchedWords(_ reasons: String) -> String {
        let words: [String: String] = [
            "hash": "a sampled signature", "timecode": "timecode", "filename": "name", "duration": "length",
            "resolution": "picture size", "vcodec": "video format", "audio": "sound format",
            "tape": "tape name", "created": "creation time",
        ]
        return reasons.split(separator: "+").map { words[String($0)] ?? String($0) }.joined(separator: ", ")
    }
}

// MARK: - Labels (one place for the words)

enum CopiesAdviceText {
    /// The menu item in Triage and the Catalog row menu.
    static let menuLabel = "Copies & Advice\u{2026}"
    static let trashButton = "Move This Copy to Trash\u{2026}"
    static let menuHelp = "One card for this file: how many copies exist, which one is kept and why, "
        + "whether the archive has it, what other footage is the same, and why it was flagged."
}
