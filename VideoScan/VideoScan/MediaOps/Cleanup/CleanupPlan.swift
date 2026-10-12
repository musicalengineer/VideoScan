// CleanupPlan.swift
// Triage ▸ Cleanup v1 — the PLAN: "which files are extra, and can go to the
// Trash?" (docs/design/cleanup_kiss_2026_10_12.md, codex-signed v1 rules).
//
// This file is values plus ONE pure function (`CleanupPlanner.plan`). It
// never touches the catalog (main actor) and never touches the disk itself:
// the disk facts come in through a closure (`CleanupDiskProbe` in
// production, a dictionary in tests), so the rules are unit-testable and
// the 100k-record scale test needs no files.
//
// The rules, in the order they are applied (a port of the tested
// scripts/one_time_cleanup_2026_10_11.py, regrouped on the STORED FULL
// SHA-256 + size instead of the sampled hash — codex design F5):
//
//   COPIES  rows with a stored full SHA-256 are grouped by (digest, size).
//           A group that shares its content with a junk-marked row is left
//           alone (the junk lane may take that one; one survivor per
//           content, codex F2). Each member must be on a connected drive, a
//           regular file at its own real path (no symlinked folder on the
//           way), at the catalog's size. Rows that are one physical file
//           (same device + inode: hard links, case-only spellings) collapse
//           to one member and none of those rows is ever removed (F3).
//           Keeper = DuplicateKeeperPolicy's volume rank among the usable
//           members; a tie for the top rank leaves the WHOLE group alone
//           (rule 4, ~587 GB, mostly copies inside FamilyArchive). Every
//           other member is a target unless it is protected (FamilyArchive /
//           the Master Archive / a drive marked Read only), archived, half
//           of an A/V pair, inside Avid MediaFiles or an app library, or
//           carries more of Rick's own marks (stars, notes, people…) than
//           the copy that stays.
//   JUNK    rows Rick marked Confirmed Junk: same disk checks, never
//           archived / A/V halves / Avid / app libraries, never a physical
//           file that is some group's keeper. On the FamilyArchive volume
//           (never inside the archive tree) they go to their own list — the
//           per-run tick box (Rick 2026-10-12, option b).
//   NOT CHECKED YET  active rows with no stored full hash: information only.
//
// THE INVARIANT the planner guarantees (pinned by CleanupPlanTests): no
// keeper — by row OR by physical file — is ever in `copies` or `junk` or
// `archiveJunk`.
//
// Memory: one `CleanupRow` (~200 bytes) per active record, one disk-facts
// entry per active row (every row is stat'ed once, so an alias under any
// name is seen), and the plan's lists. ~50 MB worst case at 100k.
//
// (For Rick: everything here is a `struct` — value semantics, copied like a
// C++ POD — and `Sendable`, so the planner can run on a worker thread with
// no locks.)

import Foundation
import VideoScanCore

// MARK: - Input: one catalog row, as Cleanup reads it

/// One active catalog row, copied on the main actor. Everything the rules
/// need, nothing more.
struct CleanupRow: Sendable, Equatable {
    let id: UUID
    let path: String
    let filename: String
    let volumeName: String
    let sizeBytes: Int64
    /// The stored whole-file SHA-256 (contentFixity, else archiveFixity),
    /// only when it covers exactly `sizeBytes`. nil = "not checked yet".
    let fullDigest: String?
    let isJunk: Bool
    /// An archive copy, inside the archive tree, or a source whose content
    /// already has a master copy (the Excess copies lane owns those).
    let isArchived: Bool
    let isPairHalf: Bool
    /// Set aside (hidden) in the catalog — neither kept nor removed here.
    let isSetAside: Bool
    /// The bulk-verb gate's verdict for this row (nil = no protection).
    /// Filled off the main actor (`CleanupInputs.plan`).
    var protection: CleanupProtection?
    /// Rick's own HAND marks on the row (`CleanupHandMarks`).
    let marks: CleanupHandMarks
}

