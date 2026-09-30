// FamilyTreeNoteCorrectionUI.swift
// "Correct a family note" (Rick, approved 2026-09-29):
//
//   Take back, reword, or move one note about one person — nothing is ever
//   erased; the old text stays in the file, hidden unless Rick asks to see
//   corrections.
//
// The "…" menu on a note row opens ONE sheet in one of three modes (Edit…,
// Remove…, Move to…). The sheet holds a copy of the row as it was when the
// menu was opened — its item id, the tree person it was read for, and its
// CyberBrain person — so the correction acts on THAT note even if the
// selection moves while the sheet is up. All writing happens in
// FamilyTreeLiveModel (removeNote / editNote / moveNote → the core's
// durable corrector); nothing here touches the file.

import SwiftUI
import VideoScanCore

/// Which correction the sheet is for.
enum FamilyTreeNoteCorrectionMode: String, Sendable {
    case edit, remove, move
}

/// What `.sheet(item:)` presents: one note + one mode. `Identifiable` is
/// the SwiftUI hook that makes the sheet show while this is non-nil (≈ a
/// pointer whose non-null-ness IS the "sheet is open" flag).
struct FamilyTreeNoteCorrectionTarget: Identifiable, Equatable {
    let note: FamilyTreeNote
    let mode: FamilyTreeNoteCorrectionMode
    var id: String { "\(mode.rawValue):\(note.id)" }
}

/// The reason choices for Remove…, in the order Rick named them.
enum FamilyTreeNoteRemoveReason: String, CaseIterable, Identifiable {
    case wrongPerson, wrongInformation, duplicate, other
    var id: String { rawValue }

    var label: String {
        switch self {
        case .wrongPerson: return "Wrong person"
        case .wrongInformation: return "Wrong information"
        case .duplicate: return "Duplicate"
        case .other: return "Other…"
        }
    }

    var coreReason: CyberBrainCorrection.Reason {
        switch self {
        case .wrongPerson: return .wrongPerson
        case .wrongInformation: return .wrongInformation
        case .duplicate: return .duplicate
        case .other: return .other
        }
    }
}

struct FamilyTreeNoteCorrectionSheet: View {
    // `@ObservedObject` ≈ a non-owning reference to the model: the tab owns
    // it, this sheet only watches it.
    @ObservedObject var model: FamilyTreeLiveModel
    let target: FamilyTreeNoteCorrectionTarget
    let onDone: () -> Void

    @State private var editedText = ""
    @State private var reason: FamilyTreeNoteRemoveReason = .wrongPerson
    @State private var detail = ""
    @State private var query = ""
    /// Recomputed when the query changes (never in `body`), ≤ 30 rows.
    @State private var candidates: [FamilyTreePersonSummary] = []
    @State private var chosen: FamilyTreePersonSummary?
    @State private var error: String?

    private var aboutName: String {
        model.treePerson(id: target.note.treePersonID)?.name ?? "this person"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(target.note.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            switch target.mode {
            case .edit: editBody
            case .remove: removeBody
            case .move: moveBody
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Nothing is erased: the old version stays in the family knowledge file and shows, struck through, under Show corrections.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .keyboardShortcut(.cancelAction)
                confirmButton
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear { editedText = target.note.text }
    }

    private var title: String {
        switch target.mode {
        case .edit: return "Edit note about \(aboutName)"
        case .remove: return "Remove note from \(aboutName)"
        case .move: return "Move note from \(aboutName) to…"
        }
    }

    // MARK: Edit

    private var editBody: some View {
        TextEditor(text: $editedText)
            .font(.system(size: 12))
            .frame(minHeight: 90, maxHeight: 180)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var editIsSavable: Bool {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed != target.note.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Remove

    private var removeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            // `Picker` with `.radioGroup` ≈ a classic Mac radio-button group
            // bound to one enum value.
            Picker("Why?", selection: $reason) {
                ForEach(FamilyTreeNoteRemoveReason.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            if reason == .other {
                TextField("Say briefly why", text: $detail)
                    .textFieldStyle(.roundedBorder)
                Text("\(detail.count) / \(CyberBrainCorrection.maximumDetailLength)")
                    .font(.system(size: 10))
                    .foregroundStyle(detail.count > CyberBrainCorrection.maximumDetailLength ? .orange : .secondary)
            }
        }
    }

    private var removeIsReady: Bool {
        reason != .other
            || (!detail.trimmingCharacters(in: .whitespaces).isEmpty
                && detail.count <= CyberBrainCorrection.maximumDetailLength)
    }

    // MARK: Move

    private var moveBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search the tree by name", text: $query)
                .textFieldStyle(.roundedBorder)
                // `.onChange` ≈ an observer on `query`: the search runs once
                // per edit here, not on every redraw of `body`.
                .onChange(of: query) { _, newValue in
                    candidates = model.moveCandidates(matching: newValue,
                                                      excluding: target.note.treePersonID)
                    if let chosen, !candidates.contains(where: { $0.id == chosen.id }) {
                        self.chosen = nil
                    }
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(candidates) { person in
                        Button { chosen = person } label: {
                            HStack {
                                Text(person.name)
                                    .font(.system(size: 12, weight: chosen?.id == person.id ? .semibold : .regular))
                                Spacer()
                                // Years are what tell John C. Latta (1805)
                                // from John Robert Latta (1835).
                                Text(person.years ?? "dates unknown")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .background(chosen?.id == person.id ? Color.accentColor.opacity(0.18) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 180)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty, candidates.isEmpty {
                Text("Nobody in the tree matches that name.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Confirm

    @ViewBuilder
    private var confirmButton: some View {
        switch target.mode {
        case .edit:
            Button("Save new wording") { run { try model.editNote(target.note, newText: editedText) } }
                .masterOnly()
                .keyboardShortcut(.defaultAction)
                .disabled(!editIsSavable)
        case .remove:
            Button("Remove note", role: .destructive) {
                run {
                    try model.removeNote(target.note, reason: reason.coreReason,
                                         detail: reason == .other ? detail : nil)
                }
            }
            .masterOnly()
            .disabled(!removeIsReady)
        case .move:
            Button(chosen.map { "Move to \($0.name)" } ?? "Move") {
                guard let chosen else { return }
                run { try model.moveNote(target.note, toTreePerson: chosen.id) }
            }
            .masterOnly()
            .keyboardShortcut(.defaultAction)
            .disabled(chosen == nil)
        }
    }

    /// Run one correction; close on success, show the reason otherwise.
    private func run(_ body: () throws -> Void) {
        do {
            try body()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One struck-through line under "Show corrections": red for a removed or
/// moved-away note, grey for an earlier wording.
struct FamilyTreeNoteCorrectionLineView: View {
    let line: FamilyTreeNoteCorrectionLine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.text)
                .font(.system(size: 11))
                .strikethrough(true, color: color)
                .foregroundStyle(color.opacity(0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(line.caption)
                .font(.system(size: 10))
                .foregroundStyle(color)
            ForEach(line.earlierVersions) { earlier in
                FamilyTreeNoteCorrectionLineView(line: earlier)
                    .padding(.leading, 10)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var color: Color {
        line.style == .retracted ? .red : .gray
    }
}
