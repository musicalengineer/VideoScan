// ArchivistChatWindow.swift
// The Family Archivist's own window (Rick 2026-08-07: "spawn a new
// search window which floats on top which carries a conversation…
// some kind of back & forth from an agent would be VERY cool").
//
// A floating chat over the SAME honest pipeline the sparkle popover
// used: sentence → local LLM translator → validated spec → the
// catalog's infix search grammar — every answer prints the exact query
// it ran, and every suggestion chip is MINED from real catalog data
// (folder names, known family members), never generated. The agent's
// "back & forth" today:
//   - greetings + guidance
//   - person resolution: unknown names answered honestly ("I don't
//     know anyone called…"), shared nicknames counter-asked ("Tim or
//     Timmy?") with one-tap corrections (PersonResolver — never guess)
//   - count questions ANSWERED ("214 videos") with a "Show them" chip
//     instead of silently filtering
//   - broad matches counter-asked ("Which ones? CapeCod (14) ·
//     Montana (5)") with instant narrowing
//   - filters applied live to the catalog behind the window via
//     VideoScanModel.archivistSearchRequest
//
// The catalog stays the display surface; this window is the voice.

import SwiftUI

// MARK: - Messages

struct ArchivistMessage: Identifiable {
    enum Role { case user, assistant }

    struct Chip: Identifiable {
        enum Action {
            /// Apply this composed query to the catalog now.
            case applyQuery(String)
            /// Send this text through the full ask pipeline (used for
            /// person-disambiguation corrections).
            case askText(String)
        }
        let id = UUID()
        let label: String
        let action: Action
    }

    let id = UUID()
    let role: Role
    let text: String
    /// Monospaced sub-line showing the exact query (assistant only).
    var queryLine: String?
    var chips: [Chip] = []
}

// MARK: - Window

struct ArchivistChatWindow: View {
    @EnvironmentObject var model: VideoScanModel

    @AppStorage("archivist.ollamaHost") private var ollamaHost = "ricksm5.local"
    @AppStorage("archivist.ollamaModel") private var ollamaModel = "qwen3.6:35b-a3b-nvfp4"

    @State private var messages: [ArchivistMessage] = []
    @State private var input = ""
    @State private var isThinking = false
    @FocusState private var inputFocused: Bool

