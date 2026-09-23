// FamilyMusicSheet.swift
// Catalog right-click → "Mark as Family Music…" (Rick 2026-09-23). One
// small sheet: performer + title, both optional. One file: both fields,
// prefilled from its existing mark, else the filename (title) and its
// confirmed people (performer). Several files: performer only — one answer
// applied to all, each file keeps its own title (the list shows the
// filename when there is none).
//
// Large-text friendly (Rick's vision priority): 15–17 pt, fields wide,
// nothing truncated.

import SwiftUI
import VideoScanCore

/// Menu titles (Rick's convention: an ellipsis only when a sheet opens).
enum FamilyMusicMenu {
    static let markTitle = "Mark as Family Music\u{2026}"
    static let unmarkTitle = "Unmark Family Music"
}

/// `.sheet(item:)` driver (the chained-sheet rule: one item, one sheet).
/// Prefill is resolved at right-click time (O(selection)) so the sheet
/// body never walks records.
struct FamilyMusicSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let recordIDs: [UUID]
    /// Shown in the header: the filename for one file, "N files" for more.
    let subject: String
    let performer: String
    let title: String

    var isMulti: Bool { recordIDs.count > 1 }

    @MainActor
    static func make(for recs: [VideoRecord]) -> FamilyMusicSheetRequest? {
        guard let first = recs.first else { return nil }
        if recs.count == 1 {
            return FamilyMusicSheetRequest(
                recordIDs: [first.id],
                subject: first.filename,
                performer: first.familyMusic?.performer ?? FamilyMusicPrefill.performer(for: first),
                title: first.familyMusic?.title ?? FamilyMusicPrefill.title(fromFilename: first.filename))
        }
        return FamilyMusicSheetRequest(recordIDs: recs.map(\.id),
                                       subject: "\(recs.count) files",
                                       performer: FamilyMusicPrefill.commonPerformer(for: recs),
                                       title: "")
    }
}

struct FamilyMusicSheet: View {
    let request: FamilyMusicSheetRequest
    /// Called with (performer, title) — title is nil for a multi-selection.
    let onMark: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var performer = ""
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mark as Family Music")
                        .font(.title2.weight(.semibold))
                    Text(request.subject)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Recordings of family members playing or singing. It will appear under Music in the Archive tab.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            field("Who is playing", text: $performer, prompt: "e.g. Tim, or Rick & Donna")
                .accessibilityIdentifier("familyMusic.sheet.performer")
            if !request.isMulti {
                field("Title", text: $title, prompt: "e.g. Blackbird, Christmas 1998")
                    .accessibilityIdentifier("familyMusic.sheet.title")
            } else {
                Text("Each file keeps its own title (its filename unless you name it later).")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(request.isMulti ? "Optional — left blank, each file keeps the performer it has." : "Both are optional.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isMulti ? "Mark \(request.recordIDs.count) Files" : "Mark") {
                    onMark(performer, request.isMulti ? nil : title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("familyMusic.sheet.mark")
            }
        }
        .padding(22)
        .frame(minWidth: 480, idealWidth: 540)
        .onAppear {
            performer = request.performer
            title = request.title
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 15, weight: .medium))
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 16))
        }
    }
}