/// The marks a HAND put on a row — and nothing a machine stamped. The
/// keeper election's `humanMetadataScore` also counts Migrate's
/// `originalFullPath`, machine note lines and tags; on the real catalog
/// (dry run 2026-10-12) that held 117 copies for "your marks" when ~4
/// carried any. Cleanup asks only: stars, people Rick confirmed, a date or
/// place he typed, and note lines a person could have written
/// (`MachineNote` says which lines a machine wrote — the one classifier
/// every notes writer signs through). Conservative on purpose: a copy with
/// MORE of any of these than the copy that stays is left alone.
struct CleanupHandMarks: Sendable, Equatable {
    var stars = 0
    var confirmedPeople = 0
    var hasDate = false
    var hasPlace = false
    var noteLines = 0

    static let none = CleanupHandMarks()

    /// What `self` has that `keeper` lacks, in words ("stars, a date") —
    /// nil when nothing. Pure.
    func lacking(in keeper: CleanupHandMarks) -> String? {
        var parts: [String] = []
        if stars > keeper.stars { parts.append("stars") }
        if confirmedPeople > keeper.confirmedPeople { parts.append("confirmed people") }
        if hasDate && !keeper.hasDate { parts.append("a date") }
        if hasPlace && !keeper.hasPlace { parts.append("a place") }
        if noteLines > keeper.noteLines { parts.append("notes") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The note lines a person could have written: every line of
    /// `userNotes` that `MachineNote` does not attribute to a machine. Pure.
    static func humanNoteLines(_ userNotes: String) -> Int {
        userNotes.split(whereSeparator: { $0.isNewline })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !MachineNote.isMachineLine($0) }
            .count
    }
}

/// Why the one bulk-verb gate (`bulkDeleteRefusal`) would leave a row alone,
/// reduced to what Cleanup decides on.
enum CleanupProtection: Sendable, Hashable {
    /// Inside the Master Archive tree / a promoted copy. Never.
    case archiveTree
    /// Elsewhere on the Master Archive volume (FamilyArchive). Copies:
    /// never. Junk: only through the per-run tick box.
    case archiveVolume
    /// Any other refusal (a drive marked Read only, the archive volume
    /// unprovable…) with the gate's own words.
    case other(String)
}

/// What the disk says about one path, right now.
enum CleanupDiskFacts: Sendable, Equatable {
    case driveNotConnected
    case missing
    /// A symlink, folder, FIFO… — not a plain file.
    case notRegularFile
    /// The path runs through a symlinked folder: the file has another,
    /// real name (e.g. the 27 links from ~/Movies into the media drives).
    /// The real file's identity (a stat of the resolved path) rides along
    /// so the alias still names its file in the physical index (codex r2
    /// F3); nil when the link dangles.
    case throughLink(FileIdentityStamp?)
    /// A plain file at its own real path; its identity now.
    case file(FileIdentityStamp)
}

// MARK: - Output: the plan

/// One file the plan names.
struct CleanupFile: Sendable, Equatable, Identifiable {
    let id: UUID
    let path: String
    let filename: String
    let volumeName: String
    let sizeBytes: Int64
    /// The file as the plan saw it (device, inode, size, mtime, ctime).
    let identity: FileIdentityStamp
}

struct CleanupPlan: Sendable, Equatable {

    /// One extra copy and the copy that stays for it.
    struct Copy: Sendable, Equatable, Identifiable {
        let target: CleanupFile
        let keeper: CleanupFile
        /// The stored full SHA-256 both rows carry (the fresh reads decide).
        let digest: String
        var id: UUID { target.id }
    }

    /// Files and bytes for one row of the page or one exclusion reason.
    struct Tally: Sendable, Equatable {
        var files = 0
        var bytes: Int64 = 0
        mutating func add(_ size: Int64) { files += 1; bytes += size }
    }

    var copies: [Copy] = []
    /// Junk you marked, not on FamilyArchive.
    var junk: [CleanupFile] = []
    /// Junk you marked on FamilyArchive — only with the per-run tick box.
    var archiveJunk: [CleanupFile] = []
    /// Active rows with no stored full hash (information only).
    var notChecked = Tally()
    /// Everything else the plan looked at and left alone, by reason.
    var leftAlone: [CleanupExclusion: Tally] = [:]
    /// Every keeper's physical identity (device, inode) — reserved for the
    /// whole run; the job re-checks junk against it at each move.
    var reservedSurvivors: Set<CleanupPhysicalID> = []

    static let empty = CleanupPlan()

