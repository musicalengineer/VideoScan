// PrunePlan.swift
// The pure half of "delete as we promote, carefully" (Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md, stage 2 — DRY RUN ONLY):
//
//   - `ArchiveCopySnapshot` — the Sendable facts about ONE catalog copy
//     that the protection line and the prune plan both read. The model
//     snapshots the catalog once (cheap value capture on the main actor),
//     then everything below runs off-main.
//   - `ArchiveCopyFamilies.group` — same-content families keyed by the
//     batch's records (the `protectionFamilies` algorithm, made pure).
//   - `ImportanceBar` — "the user sets the bar per importance": three
//     levels, thresholds editable in Settings, with the design's defaults:
//         Important (★★★ / disposition Important): verified archive + 1 more device + cloud-or-off-site attestation
//         Ordinary  (★★ / unrated):                verified archive + 1 more device
//         Low       (★ / Recoverable):             verified archive alone
//   - `PrunePlan.compute` — the scrubbable-copy rule
//     (docs/archived_duplicate_scrub_design.md) + the bar, per family:
//     which extra copies WOULD go to the Trash, which one working copy is
//     kept (connected working volume with the most free space, original
//     over versions, user may override), and which families are "not
//     covered by the bar" (all copies stay until the user attests).
//   - `PrunePlan.Family.rows` / `PrunePlan.selection` (2026-09-20) — the
//     per-copy CHECKLIST the sheet shows since Rick's "the dialog did not
//     let me delete any dups": the bar-respecting plan above is the
//     DEFAULT (what is checked), the family's `advice` is the bar's
//     shortfall in words, and the person decides. `isCandidate` still
//     says which rows may be checked at all; `Selection` judges the
//     choice against the bar (the `override` the ledger records).
//
// Rules pinned by tests:
//   * A copy is deletable only when: not inside the archive root; its
//     family has a FIXITY-VERIFIED archive copy; no human note; reachable
//     (online); not a recovered A/V pair member; not a version. Offline
//     copies are never elected and never counted as "extra" — they DO
//     count as a device the family already has (the retired drives are
//     insurance, scrub design §3-2-1).
//   * Disposition Important maps to the Important LEVEL (the design's
//     table), not to an absolute keep; a human note IS an absolute keep.
//   * The bar is checked per family, so one batch can mix outcomes.
//
// Worst-case memory: one snapshot (~200 bytes + strings) per catalog
// record in the families touched — a 100k-record catalog is ~30 MB
// transiently, released when the plan is built. Nothing is cached here.
//
// (For Rick: plain value types and static functions — no globals, every
// rule table-testable. `Sendable` ≈ "safe to hand to another thread".)

import Foundation

// MARK: - Snapshot of one copy

public struct ArchiveCopySnapshot: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var fullPath: String
    public var volumeName: String
    public var sizeBytes: Int64
    /// `MediaLedgerEvent.contentKey(...)`; "" = unknown → its own family.
    public var contentKey: String
    /// The source record an ARCHIVE COPY was promoted from — joins the
    /// copy to its family even when the source was never hashed.
    public var promotedFromID: UUID?
    public var isArchiveCopy: Bool
    /// The archive copy carries a read-back fixity record.
    public var fixityVerified: Bool
    public var isInsideArchiveRoot: Bool
    public var isOnline: Bool
    public var isPairMember: Bool
    /// A balance-audio / trim / transcode of another record (repairs are
    /// not versions) — kept, never elected, never trashed by this plan.
    public var isVersion: Bool
    public var hasHumanNote: Bool
    public var starRating: Int
    public var disposition: MediaDisposition
    public var attestations: [BackupAttestation]
    /// A reachable, non-retired, non-archive working volume — where a
    /// keeper may live.
    public var volumeIsConnectedWorking: Bool
    public var volumeFreeBytes: Int64?
    public var isPurged: Bool

    public init(id: UUID, filename: String, fullPath: String, volumeName: String, sizeBytes: Int64,
                contentKey: String, promotedFromID: UUID? = nil, isArchiveCopy: Bool = false,
                fixityVerified: Bool = false, isInsideArchiveRoot: Bool = false, isOnline: Bool = true,
                isPairMember: Bool = false, isVersion: Bool = false, hasHumanNote: Bool = false,
                starRating: Int = 0, disposition: MediaDisposition = .unreviewed,
                attestations: [BackupAttestation] = [], volumeIsConnectedWorking: Bool = true,
                volumeFreeBytes: Int64? = nil, isPurged: Bool = false) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.volumeName = volumeName
        self.sizeBytes = sizeBytes; self.contentKey = contentKey; self.promotedFromID = promotedFromID
        self.isArchiveCopy = isArchiveCopy; self.fixityVerified = fixityVerified
        self.isInsideArchiveRoot = isInsideArchiveRoot; self.isOnline = isOnline
        self.isPairMember = isPairMember; self.isVersion = isVersion; self.hasHumanNote = hasHumanNote
        self.starRating = starRating; self.disposition = disposition; self.attestations = attestations
        self.volumeIsConnectedWorking = volumeIsConnectedWorking; self.volumeFreeBytes = volumeFreeBytes
        self.isPurged = isPurged
    }

    /// The protection-line view of this copy.
    public var copyFacts: ProtectionSummary.CopyFacts {
        ProtectionSummary.CopyFacts(volumeName: volumeName, isOnline: isOnline,
                                    isArchiveCopy: isArchiveCopy || isInsideArchiveRoot,
                                    fixityVerified: (isArchiveCopy || isInsideArchiveRoot) && fixityVerified,
                                    attestations: attestations)
    }
}

