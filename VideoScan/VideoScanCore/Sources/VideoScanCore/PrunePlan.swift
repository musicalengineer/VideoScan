// PrunePlan.swift
// The pure half of "delete as we promote, carefully" (Rick 2026-09-12,
// docs/promote_and_prune_workflow_design.md, stage 2 — DRY RUN ONLY):
//
//   - `ArchiveCopySnapshot` — the Sendable facts about ONE catalog copy
//     that the protection line and the prune plan both read. The model
//     snapshots the catalog once (cheap value capture on the main actor),
//     then everything below runs off-main.
//   - `ArchiveCopyFamilies.group` — families keyed by CONTENT + PROVENANCE
//     (v3, 2026-09-20): same content key, an archive copy joins its
//     promotion source, and a VERSION (trim / balance / transcode — any
//     `derivedFrom` chain of at most four hops that is not a repair)
//     joins the family of the original it was cut from.
//   - `ArchiveCopyFamilies.nameRelated` — per family, the other active
//     records on working volumes whose NAME says "maybe a copy" (same
//     base stem, or the same filename) but whose content does not: never
//     hashed, or hashed differently. The sheet lists them under "Might be
//     copies" with a Hash-to-confirm button; a matching hash joins the
//     family on the next plan, a different one is "different footage".
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
//     covered by the bar" (the advice line; the person still decides).
//   - `PrunePlan.Family.rows` / `PrunePlan.selection` (2026-09-20) — the
//     per-copy CHECKLIST the sheet shows: the bar-respecting plan above is
//     the DEFAULT (what is checked), the family's `advice` is the bar's
//     shortfall in words, and the person decides. `Selection` judges the
//     choice against the bar (the `override` the ledger records).
//
// Rick's ruling (2026-09-20, after using the checklist): "allow me to
// delete any copy or all copies on any drive EXCEPT FamilyArchive … many
// are subsets or improvements or trimmed … don't even list [the archive]
// as an option" — and, in the same breath, "I would rather you be
// cautious with my family media than rampantly allowing me to delete."
// The standing rule (feedback_delete_safety_principle): the app must never
// let the LAST VERIFIED copy go; everything else is the person's call,
// shown clearly, Trash only, logged and ledgered. So:
//   * The archive copies (and anything inside the archive root) are NOT
//     rows. The family header says "In FamilyArchive, verified (N)".
//   * Nothing is checkable in a family without a FIXITY-VERIFIED archive
//     copy — those rows are listed, disabled, with the reason.
//   * Still refused, listed and disabled with the reason: an offline copy
//     ("drive not connected") and a recovered A/V pair half.
//   * A MISSING FILE (2026-09-21, Rick: "'M4drive' was said 'not connected'
//     in some cases which is weird" — the boot volume is M4drive and the
//     file had been moved or deleted outside the app) is neither: the
//     volume is online, the file is not there. It is listed, disabled,
//     with "not on M4drive any more (moved or deleted?)", never a copy for
//     the tier / keeper / device counts, and the sheet offers to remove
//     the row from the catalog (a tombstone — nothing on disk).
//   * A VERSION and a copy WITH A NOTE are checkable — unchecked by
//     default, with the advice in words (the note is carried to the
//     archive copy's record by the apply path before the file goes).
//   * An attestation of "n/a for these" satisfies the bar's cloud-or-off-
//     site want for THIS batch's advice (the ledger still records n/a).
//
// Worst-case memory: one snapshot (~220 bytes + strings) per catalog
// record in the families touched — a 100k-record catalog is ~35 MB
// transiently, plus two id→key dictionaries (~10 MB), released when the
// plan is built. Nothing is cached here.
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
    /// Elsewhere on the volume that hosts the Master Archive (outside its
    /// tree) — or on a drive that cannot be told apart from it while the
    /// archive volume is not connected. Never offered, never moved (Rick
    /// 2026-09-22: "the app should never offer to delete from
    /// FamilyArchive"). Not archive-side: it is still a working copy row.
    public var isOnArchiveVolume: Bool
    /// The VOLUME holding the file is mounted (never "the file exists").
    public var isOnline: Bool
    /// The file is on disk where the catalog says — meaningful only when
    /// `isOnline`; left `true` (unknown) for an offline volume. Filled by
    /// `ArchiveCopyFamilies.checkingFiles` off the main actor, for the
    /// working copies of the batch's families only.
    public var fileExists: Bool
    public var isPairMember: Bool
    /// A balance-audio / trim / transcode of another record (repairs are
    /// not versions) — never elected as the keeper, unchecked by default,
    /// joined to its original's family through `derivedFrom`.
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
    /// Provenance (v3): the record this one was derived from, for ANY
    /// derivation (an archive copy's is its promotion source), and the
    /// verb ("trim", "balanceAudio", "archivePromotion", …; nil for an
    /// older transcode with no stamp).
    public var derivedFrom: UUID?
    public var derivationKind: String?

    public init(id: UUID, filename: String, fullPath: String, volumeName: String, sizeBytes: Int64,
                contentKey: String, promotedFromID: UUID? = nil, isArchiveCopy: Bool = false,
                fixityVerified: Bool = false, isInsideArchiveRoot: Bool = false, isOnline: Bool = true,
                fileExists: Bool = true, isPairMember: Bool = false, isVersion: Bool = false, hasHumanNote: Bool = false,
                starRating: Int = 0, disposition: MediaDisposition = .unreviewed,
                attestations: [BackupAttestation] = [], volumeIsConnectedWorking: Bool = true,
                volumeFreeBytes: Int64? = nil, isPurged: Bool = false,
                derivedFrom: UUID? = nil, derivationKind: String? = nil,
                isOnArchiveVolume: Bool = false) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.volumeName = volumeName
        self.sizeBytes = sizeBytes; self.contentKey = contentKey; self.promotedFromID = promotedFromID
        self.isArchiveCopy = isArchiveCopy; self.fixityVerified = fixityVerified
        self.isInsideArchiveRoot = isInsideArchiveRoot; self.isOnline = isOnline
        self.isOnArchiveVolume = isOnArchiveVolume
        self.fileExists = fileExists; self.isPairMember = isPairMember; self.isVersion = isVersion; self.hasHumanNote = hasHumanNote
        self.starRating = starRating; self.disposition = disposition; self.attestations = attestations
        self.volumeIsConnectedWorking = volumeIsConnectedWorking; self.volumeFreeBytes = volumeFreeBytes
        self.isPurged = isPurged
        self.derivedFrom = derivedFrom ?? promotedFromID
        self.derivationKind = derivationKind
    }

    /// The protection-line view of this copy.
    public var copyFacts: ProtectionSummary.CopyFacts {
        ProtectionSummary.CopyFacts(volumeName: volumeName, isOnline: isOnline,
                                    isArchiveCopy: isArchiveCopy || isInsideArchiveRoot,
                                    fixityVerified: (isArchiveCopy || isInsideArchiveRoot) && fixityVerified,
                                    attestations: attestations)
    }

    /// The archive side of a family: a promoted copy or anything inside
    /// the archive root. Never a row.
    public var isArchiveSide: Bool { isArchiveCopy || isInsideArchiveRoot }

    /// The volume is mounted and the file is not there: a catalog row
    /// with nothing behind it — not a copy.
    public var isMissingFile: Bool { isOnline && !fileExists }

    /// "h" for a segmented content hash, "p" for the partial-MD5 + size
    /// pair, nil when never hashed.
    public var contentKeyKind: Character? { contentKey.first }

    /// The filename without its extension — what name-relatedness reads.
    public var stem: String { (filename as NSString).deletingPathExtension }
}

