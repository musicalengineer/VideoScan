// ArchivistSpeakerSettingsSheet.swift
// "Who is talking to her" — the two names Hallie needs to bind pronouns.
//
// Rick (Hallie log 2026-08-18): "how am I related to you?" failed; part of
// the fix is knowing who "I" is. This sheet edits the owner's name (the
// person using the app) and, optionally, the archivist's exact family-tree
// spelling when her display name ("Hallie Mae") doesn't match the GEDCOM
// ("Hallie May McGill"). Both persist as `archivist.*` @AppStorage keys,
// read back by `HallieTurnExecutor.Speakers.fromDefaults()`.

import SwiftUI

struct ArchivistSpeakerSettingsSheet: View {
    // `@Binding` ≈ a reference to the caller's variable; edits write
    // straight through to the @AppStorage in the chat window.
    @Binding var ownerPersonName: String
    @Binding var archivistPersonName: String
    let archivistName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who is talking to \(archivistName.isEmpty ? "the archivist" : archivistName)?")
                .font(.system(size: 18, weight: .semibold, design: .serif))
            Text("When you say “I”, “me”, or “my”, she looks this person up in the family tree. When you say “you” or her name, she means herself.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("“I” am")
                    TextField("Your name as the family tree knows you", text: $ownerPersonName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 280)
                }
                GridRow {
                    Text("“You” are")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(archivistName.isEmpty ? "Her family-tree name" : "Same as “\(archivistName)” unless the tree spells her differently",
                                  text: $archivistPersonName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 280)
                        Text("Optional. Leave empty to match her display name; set it if the GEDCOM spells her differently (e.g. “Hallie May McGill”).")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