// MARK: - Families

public enum ArchiveCopyFamilies {

    /// Same-content families containing at least one `batch` record, in a
    /// stable order. Key = content key, else identity; an archive copy
    /// joins its promotion source's family. Purged copies are dropped.
    /// O(snapshots) time, two dictionary passes.
    public static func group(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot]) -> [[ArchiveCopySnapshot]] {
        guard !batch.isEmpty else { return [] }
        var keyByID: [UUID: String] = [:]
        keyByID.reserveCapacity(snapshots.count)
        for s in snapshots {
            keyByID[s.id] = s.contentKey.isEmpty ? "i:\(s.id.uuidString)" : s.contentKey
        }
        for s in snapshots where s.isArchiveCopy {
            if let src = s.promotedFromID, let k = keyByID[src] { keyByID[s.id] = k }
        }
        var wanted: [String: Int] = [:]
        var families: [[ArchiveCopySnapshot]] = []
        for id in batch.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let k = keyByID[id], wanted[k] == nil else { continue }
            wanted[k] = families.count
            families.append([])
        }
        guard !wanted.isEmpty else { return [] }
        for s in snapshots {
            guard !s.isPurged, let k = keyByID[s.id], let idx = wanted[k] else { continue }
            families[idx].append(s)
        }
        return families
    }

    /// The protection line for a batch, from the same families.
    public static func protection(families: [[ArchiveCopySnapshot]]) -> ProtectionSummary {
        ProtectionSummary.summarize(families: families.map { $0.map(\.copyFacts) })
    }
}

// MARK: - Importance bar

public struct ImportanceBar: Equatable, Sendable {

    public enum Level: String, CaseIterable, Sendable {
        case important, ordinary, low

        public var displayName: String {
            switch self {
            case .important: return "★★★ / Important"
            case .ordinary:  return "★★ / unrated"
            case .low:       return "★ / Recoverable"
            }
        }
        var rank: Int {
            switch self {
            case .important: return 2
            case .ordinary:  return 1
            case .low:       return 0
            }
        }
    }

    /// Copies required — beyond the verified archive copy — before extra
    /// copies may go.
    public struct Requirement: Equatable, Sendable {
        /// Distinct devices holding a working copy (0…3).
        public var extraDevices: Int
        /// A cloud OR off-site "yes" attestation.
        public var cloudOrOffsite: Bool
        public init(extraDevices: Int, cloudOrOffsite: Bool) {
            self.extraDevices = max(0, min(3, extraDevices))
            self.cloudOrOffsite = cloudOrOffsite
        }
    }

    public var important: Requirement
    public var ordinary: Requirement
    public var low: Requirement

    public init(important: Requirement, ordinary: Requirement, low: Requirement) {
        self.important = important; self.ordinary = ordinary; self.low = low
    }

    /// The design's defaults.
    public static let defaults = ImportanceBar(
        important: Requirement(extraDevices: 1, cloudOrOffsite: true),
        ordinary: Requirement(extraDevices: 1, cloudOrOffsite: false),
        low: Requirement(extraDevices: 0, cloudOrOffsite: false))

    public func requirement(for level: Level) -> Requirement {
        switch level {
        case .important: return important
        case .ordinary:  return ordinary
        case .low:       return low
        }
    }

    /// The level is never inferred from the file — it is the stars /
    /// disposition Rick already sets. Important disposition or ★★★ →
    /// important; ★ or Recoverable → low; everything else (★★, unrated,
    /// suspected/confirmed junk) → ordinary.
    public static func level(starRating: Int, disposition: MediaDisposition) -> Level {
        if disposition == .important || starRating >= 3 { return .important }
        if starRating == 1 || disposition == .recoverable { return .low }
        return .ordinary
    }