    // The page's numbers, summed ONCE when the plan is built (`finishTotals`)
    // — never in a view body (codex r1 P3-7).
    private(set) var copyBytes: Int64 = 0
    private(set) var junkBytes: Int64 = 0
    private(set) var archiveJunkBytes: Int64 = 0
    private(set) var leftAloneTotal = Tally()
    /// Left-alone reasons, biggest first (the page's compact explanation).
    private(set) var leftAloneSorted: [LeftAloneLine] = []

    /// One left-alone reason with its files and bytes.
    struct LeftAloneLine: Sendable, Equatable, Identifiable {
        let reason: CleanupExclusion
        let tally: Tally
        var id: CleanupExclusion { reason }
    }

    /// Sum the page's numbers from the lists. The planner calls it last.
    mutating func finishTotals() {
        copyBytes = copies.reduce(Int64(0)) { $0 + $1.target.sizeBytes }
        junkBytes = junk.reduce(Int64(0)) { $0 + $1.sizeBytes }
        archiveJunkBytes = archiveJunk.reduce(Int64(0)) { $0 + $1.sizeBytes }
        leftAloneSorted = leftAlone.map { LeftAloneLine(reason: $0.key, tally: $0.value) }
            .sorted { $0.tally.bytes != $1.tally.bytes ? $0.tally.bytes > $1.tally.bytes : $0.reason.words < $1.reason.words }
        leftAloneTotal = leftAlone.values.reduce(into: Tally()) { $0.files += $1.files; $0.bytes += $1.bytes }
    }
}

/// One physical file: device + inode, from one stat pass.
struct CleanupPhysicalID: Sendable, Hashable {
    let device: UInt64
    let inode: UInt64
    init(_ stamp: FileIdentityStamp) {
        device = stamp.device
        inode = stamp.inode
    }
}

/// Why a row is not in Cleanup: a stable key plus its plain words for the
/// page. A value carrying its own words, not an enum plus a words switch —
/// the switch was a jump table that grew a branch per reason (the
/// MediaFileOperationKind ruling, 2026-10-08). `Error` only so it can be
/// the failure side of a `Result` (≈ a C++ `expected<T, E>`).
/// (For Rick: `static let` instances ≈ C++ `static const` objects of the
/// type; `==` compares key and words, so `case .missing:` in a switch works.)
struct CleanupExclusion: Error, Sendable, Hashable {
    let key: String
    let words: String

    private init(_ key: String, _ words: String) {
        self.key = key
        self.words = words
    }

    static let driveNotConnected = Self("driveNotConnected", "its drive isn't connected")
    static let missing = Self("missing", "not on its drive now")
    static let notRegularFile = Self("notRegularFile", "not a plain file (a link or a folder)")
    static let throughLink = Self("throughLink", "its path runs through a linked folder (the same file has another name)")
    static let sizeChanged = Self("sizeChanged", "changed size since it was catalogued")
    static let sameFileAsAnotherRow = Self("sameFileAsAnotherRow",
                                           "the same file as another catalog row (a hard link or another spelling)")
    static let onlyUsableCopy = Self("onlyUsableCopy", "no other copy is on a connected drive")
    static let keeperTie = Self("keeperTie", "no clear copy to keep (a tie) — left alone")
    static let copyIsJunk = Self("copyIsJunk", "a copy of it is marked junk — left for you")
    static let setAside = Self("setAside", "set aside in the catalog")
    static let archived = Self("archived", "already archived — Archive's own lane handles it")
    static let pairHalf = Self("pairHalf", "half of an audio/video pair")
    static let avidMediaFiles = Self("avidMediaFiles", "in an Avid MediaFiles folder (its bins would go offline)")
    static let appLibrary = Self("appLibrary", "inside an app library (Photos, iMovie, Final Cut…)")
    /// Says what it saw: "has stars, a date the kept copy lacks".
    static func carriesYourMarks(_ what: String) -> Self { Self("carriesYourMarks", "has \(what) the kept copy lacks") }
    static let familyArchive = Self("familyArchive", "on FamilyArchive — never trimmed as a copy")
    static let survivorOfAnother = Self("survivorOfAnother", "is the copy that stays for another file")
    /// Any other protection, in the bulk gate's own words (a drive marked
    /// Read only, the archive volume unprovable…).
    static func protected(_ why: String) -> Self { Self("protected", why) }
}

// MARK: - Path rules (pure)

enum CleanupPathRules {
    /// Avid's managed media folders. Their bins point at these files by
    /// path, so a copy elsewhere does not keep a sequence online (codex F6).
    static func isAvidMediaFiles(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.contains("/avid mediafiles/") || lower.contains("/omfi mediafiles/")
    }

