// TreeLinkBadge.swift
// The little "GEDCOM ID flag" on each People-tab card (Rick, 2026-08-29:
// "so we know the biography and gedcom are satisfied about that person").
//
// Two halves, kept apart so the first is testable without a window:
//
//   • `TreeLinkBadge` — a pure value: which of the five visible states a
//     profile is in, the short label, and the tooltip. Built by
//     `TreeLinkBadge.state(for:profile:)` from the Show-in-Family-Tree
//     reducer's verdict plus the profile's persisted pin fields. `nil` means
//     "no badge" (no tree installed, or nothing derivable yet).
//   • `TreeLinkBadgeView` — the capsule. Clicking it runs the SAME flow as
//     right-click → "Show in Family Tree" (nag-button pattern: the badge is
//     the entry point that performs the fix).
//
// The per-profile map is memoised in TreeIdentityCenter.treeLinkBadges(for:)
// — one pass per (tree generation, identity signature, pinsRevision,
// derivation pass); a card render is a dictionary lookup.
//
// C++ readers: `TreeLinkBadge?` in a `[String: TreeLinkBadge]` value is the
// std::optional<T> you'd get back from map::find — the enum `Kind` is a
// plain tagged value, no payload.

import SwiftUI

struct TreeLinkBadge: Equatable, Sendable {
    enum Kind: Equatable, Sendable, CaseIterable {
        /// A usable pin: tree icon + the FamilySearch ID, green.
        case pinned
        /// Derivable but unconfirmed ("derived — confirm"), amber.
        case derived
        /// Several records could be them ("?"), grey.
        case ambiguous
        /// Stale / unreadable / colliding pin ("fix pin"), red.
        case pinProblem
        /// Rick said they are not on the tree — plain outline.
        case notInTree
    }

    let kind: Kind
    /// Short capsule text. The FSID is short ("GVQV-NW3") and is never
    /// truncated; the other labels are one or two words.
    let label: String
    /// Full sentence for the tooltip / accessibility value.
    let tooltip: String

    // MARK: State mapping

    /// The badge for one profile, or nil for "no badge" (`.noTree`, `.none`).
    static func state(for state: ShowInTreeState, profile: POIProfile) -> TreeLinkBadge? {
        switch state {
        case .noTree, .none:
            return nil
        case .pinned(let candidate):
            return TreeLinkBadge(
                kind: .pinned,
                label: candidate.code,
                tooltip: "\(candidate.label) · \(candidate.code) · \(describeAttestation(profile.treeIdentityAttestation))")
        case .derived(let candidate, let reason):
            return TreeLinkBadge(
                kind: .derived,
                label: "confirm",
                tooltip: "Looks like \(candidate.label) · \(candidate.code) (\(reason.rawValue)) — click to confirm")
        case .ambiguous(let candidates):
            return TreeLinkBadge(
                kind: .ambiguous,
                label: "?",
                tooltip: "\(candidates.count) tree records could be \(profile.name) — which one? Click to choose")
        case .pinProblem(let why):
            return TreeLinkBadge(
                kind: .pinProblem,
                label: "fix pin",
                tooltip: "\(why) — click to fix")
        case .notInTree:
            return TreeLinkBadge(
                kind: .notInTree,
                label: "not in tree",
                tooltip: "\(profile.name) is not in the family tree (click to change that)")
        }
    }

    /// "picked: Rick, 2026-08-29" → "confirmed 2026-08-29";
    /// "derived: owner setting (Show in Family Tree)" → "derived: owner setting";
    /// nil → "pinned before attestations were recorded".
    static func describeAttestation(_ attestation: String?) -> String {
        guard let attestation, !attestation.isEmpty else {
            return "pinned before attestations were recorded"
        }
        if attestation.hasPrefix("picked:") {
            // Everything after the last comma is the date the picker wrote.
            if let comma = attestation.lastIndex(of: ",") {
                let date = attestation[attestation.index(after: comma)...]
                    .trimmingCharacters(in: .whitespaces)
                if !date.isEmpty { return "confirmed \(date)" }
            }
            return "confirmed"
        }
        if attestation.hasPrefix("derived:") {
            // Drop the "(Show in Family Tree)" provenance suffix — the
            // tooltip only needs the evidence source.
            if let paren = attestation.range(of: " (") {
                return String(attestation[..<paren.lowerBound])
            }
            return attestation
        }
        return attestation
    }

    // MARK: Presentation

    var systemImage: String {
        switch kind {
        case .pinned:     return "tree.fill"
        case .derived:    return "tree"
        case .ambiguous:  return "questionmark"
        case .pinProblem: return "exclamationmark.triangle.fill"
        case .notInTree:  return "tree"
        }
    }

    var tint: Color {
        switch kind {
        case .pinned:     return .green
        case .derived:    return .orange
        case .ambiguous:  return .gray
        case .pinProblem: return .red
        case .notInTree:  return .secondary
        }
    }

    /// `.notInTree` is drawn as an outline; the rest are filled capsules.
    var isOutline: Bool { kind == .notInTree }
}

/// The People-tab header's "Show:" chip.
enum TreeLinkFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case linked = "Linked"
    case needsConfirm = "Needs confirm"
    case notLinked = "Not linked"

    var id: String { rawValue }

    /// Does a profile with this badge (nil = none) pass the filter?
    func matches(_ badge: TreeLinkBadge?) -> Bool {
        switch self {
        case .all:
            return true
        case .linked:
            return badge?.kind == .pinned
        case .needsConfirm:
            switch badge?.kind {
            case .derived?, .ambiguous?, .pinProblem?: return true
            default: return false
            }
        case .notLinked:
            switch badge?.kind {
            case nil, .notInTree?: return true
            default: return false
            }
        }
    }
}

// MARK: - View

/// The capsule. `fontSize` is the card's derived caption size; it is then
/// scaled with the user's Dynamic Type setting (`@ScaledMetric` ≈ a
/// number the OS multiplies by the accessibility text scale).
struct TreeLinkBadgeView: View {
    let badge: TreeLinkBadge
    var fontSize: CGFloat = 10
    /// nil ⇒ informational only (the person editor header).
    var action: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .caption2) private var typeScale: CGFloat = 1

    var body: some View {
        Group {
            if let action {
                Button(action: action) { capsule }
                    .buttonStyle(.plain)
            } else {
                capsule
            }
        }
        .help(badge.tooltip)
        .accessibilityLabel("Family tree link")
        .accessibilityValue(badge.tooltip)
    }

    private var capsule: some View {
        HStack(spacing: 3) {
            Image(systemName: badge.systemImage)
            Text(badge.label)
                .lineLimit(1)
                .fixedSize()          // the FSID is short — never truncate it
        }
        .font(.system(size: max(9, fontSize) * typeScale, weight: .semibold))
        .foregroundColor(badge.isOutline ? badge.tint : .white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(badge.isOutline ? Color.clear : badge.tint)
        )
        .overlay(
            Capsule().stroke(badge.isOutline ? badge.tint.opacity(0.6)
                                             : Color(NSColor.windowBackgroundColor),
                             lineWidth: badge.isOutline ? 1 : 1.5)
        )
    }
}
