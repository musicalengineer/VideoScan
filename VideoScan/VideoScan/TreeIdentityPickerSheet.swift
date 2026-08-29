// TreeIdentityPickerSheet.swift
// The "which one?" sheet behind People → Show in Family Tree and the tree
// tab's "Not right?" (2026-08-29). One sheet, five moods (TreeIdentityPickTarget
// .Mode): ambiguous (pick from the list), not found (search, or say they
// are not on the tree), change pin (current preselected), pin problem
// (reason on top), already not-in-tree (offer to change that).
//
// Picking persists through TreeIdentityCenter (collision refused inline —
// the sheet stays open with the reason) and the caller then focuses the
// tree. Typing a FamilySearch ID is possible in the search field, but it
// is the fallback, never the first thing asked for.
//
// C++ readers: `@State` ≈ a member the framework keeps alive across
// re-renders of this value-type view; `.sheet(item:)` presents while the
// bound optional is non-nil.

import SwiftUI

struct TreeIdentityPickerSheet: View {
    let target: TreeIdentityPickTarget
    @ObservedObject var center: TreeIdentityCenter
    let profiles: [POIProfile]
    /// Called after a successful pin (the caller focuses the tree).
    let onPinned: (TreeIdentityCandidate) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var error: String?

    private var profileName: String { target.profile.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.title3.weight(.semibold))
            if let subline {
                Text(subline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            let listed = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? target.candidates
                : center.searchCandidates(searchText)
            if !listed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(listed) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(minHeight: 60, maxHeight: 280)
            } else if !searchText.isEmpty {
                Text("No one in the tree matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Search the tree by name (or FamilySearch ID)", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("people.identity.search")

            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                if target.mode != .notInTree {
                    Button("\(profileName) is not in the tree") {
                        switch center.markNotInTree(target.profile) {
                        case .saved: onDismiss()
                        case .refused(let why): error = why
                        }
                    }
                    .help("Living relatives are never on FamilySearch — stop asking for this person.")
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var headline: String {
        switch target.mode {
        case .ambiguous:     return "Which one is \(profileName)?"
        case .notFound:      return "I can't find \(profileName) in the tree"
        case .changePin:     return "Who is \(profileName) in the tree?"
        case .pinProblem:    return "\(profileName)'s tree record needs picking again"
        case .notInTree:     return "\(profileName) is marked as not in the family tree"
        }
    }

    private var subline: String? {
        switch target.mode {
        case .ambiguous:
            return "More than one record could be \(profileName). Pick the right one; it is remembered on the profile."
        case .notFound:
            return "Type a name to search, or say they are not on the tree."
        case .changePin:
            return target.current.map { "Currently \($0.label) · \($0.code)." }
        case .pinProblem(let why):
            return why
        case .notInTree:
            return "Pick a record below to change that."
        }
    }

    @ViewBuilder
    private func candidateRow(_ candidate: TreeIdentityCandidate) -> some View {
        let isCurrent = candidate.personID == target.current?.personID
        Button {
            let attestation = "picked: \(HallieTurnExecutor.Speakers.fromDefaults().ownerName ?? "owner"), \(Self.today())"
            switch center.pin(candidate, on: target.profile, among: profiles, attestation: attestation) {
            case .saved:
                onPinned(candidate)
            case .refused(let why):
                error = why
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name).lineLimit(1)
                    if !candidate.detail.isEmpty {
                        Text(candidate.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(candidate.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
