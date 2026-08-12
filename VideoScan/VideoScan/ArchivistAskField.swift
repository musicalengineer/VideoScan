// ArchivistAskField.swift
// Family Archivist P2 — the front door (docs/family-archivist-phase1.md).
// A plain-English ask popover on the catalog toolbar: sentence → local
// LLM translator (NLQueryTranslating brain, ollama/qwen by default) →
// validated NLQuerySpec → the SAME composed infix grammar the catalog
// search field already speaks. The composed query lands IN the search
// field, visible and editable — the user always sees exactly what their
// words became and can correct it by hand.
//
// CONVERSATIONAL (2026-08-07, Rick: "make it seem more interactive" +
// "you might say: down the cape or at home or in montana?"): the
// popover stays open across questions and keeps a session transcript.
// Each ask answers with a live match count ("37 videos match — showing
// them now") while the table filters behind it — and when the match is
// BROAD, the archivist asks back, offering refinements mined from
// where the matching files actually live (top folder names of the
// result set). Clicking one narrows instantly, no LLM round-trip.
// Grounded, not generated: every option shown is a real place in the
// catalog, and every answer line shows the exact query the words
// became. Zero invention.
//
// Failure honesty (file-header contract in OllamaQueryTranslator): a
// brain that throws is fine — we offer literal substring search of the
// raw sentence instead, clearly labeled. No silent guessing.

import SwiftUI

struct ArchivistAskPopover: View {
    @Binding var searchText: String
    @Binding var isPresented: Bool
    @EnvironmentObject var model: VideoScanModel

    /// Brain endpoint knobs — editable without a rebuild. Defaults match
    /// OllamaQueryTranslator (Jim's qwen on the M5).
    @AppStorage("archivist.ollamaHost") private var ollamaHost = "ricksm5.local"
    /// Host that answered the most recent ask, once one has.
    @State private var lastResponder: String?

    /// Never claims a host we are not actually talking to: the fleet's
    /// first entry while in flight, the real responder once it answers.
    private var askStatusText: String {
        let hosts = OllamaEndpoints.resolved(from: .standard)
        let where_ = lastResponder ?? hosts.first ?? "the fleet"
        return "Asking \(ollamaModel) @ \(where_)…"
    }
    @AppStorage("archivist.ollamaModel") private var ollamaModel = "qwen3.6:35b-a3b-nvfp4"

