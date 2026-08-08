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
import UniformTypeIdentifiers

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
            /// Play this specific record (the "▶︎ Play …" offer).
            case playRecord(UUID)
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

    /// The last filter's matches — "play the first one" needs a
    /// referent (class refs, not copies).
    @State private var lastMatches: [VideoRecord] = []
    /// Set by "play <something>": after the filter answer lands, the
    /// first match auto-plays.
    @State private var playAfterAnswer = false
    /// Lazily-loaded kinship graph from the user's exported GEDCOM
    /// (App Support/family-tree/originals). Double-optional: nil =
    /// not tried; .some(nil) = tried, unavailable.
    @State private var familyGraph: GedcomFamilyGraph??

    private static let starterQuestions = [
        "show me Donna down the cape in the early 90s",
        "how many videos of Donna do we have?",
        "Christmas videos from 2006",
    ]

    /// The archivist's identity — name + portrait, both Rick-pickable
    /// (2026-08-07: "make the archivist have a name a photo on the top
    /// line, like name TBD, photo TBD (i will pick from archive)").
    @AppStorage("archivist.name") private var archivistName = "Hallie Mae"
    @AppStorage("archivist.photoPath") private var archivistPhotoPath = ""
    /// Which drawn avatar fronts the archivist when no photo is set:
    /// "donna" (the caricature from Rick's photo) or "hallie" (the
    /// original librarian). Right-click the portrait to switch.
    @AppStorage("archivist.avatar") private var archivistAvatar = "donna"

    var body: some View {
        VStack(spacing: 0) {
            identityHeader
            Divider()
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
                    .font(.system(size: 15))
                    .controlSize(.large)
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
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 680)
        .background(ArchivistWindowConfigurator())
        .onAppear {
            inputFocused = true
            // A pre-avatar launch may have persisted the placeholder —
            // she has a name now (Rick's great-grandmother's).
            if archivistName == "Name TBD" { archivistName = "Hallie Mae" }
            // Default portrait (Rick 2026-08-07: the drawn avatars
            // "just aren't working for me"): first staged portrait —
            // the brunette librarian cartoon — unless he's already
            // picked something.
            if archivistPhotoPath.isEmpty,
               let first = Self.stockPortraits.first(where: {
                   FileManager.default.fileExists(atPath: $0.path)
               }) {
                archivistPhotoPath = first.path
            }
            if messages.isEmpty { greet() }
        }
    }

    // MARK: Identity header

    /// Portrait + editable name. Click the portrait to pick a photo
    /// from the archive; the name edits in place.
    private var identityHeader: some View {
        HStack(spacing: 10) {
            Button(action: choosePhoto) {
                Group {
                    if !archivistPhotoPath.isEmpty,
                       FileManager.default.fileExists(atPath: archivistPhotoPath) {
                        // Photos auto-fill-crop to the circle (Rick:
                        // "where do I edit the photos to fit?" —
                        // nowhere, that's the computer's job). GIFs go
                        // through NSImageView, the only view that
                        // animates them, and keep proportional fit.
                        if archivistPhotoPath.lowercased().hasSuffix(".gif") {
                            AnimatablePortrait(path: archivistPhotoPath)
                        } else if let image = NSImage(contentsOfFile: archivistPhotoPath) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    } else if archivistAvatar == "hallie" {
                        HallieMaeAvatar(isTalking: isThinking)
                            .background(Circle().fill(Color(red: 0.96, green: 0.93, blue: 0.86)))
                    } else {
                        DonnaAvatar(isTalking: isThinking)
                            .background(Circle().fill(Color(red: 0.93, green: 0.95, blue: 0.97)))
                    }
                }
                .frame(width: 84, height: 84)
                .background(Circle().fill(Color.white))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.purple.opacity(0.4), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .contextMenu {
                // Rick's picked portraits (copied to App Support/
                // VideoScan/archivist by Claude, 2026-08-07) + the
                // drawn fallbacks. Quick switches, no file dialog.
                ForEach(Self.stockPortraits, id: \.path) { portrait in
                    if FileManager.default.fileExists(atPath: portrait.path) {
                        Button(portrait.label) { archivistPhotoPath = portrait.path }
                    }
                }
                Divider()
                Button("Donna caricature (drawn)") {
                    archivistAvatar = "donna"
                    archivistPhotoPath = ""
                }
                Button("Hallie Mae (drawn)") {
                    archivistAvatar = "hallie"
                    archivistPhotoPath = ""
                }
                Divider()
                Button("Choose a photo or GIF…", action: choosePhoto)
            }
            .help("Click to pick a portrait or GIF — right-click for quick switches")

            VStack(alignment: .leading, spacing: 2) {
                TextField("Name TBD", text: $archivistName)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                Text("Family Archivist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.purple)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Rick's chosen portraits, staged in App Support (Downloads is
    /// volatile). First existing one is the default on first launch.
    static let stockPortraits: [(label: String, path: String)] = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first?
            .appendingPathComponent("VideoScan/archivist").path ?? ""
        return [
            ("Librarian cartoon", base + "/librarian-cartoon.png"),
            ("Donna photo", base + "/donna-photo.jpeg"),
            ("Flat librarian", base + "/librarian-flat.png"),
        ]
    }()

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .gif]
        panel.allowsMultipleSelection = false
        panel.title = "Choose the Archivist's Portrait (photo or GIF)"
        if panel.runModal() == .OK, let url = panel.url {
            archivistPhotoPath = url.path
        }
    }

    // MARK: Bubbles

    @ViewBuilder
    private func bubble(for message: ArchivistMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 5) {
                Text(message.text)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                if let query = message.queryLine {
                    Text(query)
                        .font(.footnote.monospaced())
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
        case .playRecord(let id):
            if let rec = model.record(forID: id) { play(rec) }
        }
    }

    private func ask(_ text: String) {
        messages.append(ArchivistMessage(role: .user, text: text))
        // Local pre-passes — no LLM round-trip needed for either.
        if handlePlayCommand(text) { return }
        if handleGeneralQuestion(text) { return }
        if handleKinship(text) { return }
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
                playAfterAnswer = false   // a failed 'play X' must not arm a later answer
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

    // MARK: Play (Rick 2026-08-07: "at least 'play the current video'")

    /// "play it / play the first one / play" plays the first match of
    /// the LAST answer; "play <anything else>" runs the ask pipeline
    /// on the remainder and auto-plays the first result. Smart-player
    /// routing via MediaOpener (QuickTime vs VLC by container).
    private func handlePlayCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        let verbs = ["play", "watch"]
        guard let verb = verbs.first(where: {
            lower == $0 || lower.hasPrefix($0 + " ")
        }) else { return false }
        let remainder = lower.dropFirst(verb.count)
            .trimmingCharacters(in: .whitespaces)
        let bareReferents: Set<String> = [
            "", "it", "that", "this", "first", "the first", "the first one",
            "the first video", "the current video", "the video", "them",
        ]
        if bareReferents.contains(remainder) {
            guard !lastMatches.isEmpty else {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "Play what? Ask me to find something first — then "
                        + "say “play the first one”."))
                return true
            }
            play(bestOf: lastMatches)
            return true
        }
        // "play <query>": find it, then play the best match.
        playAfterAnswer = true
        // Re-enter with the query part only (original casing preserved
        // by slicing the raw text).
        let query = String(text.dropFirst(verb.count))
            .trimmingCharacters(in: .whitespaces)
        ask(query)
        return true
    }

    /// Play with HONESTY (codex #300: MediaOpener silently drops
    /// unreachable records — the old path claimed "Playing" over a
    /// no-op when the first match sat on an unmounted volume). The
    /// pure choice policy is the codex test seam.
    private func play(bestOf matches: [VideoRecord]) {
        switch ArchivistPlayPolicy.choose(
            matches: matches,
            isReachable: { VolumeReachability.isReachable(path: $0) }) {
        case .none:
            let volume = (matches.first?.fullPath).map {
                MediaVolumeGatePolicy.volumeRoot(forPath: $0)
            } ?? "its volume"
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I can't play any of those right now — they're on "
                    + "an offline drive (\(volume)). Mount it and ask me again."))
        case .play(let rec, substitutedForOffline: let substituted):
            if substituted {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "The first one is on an offline drive — playing the "
                        + "first available instead."))
            }
            play(rec)
        }
    }

    private func play(_ rec: VideoRecord) {
        // Cached reachability gate first (nonblocking); the existence
        // probe for the ONE chosen file runs OFF-MAIN — a synchronous
        // fileExists here against a sleeping drive is the 60-second
        // beachball class (codex #303/#305).
        guard VolumeReachability.isReachable(path: rec.fullPath) else {
            let volume = MediaVolumeGatePolicy.volumeRoot(forPath: rec.fullPath)
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "“\(rec.filename)” is on an offline drive (\(volume)) — "
                    + "mount it and I'll play it."))
            return
        }
        let path = rec.fullPath
        let filename = rec.filename
        Task { @MainActor in
            let exists = await Task.detached(priority: .userInitiated) {
                FileManager.default.fileExists(atPath: path)
            }.value
            guard exists else {
                // Mounted volume, file gone — "unavailable", NOT
                // "offline" (we know the difference here).
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "“\(filename)” is unavailable — its drive is "
                        + "mounted but the file isn't there anymore "
                        + "(moved or deleted since cataloging)."))
                return
            }
            // Say WHERE it plays (Rick: "it plays but where?") and
            // STEP ASIDE — this window's floating level otherwise sits
            // ABOVE the player, hiding the video behind the chat. The
            // window re-floats when clicked back into.
            let player = MediaOpener.preferredPlayer(
                for: rec, hasVLC: MediaOpener.hasVLC) == .quickTime
                ? "QuickTime Player" : "VLC"
            MediaOpener.open([rec])
            ArchivistWindowFloat.stepAsideForPlayback()
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "▶️ Playing “\(filename)” in \(player) — it's front "
                    + "and center; click me to bring this chat back on top."))
        }
    }

    // MARK: General questions (Rick 2026-08-07: "who is hallie mae
    // mcgill", "when was rick born", "the family ancestry")

    /// Tree-answerable questions, handled locally: who-is biographies,
    /// birth/death dates, and the family-ancestry view. Grounded in
    /// the GEDCOM; unknowns answered honestly.
    private func handleGeneralQuestion(_ text: String) -> Bool {
        let lower = text.lowercased()

        // "family ancestry" / "family tree" → open the rendered tree.
        if lower.contains("family tree") || lower.contains("ancestry")
            || lower.contains("family history") {
            let report = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("VideoScan/family-tree/reports/breen-family-tree.html")
            let peopleCount = loadFamilyGraph()?.people.count
            if let report, FileManager.default.fileExists(atPath: report.path) {
                NSWorkspace.shared.open(report)
                ArchivistWindowFloat.stepAsideForPlayback()
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "Opening the family tree — \(peopleCount.map { "\($0) relatives" } ?? "the family") "
                        + "across the generations, in your browser."))
            } else if let count = peopleCount {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "The family tree records \(count) people. Ask me about "
                        + "any of them — \"who is …\" or \"when was … born\"."))
            } else {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I don't have the family tree loaded yet — export a "
                        + "GEDCOM into the archive and I'll learn it."))
            }
            return true
        }

        // "when was X born" / "when did X die"
        if let match = text.firstMatch(
            of: /when (?:was|did)\s+(.+?)\s+(born|die|died)/.ignoresCase()) {
            return answerDate(personText: String(match.1),
                              wantsBirth: String(match.2).lowercased() == "born",
                              original: text)
        }

        // "who is X" / "who was X" / "tell me about X"
        if let match = text.firstMatch(
            of: /(?:who is|who was|tell me about)\s+([A-Za-z][A-Za-z .']+)/.ignoresCase()) {
            return answerWhoIs(personText: String(match.1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!")),
                original: text)
        }
        return false
    }

    private func answerDate(personText: String, wantsBirth: Bool,
                            original: String) -> Bool {
        guard let graph = loadFamilyGraph() else { return false }
        let candidates = graph.people(matching: personText)
        switch candidates.count {
        case 0:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't find “\(personText)” in the family tree — try a fuller name."))
        case 1:
            let person = candidates[0]
            let date = wantsBirth ? person.birthDate : person.deathDate
            if let date {
                // Rick 2026-08-07: the departed are spoken of gently.
                let pronoun = person.sex == "M" ? "he"
                    : person.sex == "F" ? "she" : "they"
                let has = pronoun == "they" ? "have" : "has"
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: wantsBirth
                        ? "\(person.name) was born \(date)."
                        : "\(person.name) is no longer with us — \(pronoun) \(has) "
                            + "been resting in peace since \(date)."))
            } else {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "The family tree doesn't record "
                        + (wantsBirth ? "a birth date" : "a death date")
                        + " for \(person.name)."))
            }
        default:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Which \(personText) do you mean?",
                chips: candidates.prefix(4).map { candidate in
                    ArchivistMessage.Chip(
                        label: candidate.name,
                        action: .askText(original.replacingOccurrences(
                            of: personText, with: candidate.name,
                            options: .caseInsensitive)))
                }))
        }
        return true
    }

    private func answerWhoIs(personText: String, original: String) -> Bool {
        guard let graph = loadFamilyGraph() else { return false }
        let candidates = graph.people(matching: personText)
        switch candidates.count {
        case 0:
            return false   // not a tree person — let the LLM try it as a search
        case 1:
            let person = candidates[0]
            var facts: [String] = []
            if let born = person.birthDate { facts.append("born \(born)") }
            if let died = person.deathDate {
                facts.append("resting in peace since \(died)")
            }
            let parents = graph.relatives(.parents, of: person).map(\.name)
            if !parents.isEmpty {
                facts.append("child of \(parents.joined(separator: " and "))")
            }
            let spouses = graph.relatives(.spouse, of: person).map(\.name)
            if !spouses.isEmpty {
                facts.append("married to \(spouses.joined(separator: ", "))")
            }
            let kids = graph.relatives(.children, of: person).map(\.name)
            if !kids.isEmpty {
                facts.append("parent of \(kids.joined(separator: ", "))")
            }
            let sentence = facts.isEmpty
                ? "\(person.name) is in the family tree, but it records no further details."
                : "\(person.name) — \(facts.joined(separator: "; "))."
            // Offer the catalog angle via the given name.
            var chips: [ArchivistMessage.Chip] = []
            if let given = person.name.split(separator: " ").first {
                chips.append(ArchivistMessage.Chip(
                    label: "Videos of \(given)",
                    action: .applyQuery("people:\(given.lowercased())")))
            }
            messages.append(ArchivistMessage(role: .assistant, text: sentence,
                                             chips: chips))
        default:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Which \(personText) do you mean?",
                chips: candidates.prefix(4).map { candidate in
                    ArchivistMessage.Chip(
                        label: candidate.name,
                        action: .askText(original.replacingOccurrences(
                            of: personText, with: candidate.name,
                            options: .caseInsensitive)))
                }))
        }
        return true
    }

    // MARK: Kinship (Rick 2026-08-07: "show videos of rick's father")

    /// "<name>'s <relation> …" resolved against the family GEDCOM —
    /// announces the lineage fact, then re-asks with the real name.
    /// Ambiguous possessors counter-ask; unknown facts answer honestly.
    private func handleKinship(_ text: String) -> Bool {
        guard let graph = loadFamilyGraph() else { return false }
        let pattern = /([A-Za-z][A-Za-z .]*?)['’]s\s+([A-Za-z]+)/
        guard let match = text.firstMatch(of: pattern),
              let relation = GedcomFamilyGraph.relation(
                fromWord: String(match.2)) else { return false }
        let possessorTyped = String(match.1)
            .trimmingCharacters(in: .whitespaces)

        let candidates = graph.people(matching: possessorTyped)
        switch candidates.count {
        case 0:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't find “\(possessorTyped)” in the family tree — "
                    + "try a fuller name."))
            return true
        case 1:
            break
        default:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Which \(possessorTyped) do you mean?",
                chips: candidates.prefix(4).map { candidate in
                    ArchivistMessage.Chip(
                        label: candidate.name,
                        action: .askText(text.replacingOccurrences(
                            of: possessorTyped, with: candidate.name,
                            options: .caseInsensitive)))
                }))
            return true
        }

        let possessor = candidates[0]
        let relatives = graph.relatives(relation, of: possessor)
        guard !relatives.isEmpty else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "The family tree doesn't record a \(match.2) for "
                    + "\(possessor.name)."))
            return true
        }
        let names = relatives.map(\.name)
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "\(possessor.name)'s \(match.2): \(names.joined(separator: ", ")) "
                + "— searching the catalog…"))
        // Re-ask with the resolved name(s) substituted for the phrase.
        let phrase = "\(match.1)'s \(match.2)"
        let rewritten = text.replacingOccurrences(
            of: phrase, with: names.joined(separator: " and "),
            options: .caseInsensitive)
        ask(rewritten)
        return true
    }

    /// Load the newest .ged from App Support/family-tree/originals.
    private func loadFamilyGraph() -> GedcomFamilyGraph? {
        if let cached = familyGraph { return cached }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first?
            .appendingPathComponent("VideoScan/family-tree/originals")
        let gedcom = dir.flatMap {
            try? FileManager.default.contentsOfDirectory(
                at: $0, includingPropertiesForKeys: nil)
        }?
        .filter { $0.pathExtension.lowercased() == "ged" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .last
        let graph = gedcom.flatMap { GedcomFamilyGraph(fileURL: $0) }
        familyGraph = .some(graph)
        return graph
    }

    /// The archivist's reply policy — resolution first, then intent.
    private func respond(to question: String, spec: NLQuerySpec) {
        // Disarm the play-after flag FIRST (codex #300: count/ambiguity/
        // empty-compose returns left it armed, and a failed 'play X'
        // would fire on a later unrelated answer). The local carries
        // this answer's intent to the filter branch.
        let wantPlayAfter = playAfterAnswer
        playAfterAnswer = false
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
        lastMatches = matches   // "play the first one" referent

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
        // The occasional OFFER (Rick 2026-08-07: "ask, do you want me
        // to play any of these… so it feels interactive, without
        // interrupting"): small result sets get a play chip — an
        // invitation, never a nag.
        if !wantPlayAfter, (1...8).contains(matches.count),
           case .play(let candidate, _) = ArchivistPlayPolicy.choose(
               matches: matches,
               isReachable: { VolumeReachability.isReachable(path: $0) }) {
            chips.append(ArchivistMessage.Chip(
                label: "▶︎ Play “\(candidate.filename)”",
                action: .playRecord(candidate.id)))
        }
        messages.append(ArchivistMessage(role: .assistant, text: text,
                                         queryLine: composed, chips: chips))

        // "play <something>" auto-plays the best result of its search.
        if wantPlayAfter, !matches.isEmpty {
            play(bestOf: matches)
        }
    }

    private func apply(query: String, announcedAs label: String) {
        let matches = model.searchIndex.filter(records: model.records,
                                               query: query)
        lastMatches = matches   // refinement chips refresh the play referent
                                // too (codex #302: stale lastMatches let
                                // 'play first' play the PRE-refinement set)
        apply(composed: query, matches: matches.count)
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "\(matchSentence(matches.count))",
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

// MARK: - Animatable portrait (photo or GIF)

/// NSImageView-backed portrait: unlike SwiftUI's Image(nsImage:), an
/// NSImageView with `animates` plays animated GIFs — so Rick can drop
/// in "my own gif" and it moves (2026-08-07).
private struct AnimatablePortrait: NSViewRepresentable {
    let path: String

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(contentsOfFile: path)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image?.name() != path {
            view.image = NSImage(contentsOfFile: path)
        }
    }
}

// MARK: - Play policy (pure — the codex test seam, #300)

/// Which record to actually play, honestly. MediaOpener silently
/// drops unreachable records, so the CHOICE must happen before the
/// success message: the first CACHED-REACHABLE match wins (catalog
/// order preserved), noting when it substituted for an offline first
/// match; nothing reachable is `.none`, never a false "Playing".
///
/// SELECTION USES CACHED REACHABILITY ONLY (codex #303/#305): a
/// synchronous FileManager.fileExists here — on MainActor, against
/// possibly-sleeping archive drives — is the documented 60-second
/// beachball class (VolumeReachability's whole reason to exist).
/// Per-file existence is probed asynchronously OFF-MAIN for the ONE
/// chosen candidate, by the caller, after selection.
enum ArchivistPlayPolicy {
    enum Choice: Equatable {
        case none
        case play(VideoRecord, substitutedForOffline: Bool)

        static func == (lhs: Choice, rhs: Choice) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none): return true
            case (.play(let a, let sa), .play(let b, let sb)):
                return a.id == b.id && sa == sb
            default: return false
            }
        }
    }

    static func choose(matches: [VideoRecord],
                       isReachable: (String) -> Bool) -> Choice {
        guard let playable = matches.first(where: { isReachable($0.fullPath) })
        else { return .none }
        let substituted = playable.id != matches.first?.id
        return .play(playable, substitutedForOffline: substituted)
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
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
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
///
/// Playback etiquette (Rick: "it plays but where?"): a floating window
/// sits above EVERY normal window including the video player it just
/// launched — the movie played invisibly behind the chat. stepAside
/// drops to .normal so the player lands in front; becoming key again
/// (clicking the chat) restores the float.
@MainActor
enum ArchivistWindowFloat {
    fileprivate(set) static weak var window: NSWindow?

    static func stepAsideForPlayback() {
        window?.level = .normal
    }

    fileprivate static func restoreFloat() {
        window?.level = .floating
    }
}

private struct ArchivistWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.fullScreenAuxiliary)
            ArchivistWindowFloat.window = window
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window, queue: .main) { _ in
                MainActor.assumeIsolated { ArchivistWindowFloat.restoreFloat() }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
