// VolumeStatusEnums.swift
// Volume lifecycle / role / trust / media-tech enums — moved verbatim
// from Models.swift (refactor 2026-06-26, model decomposition step 1), then
// into the VideoScanCore package (2026-06-26 step 3). The SwiftUI display
// accessors (SF Symbol / Color / short-label properties) live in
// ModelsUI/VolumeStatusEnums+Presentation.swift and the wholly-UI
// DestinationPolicy enum in ModelsUI/DestinationPolicy.swift, app-side, so
// this file is Foundation-only. `public` added during package extraction so
// the app target (which sees the package via @_exported) reads these
// unchanged.
//
// 2026-08-16 — volume-role taxonomy cleanup (docs/volume_taxonomy_proposal.md,
// approved by Rick): `.retired` REMOVED (retirement is a lifecycle event
// owned solely by `CatalogScanTarget.retiredAt`), `.lta` RENAMED `.offsite`
// (raw "Offsite"), `.working` ADDED. Legacy raw strings still decode via
// `VolumeRole.decodeLegacy(_:)` — every persistence path goes through it.

import Foundation

// MARK: - Volume Phase (lifecycle)

public enum VolumePhase: String, CaseIterable, Codable {
    case noCatalog    = "NO CATALOG"
    case cataloged    = "Cataloged"
    case reviewed     = "Reviewed"
    case consolidated = "Consolidated"
    case archived     = "Archived"

    // Legacy decoding: "New" → .noCatalog
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "New" { self = .noCatalog; return }
        guard let v = VolumePhase(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "Unknown VolumePhase: \(raw)")
        }
        self = v
    }

    /// Next phase in the lifecycle, or nil if already archived.
    public var next: VolumePhase? {
        guard let idx = Self.allCases.firstIndex(of: self),
              idx + 1 < Self.allCases.count else { return nil }
        return Self.allCases[idx + 1]
    }
}

// MARK: - Volume Role

/// What a volume is FOR (user intent). One owner per concern: retirement
/// is NOT a role (see `CatalogScanTarget.retiredAt`), safety is derived
/// (`destinationPolicy`), condition is `VolumeTrust`.
///
///   unassigned  — never classified
///   system      — the boot volume root; auto-assigned, never user-picked
///   working     — current-time media, scratch, edits, projects
///   original    — source-of-truth camera/tape captures
///   backup      — a copy of something else
///   archive     — THE Master Archive; set only by Initialize, never picked
///   offsite     — the 3-2-1 third leg (was "Long-Term Archive")
public enum VolumeRole: String, CaseIterable, Codable, Sendable {
    case unassigned  = "Unassigned"
    case system      = "System"
    case working     = "Working"
    case original    = "Original"
    case backup      = "Backup"
    case archive     = "Archive"
    case offsite     = "Offsite"

    /// The roles a user may CHOOSE in any role picker/menu. `.archive` is
    /// reserved for the Master Archive (Initialize sets it) and `.system`
    /// is auto-assigned to the boot volume — both are display-only.
    /// Every role picker in the app must iterate this, never `allCases`.
    public static let pickerCases: [VolumeRole] = [.unassigned, .working, .original, .backup, .offsite]

    /// True for roles the user may set by hand.
    public var isUserSelectable: Bool { Self.pickerCases.contains(self) }

    /// Picker menu contents for a target currently holding `current`:
    /// `pickerCases`, plus `current` when it is a display-only role so
    /// SwiftUI's Picker still has a valid selection (a legacy non-master
    /// "Archive" target keeps showing Archive until the user picks
    /// something else; nothing offers Archive/System afresh).
    public static func pickerChoices(including current: VolumeRole) -> [VolumeRole] {
        pickerCases.contains(current) ? pickerCases : pickerCases + [current]
    }

    // MARK: Legacy decoding

    /// Result of decoding a persisted role string, legacy or current.
    /// Carries the side-channel facts the migration needs (`wasRetired`)
    /// without smuggling them back into the enum.
    public struct LegacyDecode: Equatable, Sendable {
        public let role: VolumeRole
        /// The raw string was the pre-2026-08-16 "Retired" role. The caller
        /// must stamp `retiredAt` (retirement's ONE owner) if it is nil.
        public let wasRetired: Bool
        /// The raw string was not recognised at all — decoded as
        /// `.unassigned`; caller should log it. Nil when recognised.
        public let unknownRaw: String?