// MARK: - Families

public enum ArchiveCopyFamilies {

    /// A version joins its original's family through at most this many
    /// `derivedFrom` hops (the app's `isVersionOfArchived` uses the same
    /// bound).
    public static let maxProvenanceHops = 4

    /// Families containing at least one `batch` record, in a stable
    /// order. Key = content key, else identity; an archive copy joins its
    /// promotion source's family; a VERSION joins the family of the first
    /// non-version record up its `derivedFrom` chain (≤ 4 hops — an
    /// original, an archive copy, or a repair, which is its own thing).
    /// Purged copies are dropped. O(snapshots) time, three dictionary
    /// passes.
    public static func group(batch: Set<UUID>, snapshots: [ArchiveCopySnapshot]) -> [[ArchiveCopySnapshot]] {
        guard !batch.isEmpty else { return [] }
        var keyByID: [UUID: String] = [:]
        var indexByID: [UUID: Int] = [:]
        keyByID.reserveCapacity(snapshots.count)
        indexByID.reserveCapacity(snapshots.count)
        for (i, s) in snapshots.enumerated() {
            keyByID[s.id] = s.contentKey.isEmpty ? "i:\(s.id.uuidString)" : s.contentKey
            indexByID[s.id] = i
        }
        // Pass A: archive copies take their source's key (the source may be
        // a version — resolved in pass B, so pass A runs again after it).
        func joinArchiveCopies() {
            for s in snapshots where s.isArchiveCopy {
                if let src = s.promotedFromID, let k = keyByID[src] { keyByID[s.id] = k }
            }
        }
        joinArchiveCopies()
        // Pass B: versions climb to the first non-version ancestor.
        for s in snapshots where s.isVersion && !s.isArchiveSide {
            var cursor = s
            var seen: Set<UUID> = [s.id]
            for _ in 0..<maxProvenanceHops {
                guard let parentID = cursor.derivedFrom, let pi = indexByID[parentID],
                      seen.insert(parentID).inserted else { break }
                let parent = snapshots[pi]
                if !parent.isVersion || parent.isArchiveSide {
                    if let k = keyByID[parent.id] { keyByID[s.id] = k }
                    break
                }
                cursor = parent
            }
        }
        joinArchiveCopies()
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

    /// The protection line for a batch, from the same families. A missing
    /// file is not a copy — it neither counts nor names its volume.
    public static func protection(families: [[ArchiveCopySnapshot]]) -> ProtectionSummary {
        ProtectionSummary.summarize(families: families.map { fam in
            fam.filter { !$0.isMissingFile }.map(\.copyFacts)
        })
    }

    /// The same families with `fileExists` filled in for every WORKING
    /// copy on an online volume (the archive side has its own disk checks
    /// in the apply path; an offline volume cannot be asked). One stat per
    /// working copy in the batch's families — call it off the main actor.
    public static func checkingFiles(_ families: [[ArchiveCopySnapshot]],
                                     fileExists: (String) -> Bool) -> [[ArchiveCopySnapshot]] {
        families.map { fam in
            fam.map { s in
                guard !s.isPurged, !s.isArchiveSide, s.isOnline else { return s }
                var out = s
                out.fileExists = fileExists(s.fullPath)
                return out
            }
        }
    }

    /// "Might be copies" of one family: the related snapshots (capped) and
    /// how many more there were.
    public struct RelatedGroup: Equatable, Sendable {
        public var members: [ArchiveCopySnapshot]
        public var hiddenCount: Int
        public init(members: [ArchiveCopySnapshot] = [], hiddenCount: Int = 0) {
            self.members = members; self.hiddenCount = hiddenCount
        }
        public static let empty = RelatedGroup()
    }

    /// Related rows a family shows at most (a generic name like "Clip 08"
    /// can match hundreds; the rest are counted).
    public static let maxRelatedPerFamily = 20

    /// Per family (same order), the other ACTIVE, reachable records that
    /// are name-related to a member — the same `baseStem` (the app passes
    /// ArchiveAngelFamily.baseStem: derivative and share-out tokens
    /// stripped) or the same filename — but NOT in the family by content.
    /// Archive-side, purged, offline, missing-file and family members (of
    /// ANY family in the batch) are never related rows. (Reachable, not "connected
    /// working": a copy on a retired drive that is plugged in may be
    /// hashed and, if it matches, offered — it is the person's call.)
    /// O(snapshots × stem length) hash lookups; `baseStem` runs only on
    /// the prefix hits, never on every record.
    public static func nameRelated(families: [[ArchiveCopySnapshot]], snapshots: [ArchiveCopySnapshot],
                                   baseStem: (String) -> String = { $0.lowercased() },
                                   maxPerFamily: Int = maxRelatedPerFamily) -> [RelatedGroup] {
        guard !families.isEmpty else { return [] }
        var memberIDs = Set<UUID>()
        var familyOfBase: [String: Int] = [:]
        for (i, fam) in families.enumerated() {
            for m in fam {
                memberIDs.insert(m.id)
                let base = baseStem(m.stem)
                if !base.isEmpty, familyOfBase[base] == nil { familyOfBase[base] = i }
            }
        }
        var out = [RelatedGroup](repeating: .empty, count: families.count)
        guard !familyOfBase.isEmpty else { return out }
        for s in snapshots {
            guard !s.isPurged, !s.isArchiveSide, s.isOnline, s.fileExists, !memberIDs.contains(s.id) else { continue }
            let lower = s.stem.lowercased()
            guard !lower.isEmpty else { continue }
            // A base stem is always a prefix of the lowercased stem, so a
            // prefix miss is a cheap "not related".
            var hit = false
            var prefix = ""
            prefix.reserveCapacity(lower.count)
            for ch in lower {
                prefix.append(ch)
                if familyOfBase[prefix] != nil { hit = true; break }
            }
            guard hit, let idx = familyOfBase[baseStem(s.stem)] else { continue }
            if out[idx].members.count < maxPerFamily {
                out[idx].members.append(s)
            } else {
                out[idx].hiddenCount += 1
            }
        }
        return out
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
        /// An archive-side copy with a read-back fixity record (false for
        /// every working copy).
        public let fixityVerified: Bool
        init(_ s: ArchiveCopySnapshot) {
            id = s.id; filename = s.filename; fullPath = s.fullPath; volumeName = s.volumeName; sizeBytes = s.sizeBytes
            fixityVerified = s.isArchiveSide && s.fixityVerified
        }
    }

    /// Why a copy stays.
    public enum KeepReason: String, Equatable, Sendable {
        case archiveCopy, insideArchiveRoot, offline, pairMember, version, humanNote, keeper, barNotMet
        case noArchiveCopy, archiveUnverified
        /// The volume is connected but the file is not where the catalog
        /// says (moved or deleted outside the app) — not a copy at all.
        case fileMissing
        /// On the Master Archive's volume, outside its tree — only archive
        /// actions change that volume (Rick 2026-09-22).
        case onArchiveVolume

        public var displayText: String {
            switch self {
            case .archiveCopy:       return "the archive copy"
            case .insideArchiveRoot: return "inside the Master Archive"
            case .offline:           return "drive not connected"
            case .fileMissing:       return "file not found — moved or deleted outside the app?"
            case .onArchiveVolume:   return "on the Master Archive volume — only archive actions change it"
            case .pairMember:        return "part of a recovered A/V pair Combine still needs"
            case .version:           return "a version — the original is in the archive"
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
    /// behind, maybe not"). Every non-purged WORKING copy in the family is
    /// a row (the archive copies are the header); the bar ADVISES (the
    /// family's `advice`), the person decides — but nothing is checkable
    /// without a fixity-verified archive copy in the family, and an
    /// offline copy or an A/V pair half is never checkable.
    public struct CopyRow: Equatable, Sendable, Identifiable {
        public enum Role: Equatable, Sendable {
            /// Checkable: passes `isCandidate` and the family has a
            /// verified archive copy.
            case candidate
            /// Never checkable — offline / missing / pair, or any working
            /// copy in a family with no verified archive copy.
            case kept(KeepReason)
        }

        /// The chip: what this copy IS, relative to the archive copy.
        public enum Kind: String, Equatable, Sendable {
            case original, duplicate, balanced, trimmed, transcoded, cleaned, otherVersion

            public var chip: String {
                switch self {
                case .original:     return "original"
                case .duplicate:    return "duplicate"
                case .balanced:     return "balanced"
                case .trimmed:      return "trimmed"
                case .transcoded:   return "transcoded"
                case .cleaned:      return "cleaned"
                case .otherVersion: return "other version"
                }
            }
            public var isVersion: Bool { self != .original && self != .duplicate }

            /// From the snapshot's provenance and whether it is the
            /// promotion source.
            static func of(_ c: ArchiveCopySnapshot, originalID: UUID?) -> Kind {
                guard c.isVersion else { return c.id == originalID ? .original : .duplicate }
                switch c.derivationKind ?? "" {
                case "trim":         return .trimmed
                case "balanceAudio": return .balanced
                case "cleanup":      return .cleaned
                case "", "transcode", "reformat": return .transcoded
                default:             return .otherVersion
                }
            }
        }

        public var id: UUID { copy.id }
        public let copy: CopyRef
        public let role: Role
        public let kind: Kind
        /// The copy carries a human note (the apply path carries it to the
        /// archive copy; a note ADDED since the list was shown holds it).
        public let hasNote: Bool
        /// For a candidate: why the bar-respecting plan would KEEP it
        /// (`.keeper` — the elected working copy; `.barNotMet` — the bar
        /// is not met; `.version` / `.humanNote` — never checked by
        /// default), nil when that plan would Trash it. nil for a kept row.
        public let planKeeps: KeepReason?
        /// The bar-respecting plan would Trash it (= the trash set).
        public let defaultChecked: Bool

        public var checkable: Bool { role == .candidate }

        /// The volume is connected, the file is not there: listed so the
        /// person can remove the row from the catalog; never a copy.
        public var isMissingFile: Bool { role == .kept(.fileMissing) }

        /// Why the box is disabled, or the plan's hint on a checkable row
        /// (nil = a plain candidate).
        public var reasonText: String? {
            switch role {
            case .kept(.fileMissing):
                return "not on \(copy.volumeName.isEmpty ? "its drive" : copy.volumeName) any more (moved or deleted?)"
            case .kept(let r): return r.displayText
            case .candidate:
                switch planKeeps {
                case .keeper:    return "the plan would keep this one"
                case .version:   return "a \(kind.chip) version — the original is in the archive"
                case .humanNote: return "has your note — it will be carried to the archive copy"
                default:         return nil
                }
            }
        }
    }

    /// One "Might be copies" line: name-related, not in the family by
    /// content. Never checkable here — a matching hash makes it a normal
    /// candidate on the next plan.
    public struct RelatedRow: Equatable, Sendable, Identifiable {
        public enum Status: Equatable, Sendable {
            /// Never hashed (or hashed a different way than the family):
            /// "Hash to confirm".
            case needsHash
            /// Hashed, and the hash differs from the family's.
            case differentFootage
        }
        public var id: UUID { copy.id }
        public let copy: CopyRef
        public let status: Status
        public var reasonText: String {
            switch status {
            case .needsHash:        return "same name — hash to confirm it is a copy"
            case .differentFootage: return "different footage — not a copy"
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
        /// Online checkable copies — the "extra copies" the sheet counts
        /// (duplicates, versions and noted copies alike).
        public let extraCount: Int
        public let extraBytes: Int64
        /// A representative name for lists ("2 files are not covered…").
        public let displayName: String
        /// The bar for this family's level — what `selection(_:)` judges
        /// the person's choice against.
        public let requirement: ImportanceBar.Requirement
        /// A cloud or off-site "yes" somewhere in the family.
        public let cloudOrOffsiteAttested: Bool
        /// A cloud or off-site "n/a for these" somewhere in the family
        /// (Rick's ruling: satisfies the bar's want for this batch).
        public let cloudOrOffsiteNotApplicable: Bool
        /// The line under the family header when the bar is not met: the
        /// shortfall in words, ending "You can still choose." — or, with
        /// no verified archive copy, why nothing here may go. nil when
        /// covered.
        public let advice: String?
        /// A quiet line under the header when the bar was satisfied by
        /// the person's word rather than a copy ("you said cloud/off-site
        /// don't apply to these").
        public let note: String?
        /// The archive side that PROVES this family's content is archived
        /// — the header, never rows: archive copies promoted from a
        /// NON-version member, or whose content key equals a non-version
        /// member's. (QA 2026-09-20 BLOCKER: the archive copy of a
        /// trimmed VERSION is not an archive copy of the original — it
        /// lives in `versionArchive`, never here.)
        public let archive: [CopyRef]
        public let archiveVerified: Bool
        /// The first proof copy with a read-back fixity — what the apply
        /// path checks on disk and verifies duplicates against.
        public let verifiedArchive: CopyRef?
        /// Archive copies of VERSIONS in this family ("the trimmed version
        /// is archived too") — a header note, never proof for the original.
        public let versionArchive: [CopyRef]
        /// The checklist: the working copies in catalog order.
        public let rows: [CopyRow]
        /// "Might be copies" — name-related records outside the family.
        public let related: [RelatedRow]
        public let relatedHiddenCount: Int
        /// Family members with no segmented content hash (online) — hashed
        /// along with a related row so the keys can compare.
        public let unhashedMemberIDs: [UUID]

        /// Rows the person may check.
        public var candidateCount: Int { rows.reduce(0) { $0 + ($1.checkable ? 1 : 0) } }
        /// What the bar-respecting plan would Trash (= `trash`'s ids).
        public var defaultSelection: Set<UUID> { Set(rows.lazy.filter(\.defaultChecked).map(\.id)) }
        /// Every row the person may check, in row order.
        public var checkableIDs: [UUID] { rows.filter(\.checkable).map(\.id) }
        /// Rows whose file is gone from a connected volume — removable
        /// from the catalog, never Trashed, never counted.
        public var missingIDs: [UUID] { rows.filter(\.isMissingFile).map(\.id) }
        public var checkableBytes: Int64 { rows.reduce(0) { $0 + ($1.checkable ? $1.copy.sizeBytes : 0) } }
        /// The bar's cloud-or-off-site want is met — by a "yes" or by
        /// "n/a for these".
        public var cloudOrOffsiteSatisfied: Bool { cloudOrOffsiteAttested || cloudOrOffsiteNotApplicable }

        /// The person's choice in THIS family, judged against the bar.
        public func selection(_ selected: Set<UUID>) -> Selection {
            var count = 0, verify = 0
            var bytes: Int64 = 0
            var devicesAfter = Set<String>()
            var archiveOnly = true
            for row in rows {
                // A missing file is not a copy: it holds no device and
                // does not keep the family off "archive only".
                if row.isMissingFile { continue }
                switch row.role {
                case .kept:
                    archiveOnly = false
                    if !row.copy.volumeName.isEmpty { devicesAfter.insert(row.copy.volumeName) }
                case .candidate:
                    if selected.contains(row.id) {
                        count += 1
                        bytes += row.copy.sizeBytes
                        if row.kind == .duplicate { verify += 1 }
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
            if requirement.cloudOrOffsite && !cloudOrOffsiteSatisfied {
                shortfalls.append("no cloud or off-site copy attested")
            }
            let against = shortfalls.isEmpty ? nil : "\(level.displayName) — " + shortfalls.joined(separator: ", ")
            return Selection(count: count, bytes: bytes,
                             overrideCount: against == nil ? 0 : count,
                             overrideShortfalls: against.map { [$0] } ?? [],
                             archiveOnlyFamilies: archiveOnly ? [displayName] : [],
                             verifyCount: verify)
        }

        /// The one log line per family written when the sheet opens, so
        /// "why couldn't I select X" can always be answered from the log:
        /// "what-next: Christmas2008.mov — archive ✓ (1) · 3 copies on
        /// CrucialX9, M4drive, LaCieWorkspace (2 checkable, 1 offline) ·
        /// 2 name-related (2 unhashed)".
        public var logLine: String {
            var parts: [String] = []
            parts.append("archive \(archiveVerified ? "✓" : "✗ unverified") (\(archive.count))"
                         + (versionArchive.isEmpty ? "" : " + \(versionArchive.count) version\(versionArchive.count == 1 ? "" : "s") archived"))
            var volumes: [String] = []
            var seen = Set<String>()
            var checkable = 0, offline = 0, missing = 0, pair = 0, locked = 0, versions = 0, noted = 0
            for r in rows {
                let v = r.copy.volumeName.isEmpty ? "?" : r.copy.volumeName
                if seen.insert(v).inserted { volumes.append(v) }
                switch r.role {
                case .candidate:
                    checkable += 1
                    if r.kind.isVersion { versions += 1 }
                    if r.hasNote { noted += 1 }
                case .kept(.offline): offline += 1
                case .kept(.fileMissing): missing += 1
                case .kept(.pairMember): pair += 1
                case .kept: locked += 1
                }
            }
            var counts: [String] = ["\(checkable) checkable"]
            if versions > 0 { counts.append("\(versions) version\(versions == 1 ? "" : "s")") }
            if noted > 0 { counts.append("\(noted) noted") }
            if offline > 0 { counts.append("\(offline) offline") }
            if missing > 0 { counts.append("\(missing) missing (removable)") }
            if pair > 0 { counts.append("\(pair) pair") }
            if locked > 0 { counts.append("\(locked) locked: \(shortfall ?? "")") }
            parts.append(rows.isEmpty
                         ? "no working copies"
                         : "\(rows.count) cop\(rows.count == 1 ? "y" : "ies") on \(volumes.joined(separator: ", ")) (\(counts.joined(separator: ", ")))")
            if !related.isEmpty || relatedHiddenCount > 0 {
                let unhashed = related.filter { $0.status == .needsHash }.count
                let different = related.count - unhashed
                var r: [String] = []
                if unhashed > 0 { r.append("\(unhashed) unhashed") }
                if different > 0 { r.append("\(different) different") }
                if relatedHiddenCount > 0 { r.append("\(relatedHiddenCount) more") }
                parts.append("\(related.count + relatedHiddenCount) name-related (\(r.joined(separator: ", ")))")
            }
            if let advice { parts.append("advice: \(advice)") }
            if let note { parts.append(note) }
            return "what-next: \(displayName) — " + parts.joined(separator: " · ")
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
        /// Checked `.duplicate` rows — the ones that claim byte identity
        /// with the archive copy and are read in full against it before
        /// they go (QA 2026-09-20 MAJOR: a segmented-hash match is a
        /// candidate, never proof). Versions go on provenance.
        public let verifyCount: Int

        public init(count: Int, bytes: Int64, overrideCount: Int, overrideShortfalls: [String],
                    archiveOnlyFamilies: [String], verifyCount: Int = 0) {
            self.count = count; self.bytes = bytes; self.overrideCount = overrideCount
            self.overrideShortfalls = overrideShortfalls; self.archiveOnlyFamilies = archiveOnlyFamilies
            self.verifyCount = verifyCount
        }

        public static let empty = Selection(count: 0, bytes: 0, overrideCount: 0, overrideShortfalls: [],
                                            archiveOnlyFamilies: [])

        /// "2 copies will be checked byte-for-byte against the archive
        /// before they go." nil when no duplicate is checked.
        public var verifySentence: String? {
            guard verifyCount > 0 else { return nil }
            return "\(verifyCount) cop\(verifyCount == 1 ? "y" : "ies") will be checked byte-for-byte against the archive before \(verifyCount == 1 ? "it goes" : "they go")."
        }

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

    /// Rows whose file is gone from a connected volume, across the batch.
    public var missingIDs: [UUID] { families.flatMap(\.missingIDs) }
    public var missingCount: Int { families.reduce(0) { $0 + $1.missingIDs.count } }

    public var checkableCount: Int { families.reduce(0) { $0 + $1.candidateCount } }
    public var checkableBytes: Int64 { families.reduce(0) { $0 + $1.checkableBytes } }
    public var rowCount: Int { families.reduce(0) { $0 + $1.rows.count } }
    public var relatedCount: Int { families.reduce(0) { $0 + $1.related.count } }

    /// The person's choice across the batch, judged against the bar.
    public func selection(_ selected: Set<UUID>) -> Selection {
        guard !selected.isEmpty else { return .empty }
        var count = 0, overrides = 0, verify = 0
        var bytes: Int64 = 0
        var shortfalls: [String] = []
        var seen = Set<String>()
        var archiveOnly: [String] = []
        for f in families {
            let s = f.selection(selected)
            count += s.count
            bytes += s.bytes
            overrides += s.overrideCount
            verify += s.verifyCount
            for text in s.overrideShortfalls where seen.insert(text).inserted { shortfalls.append(text) }
            archiveOnly.append(contentsOf: s.archiveOnlyFamilies)
        }
        return Selection(count: count, bytes: bytes, overrideCount: overrides,
                         overrideShortfalls: shortfalls, archiveOnlyFamilies: archiveOnly, verifyCount: verify)
    }

    public static let empty = PrunePlan(families: [], trashCount: 0, trashBytes: 0, extraCount: 0, extraBytes: 0,
                                        notCoveredCount: 0, keeperRequiredCount: 0, keeperVolumes: [],
                                        suggestedKeeperVolume: nil)

    // MARK: Compute

    /// `related` is per family (same order) from `nameRelated`; empty when
    /// the caller did not look.
    public static func compute(families: [[ArchiveCopySnapshot]],
                               related: [ArchiveCopyFamilies.RelatedGroup] = [],
                               options: Options) -> PrunePlan {
        // Pass 1: candidate volumes across every family (the picker) —
        // where a KEEPER may live, so plain copies only.
        var volumeFree: [String: Int64?] = [:]
        var volumeFamilies: [String: Int] = [:]
        for fam in families {
            var seen = Set<String>()
            for c in fam where isPlainCandidate(c) && c.volumeIsConnectedWorking && !c.volumeName.isEmpty {
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
        for (i, fam) in families.enumerated() where !fam.isEmpty {
            let group = i < related.count ? related[i] : .empty
            let f = plan(family: fam, related: group, options: options)
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
    /// online, ON DISK, not a pair member. Versions and noted copies ARE
    /// candidates (Rick's ruling 2026-09-20) — unchecked by default, see
    /// `isPlainCandidate`.
    public static func isCandidate(_ c: ArchiveCopySnapshot) -> Bool {
        !c.isPurged && !c.isArchiveSide && !c.isOnArchiveVolume && c.isOnline && c.fileExists && !c.isPairMember
    }

    /// A candidate the bar-respecting plan may elect or Trash by default:
    /// a plain copy — not a version, no note.
    public static func isPlainCandidate(_ c: ArchiveCopySnapshot) -> Bool {
        isCandidate(c) && !c.isVersion && !c.hasHumanNote
    }

    static func plan(family fam: [ArchiveCopySnapshot], related: ArchiveCopyFamilies.RelatedGroup,
                     options: Options) -> Family {
        let key = fam.first?.contentKey ?? ""
        let display = fam.first(where: \.isArchiveSide)?.filename ?? fam[0].filename
        // Level = the strongest mark in the family (an archive copy is ★★★).
        let level = fam.map { ImportanceBar.level(starRating: $0.starRating, disposition: $0.disposition) }
            .max(by: { $0.rank < $1.rank }) ?? .ordinary
        let req = options.bar.requirement(for: level)

        // Archive state — the header, never rows. PROOF that THIS content
        // is archived: an archive copy promoted from a NON-version member,
        // or one whose content key equals a non-version member's. The
        // archive copy of a trimmed VERSION (which pass B joined to the
        // original's family) proves nothing for the original — the only
        // archived bytes are the trimmed ones (QA 2026-09-20 BLOCKER).
        let originalMemberIDs = Set(fam.lazy.filter { !$0.isPurged && !$0.isArchiveSide && !$0.isVersion }.map(\.id))
        let originalKeys = Set(fam.lazy.filter { !$0.isPurged && !$0.isArchiveSide && !$0.isVersion && !$0.contentKey.isEmpty }.map(\.contentKey))
        var archiveCopies: [ArchiveCopySnapshot] = []
        var versionArchiveCopies: [ArchiveCopySnapshot] = []
        for c in fam where c.isArchiveSide && !c.isPurged {
            let bySource = c.promotedFromID.map(originalMemberIDs.contains) ?? false
            let byContent = !c.contentKey.isEmpty && originalKeys.contains(c.contentKey)
            if bySource || byContent { archiveCopies.append(c) } else { versionArchiveCopies.append(c) }
        }
        let archiveVerified = archiveCopies.contains { $0.fixityVerified }
        let archiveRefs = archiveCopies.map(CopyRef.init)
        let verifiedArchive = archiveCopies.first { $0.fixityVerified }.map(CopyRef.init)
        let versionArchiveRefs = versionArchiveCopies.map(CopyRef.init)
        let originalID = archiveCopies.compactMap(\.promotedFromID).first

        // Classify the working copies.
        var kept: [KeptCopy] = []
        var plain: [ArchiveCopySnapshot] = []
        var soft: [ArchiveCopySnapshot] = []        // versions / noted: checkable, never elected
        var devicesKept = Set<String>()
        for c in fam where !c.isPurged {
            if c.isArchiveCopy { kept.append(KeptCopy(copy: CopyRef(c), reason: .archiveCopy)); continue }
            if c.isInsideArchiveRoot { kept.append(KeptCopy(copy: CopyRef(c), reason: .insideArchiveRoot)); continue }
            if let locked = lockedReason(c) {
                kept.append(KeptCopy(copy: CopyRef(c), reason: locked))
                // A missing file holds no device (an offline copy does —
                // it exists, on a drive that is not here).
                // Nor does a copy on the archive's own volume: it is not an
                // EXTRA device beyond the archive (conservative — the bar
                // counts fewer devices, so fewer copies are offered).
                if locked != .fileMissing, locked != .onArchiveVolume, !c.volumeName.isEmpty {
                    devicesKept.insert(c.volumeName)
                }
            } else if softReason(c) != nil {
                // Listed in `kept` below with its reason (or the family's
                // no-archive reason); it still counts as a device.
                if !c.volumeName.isEmpty { devicesKept.insert(c.volumeName) }
                soft.append(c)
            } else {
                plain.append(c)
            }
        }
        let extraCount = plain.count + soft.count
        let extraBytes = (plain + soft).reduce(Int64(0)) { $0 + $1.sizeBytes }

        // Attestations: latest per kind across the family. "n/a for these"
        // satisfies the want for this batch (Rick's ruling); "no" does not.
        let latest = BackupAttestation.latestPerKind(fam.flatMap(\.attestations))
        let cloudOrOffsite = latest[.cloud]?.answer == .yes || latest[.offsite]?.answer == .yes
        let notApplicable = !cloudOrOffsite
            && (latest[.cloud]?.answer == .notApplicable || latest[.offsite]?.answer == .notApplicable)
        let note: String? = req.cloudOrOffsite && notApplicable
            ? "You said cloud and off-site copies don't apply to these — the bar is met on your word."
            : nil

        // Might-be-copies rows and the members that need a hash to compare.
        let memberKinds = Set(fam.lazy.filter { !$0.isVersion && !$0.isPurged }.compactMap(\.contentKeyKind))
        let relatedRows = related.members.map { s -> RelatedRow in
            var status = RelatedRow.Status.needsHash
            if let kind = s.contentKeyKind, memberKinds.contains(kind) { status = .differentFootage }
            return RelatedRow(copy: CopyRef(s), status: status)
        }
        let unhashed = fam.filter { !$0.isPurged && !$0.isVersion && $0.isOnline && $0.fileExists && $0.contentKeyKind != "h" }.map(\.id)

        func make(covered: Bool, shortfall: String?, keeper: CopyRef?, keeperRequired: Bool, trash: [CopyRef],
                  kept: [KeptCopy], advice: String?, rows: [CopyRow]) -> Family {
            Family(key: key, level: level, covered: covered, shortfall: shortfall, keeper: keeper,
                   keeperRequired: keeperRequired, trash: trash, kept: kept, extraCount: extraCount,
                   extraBytes: extraBytes, displayName: display, requirement: req,
                   cloudOrOffsiteAttested: cloudOrOffsite, cloudOrOffsiteNotApplicable: notApplicable,
                   advice: advice, note: note, archive: archiveRefs, archiveVerified: archiveVerified,
                   verifiedArchive: verifiedArchive, versionArchive: versionArchiveRefs, rows: rows,
                   related: relatedRows, relatedHiddenCount: related.hiddenCount, unhashedMemberIDs: unhashed)
        }

        // No verified archive copy → nothing may go, whatever the bar; the
        // rows show every copy with that reason, none checkable. THE rule
        // the ruling keeps: the last verified copy never goes.
        if archiveCopies.isEmpty || !archiveVerified {
            let reason: KeepReason = archiveCopies.isEmpty ? .noArchiveCopy : .archiveUnverified
            kept.append(contentsOf: (plain + soft).map { KeptCopy(copy: CopyRef($0), reason: reason) })
            let advice: String
            if !archiveCopies.isEmpty {
                advice = "The archive copy is not verified yet — nothing here can go until it reads back."
            } else if !versionArchiveCopies.isEmpty {
                advice = "Only a version of this is archived (\(versionArchiveCopies.map(\.filename).joined(separator: ", "))) — the original must be promoted and verified before anything here can go."
            } else {
                advice = "No archive copy yet — nothing here can go until one is promoted and verified."
            }
            return make(covered: false, shortfall: reason.displayText, keeper: nil, keeperRequired: false,
                        trash: [], kept: kept, advice: advice,
                        rows: rows(fam, originalID: originalID, candidateRole: { _ in (.kept(reason), nil, false) }))
        }

        // Versions and noted copies stay by default, with their reason.
        for c in soft { if let s = softReason(c) { kept.append(KeptCopy(copy: CopyRef(c), reason: s)) } }

        // Keeper election — among the plain copies; a version or a noted
        // copy is never elected ("original over versions").
        let keeperRequired = req.extraDevices > devicesKept.count
        var keeper: ArchiveCopySnapshot?
        if !plain.isEmpty, keeperRequired || options.keepOne {
            keeper = electKeeper(plain, devicesKept: devicesKept, preferredVolume: options.keeperVolume)
        }
        var devicesAfter = devicesKept
        if let k = keeper, !k.volumeName.isEmpty { devicesAfter.insert(k.volumeName) }

        // The bar.
        let bar = barShortfall(level: level, req: req, devicesAfter: devicesAfter.count,
                               cloudOrOffsite: cloudOrOffsite || notApplicable)
        if let shortfall = bar.shortfall {
            kept.append(contentsOf: plain.map { KeptCopy(copy: CopyRef($0), reason: .barNotMet) })
            // The bar advises; every candidate is checkable, none checked.
            // The elected keeper is still hinted so the person knows which
            // one the plan would leave behind.
            let keeperID = keeper?.id
            return make(covered: false, shortfall: shortfall, keeper: nil, keeperRequired: keeperRequired,
                        trash: [], kept: kept, advice: bar.advice,
                        rows: rows(fam, originalID: originalID, candidateRole: { c in
                            if let s = softReason(c) { return (.candidate, s, false) }
                            return (.candidate, c.id == keeperID ? .keeper : .barNotMet, false)
                        }))
        }
        var trash: [CopyRef] = []
        for c in plain {
            if let k = keeper, k.id == c.id {
                kept.append(KeptCopy(copy: CopyRef(c), reason: .keeper))
            } else {
                trash.append(CopyRef(c))
            }
        }
        let keeperID = keeper?.id
        return make(covered: true, shortfall: nil, keeper: keeper.map(CopyRef.init), keeperRequired: keeperRequired,
                    trash: trash, kept: kept, advice: nil,
                    rows: rows(fam, originalID: originalID, candidateRole: { c in
                        if let s = softReason(c) { return (.candidate, s, false) }
                        return c.id == keeperID ? (.candidate, .keeper, false) : (.candidate, nil, true)
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

    /// The checklist rows for one family: the WORKING copies in catalog
    /// order (archive copies are the header). Locked reasons (offline /
    /// missing / pair) are the plan's own; `candidateRole` says what a copy that
    /// passes `isCandidate` becomes in this family — (role, planKeeps,
    /// defaultChecked). O(copies).
    static func rows(_ fam: [ArchiveCopySnapshot], originalID: UUID?,
                     candidateRole: (ArchiveCopySnapshot) -> (CopyRow.Role, KeepReason?, Bool)) -> [CopyRow] {
        var working: [CopyRow] = []
        for c in fam where !c.isPurged && !c.isArchiveSide {
            let kind = CopyRow.Kind.of(c, originalID: originalID)
            if let locked = lockedReason(c) {
                working.append(CopyRow(copy: CopyRef(c), role: .kept(locked), kind: kind, hasNote: c.hasHumanNote,
                                       planKeeps: nil, defaultChecked: false))
            } else {
                let (role, keeps, checked) = candidateRole(c)
                working.append(CopyRow(copy: CopyRef(c), role: role, kind: kind, hasNote: c.hasHumanNote,
                                       planKeeps: keeps, defaultChecked: checked))
            }
        }
        return working
    }

    /// Why a working copy can never be a candidate (nil = it can): its
    /// volume is not reachable, its file is not there, or it is a
    /// recovered A/V pair half. Offline is judged first: an unmounted
    /// volume cannot say whether the file exists.
    static func lockedReason(_ c: ArchiveCopySnapshot) -> KeepReason? {
        // First: a settled fact about the copy, whatever the drive's state.
        if c.isOnArchiveVolume { return .onArchiveVolume }
        if !c.isOnline { return .offline }
        if !c.fileExists { return .fileMissing }
        if c.isPairMember { return .pairMember }
        return nil
    }

    /// Why the bar-respecting plan leaves a candidate unchecked by
    /// default and never elects it (nil = a plain copy).
    static func softReason(_ c: ArchiveCopySnapshot) -> KeepReason? {
        if c.isVersion { return .version }
        if c.hasHumanNote { return .humanNote }
        return nil
    }

    /// "Keep one" picks the copy on the connected working volume with the
    /// most free space (the design rule); the user's override (a volume
    /// name) wins outright when the family has a copy there. Ties on free
    /// space go to a volume the family has no other copy on (a keeper on
    /// a NEW device adds protection), then to the lower path. Versions
    /// never reach here (they are soft candidates), so "original over
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