    /// Inside a Finder Trash (a ".Trash" or ".Trashes" folder on the way),
    /// case-insensitively. A file already in a Trash is never "the copy that
    /// stays" and is never moved again.
    static func isInTrash(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { $0.caseInsensitiveCompare(".Trash") == .orderedSame
            || $0.caseInsensitiveCompare(".Trashes") == .orderedSame }
    }

    /// Runs through a folder named like the Master Archive's root, by NAME —
    /// a second net under the tree check for a path spelled differently
    /// from the designation. Case-insensitive, like the volumes it sits
    /// on (QA P3). Junk there is never offered, and the engine's
    /// FamilyArchive-junk waiver never lifts it.
    static func isInArchiveRootFolder(_ path: String) -> Bool {
        path.range(of: "/\(MasterArchiveLayout.rootFolderName)/", options: .caseInsensitive) != nil
    }

    /// Inside an application's library package, or an iMovie / Final Cut
    /// path — the app owns those files (ported from the one-time script).
    static func isInAppLibrary(_ path: String) -> Bool {
        let lower = path.lowercased()
        for ext in libraryPackages where lower.contains(ext + "/") { return true }
        return lower.contains("/imovie") || lower.contains("final cut")
    }

    private static let libraryPackages = [
        ".photoslibrary", ".fcpbundle", ".fcpproject", ".fcpevent", ".imovielibrary", ".imovieproject",
        ".aplibrary", ".tvlibrary", ".logicx", ".band", ".lrlibrary", ".rcproject",
    ]
}

// MARK: - The planner (pure)

enum CleanupPlanner {

    /// Build the plan. Three passes:
    ///   1. sort rows into lanes (junk · hashed groups · not checked yet);
    ///   2. ask `facts` once for EVERY active row — not only the candidates
    ///      (codex r1 P2-3: an unhashed, set-aside or unique-content row can
    ///      be another name for a candidate's file) — and index the physical
    ///      files, so two rows naming one file are known BEFORE anything is
    ///      chosen;
    ///   3. decide: groups first (that reserves every keeper), then junk.
    /// `rank` is the keeper election's volume rank for a path
    /// (`DuplicateKeeperPolicy.volumeRank(forPath:)`).
    static func plan(rows: [CleanupRow],
                     facts: (String) -> CleanupDiskFacts,
                     rank: (String) -> DuplicateKeeperPolicy.VolumeRank) -> CleanupPlan {
        var plan = CleanupPlan()
        let lanes = Lanes(rows, into: &plan)
        var disk: [UUID: CleanupDiskFacts] = [:]
        var index = PhysicalIndex()
        for row in rows {
            let fact = facts(row.path)
            disk[row.id] = fact
            switch fact {
            case .file(let stamp): index.note(CleanupPhysicalID(stamp))
            // An alias through a linked folder is never selected, but it
            // still NAMES its real file: that file is ambiguous (codex r2 F3).
            case .throughLink(let real?): index.note(CleanupPhysicalID(real))
            case .throughLink(nil), .driveNotConnected, .missing, .notRegularFile: break
            }
        }
        for group in lanes.groups {
            planGroup(group.members, digest: group.key.digest, disk: disk, index: index, rank: rank, into: &plan)
        }
        for row in lanes.junk {
            planJunk(row, fact: disk[row.id] ?? .missing, index: index, into: &plan)
        }
        plan.finishTotals()
        return plan
    }

    /// Two volume ranks tie when neither component the election ORDERS by
    /// (availability, precedence) tells them apart.
    static func ties(_ a: DuplicateKeeperPolicy.VolumeRank, _ b: DuplicateKeeperPolicy.VolumeRank) -> Bool {
        !(a < b) && !(b < a)
    }

    // MARK: Pass 1 — lanes