        public init(role: VolumeRole, wasRetired: Bool = false, unknownRaw: String? = nil) {
            self.role = role
            self.wasRetired = wasRetired
            self.unknownRaw = unknownRaw
        }
    }

    /// Pre-taxonomy raw strings and their targets. Kept as data so the
    /// test matrix and the decoder agree by construction.
    ///   "Long-Term Archive" → .offsite   (rename)
    ///   "Retired"           → .unassigned + wasRetired (role → lifecycle event)
    ///   "LTA"               → .offsite   (short label some hand-edits used)
    public static let legacyRawValues: [String: VolumeRole] = [
        "Long-Term Archive": .offsite,
        "LTA":               .offsite,
        "Retired":           .unassigned,
    ]

    /// Decode ANY persisted role string — current or legacy — never
    /// failing. Unknown strings decode to `.unassigned` (and are reported
    /// via `unknownRaw`) so a target is never dropped for a bad role.
    /// Whitespace-tolerant and case-insensitive on the fallback path so a
    /// hand-edited plist ("backup") still lands.
    public static func decodeLegacy(_ raw: String) -> LegacyDecode {
        if let r = VolumeRole(rawValue: raw) { return LegacyDecode(role: r) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = VolumeRole(rawValue: trimmed) { return LegacyDecode(role: r) }
        if let r = legacyRawValues[trimmed] {
            return LegacyDecode(role: r, wasRetired: trimmed == "Retired")
        }
        // Case-insensitive last chance across current + legacy tables.
        let folded = trimmed.lowercased()
        if let r = VolumeRole.allCases.first(where: { $0.rawValue.lowercased() == folded }) {
            return LegacyDecode(role: r)
        }
        if let (k, r) = legacyRawValues.first(where: { $0.key.lowercased() == folded }) {
            return LegacyDecode(role: r, wasRetired: k == "Retired")
        }
        return LegacyDecode(role: .unassigned, unknownRaw: raw)
    }

    /// Convenience: the role alone. Nil ONLY for an unrecognised string
    /// (so callers that want the fall-back-to-unassigned behaviour use
    /// `decodeLegacy`, and callers that want to *know* use this).
    public init?(legacyRawValue raw: String) {
        let d = VolumeRole.decodeLegacy(raw)
        guard d.unknownRaw == nil else { return nil }
        self = d.role
    }

    /// Codable: accept legacy raw strings anywhere a VolumeRole is JSON-
    /// decoded directly (Foundation `Codable` ≈ a C++ serialization
    /// operator overload). Unknown strings decode to `.unassigned` — a
    /// role is never worth failing a whole document over. Note the
    /// "Retired" side channel is lost on this path; the two real
    /// persistence paths (UserDefaults dictionaries, bundle snapshots)
    /// store strings and use `decodeLegacy` so nothing is lost there.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VolumeRole.decodeLegacy(raw).role
    }
}

public enum VolumeTrust: String, CaseIterable, Codable, Sendable {
    case unknown    = "Unknown"
    case reliable   = "Reliable"
    case aging      = "Aging"
    case unreliable = "Unreliable"
}

// MARK: - Volume Media Technology

public enum VolumeMediaTech: String, CaseIterable, Codable {
    case unknown = "Unknown"
    case ssd     = "SSD"
    case hdd     = "HDD"
    case raid0   = "RAID-0"
    case raid1   = "RAID-1"
    case raid5   = "RAID-5"
    case raid10  = "RAID-10"
    case cloud   = "Cloud"
    case network = "Network"

    /// Multi-disk redundancy: a single-disk failure doesn't lose the volume.
    public var isRedundant: Bool {
        switch self {
        case .raid1, .raid5, .raid10, .cloud: return true
        default: return false
        }
    }

    /// RAID-0 doubles failure probability with no redundancy — never an
    /// archive destination, even when new.
    public var isFragile: Bool { self == .raid0 }
}
