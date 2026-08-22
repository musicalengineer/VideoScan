// ArchivistSpeakerSettingsSheet.swift
// "Who is talking to her" — the two names Hallie needs to bind pronouns.
//
// Rick (Hallie log 2026-08-18): "how am I related to you?" failed; part of
// the fix is knowing who "I" is. This sheet edits the owner's name (the
// person using the app) and, optionally, the archivist's exact family-tree
// spelling when her display name ("Hallie Mae") doesn't match the GEDCOM
// ("Hallie May McGill"). Both persist as `archivist.*` @AppStorage keys,
// read back by `HallieTurnExecutor.Speakers.fromDefaults()`.

import AppKit
import AVFoundation
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

            Divider().padding(.vertical, 4)
            HallieReadAloudSettings()

            Divider().padding(.vertical, 4)
            HallieWebAccessSettings()

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

/// "Hallie on the home network": one switch, the address to type on the
/// iPad, an optional passphrase. Rick 2026-08-21: "a mini app my wife can
/// use on her iPad" — Safari's Add to Home Screen is the app.
struct HallieWebAccessSettings: View {
    @AppStorage(HallieWebAccess.enabledKey) private var enabled = false
    @AppStorage(HallieWebAccess.portKey) private var port = HallieWebAccess.defaultPort
    @AppStorage(HallieWebAccess.passphraseKey) private var passphrase = ""
    @ObservedObject private var access = HallieWebAccess.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Let the family talk to her from the iPad / laptop", isOn: $enabled)
                .onChange(of: enabled) { _, _ in access.apply() }
            if enabled {
                HStack(spacing: 8) {
                    Text("On their device, open")
                    Text(HallieWebAccess.url(port: port))
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HallieWebAccess.url(port: port), forType: .string)
                    }
                    .controlSize(.small)
                }
                .font(.system(size: 13))
                Text("Then Share → Add to Home Screen. It only works on the home network; nothing is opened to the internet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text("Family passphrase")
                    TextField("optional", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("Port")
                    TextField("8765", value: $port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .onSubmit { access.apply() }
                }
                .font(.system(size: 13))
                if let error = access.lastError {
                    Text("Couldn't start: \(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else if access.isRunning {
                    Text("Listening.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// "Read answers aloud" + which voice (Rick 2026-08-22: no audio in-app;
/// "soft-spoken librarian, gentle but firm, a teeny bit slower").
struct HallieReadAloudSettings: View {
    @AppStorage(HallieSpeaker.enabledKey) private var enabled = true
    @AppStorage(HallieSpeaker.voiceKey) private var voiceID = ""
    private let voices = HallieSpeaker.englishVoices()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Read her answers aloud", isOn: $enabled)
                .font(.system(size: 15))
                .onChange(of: enabled) { _, on in if !on { HallieSpeaker.shared.stop() } }
            if enabled {
                HStack(spacing: 8) {
                    Text("Voice")
                    Picker("", selection: $voiceID) {
                        Text("Best installed (\(voices.first?.name ?? "system"))").tag("")
                        if HallieNeuralSpeech.isInstalled {
                            Section("Local neural voices") {
                                ForEach(HallieNeuralVoice.choices) { voice in
                                    Text(voice.displayName + " ✦").tag(voice.id)
                                }
                            }
                        }
                        Section("Apple voices") {
                            ForEach(voices, id: \.identifier) { voice in
                                Text(voice.name + (voice.quality == .premium ? " ★★" : voice.quality == .enhanced ? " ★" : ""))
                                    .tag(voice.identifier)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .onChange(of: voiceID) { _, _ in HallieSpeaker.shared.audition() }
                    Button("Hear her") { HallieSpeaker.shared.audition() }
                        .controlSize(.small)
                }
                .font(.system(size: 13))
                Text(HallieNeuralSpeech.isInstalled
                     ? "✦ voices are private, local neural speech. ★★ premium and ★ enhanced voices are Apple's installed alternatives."
                     : "★★ premium and ★ enhanced voices sound far more natural. Download them in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices… (Ava, Zoe, Allison are the softest).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