    /// A (digest, size) group key. Comparable so the walk is deterministic.
    struct GroupKey: Hashable, Comparable, Sendable {
        let digest: String
        let size: Int64
        static func < (a: GroupKey, b: GroupKey) -> Bool {
            a.digest != b.digest ? a.digest < b.digest : a.size < b.size
        }
    }

    /// The rows sorted into lanes. Groups of one (unique content) are not
    /// copies and are not in Cleanup at all — not even "left alone". A
    /// group that shares its content with a junk-marked row is left alone
    /// whole (one survivor per content, codex F2).
    private struct Lanes {
        var junk: [CleanupRow] = []
        var groups: [(key: GroupKey, members: [CleanupRow])] = []

        init(_ rows: [CleanupRow], into plan: inout CleanupPlan) {
            var byKey: [GroupKey: [CleanupRow]] = [:]
            for row in rows {
                if row.isJunk {
                    junk.append(row)
                } else if row.isSetAside {
                    plan.leftAlone[.setAside, default: .init()].add(row.sizeBytes)
                } else if let digest = row.fullDigest {
                    byKey[GroupKey(digest: digest, size: row.sizeBytes), default: []].append(row)
                } else {
                    plan.notChecked.add(row.sizeBytes)
                }
            }
            let junkContent = Set(junk.compactMap { r in r.fullDigest.map { GroupKey(digest: $0, size: r.sizeBytes) } })
            for (key, members) in byKey.sorted(by: { $0.key < $1.key }) where members.count > 1 {
                if junkContent.contains(key) {
                    for m in members { plan.leftAlone[.copyIsJunk, default: .init()].add(m.sizeBytes) }
                } else {
                    groups.append((key, members))
                }
            }
        }
    }

    // MARK: Pass 2 — physical files

    /// How many catalog rows name each physical file (over every row whose
    /// disk facts were asked). More than one = ambiguous identity.
    struct PhysicalIndex {
        private(set) var rowsByFile: [CleanupPhysicalID: Int] = [:]
        mutating func note(_ id: CleanupPhysicalID) { rowsByFile[id, default: 0] += 1 }
        func isShared(_ id: CleanupPhysicalID) -> Bool { (rowsByFile[id] ?? 0) > 1 }
    }

    // MARK: Pass 3 — groups

    /// One usable group member: the row and the file it names now.
    private struct Member {
        let row: CleanupRow
        let stamp: FileIdentityStamp
        var physical: CleanupPhysicalID { CleanupPhysicalID(stamp) }
        var file: CleanupFile {
            CleanupFile(id: row.id, path: row.path, filename: row.filename, volumeName: row.volumeName,
                        sizeBytes: row.sizeBytes, identity: stamp)
        }
    }

    private static func planGroup(_ rows: [CleanupRow], digest: String, disk: [UUID: CleanupDiskFacts],
                                  index: PhysicalIndex, rank: (String) -> DuplicateKeeperPolicy.VolumeRank,
                                  into plan: inout CleanupPlan) {
        // One member per physical file, in path order; every other name of
        // a file already met — and every unusable row — is left alone.
        var physical: [Member] = []
        for row in rows.sorted(by: { $0.path < $1.path }) {
            switch usableStamp(row, fact: disk[row.id] ?? .missing) {
            case .failure(let why):
                plan.leftAlone[why, default: .init()].add(row.sizeBytes)
            case .success(let stamp):
                let m = Member(row: row, stamp: stamp)
                if physical.contains(where: { $0.physical == m.physical }) {
                    plan.leftAlone[.sameFileAsAnotherRow, default: .init()].add(row.sizeBytes)
                } else {
                    physical.append(m)
                }
            }
        }
        guard physical.count > 1 else {
            for m in physical { plan.leftAlone[.onlyUsableCopy, default: .init()].add(m.row.sizeBytes) }
            return
        }
        let ranked = physical.sorted { lhs, rhs in
            let l = rank(lhs.row.path), r = rank(rhs.row.path)
            return ties(l, r) ? lhs.row.path < rhs.row.path : r < l
        }
        guard !ties(rank(ranked[0].row.path), rank(ranked[1].row.path)) else {
            for m in ranked { plan.leftAlone[.keeperTie, default: .init()].add(m.row.sizeBytes) }
            return
        }
        let keeper = ranked[0]
        plan.reservedSurvivors.insert(keeper.physical)
        for m in ranked.dropFirst() {
            if let why = copyExclusion(m.row, keeper: keeper.row, aliased: index.isShared(m.physical)) {
                plan.leftAlone[why, default: .init()].add(m.row.sizeBytes)
            } else {
                plan.copies.append(CleanupPlan.Copy(target: m.file, keeper: keeper.file, digest: digest))
            }
        }
    }