    // MARK: Settings keys (UserDefaults; editable in Settings)

    public enum Key {
        public static let importantDevices = "prune.bar.important.devices"
        public static let importantCloudOrOffsite = "prune.bar.important.cloudOrOffsite"
        public static let ordinaryDevices = "prune.bar.ordinary.devices"
        public static let ordinaryCloudOrOffsite = "prune.bar.ordinary.cloudOrOffsite"
        public static let lowDevices = "prune.bar.low.devices"
        public static let lowCloudOrOffsite = "prune.bar.low.cloudOrOffsite"
        public static let all = [importantDevices, importantCloudOrOffsite, ordinaryDevices,
                                 ordinaryCloudOrOffsite, lowDevices, lowCloudOrOffsite]
    }

    /// Pure loader: `read(key)` returns the stored value (Int / Bool /
    /// NSNumber) or nil → the default for that key. Anything malformed
    /// falls back to the default; the devices count is clamped 0…3.
    public static func load(_ read: (String) -> Any?) -> ImportanceBar {
        func int(_ key: String, _ fallback: Int) -> Int {
            switch read(key) {
            case let n as Int: return n
            case let n as NSNumber: return n.intValue
            case let s as String: return Int(s) ?? fallback
            default: return fallback
            }
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            switch read(key) {
            case let b as Bool: return b
            case let n as NSNumber: return n.boolValue
            case let s as String: return (s as NSString).boolValue
            default: return fallback
            }
        }
        let d = defaults
        return ImportanceBar(
            important: Requirement(extraDevices: int(Key.importantDevices, d.important.extraDevices),
                                   cloudOrOffsite: bool(Key.importantCloudOrOffsite, d.important.cloudOrOffsite)),
            ordinary: Requirement(extraDevices: int(Key.ordinaryDevices, d.ordinary.extraDevices),
                                  cloudOrOffsite: bool(Key.ordinaryCloudOrOffsite, d.ordinary.cloudOrOffsite)),
            low: Requirement(extraDevices: int(Key.lowDevices, d.low.extraDevices),
                             cloudOrOffsite: bool(Key.lowCloudOrOffsite, d.low.cloudOrOffsite)))
    }

    public static func load(defaults store: UserDefaults) -> ImportanceBar {
        load { store.object(forKey: $0) }
    }

    /// One line for the sheet: "★★★: archive + 1 device + cloud or off-site".
    public static func describe(_ r: Requirement) -> String {
        var parts = ["verified archive copy"]
        if r.extraDevices > 0 { parts.append("\(r.extraDevices) more device\(r.extraDevices == 1 ? "" : "s")") }
        if r.cloudOrOffsite { parts.append("a cloud or off-site copy") }
        return parts.joined(separator: " + ")
    }
}

// MARK: - Prune plan

public struct PrunePlan: Equatable, Sendable {

    public struct Options: Equatable, Sendable {
        /// Keep one working copy even where the bar does not require it.
        public var keepOne: Bool
        /// The user's override for where the kept copy lives (a volume
        /// name); nil = the connected working volume with the most free
        /// space, per family.
        public var keeperVolume: String?
        public var bar: ImportanceBar
        public init(keepOne: Bool = true, keeperVolume: String? = nil, bar: ImportanceBar = .defaults) {
            self.keepOne = keepOne; self.keeperVolume = keeperVolume; self.bar = bar
        }
    }

