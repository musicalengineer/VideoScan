// VolumeShowFilter.swift
// Which volumes the Catalog tab's volume list shows — the volume-side
// twin of CatalogShowingSummary (Rick 2026-08-28: "probably the default
// is to show only connected, workspace, or archive volumes… what does
// matter is that I see all the media online and available. Conform it
// to look like catalog list where we have Show pulldown then a
// highlight of what is showing, no need for 'Showing:'").
//
// Three independent knobs, all persisted together:
//   connectedOnly  — AND: hide volumes that are not mounted right now
//   roles          — OR:  which VolumeRole kinds are listed
//   includeRetired — reveal: retired volumes are hidden unless asked for
//
// Default = connected + every role + no retired → "media online and
// available". The old Show items (Network, Uncataloged, With Errors…)
// still narrow on top of this; they used to own "Connected" and no
// longer do.
//
// Pure value type — headless-testable, no SwiftUI state, no model.

import Foundation
import SwiftUI
import VideoScanCore

// MARK: - The filter

/// `Codable` ≈ auto-generated serialize/deserialize (JSON here). Adding
/// a field later needs a default so old saved copies still decode.
struct VolumeShowFilter: Codable, Equatable {
    var connectedOnly: Bool = true
    var roles: Set<VolumeRole> = Set(VolumeRole.allCases)
    var includeRetired: Bool = false

    /// "Media online and available" — the launch default.
    static let `default` = VolumeShowFilter()

    /// The everything-goes state behind the "All volumes" menu item.
    static let all = VolumeShowFilter(connectedOnly: false,
                                      roles: Set(VolumeRole.allCases),
                                      includeRetired: true)

    var isAll: Bool { self == .all }

    // MARK: Menu vocabulary

    /// The role toggles the Show menu offers, in reading order. System +
    /// Unassigned are folded into one "Other" entry — nobody files media
    /// by "unassigned", and the boot volume is a curiosity, not a choice.
    enum RoleGroup: String, CaseIterable, Identifiable {
        case archive   = "Master Archive"
        case workspace = "Workspace"
        case backup    = "Backup"
        case cloud     = "Cloud"
        case other     = "Other"

        var id: String { rawValue }

        var members: [VolumeRole] {
            switch self {
            case .archive:   return [.archive]
            case .workspace: return [.workspace]
            case .backup:    return [.backup]
            case .cloud:     return [.cloud]
            case .other:     return [.unassigned, .system]
            }
        }

        var icon: String {
            switch self {
            case .archive:   return "archivebox"
            case .workspace: return "externaldrive"
            case .backup:    return "externaldrive.badge.checkmark"
            case .cloud:     return "icloud"
            case .other:     return "questionmark.folder"
            }
        }

        /// Pill / chip text — shorter than the menu label where it helps.
        var words: String { self == .archive ? "Archive" : rawValue }
    }

    func includes(_ group: RoleGroup) -> Bool {
        group.members.contains { roles.contains($0) }
    }

    mutating func toggle(_ group: RoleGroup) {
        if includes(group) {
            roles.subtract(group.members)
        } else {
            roles.formUnion(group.members)
        }
        // Nothing ticked lists nothing — snap back to every role rather
        // than present an empty table with no hint why.
        if roles.isEmpty { roles = Set(VolumeRole.allCases) }
    }

    // MARK: Predicate

    /// One volume in, keep/hide out. O(1); the caller maps it over the
    /// scan targets once per redraw (O(volumes), never O(records)).
    func admits(role: VolumeRole, isReachable: Bool, isRetired: Bool) -> Bool {
        if connectedOnly && !isReachable { return false }
        if isRetired && !includeRetired { return false }
        return roles.contains(role)
    }

    // MARK: Summary chip words

    /// "Connected · Archive · Workspace · Backup · Cloud · Other" — or
    /// "All volumes" — with "5 of 9" appended whenever something is
    /// hidden. No "Showing:" prefix (Rick).
    func summary(shown: Int, total: Int) -> String {
        var parts: [String] = []
        if isAll {
            parts.append("All volumes")
        } else {
            if connectedOnly { parts.append("Connected") }
            for g in RoleGroup.allCases where includes(g) {
                parts.append(g.words)
            }
            if includeRetired { parts.append("Retired") }
        }
        var text = parts.joined(separator: " · ")
        if shown < total {
            text += " — \(shown) of \(total)"
        }
        return text
    }

    // MARK: Persistence

    /// One UserDefaults string. Unknown / malformed → the default, never a
    /// crash. Roles that a later build removes are dropped by the decoder
    /// (VolumeRole's rawValue init fails → whole decode fails → default),
    /// which is the safe outcome for a display filter.
    static func encode(_ f: VolumeShowFilter) -> String {
        guard let data = try? JSONEncoder().encode(f),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    static func decode(_ raw: String) -> VolumeShowFilter {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let f = try? JSONDecoder().decode(VolumeShowFilter.self, from: data),
              !f.roles.isEmpty else { return .default }
        return f
    }
}

// MARK: - The chip

/// The highlighted summary beside the volume list's Show menu. Same
/// geometry and type size as `CatalogShowingBox`; neutral fill because
/// there is no to-do/done distinction to colour here.
struct VolumeShowingBox: View {
    let filter: VolumeShowFilter
    let shown: Int
    let total: Int

    private static let font = Font.system(size: 14, weight: .semibold)

    var body: some View {
        Text(filter.summary(shown: shown, total: total))
            .font(Self.font)
            .foregroundColor(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.18)))
            .help("Which volumes are listed. Use the Show menu to change it.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Showing " + filter.summary(shown: shown, total: total))
            .accessibilityIdentifier("catalog.volumeShowingBox")
    }
}
