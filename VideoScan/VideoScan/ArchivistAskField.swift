// ArchivistAskField.swift
// Family Archivist P2 — the front door (docs/family-archivist-phase1.md).
// A plain-English ask popover on the catalog toolbar: sentence → local
// LLM translator (NLQueryTranslating brain, ollama/qwen by default) →
// validated NLQuerySpec → the SAME composed infix grammar the search
// field already speaks. The composed query lands IN the search field,
// visible and editable — the "Interpreted as:" display is the search
// box itself, so the user always sees exactly what their words became
// and can correct it by hand.
//
// Failure honesty (file-header contract in OllamaQueryTranslator): a
// brain that throws is fine — we offer literal substring search of the
// raw sentence instead, clearly labeled. No silent guessing.

import SwiftUI

struct ArchivistAskPopover: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool

    /// Brain endpoint knobs — editable without a rebuild. Defaults match
    /// OllamaQueryTranslator (Jim's qwen on the M5).
    @AppStorage("archivist.ollamaHost") private var ollamaHost = "ricksm5.local"
    @AppStorage("archivist.ollamaModel") private var ollamaModel = "qwen3.6:35b-a3b-nvfp4"

    @State private var question = ""
    @State private var isThinking = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask the catalog")
                .font(.headline)
            TextField("e.g. show me Donna down the cape 1990 to 1995",
                      text: $question)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .disabled(isThinking)
                .onSubmit { ask() }
                .accessibilityIdentifier("archivist.askField")

            if isThinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Asking \(ollamaModel) @ \(ollamaHost)…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let errorText {
                VStack(alignment: .leading, spacing: 6) {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                    // The honest fallback: the words, searched literally.
                    Button("Search these words literally instead") {
                        searchText = question
                        isPresented = false
                    }
                    .font(.caption)
                }
            } else {
                Text("Your words become a search you can see and edit — nothing is invented.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Ask") { ask() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty
                              || isThinking)
            }
        }
        .padding(14)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        errorText = nil
        isThinking = true
        var translator = OllamaQueryTranslator()
        translator.host = ollamaHost
        translator.model = ollamaModel
        Task { @MainActor in
            defer { isThinking = false }
            do {
                let spec = try await translator.translate(text)
                let composed = NLQueryComposer.infixString(
                    for: NLQueryNormalizer.normalize(spec))
                guard !composed.isEmpty else {
                    errorText = "I couldn't find anything searchable in that — try naming a person, a year, or a place."
                    return
                }
                searchText = composed
                isPresented = false
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