    public struct CopyRef: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let filename: String
        public let fullPath: String
        public let volumeName: String
        public let sizeBytes: Int64
        init(_ s: ArchiveCopySnapshot) {
            id = s.id; filename = s.filename; fullPath = s.fullPath; volumeName = s.volumeName; sizeBytes = s.sizeBytes
        }
    }

    /// Why a copy stays.
    public enum KeepReason: String, Equatable, Sendable {
        case archiveCopy, insideArchiveRoot, offline, pairMember, version, humanNote, keeper, barNotMet
        case noArchiveCopy, archiveUnverified

        public var displayText: String {
            switch self {
            case .archiveCopy:       return "the archive copy"
            case .insideArchiveRoot: return "inside the Master Archive"
            case .offline:           return "offline — never elected"
            case .pairMember:        return "part of a recovered A/V pair"
            case .version:           return "a version (balanced / trimmed / transcoded)"
            case .humanNote:         return "has your note"
            case .keeper:            return "the working copy to keep"
            case .barNotMet:         return "not covered by the bar"
            case .noArchiveCopy:     return "no archive copy"
            case .archiveUnverified: return "archive copy unverified"
            }
        }
    }

    public struct KeptCopy: Equatable, Sendable, Identifiable {
        public var id: UUID { copy.id }
        public let copy: CopyRef
        public let reason: KeepReason
    }

    /// One line of the sheet's checklist (Rick 2026-09-20: "I want to see
    /// a list of dups and decide which ones to delete, maybe leave one
    /// behind, maybe not"). Every non-purged copy in the family is a row;
    /// the bar ADVISES (the family's `advice`), the person decides — but
    /// the scrubbable-copy rule still says which rows may be checked at
    /// all, and nothing is checkable without a fixity-verified archive
    /// copy in the family.
    public struct CopyRow: Equatable, Sendable, Identifiable {
        public enum Role: Equatable, Sendable {
            case archiveCopy
            case insideArchiveRoot
            /// Checkable: passes `isCandidate` and the family has a
            /// verified archive copy.
            case candidate
            /// Never checkable — offline / pair / version / note, or a
            /// candidate in a family with no verified archive copy.
            case kept(KeepReason)
        }
        public var id: UUID { copy.id }
        public let copy: CopyRef
        public let role: Role
        /// For a candidate: why the bar-respecting plan would KEEP it
        /// (`.keeper` — the elected working copy; `.barNotMet` — the bar
        /// is not met), nil when that plan would Trash it. nil for every
        /// other role.
        public let planKeeps: KeepReason?
        /// The bar-respecting plan would Trash it (= the trash set).
        public let defaultChecked: Bool

        public var checkable: Bool { role == .candidate }

        /// Why the box is disabled, or the plan's hint on a checkable row
        /// (nil = a plain candidate).
        public var reasonText: String? {
            switch role {
            case .archiveCopy:       return KeepReason.archiveCopy.displayText
            case .insideArchiveRoot: return KeepReason.insideArchiveRoot.displayText
            case .kept(let r):       return r.displayText
            case .candidate:         return planKeeps == .keeper ? "the plan would keep this one" : nil
            }
        }
    }

    public struct Family: Equatable, Sendable {
        public let key: String
        public let level: ImportanceBar.Level
        /// The bar is met once the plan below is applied.
        public let covered: Bool
        /// Why not, when `covered` is false.
        public let shortfall: String?
        public let keeper: CopyRef?
        /// The bar itself made a keeper necessary (vs. the user's
        /// keep-one choice).
        public let keeperRequired: Bool
        public let trash: [CopyRef]
        public let kept: [KeptCopy]
        /// Online scrubbable copies — the "extra copies" the sheet counts.
        public let extraCount: Int
        public let extraBytes: Int64
        /// A representative name for lists ("2 files are not covered…").
        public let displayName: String
        /// The bar for this family's level — what `selection(_:)` judges
        /// the person's choice against.
        public let requirement: ImportanceBar.Requirement
        /// A cloud or off-site "yes" somewhere in the family.
        public let cloudOrOffsiteAttested: Bool
        /// The line under the family header when the bar is not met: the
        /// shortfall in words, ending "You can still choose." — or, with
        /// no verified archive copy, why nothing here may go. nil when
        /// covered.
        public let advice: String?
        /// The checklist: archive copies first, then the working copies
        /// in catalog order.
        public let rows: [CopyRow]

        /// Rows the person may check.
        public var candidateCount: Int { rows.reduce(0) { $0 + ($1.checkable ? 1 : 0) } }
        /// What the bar-respecting plan would Trash (= `trash`'s ids).
        public var defaultSelection: Set<UUID> { Set(rows.lazy.filter(\.defaultChecked).map(\.id)) }

        /// The person's choice in THIS family, judged against the bar.
        public func selection(_ selected: Set<UUID>) -> Selection {
            var count = 0
            var bytes: Int64 = 0
            var devicesAfter = Set<String>()
            var archiveOnly = true
            for row in rows {
                switch row.role {
                case .archiveCopy, .insideArchiveRoot:
                    continue
                case .kept:
                    archiveOnly = false
                    if !row.copy.volumeName.isEmpty { devicesAfter.insert(row.copy.volumeName) }
                case .candidate:
                    if selected.contains(row.id) {
                        count += 1
                        bytes += row.copy.sizeBytes
                    } else {
                        archiveOnly = false
                        if !row.copy.volumeName.isEmpty { devicesAfter.insert(row.copy.volumeName) }
                    }
                }
            }
            guard count > 0 else { return .empty }
            var shortfalls: [String] = []
            if devicesAfter.count < requirement.extraDevices {
                let missing = requirement.extraDevices - devicesAfter.count
                shortfalls.append("needs \(missing) more device\(missing == 1 ? "" : "s")")
            }
            if requirement.cloudOrOffsite && !cloudOrOffsiteAttested {
                shortfalls.append("no cloud or off-site copy attested")
            }
            let against = shortfalls.isEmpty ? nil : "\(level.displayName) — " + shortfalls.joined(separator: ", ")
            return Selection(count: count, bytes: bytes,
                             overrideCount: against == nil ? 0 : count,
                             overrideShortfalls: against.map { [$0] } ?? [],
                             archiveOnlyFamilies: archiveOnly ? [displayName] : [])
        }
    }

    /// The person's checklist choice, judged against the bar: what goes,
    /// how much of it goes AGAINST the bar (and why), and which files
    /// would then exist only in the Master Archive. Pure; the sheet shows
    /// it, the apply path writes it to the ledger.
    public struct Selection: Equatable, Sendable {
        public let count: Int
        public let bytes: Int64
        /// Checked copies in families whose bar is not met once they go.
        public let overrideCount: Int
        /// "★★★ / Important — no cloud or off-site copy attested", one per
        /// family, deduplicated in family order.
        public let overrideShortfalls: [String]
        /// Display names of families that keep ONLY their archive copy.
        public let archiveOnlyFamilies: [String]

        public init(count: Int, bytes: Int64, overrideCount: Int, overrideShortfalls: [String],
                    archiveOnlyFamilies: [String]) {
            self.count = count; self.bytes = bytes; self.overrideCount = overrideCount
            self.overrideShortfalls = overrideShortfalls; self.archiveOnlyFamilies = archiveOnlyFamilies
        }

        public static let empty = Selection(count: 0, bytes: 0, overrideCount: 0, overrideShortfalls: [],
                                            archiveOnlyFamilies: [])

        /// The ledger's `override` detail: "2 copies — ★★★ / Important —
        /// no cloud or off-site copy attested". nil when nothing goes
        /// against the bar.
        public var overrideText: String? {
            guard overrideCount > 0 else { return nil }
            return "\(overrideCount) cop\(overrideCount == 1 ? "y" : "ies") — " + overrideShortfalls.joined(separator: "; ")
        }

        /// The confirmation sentence: "2 copies go against the bar you
        /// set: ★★★ / Important — no cloud or off-site copy attested."
        public var overrideSentence: String? {
            guard overrideCount > 0 else { return nil }
            return "\(overrideCount) cop\(overrideCount == 1 ? "y goes" : "ies go") against the bar you set: "
                + overrideShortfalls.joined(separator: "; ") + "."
        }

        /// "Christmas2008.mov will exist only in the Master Archive after
        /// this." / "Christmas2008.mov and 2 more will exist only…"
        public var archiveOnlySentence: String? {
            guard let first = archiveOnlyFamilies.first else { return nil }
            let more = archiveOnlyFamilies.count - 1
            let who = more == 0 ? first : "\(first) and \(more) more"
            return "\(who) will exist only in the Master Archive after this."
        }
    }

    public struct VolumeChoice: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let freeBytes: Int64?
        /// Families with a candidate copy on this volume.
        public let familyCount: Int
    }

    public let families: [Family]
    public let trashCount: Int
    public let trashBytes: Int64
    public let extraCount: Int
    public let extraBytes: Int64
    public let notCoveredCount: Int
    /// "(required for 19 ★★/★★★ files)" — families where the bar itself
    /// needs the kept copy.
    public let keeperRequiredCount: Int
    /// Connected working volumes a keeper could live on, best first.
    public let keeperVolumes: [VolumeChoice]
    public let suggestedKeeperVolume: String?

    public var trashFiles: [CopyRef] { families.flatMap(\.trash) }
    public var notCoveredFamilies: [Family] { families.filter { !$0.covered } }

    // MARK: The checklist view (all O(rows), never O(records))

    /// What the bar-respecting plan would Trash — the sheet's default
    /// checks. Equals `trashFiles`' ids.
    public var defaultSelection: Set<UUID> {
        var out = Set<UUID>()
        for f in families { for r in f.rows where r.defaultChecked { out.insert(r.id) } }
        return out
    }

    /// Every row the person may check.
    public var checkableIDs: Set<UUID> {
        var out = Set<UUID>()
        for f in families { for r in f.rows where r.checkable { out.insert(r.id) } }
        return out
    }

    public var checkableCount: Int { families.reduce(0) { $0 + $1.candidateCount } }
    public var rowCount: Int { families.reduce(0) { $0 + $1.rows.count } }

    /// The person's choice across the batch, judged against the bar.
    public func selection(_ selected: Set<UUID>) -> Selection {
        guard !selected.isEmpty else { return .empty }
        var count = 0, overrides = 0
        var bytes: Int64 = 0
        var shortfalls: [String] = []
        var seen = Set<String>()
        var archiveOnly: [String] = []
        for f in families {
            let s = f.selection(selected)
            count += s.count
            bytes += s.bytes
            overrides += s.overrideCount
            for text in s.overrideShortfalls where seen.insert(text).inserted { shortfalls.append(text) }
            archiveOnly.append(contentsOf: s.archiveOnlyFamilies)
        }
        return Selection(count: count, bytes: bytes, overrideCount: overrides,
                         overrideShortfalls: shortfalls, archiveOnlyFamilies: archiveOnly)
    }

    public static let empty = PrunePlan(families: [], trashCount: 0, trashBytes: 0, extraCount: 0, extraBytes: 0,
                                        notCoveredCount: 0, keeperRequiredCount: 0, keeperVolumes: [],
                                        suggestedKeeperVolume: nil)

    // MARK: Compute

    public static func compute(families: [[ArchiveCopySnapshot]], options: Options) -> PrunePlan {
        // Pass 1: candidate volumes across every family (the picker).
        var volumeFree: [String: Int64?] = [:]
        var volumeFamilies: [String: Int] = [:]
        for fam in families {
            var seen = Set<String>()
            for c in fam where isCandidate(c) && c.volumeIsConnectedWorking && !c.volumeName.isEmpty {
                let have: Int64? = volumeFree[c.volumeName].flatMap { $0 }
                if volumeFree[c.volumeName] == nil { volumeFree[c.volumeName] = c.volumeFreeBytes }
                else if let f = c.volumeFreeBytes, (have ?? -1) < f { volumeFree[c.volumeName] = f }
                if seen.insert(c.volumeName).inserted { volumeFamilies[c.volumeName, default: 0] += 1 }
            }
        }
        let choices = volumeFree.keys.map { VolumeChoice(name: $0, freeBytes: volumeFree[$0].flatMap { $0 },
                                                          familyCount: volumeFamilies[$0] ?? 0) }
            .sorted { a, b in
                let fa = a.freeBytes ?? -1, fb = b.freeBytes ?? -1
                if fa != fb { return fa > fb }
                return a.name < b.name
            }
        let suggested = choices.first?.name

        // Pass 2: per family.
        var out: [Family] = []
        out.reserveCapacity(families.count)
        var trashCount = 0, extraCount = 0, notCovered = 0, keeperRequired = 0
        var trashBytes: Int64 = 0, extraBytes: Int64 = 0
        for fam in families where !fam.isEmpty {
            let f = plan(family: fam, options: options)
            out.append(f)
            trashCount += f.trash.count
            trashBytes += f.trash.reduce(0) { $0 + $1.sizeBytes }
            extraCount += f.extraCount
            extraBytes += f.extraBytes
            if !f.covered { notCovered += 1 }
            if f.covered, f.keeperRequired, f.keeper != nil { keeperRequired += 1 }
        }
        return PrunePlan(families: out, trashCount: trashCount, trashBytes: trashBytes,
                         extraCount: extraCount, extraBytes: extraBytes, notCoveredCount: notCovered,
                         keeperRequiredCount: keeperRequired, keeperVolumes: choices,
                         suggestedKeeperVolume: suggested)
    }

    /// The scrubbable-copy rule for ONE copy, ignoring the family-level
    /// archive test (applied in `plan`): not archive, not inside the root,
    /// online, no note, not a pair member, not a version.
    public static func isCandidate(_ c: ArchiveCopySnapshot) -> Bool {
        !c.isPurged && !c.isArchiveCopy && !c.isInsideArchiveRoot && c.isOnline
            && !c.hasHumanNote && !c.isPairMember && !c.isVersion
    }

    static func plan(family fam: [ArchiveCopySnapshot], options: Options) -> Family {
        let key = fam.first?.contentKey ?? ""
        let display = fam.first(where: { $0.isArchiveCopy || $0.isInsideArchiveRoot })?.filename ?? fam[0].filename
        // Level = the strongest mark in the family (an archive copy is ★★★).
        let level = fam.map { ImportanceBar.level(starRating: $0.starRating, disposition: $0.disposition) }
            .max(by: { $0.rank < $1.rank }) ?? .ordinary
        let req = options.bar.requirement(for: level)

        // Archive state.
        let archiveCopies = fam.filter { $0.isArchiveCopy || $0.isInsideArchiveRoot }
        let archiveVerified = archiveCopies.contains { $0.fixityVerified }

        // Classify the working copies.
        var kept: [KeptCopy] = []
        var candidates: [ArchiveCopySnapshot] = []
        var devicesKept = Set<String>()
        for c in fam where !c.isPurged {
            if c.isArchiveCopy { kept.append(KeptCopy(copy: CopyRef(c), reason: .archiveCopy)); continue }
            if c.isInsideArchiveRoot { kept.append(KeptCopy(copy: CopyRef(c), reason: .insideArchiveRoot)); continue }
            let reason: KeepReason?
            if !c.isOnline { reason = .offline }
            else if c.isPairMember { reason = .pairMember }
            else if c.isVersion { reason = .version }
            else if c.hasHumanNote { reason = .humanNote }
            else { reason = nil }
            if let reason {
                kept.append(KeptCopy(copy: CopyRef(c), reason: reason))
                if !c.volumeName.isEmpty { devicesKept.insert(c.volumeName) }
            } else {
                candidates.append(c)
            }
        }
        let extraCount = candidates.count
        let extraBytes = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }

        // Attestations: latest per kind across the family.
        let latest = BackupAttestation.latestPerKind(fam.flatMap(\.attestations))
        let cloudOrOffsite = latest[.cloud]?.answer == .yes || latest[.offsite]?.answer == .yes

        // No verified archive copy → nothing may go, whatever the bar; the
        // rows show every copy with that reason, none checkable.
        if archiveCopies.isEmpty || !archiveVerified {
            let reason: KeepReason = archiveCopies.isEmpty ? .noArchiveCopy : .archiveUnverified
            kept.append(contentsOf: candidates.map { KeptCopy(copy: CopyRef($0), reason: reason) })
            let advice = archiveCopies.isEmpty
                ? "No archive copy yet — nothing here can go until one is promoted and verified."
                : "The archive copy is not verified yet — nothing here can go until it reads back."
            return Family(key: key, level: level, covered: false, shortfall: reason.displayText, keeper: nil,
                          keeperRequired: false, trash: [], kept: kept, extraCount: extraCount,
                          extraBytes: extraBytes, displayName: display, requirement: req,
                          cloudOrOffsiteAttested: cloudOrOffsite, advice: advice,
                          rows: rows(fam, candidateRole: { _ in (.kept(reason), nil, false) }))
        }

        // Keeper election.
        let keeperRequired = req.extraDevices > devicesKept.count
        var keeper: ArchiveCopySnapshot?
        if !candidates.isEmpty, keeperRequired || options.keepOne {
            keeper = electKeeper(candidates, devicesKept: devicesKept, preferredVolume: options.keeperVolume)
        }
        var devicesAfter = devicesKept
        if let k = keeper, !k.volumeName.isEmpty { devicesAfter.insert(k.volumeName) }

        // The bar.
        let bar = barShortfall(level: level, req: req, devicesAfter: devicesAfter.count, cloudOrOffsite: cloudOrOffsite)
        if let shortfall = bar.shortfall {
            kept.append(contentsOf: candidates.map { KeptCopy(copy: CopyRef($0), reason: .barNotMet) })
            // The bar advises; every candidate is checkable, none checked.
            // The elected keeper is still hinted so the person knows which
            // one the plan would leave behind.
            let keeperID = keeper?.id
            return Family(key: key, level: level, covered: false, shortfall: shortfall,
                          keeper: nil, keeperRequired: keeperRequired, trash: [], kept: kept,
                          extraCount: extraCount, extraBytes: extraBytes, displayName: display,
                          requirement: req, cloudOrOffsiteAttested: cloudOrOffsite, advice: bar.advice,
                          rows: rows(fam, candidateRole: { c in
                              (.candidate, c.id == keeperID ? .keeper : .barNotMet, false)
                          }))
        }
        var trash: [CopyRef] = []
        for c in candidates {
            if let k = keeper, k.id == c.id {
                kept.append(KeptCopy(copy: CopyRef(c), reason: .keeper))
            } else {
                trash.append(CopyRef(c))
            }
        }
        let keeperID = keeper?.id
        return Family(key: key, level: level, covered: true, shortfall: nil, keeper: keeper.map(CopyRef.init),
                      keeperRequired: keeperRequired, trash: trash, kept: kept,
                      extraCount: extraCount, extraBytes: extraBytes, displayName: display,
                      requirement: req, cloudOrOffsiteAttested: cloudOrOffsite, advice: nil,
                      rows: rows(fam, candidateRole: { c in
                          c.id == keeperID ? (.candidate, .keeper, false) : (.candidate, nil, true)
                      }))
    }

    /// The bar's verdict for a family, in both voices: `shortfall` (the
    /// plan's terse line — nil when the bar is met) and `advice` (the
    /// sheet's sentence, ending "You can still choose.").
    static func barShortfall(level: ImportanceBar.Level, req: ImportanceBar.Requirement,
                             devicesAfter: Int, cloudOrOffsite: Bool) -> (shortfall: String?, advice: String?) {
        var shortfalls: [String] = []
        var wants: [String] = [], haves: [String] = []
        if devicesAfter < req.extraDevices {
            let missing = req.extraDevices - devicesAfter
            shortfalls.append("needs \(missing) more device\(missing == 1 ? "" : "s")")
            wants.append("\(req.extraDevices) more device\(req.extraDevices == 1 ? "" : "s")")
            haves.append("\(devicesAfter) here")
        }
        if req.cloudOrOffsite && !cloudOrOffsite {
            shortfalls.append("no cloud or off-site copy attested")
            wants.append("a cloud or off-site copy")
            haves.append("none attested")
        }
        guard !shortfalls.isEmpty else { return (nil, nil) }
        return ("\(level.displayName) — " + shortfalls.joined(separator: ", "),
                "\(level.displayName) — the bar you set wants \(wants.joined(separator: " and ")); "
                    + haves.joined(separator: ", ") + ". You can still choose.")
    }

    /// The checklist rows for one family: archive copies first, then the
    /// working copies in catalog order. Locked reasons (offline / pair /
    /// version / note) are the plan's own; `candidateRole` says what a
    /// copy that passes `isCandidate` becomes in this family — (role,
    /// planKeeps, defaultChecked). O(copies).
    static func rows(_ fam: [ArchiveCopySnapshot],
                     candidateRole: (ArchiveCopySnapshot) -> (CopyRow.Role, KeepReason?, Bool)) -> [CopyRow] {
        var archive: [CopyRow] = [], working: [CopyRow] = []
        for c in fam where !c.isPurged {
            if c.isArchiveCopy {
                archive.append(CopyRow(copy: CopyRef(c), role: .archiveCopy, planKeeps: nil, defaultChecked: false))
            } else if c.isInsideArchiveRoot {
                archive.append(CopyRow(copy: CopyRef(c), role: .insideArchiveRoot, planKeeps: nil, defaultChecked: false))
            } else if let locked = lockedReason(c) {
                working.append(CopyRow(copy: CopyRef(c), role: .kept(locked), planKeeps: nil, defaultChecked: false))
            } else {
                let (role, keeps, checked) = candidateRole(c)
                working.append(CopyRow(copy: CopyRef(c), role: role, planKeeps: keeps, defaultChecked: checked))
            }
        }
        return archive + working
    }

    /// Why a working copy can never be a candidate (nil = it can). The
    /// same order as the classification in `plan`.
    static func lockedReason(_ c: ArchiveCopySnapshot) -> KeepReason? {
        if !c.isOnline { return .offline }
        if c.isPairMember { return .pairMember }
        if c.isVersion { return .version }
        if c.hasHumanNote { return .humanNote }
        return nil
    }

    /// "Keep one" picks the copy on the connected working volume with the
    /// most free space (the design rule); the user's override (a volume
    /// name) wins outright when the family has a copy there. Ties on free
    /// space go to a volume the family has no other copy on (a keeper on
    /// a NEW device adds protection), then to the lower path. Versions
    /// never reach here (they are kept outright), so "original over
    /// versions" is already true.
    static func electKeeper(_ candidates: [ArchiveCopySnapshot], devicesKept: Set<String>,
                            preferredVolume: String?) -> ArchiveCopySnapshot? {
        guard !candidates.isEmpty else { return nil }
        if let pv = preferredVolume, let hit = candidates.filter({ $0.volumeName == pv }).min(by: { $0.fullPath < $1.fullPath }) {
            return hit
        }
        func score(_ c: ArchiveCopySnapshot) -> (Int, Int64, Int) {
            (c.volumeIsConnectedWorking ? 1 : 0, c.volumeFreeBytes ?? -1, devicesKept.contains(c.volumeName) ? 0 : 1)
        }
        return candidates.max { a, b in
            let sa = score(a), sb = score(b)
            if sa.0 != sb.0 { return sa.0 < sb.0 }
            if sa.1 != sb.1 { return sa.1 < sb.1 }
            if sa.2 != sb.2 { return sa.2 < sb.2 }
            return a.fullPath > b.fullPath   // max(by:) → the LOWER path wins
        }
    }
}