    /// Why a non-keeper member is NOT an extra copy, or nil (it is one).
    /// The order only decides which reason the page shows.
    static func copyExclusion(_ row: CleanupRow, keeper: CleanupRow, aliased: Bool) -> CleanupExclusion? {
        if aliased { return .sameFileAsAnotherRow }
        switch row.protection {
        case .archiveTree?: return .archived
        case .archiveVolume?: return .familyArchive
        case .other(let why)?: return .protected(why)
        case nil: break
        }
        if row.isArchived { return .archived }
        if let why = contentExclusion(row) { return why }
        return row.marks.lacking(in: keeper.marks).map { .carriesYourMarks($0) }
    }

    /// The exclusions both lanes share: A/V halves, Avid, app libraries.
    static func contentExclusion(_ row: CleanupRow) -> CleanupExclusion? {
        if row.isPairHalf { return .pairHalf }
        if CleanupPathRules.isAvidMediaFiles(row.path) { return .avidMediaFiles }
        if CleanupPathRules.isInAppLibrary(row.path) { return .appLibrary }
        return nil
    }

    /// The file named by `row` if it is usable now; else why not.
    static func usableStamp(_ row: CleanupRow, fact: CleanupDiskFacts) -> Result<FileIdentityStamp, CleanupExclusion> {
        switch fact {
        case .driveNotConnected: return .failure(.driveNotConnected)
        case .missing: return .failure(.missing)
        case .notRegularFile: return .failure(.notRegularFile)
        case .throughLink: return .failure(.throughLink)
        case .file(let stamp):
            return stamp.size == row.sizeBytes ? .success(stamp) : .failure(.sizeChanged)
        }
    }

    // MARK: Pass 3 — junk

    private static func planJunk(_ row: CleanupRow, fact: CleanupDiskFacts, index: PhysicalIndex,
                                 into plan: inout CleanupPlan) {
        switch junkLane(row, fact: fact, index: index, reserved: plan.reservedSurvivors) {
        case .failure(let why):
            plan.leftAlone[why, default: .init()].add(row.sizeBytes)
        case .success(let placed):
            if placed.onArchiveVolume { plan.archiveJunk.append(placed.file) } else { plan.junk.append(placed.file) }
        }
    }

    /// A junk row the plan takes: the file, and whether it is on the
    /// FamilyArchive volume (the per-run tick box's list).
    struct PlacedJunk {
        let file: CleanupFile
        let onArchiveVolume: Bool
    }

    /// Where one junk row goes, or why it is left alone.
    static func junkLane(_ row: CleanupRow, fact: CleanupDiskFacts, index: PhysicalIndex,
                         reserved: Set<CleanupPhysicalID>) -> Result<PlacedJunk, CleanupExclusion> {
        if row.isArchived || row.protection == .archiveTree || CleanupPathRules.isInArchiveRootFolder(row.path) {
            return .failure(.archived)
        }
        if case .other(let why)? = row.protection { return .failure(.protected(why)) }
        if let why = contentExclusion(row) { return .failure(why) }
        let stamp: FileIdentityStamp
        switch usableStamp(row, fact: fact) {
        case .failure(let why): return .failure(why)
        case .success(let s): stamp = s
        }
        let physical = CleanupPhysicalID(stamp)
        if reserved.contains(physical) { return .failure(.survivorOfAnother) }
        if index.isShared(physical) { return .failure(.sameFileAsAnotherRow) }
        let file = CleanupFile(id: row.id, path: row.path, filename: row.filename, volumeName: row.volumeName,
                               sizeBytes: row.sizeBytes, identity: stamp)
        return .success(PlacedJunk(file: file, onArchiveVolume: row.protection == .archiveVolume))
    }
}

