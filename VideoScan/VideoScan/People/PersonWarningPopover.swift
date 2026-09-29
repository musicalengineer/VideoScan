// PersonWarningPopover.swift
// The yellow triangle on a People-tab card explains itself (Rick,
// 2026-09-13). Before this it was `.help(aliasWarning)` — one tooltip
// holding one to ten newline-joined lines, with no hint of what the app
// would get wrong or where the fix lives.
//
// One section per warning, in `warnings` order:
//     the line (unchanged)
//     Why this matters   — KinshipWarning.why
//     How to fix         — KinshipWarning.fix
//     [ Open Dad's Relationships ]   (only when the code has an action)
//
// Layering, deliberately: `PersonWarningPopoverModel` is pure (strings in,
// strings out) and `PersonWarningRoute` is pure (an action + a profile →
// where to go, BY UUID — never by name, because two Richards). The view is
// a thin renderer over the first and the People gallery is a thin dispatch
// over the second, so both are testable without a window.
//
// Nudge, not alarm: nothing here is an error, so the words stay plain and
// the button offers to take Rick there rather than demanding anything.

import SwiftUI

/// The popover's content as data. No view type appears here, so the section
/// list and its identifiers can be asserted in a unit test.
enum PersonWarningPopoverModel {

    struct Section: Identifiable, Equatable, Sendable {
        let code: KinshipWarning.Code
        /// The existing warning line, byte for byte.
        let text: String
        let why: String
        let fix: String
        /// nil when there is nowhere for the app to take Rick.
        let action: KinshipWarning.Action?
        /// The button's words for this person ("Open Dad's Relationships").
        let actionTitle: String?
        let identifier: String
        let actionIdentifier: String?

        var id: String { identifier }
    }

    /// One section per warning, in the order the overlay produced them
    /// (`FamilyKinshipOverlay.warnings` order — oldest cause first).
    /// Duplicate codes are fine: two dangling rows are two sections, and
    /// the identifier carries the index so they stay distinguishable.
    static func sections(for warnings: [KinshipWarning],
                         personName: String,
                         profileID: String) -> [Section] {
        warnings.enumerated().map { index, warning in
            let suffix = "\(warning.code.rawValue).\(index).\(profileID)"
            return Section(
                code: warning.code,
                text: warning.text,
                why: warning.why,
                fix: warning.fix,
                action: warning.action,
                actionTitle: warning.action?.buttonTitle(personName: personName),
                identifier: "pf.person.warning.section.\(suffix)",
                actionIdentifier: warning.action == nil ? nil : "pf.person.warning.fix.\(suffix)")
        }
    }

    static func popoverIdentifier(personName: String, profileID: String) -> String {
        "pf.person.warning.popover.\(personName).\(profileID)"
    }

    static func badgeIdentifier(personName: String, profileID: String) -> String {
        "pf.person.warning.\(personName).\(profileID)"
    }
}

/// Where a warning's fix button leads. Pure, so the People gallery's
/// dispatch is one switch and the decision itself is unit-tested.
///
/// (C++ readers: an `enum` with associated values ≈ a tagged union — the
/// payload travels with the tag, and `Equatable` is synthesized.)
enum PersonWarningRoute: Equatable {
    /// Open this person's editor — the same request the card's double-click
    /// and the context menu's "Edit…" build, so all three open one sheet.
    case editPerson(PersonEditRequest)
    /// "Show in Family Tree", which for a broken pin is the pick-the-record
    /// sheet. Carries the uuid: the durable identity, never the name.
    case familyTree(profileUUID: UUID)

    static func route(for action: KinshipWarning.Action, on profile: POIProfile) -> PersonWarningRoute {
        switch action {
        // The Relationships rows live in the same editor; the button's
        // words say where to look once it opens.
        case .editPerson, .editRelationships:
            return .editPerson(PersonEditRequest(profile))
        case .openFamilyTree:
            return .familyTree(profileUUID: profile.uuid)
        }
    }
}

// MARK: - View

struct PersonWarningPopover: View {
    let personName: String
    let profileID: String
    let warnings: [KinshipWarning]
    /// Performed by the gallery (which owns the editor state and the tree
    /// tab); the popover closes itself first so the sheet isn't presented
    /// underneath it.
    let onAction: (KinshipWarning.Action) -> Void
    let onDismiss: () -> Void

    private var sections: [PersonWarningPopoverModel.Section] {
        PersonWarningPopoverModel.sections(
            for: warnings, personName: personName, profileID: profileID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { Divider() }
                    sectionView(section)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
        .frame(maxHeight: 460)
        .accessibilityIdentifier(
            PersonWarningPopoverModel.popoverIdentifier(personName: personName, profileID: profileID))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(sections.count == 1
                 ? "One thing to tidy up for \(personName)"
                 : "\(sections.count) things to tidy up for \(personName)")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: PersonWarningPopoverModel.Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.text)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            labelled("Why this matters", section.why)
            labelled("How to fix", section.fix)

            if let action = section.action, let title = section.actionTitle {
                Button(title) {
                    onDismiss()
                    onAction(action)
                }
                .controlSize(.small)
                .accessibilityIdentifier(section.actionIdentifier ?? "")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(section.identifier)
    }

    private func labelled(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