    private static let starterQuestions = [
        "show me Donna down the cape in the early 90s",
        "how many videos of Donna do we have?",
        "Christmas videos from 2006",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            bubble(for: message)
                                .id(message.id)
                        }
                        if isThinking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("thinking…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about the family catalog…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .disabled(isThinking)
                    .accessibilityIdentifier("archivist.chatInput")
                Button("Ask", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isThinking
                              || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 620)
        .background(ArchivistWindowConfigurator())
        .onAppear {
            inputFocused = true
            if messages.isEmpty { greet() }
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(for message: ArchivistMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.text)
                    .textSelection(.enabled)
                if let query = message.queryLine {
                    Text(query)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !message.chips.isEmpty {
                    FlowChips(chips: message.chips) { chip in
                        handle(chip: chip)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(message.role == .user
                          ? Color.accentColor.opacity(0.18)
                          : Color.secondary.opacity(0.10)))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }

    // MARK: Conversation

    private func greet() {
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "Hi Rick — I'm the Family Archivist. Ask me about anyone "
                + "or anything in the catalog, and I'll show you what we have.",
            chips: Self.starterQuestions.map {
                ArchivistMessage.Chip(label: $0, action: .askText($0))
            }))
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        input = ""
        ask(text)
    }

    private func handle(chip: ArchivistMessage.Chip) {
        switch chip.action {
        case .askText(let text):
            ask(text)
        case .applyQuery(let query):
            apply(query: query, announcedAs: chip.label)
        }
    }

    private func ask(_ text: String) {
        messages.append(ArchivistMessage(role: .user, text: text))
        isThinking = true
        var translator = OllamaQueryTranslator()
        translator.host = ollamaHost
        translator.model = ollamaModel
        Task { @MainActor in
            defer { isThinking = false }
            do {
                let spec = try await translator.translate(text)
                respond(to: text, spec: spec)
            } catch {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I couldn't reach my language brain (\(error.localizedDescription)). "
                        + "I can still search your words literally:",
                    chips: [ArchivistMessage.Chip(label: "Search “\(text)” literally",
                                                  action: .applyQuery(text))]))
            }
            inputFocused = true
        }
    }

    /// The archivist's reply policy — resolution first, then intent.
    private func respond(to question: String, spec: NLQuerySpec) {
        // 1. PERSON RESOLUTION (never guess — Phase 1 contract). An
        // unknown or ambiguous name becomes a counter-question with
        // one-tap corrections.
        let known = POIProfile.listAll().map {
            ResolvablePerson(canonicalName: $0.name, aliases: [])
        }
        if !known.isEmpty {
            let resolver = PersonResolver(people: known)
            for asked in spec.people ?? [] {
                switch resolver.resolve(asked) {
                case .resolved:
                    continue
                case .ambiguous(let candidates):
                    messages.append(ArchivistMessage(
                        role: .assistant,
                        text: "Did you mean \(candidates.joined(separator: " or "))?",
                        chips: candidates.map { candidate in
                            ArchivistMessage.Chip(
                                label: candidate,
                                action: .askText(question.replacingOccurrences(
                                    of: asked, with: candidate,
                                    options: .caseInsensitive)))
                        }))
                    return
                case .unknown:
                    let names = known.map(\.canonicalName).sorted()
                    messages.append(ArchivistMessage(
                        role: .assistant,
                        text: "I don't know anyone called “\(asked)” yet. "
                            + "The family members I know are: \(names.joined(separator: ", ")).",
                        chips: names.prefix(4).map { name in
                            ArchivistMessage.Chip(
                                label: name,
                                action: .askText(question.replacingOccurrences(
                                    of: asked, with: name,
                                    options: .caseInsensitive)))
                        }))
                    return
                }
            }
        }

        let composed = NLQueryComposer.infixString(
            for: NLQueryNormalizer.normalize(spec))
        guard !composed.isEmpty else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I couldn't find anything searchable in that — try naming "
                    + "a person, a year, or a place."))
            return
        }

        let matches = model.searchIndex.filter(records: model.records,
                                               query: composed)

        // 2. COUNT questions get an ANSWER, not a filter.
        if spec.intent?.lowercased() == "count" {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: countSentence(matches.count),
                queryLine: composed,
                chips: matches.isEmpty ? [] : [
                    ArchivistMessage.Chip(label: "Show them",
                                          action: .applyQuery(composed)),
                ]))
            return
        }

        // 3. FILTER questions apply live, answer with the count, and
        // counter-ask when the match is broad.
        apply(composed: composed, matches: matches.count)
        let refinements = Self.refinements(for: matches)
        var chips = refinements.map { refinement in
            ArchivistMessage.Chip(
                label: "\(refinement.term) (\(refinement.count))",
                action: .applyQuery("\(composed) \(refinement.term)"))
        }
        var text = matchSentence(matches.count)
        if !chips.isEmpty { text += " Which ones interest you?" }
        if matches.isEmpty { chips = [] }
        messages.append(ArchivistMessage(role: .assistant, text: text,
                                         queryLine: composed, chips: chips))
    }

    private func apply(query: String, announcedAs label: String) {
        let matches = model.searchIndex.filter(records: model.records,
                                               query: query).count
        apply(composed: query, matches: matches)
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "\(matchSentence(matches))",
            queryLine: query))
    }

    /// Route the filter to the catalog window (cross-window: the
    /// catalog's search field observes archivistSearchRequest).
    private func apply(composed: String, matches: Int) {
        model.archivistSearchRequest = composed
    }

    private func countSentence(_ n: Int) -> String {
        switch n {
        case 0: return "None yet — the catalog has no videos matching that."
        case 1: return "Exactly one video."
        default: return "You have \(n) videos matching that."
        }
    }

    private func matchSentence(_ n: Int) -> String {
        switch n {
        case 0: return "No matches — the catalog is unfiltered. Try different words."
        case 1: return "Found 1 video — it's showing in the catalog now."
        default: return "Found \(n) videos — they're showing in the catalog now."
        }
    }

    /// "Down the cape, at home, or Montana?" — mined from where the
    /// matching files live (top parent folders), shown only when
    /// narrowing helps. Same policy as the popover version.
    private static let refinementStopwords: Set<String> = [
        "volumes", "users", "movies", "video", "videos", "media", "clips",
        "capture", "captures", "footage", "export", "exports", "output",
        "originals", "masters", "archive", "documents", "desktop",
    ]

    static func refinements(for matches: [VideoRecord])
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
        guard top.count >= 2, let best = top.first,
              best.count < matches.count else { return [] }
        return top
    }
}

// MARK: - Chip flow layout (simple wrapping row)

private struct FlowChips: View {
    let chips: [ArchivistMessage.Chip]
    let onTap: (ArchivistMessage.Chip) -> Void

    var body: some View {
        // Simple vertical stack of wrapping HStacks is overkill here —
        // chips are few (≤4 refinements / ≤4 names); one wrapping grid
        // row does the job.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(chips) { chip in
                Button {
                    onTap(chip)
                } label: {
                    Text(chip.label)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Floating window level

/// Sets the hosting NSWindow to float above the catalog (Rick: "floats
/// on top"). NSViewRepresentable is the reliable way to reach the
/// window from SwiftUI on macOS 13+.
private struct ArchivistWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