    /// One asked-and-answered turn in this session's conversation.
    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        let composed: String
        let matchCount: Int
        /// "Which ones?" options — (folder name, its match count),
        /// present when the result is broad enough to want narrowing.
        let refinements: [(term: String, count: Int)]
    }

    @State private var question = ""
    @State private var isThinking = false
    @State private var errorText: String?
    @State private var transcript: [Exchange] = []
    @FocusState private var fieldFocused: Bool

    private static let suggestions = [
        "show me Donna down the cape 1990 to 1995",
        "videos with Donna from the nineties",
        "Christmas videos from 2006",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask the catalog")
                .font(.headline)

            // The conversation so far — question, answer-with-count,
            // the exact query, and (latest turn only) the archivist's
            // counter-question chips.
            if !transcript.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(transcript) { exchange in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("“\(exchange.question)”")
                                    .font(.callout)
                                Text(answerLine(for: exchange))
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(exchange.matchCount > 0 ? .primary : .secondary)
                                Text(exchange.composed)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                if exchange.id == transcript.last?.id,
                                   !exchange.refinements.isEmpty {
                                    Text("Which ones?")
                                        .font(.caption.weight(.medium))
                                        .padding(.top, 2)
                                    refinementChips(for: exchange)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 230)
            }

            TextField(transcript.isEmpty
                        ? "e.g. show me Donna down the cape 1990 to 1995"
                        : "Ask a follow-up…",
                      text: $question)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .disabled(isThinking)
                .focused($fieldFocused)
                .onSubmit { ask() }
                .accessibilityIdentifier("archivist.askField")

            if isThinking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    // Was `ollamaHost` — the OLD single-host preference,
                    // which the field stopped using when it moved to the
                    // fleet. It would have named ricksm5 while actually
                    // asking the M4 (codex #313). Report the responder
                    // once known, the fleet's head while in flight.
                    Text(askStatusText)
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
            } else if transcript.isEmpty {
                // First-question seeds — click to ask.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            question = suggestion
                            ask()
                        } label: {
                            Text(suggestion)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Your words become a search you can see and edit — nothing is invented.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            HStack {
                Spacer()
                Button(transcript.isEmpty ? "Cancel" : "Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Ask") { ask() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty
                              || isThinking)
            }
        }
        .padding(14)
        .onAppear { fieldFocused = true }
    }

    /// The archivist's counter-question: real folder names from the
    /// current result set, each narrowing the search on click — no LLM
    /// round-trip, instant.
    private func refinementChips(for exchange: Exchange) -> some View {
        HStack(spacing: 6) {
            ForEach(exchange.refinements, id: \.term) { refinement in
                Button {
                    refine(exchange: exchange, term: refinement.term)
                } label: {
                    Text("\(refinement.term) (\(refinement.count))")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func answerLine(for exchange: Exchange) -> String {
        switch exchange.matchCount {
        case 0: return "No matching videos — try different words, or edit the query in the search box."
        case 1: return "1 video matches — showing it now."
        default: return "\(exchange.matchCount) videos match — showing them now."
        }
    }

    // MARK: Ask (LLM translation) and refine (instant narrowing)

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        errorText = nil
        isThinking = true
        // Ordered fleet — see OllamaEndpoints / OllamaFailoverTranslator.
        var template = OllamaQueryTranslator()
        template.model = ollamaModel
        let translator = OllamaFailoverTranslator(
            hosts: OllamaEndpoints.resolved(from: .standard),
            template: template,
            onResponder: { host in
                Task { @MainActor in lastResponder = host }
            }
        )
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
                deliver(question: text, composed: composed)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// A refinement chip narrows the LAST composed query with the
    /// chosen folder term as a free-text token — same grammar, shown
    /// in the search box like everything else.
    private func refine(exchange: Exchange, term: String) {
        deliver(question: "\(exchange.question) — \(term)",
                composed: "\(exchange.composed) \(term)")
    }

    /// Shared tail: count matches with the SAME index the table filters
    /// with, mine the counter-question options, append the transcript
    /// turn, and apply the search behind the popover.
    private func deliver(question asked: String, composed: String) {
        let matches = model.searchIndex.filter(records: model.records,
                                               query: composed)
        transcript.append(Exchange(
            question: asked,
            composed: composed,
            matchCount: matches.count,
            refinements: Self.refinements(for: matches)))
        searchText = composed
        question = ""
        fieldFocused = true
    }

    /// Directory names generic enough to be noise rather than places.
    private static let refinementStopwords: Set<String> = [
        "volumes", "users", "movies", "video", "videos", "media", "clips",
        "capture", "captures", "footage", "export", "exports", "output",
        "originals", "masters", "archive", "documents", "desktop",
    ]

    /// "Down the cape, at home, or Montana?" — mined, not generated:
    /// the top parent-folder names across the matched records, when the
    /// result is broad enough (>12) that narrowing helps and at least
    /// two real options exist.
    private static func refinements(for matches: [VideoRecord])
        -> [(term: String, count: Int)] {
        guard matches.count > 12 else { return [] }
        var counts: [String: Int] = [:]
        for rec in matches {
            let folder = (rec.directory as NSString).lastPathComponent
            let key = folder.trimmingCharacters(in: .whitespaces)
            guard key.count > 2,
                  !refinementStopwords.contains(key.lowercased()) else { continue }
            counts[key, default: 0] += 1
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(4)
            .map { (term: $0.key, count: $0.value) }
        // A single option is not a question; all-in-one-folder needs no
        // narrowing.
        guard top.count >= 2, let best = top.first,
              best.count < matches.count else { return [] }
        return top
    }
}
