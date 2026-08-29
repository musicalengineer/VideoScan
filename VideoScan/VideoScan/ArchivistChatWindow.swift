// ArchivistChatWindow.swift
// The Family Archivist's own window (Rick 2026-08-07: "spawn a new
// search window which floats on top which carries a conversation…
// some kind of back & forth from an agent would be VERY cool").
//
// Normal factual turns use the same honest QueryAST-v2 pipeline as the
// headless shell: exact question → Ollama translator → validated AST →
// HallieTurnExecutor. Translation failures fail closed. Answers carry at
// most 25 explicitly-labeled evidence samples with Play/Reveal actions.
// Shared-name ambiguity continues by stable profile/GEDCOM ID without a
// second translation, and "this clip" means exactly one Catalog selection.
//
// The catalog stays the display surface; this window is the voice.

import SwiftUI
import UniformTypeIdentifiers

/// General app-log records for Hallie actions. Deliberately accepts metadata
/// only: raw questions, answers, names and error prose belong in the scoped
/// Hallie transcript or the UI, never in videoscan.log.
enum ArchivistDiagnosticLine {
    enum FailureOperation: String { case interpretation, continuation }

    static func recompileStarted(willReask: Bool) -> String {
        "[family-tree] Hallie recompile started reask=\(willReask)"
    }

    static let focusRequested = "[family-tree] Hallie focus requested target=person-id"
    static let filmOfferSuppressed = "[hallie] film offer suppressed reason=person-predates-medium"

    static func failure(_ operation: FailureOperation, error: Error) -> String {
        let prefix = "[hallie] \(operation.rawValue) failed"
        guard let translator = error as? NLTranslatorError else {
            return prefix + " reason=unexpected category=\(String(describing: type(of: error)))"
        }
        switch translator {
        case .badResponse:
            return prefix + " reason=bad-response"
        case .unreachable:
            return prefix + " reason=unreachable"
        case .serverError(let status, _):
            return prefix + " reason=server-error http_status=\(status)"
        case .modelUnavailable:
            return prefix + " reason=model-unavailable"
        }
    }
}

// MARK: - Messages

enum ArchivistFamilyFactKind: Sendable {
    case biography
    case birth
    case death
}

struct ArchivistMessage: Identifiable {
    enum Role { case user, assistant }

    struct Chip: Identifiable {
        enum Action {
            /// Apply this composed query to the catalog now.
            case applyQuery(String)
            /// Send this text through the full ask pipeline (used for
            /// person-disambiguation corrections).
            case askText(String, playAfterAnswer: Bool)
            /// Play this specific record (the "▶︎ Play …" offer).
            case playRecord(UUID)
            /// Continue a GEDCOM ambiguity choice by stable person ID.
            case familyFact(personID: String, kind: ArchivistFamilyFactKind)
            /// Continue a kinship ambiguity choice by stable GEDCOM ID.
            case kinship(personID: String,
                         relation: GedcomFamilyGraph.Relation,
                         relationWord: String,
                         question: String,
                         matchedPhrase: String,
                         playAfterAnswer: Bool)
            /// Continue a translator person-grouping clarification without
            /// re-entering the same ambiguous resolver path.
            case resolvedPeople(question: String,
                                spec: NLQuerySpec,
                                canonicalNames: [String],
                                playAfterAnswer: Bool)
            /// Continue QueryAST-v2 with the executor-issued stable identity.
            case hallieIdentityChoice(HallieTurnExecutor.CandidateID)
            /// Open the Family Tree tab focused on a person (offered after
            /// "show Donna's family tree").
            case openFamilyTree(personName: String)
            case openFamilyTreePerson(personID: String, personName: String)
            /// Open the Family Tree tab filtered to a surname.
            case openFamilyTreeSurname(String)
            /// Open the Family Tree tab and present Get Family Tree.
            case getFamilyTree
            /// Recompile the family tree from the pulls on disk (live
            /// miss #8). `thenAsk` = the question to re-run once promoted.
            case recompileFamilyTree(thenAsk: String?)
            /// Open the People tab (relationships overview, live miss #12).
            case openPeopleTab
            /// Remote viewer: continue the MASTER's pending which-one by
            /// stable identity (HallieRemoteClient.select).
            case remoteSelect(HallieTurnExecutor.CandidateID)
        }
        let id = UUID()
        let label: String
        let action: Action
    }

    /// `var` so a progress bubble ("Recompiling the family tree… Reading
    /// a.ged…") can be updated in place by id (live miss #8).
    var id = UUID()
    let createdAt = Date()
    let role: Role
    var text: String
    /// Monospaced sub-line showing the exact query (assistant only).
    var queryLine: String?
    /// Human-readable provenance for family facts and honest declines.
    var basisLine: String?
    /// Optional verified POI cover photo attached to a biography. This is
    /// presentation only; it is never part of the LLM prompt or fact basis.
    var biographyPhoto: ArchivistBiographyPhoto? = nil
    /// Cards to look at (lineage, tree, crest, photo request) — presentation
    /// only, same rule as `biographyPhoto` (2026-08-22).
    var attachments: [HallieAttachment] = []
    /// Bounded evidence samples returned by the shared factual executor.
    /// These are explicitly samples, never represented as every match.
    var citations: [HallieTurnExecutor.Citation] = []
    /// Curated biography / GEDCOM sources. Locators remain relative and are
    /// display-only until a separately verified source-opening action exists.
    var knowledgeCitations: [HallieTurnExecutor.KnowledgeCitation] = []
    /// Per-message diagnostics. Keeping these on the message prevents a later
    /// answer from rewriting which model/route produced an earlier bubble.
    var responder: String? = nil
    var model: String? = nil
    var route: String? = nil
    var outcome: String? = nil
    /// "template" | "model": who phrased this bubble (assistant only).
    var composedBy: String? = nil
    /// The transcript-log text when the model phrased the answer: the same
    /// sentences WITH their claim tags, so the log stays traceable while the
    /// bubble stays clean. Nil = log `text`.
    var transcriptText: String? = nil
    var chips: [Chip] = []

    /// Production seam for person clarification.  These must be resolved
    /// continuations, never `.askText`, because the displayed name can itself
    /// be a reciprocal alias (Tim/Timmy) and would re-enter the same loop.
    static func personClarificationChips(
        for pending: ArchivistPersonClarification
    ) -> [Chip] {
        pending.candidates.map { candidate in
            Chip(
                label: candidate,
                action: .resolvedPeople(
                    question: pending.question,
                    spec: pending.spec,
                    canonicalNames: [candidate],
                    playAfterAnswer: pending.playAfterAnswer))
        }
    }
}

/// Downsamples a biography portrait off-main when its bubble appears. A large
/// phone/scan original must never be decoded at full resolution on MainActor.
private struct ArchivistBiographyPhotoView: View {
    let photo: ArchivistBiographyPhoto
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(photo.cropScale)
                    .offset(x: photo.cropOffsetX * 40,
                            y: photo.cropOffsetY * 40)
            } else {
                Color.secondary.opacity(0.08)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: 220, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityLabel("Photo of \(photo.profileCanonicalName)")
        .task(id: photo.fileURL) {
            guard image == nil else { return }
            let worker = Task.detached(priority: .userInitiated) {
                photo.makeThumbnail()
            }
            let thumbnail = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let thumbnail else { return }
            image = NSImage(cgImage: thumbnail, size: .zero)
        }
    }
}

// MARK: - Window

struct ArchivistChatWindow: View {
    @EnvironmentObject var model: VideoScanModel

    @AppStorage("archivist.ollamaHost") private var ollamaHost = "ricksm5.local"
    /// Which host actually answered the last question. Worth surfacing:
    /// with a fallback list, "the Archivist is slow" and "the primary is
    /// asleep and you are talking to the laptop" look identical
    /// otherwise (Rick 2026-08-12).
    @State private var lastResponder: String?
    @AppStorage("archivist.ollamaModel") private var ollamaModel = "qwen3.6:35b-a3b-nvfp4"

    @State private var messages: [ArchivistMessage] = []
    @State private var transcriptSessionID = UUID()
    @State private var transcriptSequence: UInt64 = 0
    @State private var loggedMessageIDs: Set<UUID> = []
    @State private var input = ""
    @State private var inputHistory = ArchivistChatInputHistory()
    @State private var isThinking = false
    @State private var activeRequestID: UUID?
    @State private var activeRequestTask: Task<Void, Never>?
    @State private var pendingHallieClarification:
        HallieAppTurnCoordinator.PendingClarification?
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The last filter's matches — "play the first one" needs a
    /// referent (class refs, not copies).
    @State private var lastMatches: [VideoRecord] = []
    /// Per-conversation memory for the QueryAST-v2 path: the last answered
    /// result set and AST, so "play one of them", "show more", and "and in
    /// the 90s?" resolve deterministically before any translation.
    @State private var hallieMemory = HallieTurnExecutor.ConversationMemory()
    /// Non-nil while a family member is telling Hallie about someone.
    @State private var hallieTelling: HallieTellingMode.Session?
    /// The name drill in progress ("let's practice names"), carried turn to turn.
    @State private var hallieDrill: HalliePronunciationDrillMode.Session?
    /// Set by "play <something>": after the filter answer lands, the
    /// first match auto-plays.
    @State private var playAfterAnswer = false
    /// A person question waiting for Rick's explicit choice.  Keeping the
    /// original validated spec here lets a reply continue deterministically;
    /// a context-free "yes" must never be sent back through the translator.
    @State private var pendingPersonClarification: ArchivistPersonClarification?
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
    /// "Let Hallie phrase answers in her own words (facts stay locked)".
    /// Default ON; the composer only ever re-says an approved plan and the
    /// verifier drops anything else (docs/hallie_grounded_composition.md).
    @AppStorage(HallieCompositionSettings.key) private var composeWithModel = true
    /// Which drawn avatar fronts the archivist when no photo is set:
    /// "donna" (the caricature from Rick's photo) or "hallie" (the
    /// original librarian). Right-click the portrait to switch.
    @AppStorage("archivist.avatar") private var archivistAvatar = "donna"
    /// Rick 2026-08-18: slow cycle through Hallie Mae's four angle stills
    /// when they sit beside the portrait; ON prefers them over video loops.
    @AppStorage("archivist.cycleAngles") private var cycleAngles = true
    /// Who "I" is when someone asks "how am I related to you?" — the person
    /// using the app (Rick 2026-08-18; the pronoun binding lives in
    /// HallieSpeakerBinding). "You" is the archivist herself; if her display
    /// name isn't how the family tree spells her, `archivist.personName`
    /// pins the tree spelling. Keys shared with
    /// `HallieTurnExecutor.Speakers.fromDefaults()`.
    @AppStorage("archivist.ownerPersonName") private var ownerPersonName = "Rick Breen"
    @AppStorage("archivist.personName") private var archivistPersonName = ""
    /// Human conversation is the default. Query ASTs, basis strings,
    /// responder hosts, and per-citation matching reasons remain available
    /// for QA and are always retained in the structured transcript.
    @AppStorage("archivist.showTechnicalDetails") private var showTechnicalDetails = false
    @State private var showSpeakerSettings = false
    /// Ask ⇄ Stop while she reads an answer aloud (Rick 2026-08-24:
    /// "can't stop Hallie" on long lists).
    @ObservedObject private var hallieSpeaker = HallieSpeaker.shared

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
                                    .font(.system(size: 15))
                                    .foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        } else if showTechnicalDetails,
                                  let responder = lastResponder {
                            // RENDER the responder, don't just record it
                            // (codex #315). With a fallback list, "the
                            // Archivist feels slow" and "the primary is
                            // asleep so you are on the laptop" look
                            // identical without this line.
                            Text("answered by \(OllamaEndpoints.displayLabel(for: responder))")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    queueTranscriptWrites()
                    withAnimation {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about the family catalog…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 17))
                    .controlSize(.large)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onKeyPress(keys: [.upArrow, .downArrow]) {
                        handleInputHistoryKey($0)
                    }
                    .disabled(isThinking)
                    .accessibilityIdentifier("archivist.chatInput")
                if hallieSpeaker.isSpeaking {
                    // The Ask button becomes Stop while she speaks — one
                    // obvious control in one place (⌘. also works).
                    Button("Stop") { hallieSpeaker.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                        .tint(.red)
                        .accessibilityIdentifier("archivist.stopSpeaking")
                } else {
                    Button("Ask", action: send)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isThinking
                                  || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 480, idealHeight: 680)
        .background(ArchivistWindowConfigurator())
        .sheet(isPresented: $showSpeakerSettings) {
            ArchivistSpeakerSettingsSheet(
                ownerPersonName: $ownerPersonName,
                archivistPersonName: $archivistPersonName,
                archivistName: archivistName)
        }
        .onChange(of: model.archivistAskRequest) { consumePendingAskRequest() }
        // A request that arrived while Hallie was thinking (a Photos import
        // finishing mid-answer) is picked up the moment she is free, not
        // left waiting for some unrelated next request (codex #663).
        .onChange(of: isThinking) { _, thinking in
            if !thinking { consumePendingAskRequest() }
        }
        .onAppear {
            inputFocused = true
            consumePendingAskRequest()
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
        .onDisappear {
            activeRequestID = nil
            activeRequestTask?.cancel()
            activeRequestTask = nil
            isThinking = false
        }
    }

    // MARK: Identity header

    /// Optional gaze frames beside the chosen portrait: `<name>-left.<ext>`
    /// and `<name>-right.<ext>` (head turned slightly). Absent → the single
    /// still is used for every gaze (still lives via motion).
    static func gazeFrames(for path: String) -> [ArchivistLivingPortrait.Gaze: NSImage] {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var out: [ArchivistLivingPortrait.Gaze: NSImage] = [:]
        for (gaze, suffix) in [(ArchivistLivingPortrait.Gaze.left, "-left"), (.right, "-right")] {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent(stem + suffix).appendingPathExtension(ext)
            if let img = NSImage(contentsOfFile: candidate.path) { out[gaze] = img }
        }
        return out
    }

    /// Hallie Mae's ANGLE stills beside the chosen portrait (Rick 2026-08-18:
    /// "a slow cycle through four photos of her from different angles").
    /// Discovers `<stem>-angle1.<ext>`, `-angle2`, … contiguous from 1 and
    /// stops at the first gap; fewer than two → empty (nothing to cycle).
    /// Also accepts a portrait whose OWN stem is the numbered set — e.g.
    /// `HallieMaeAngles-1.png` with `-2..-4` siblings — so picking the
    /// first frame as the portrait is enough. Returns file URLs only (pure,
    /// testable); `angleFrames(for:)` decodes them.
    static func angleFrameURLs(besideImageAt path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let fm = FileManager.default
        // A numbered stem ("Foo-1") means the portrait itself is frame 1.
        // Swift's `#/…/#` regex literal ≈ std::regex, but checked at compile time.
        let numbered = stem.firstMatch(of: #/^(.*-)(\d+)$/#).flatMap { m -> (base: String, start: Int)? in
            guard let n = Int(m.2), n == 1 else { return nil }
            return (String(m.1), n)
        }
        var found: [URL] = []
        if let numbered {
            var n = numbered.start
            while true {
                let c = dir.appendingPathComponent(numbered.base + String(n)).appendingPathExtension(ext)
                guard fm.fileExists(atPath: c.path) else { break }
                found.append(c); n += 1
            }
        } else {
            var n = 1
            while true {
                let c = dir.appendingPathComponent("\(stem)-angle\(n)").appendingPathExtension(ext)
                guard fm.fileExists(atPath: c.path) else { break }
                found.append(c); n += 1
            }
        }
        return found.count >= 2 ? found : []
    }

    /// Decoded angle frames, cached for the last portrait path so the
    /// identity header's re-renders (focus, thinking) don't re-read four
    /// PNGs. Single-entry cache: worst case ≈ 6 MB of bitmap for four
    /// 619×619 frames.
    @MainActor private static var angleFrameCache: (path: String, frames: [NSImage])?
    @MainActor static func angleFrames(for path: String) -> [NSImage] {
        if let c = angleFrameCache, c.path == path { return c.frames }
        let frames = angleFrameURLs(besideImageAt: path).compactMap { NSImage(contentsOfFile: $0.path) }
        angleFrameCache = (path, frames)
        return frames
    }

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
                        let loops = ArchivistPortraitLoops.discover(besideImageAt: archivistPhotoPath)
                        // Rick 2026-08-18: her four angle stills. Video loops
                        // (Rick's deliberate choice) win unless he asked to
                        // "Cycle through her angles" and the stills are there.
                        let angleFrames = Self.angleFrames(for: archivistPhotoPath)
                        let preferAngles = cycleAngles && angleFrames.count >= 2
                        if loops.hasVideo && !reduceMotion && !preferAngles {
                            // Outsourced "librarian at her desk" loops:
                            // idle / listening / thinking, seamless, muted.
                            ArchivistVideoPortrait(
                                loops: loops,
                                state: isThinking ? .thinking : (inputFocused ? .listening : .idle))
                        } else if archivistPhotoPath.lowercased().hasSuffix(".gif") {
                            AnimatablePortrait(path: archivistPhotoPath)
                        } else if let image = NSImage(contentsOfFile: archivistPhotoPath) {
                            // She lives a little: breathing, drifting tilt,
                            // a lean toward the input while you type, a glow
                            // while thinking, a nod when she answers.
                            ArchivistLivingPortrait(image: image,
                                                    frames: Self.gazeFrames(for: archivistPhotoPath),
                                                    angleFrames: cycleAngles ? angleFrames : [],
                                                    isListening: inputFocused && !isThinking,
                                                    isThinking: isThinking,
                                                    isComposing: inputFocused && !input.isEmpty,
                                                    answerCount: messages.count)
                        }
                    } else if archivistAvatar == "hallie" {
                        HallieMaeAvatar(isTalking: isThinking)
                            .background(Circle().fill(Color(red: 0.96, green: 0.93, blue: 0.86)))
                    } else {
                        DonnaAvatar(isTalking: isThinking)
                            .background(Circle().fill(Color(red: 0.93, green: 0.95, blue: 0.97)))
                    }
                }
                // Rick 2026-08-17: "make Hallie look a bit more real, image
                // area larger, more personal without being overwhelming."
                // 84 → 132 pt, a warm sepia-toned double ring instead of the
                // thin purple stroke, and a soft shadow so she sits ON the
                // window rather than in it.
                .frame(width: 132, height: 132)
                .background(Circle().fill(Color.white))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(red: 0.62, green: 0.48, blue: 0.32).opacity(0.55), lineWidth: 3))
                .overlay(Circle().inset(by: -5).stroke(Color(red: 0.62, green: 0.48, blue: 0.32).opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
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
                // Rick 2026-08-18: prefer the slow walk through her angle
                // stills even when video loops sit beside the portrait.
                Toggle("Cycle through her angles", isOn: $cycleAngles)
                Toggle("Show technical details", isOn: $showTechnicalDetails)
                Divider()
                // "how am I related to you?" needs to know who "I" is.
                Button("Who is talking to her… (\(ownerPersonName.isEmpty ? "not set" : ownerPersonName))") {
                    showSpeakerSettings = true
                }
                Divider()
                Button("Choose a photo or GIF…", action: choosePhoto)
            }
            .help("Click to pick a portrait or GIF — right-click for quick switches")

            VStack(alignment: .leading, spacing: 3) {
                TextField("Name TBD", text: $archivistName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                Text("Family Archivist")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                if archivistName == "Hallie Mae" {
                    // Who she was — the archivist is a real person.
                    Text("Hallie Mae McGill Latta · 1876–1908 · Louisville, Kentucky")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Rick 2026-08-22: Hallie on the left, settings far right by
            // the sparkle — large, labelled, for older eyes.
            VStack(spacing: 4) {
                Button {
                    showSpeakerSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 26, weight: .regular))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Color.secondary.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings — who is talking, read aloud, and letting the family use her from the iPad or laptop")
                .accessibilityLabel("Hallie settings")
                Text("Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.purple)
                .padding(.leading, 6)
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
            // Hallie Mae herself (Rick's family records, restored 2026-08-17).
            ("Hallie Mae — reconstructed, in the library", base + "/HallieMaeReconstructed.png"),
            // Rick 2026-08-18: four stills of her from different angles; the
            // header discovers -2..-4 beside -1 and slowly cycles. The repo
            // copy is a fallback so Rick sees her before installing.
            ("Hallie Mae — four angles", base + "/HallieMaeAngles-1.png"),
            ("Hallie Mae — four angles (repo copy)",
             NSHomeDirectory() + "/dev/VideoScan/assets/Hallie/HallieMaeAngles-1.png"),
            ("Hallie Mae — portrait c.1900", base + "/HallieMaeMcGillLatta-portrait.jpeg"),
            ("Hallie Mae — wedding c.1897", base + "/HallieMaeMcGillLatta-wedding-circa1897-straightened.jpeg"),
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
                    .font(.system(size: 17))
                    .textSelection(.enabled)
                if message.role == .assistant {
                    Button {
                        HallieSpeaker.shared.speak(message.text)
                    } label: {
                        Label("Read this aloud", systemImage: "speaker.wave.2.fill")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Read this answer aloud")
                }
                if showTechnicalDetails, let query = message.queryLine {
                    Text(query)
                        .font(.system(size: 15).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if showTechnicalDetails, let basis = message.basisLine {
                    Text(basis)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let photo = message.biographyPhoto {
                    ArchivistBiographyPhotoView(photo: photo)
                }
                if !message.attachments.isEmpty {
                    HallieAttachmentsView(attachments: message.attachments)
                }
                if !message.citations.isEmpty {
                    citationEvidence(message.citations)
                }
                if !message.knowledgeCitations.isEmpty {
                    knowledgeEvidence(message.knowledgeCitations)
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

    private func citationEvidence(
        _ citations: [HallieTurnExecutor.Citation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Evidence samples (up to 25; not all matches)")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(citations.indices, id: \.self) { index in
                let citation = citations[index]
                ArchivistCitationRow(
                    index: index,
                    citation: citation,
                    timestampSuffix: citationTimestamp(citation),
                    basisLines: showTechnicalDetails
                        ? citation.bases.map(citationBasis) : [],
                    record: model.record(forID: citation.recordID),
                    isArchived: model.record(forID: citation.recordID)
                        .map { model.pfHasMasterCopy($0) } ?? false,
                    onPlay: { playCitation(citation) },
                    onReveal: { revealCitation(citation) },
                    onShowInCatalog: { showCitationInCatalog(citation) })
                if index != citations.indices.last { Divider() }
            }
        }
        .padding(.top, 3)
    }

    private func knowledgeEvidence(
        _ citations: [HallieTurnExecutor.KnowledgeCitation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Family archive sources")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(citations) { citation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.title)
                        .font(.system(size: 15, weight: .medium))
                        .textSelection(.enabled)
                    let details = [citation.attribution, citation.locator]
                        .compactMap { $0 }
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.top, 3)
    }

    private func citationTimestamp(
        _ citation: HallieTurnExecutor.Citation
    ) -> String {
        citation.playbackSeconds.map {
            String(format: " @ %.1fs", $0)
        } ?? ""
    }

    private func citationBasis(_ basis: ArchivistEvidenceBasis) -> String {
        basis.summary
    }

    /// Snapshot newly displayed bubbles before leaving MainActor. The actor
    /// performs filesystem I/O; sequence numbers make ordering reconstructible
    /// even when separate Swift tasks reach it at slightly different times.
    private func queueTranscriptWrites() {
        var events: [HallieTranscriptEvent] = []
        for message in messages where !loggedMessageIDs.contains(message.id) {
            loggedMessageIDs.insert(message.id)
            transcriptSequence += 1
            let media = message.citations.map { citation in
                HallieTranscriptEvent.MediaEvidence(
                    recordID: citation.recordID,
                    filename: citation.filename,
                    fullPath: citation.fullPath,
                    playbackSeconds: citation.playbackSeconds,
                    bases: citation.bases.map(citationBasis))
            }
            let knowledge = message.knowledgeCitations.map { citation in
                HallieTranscriptEvent.KnowledgeEvidence(
                    id: citation.id,
                    title: citation.title,
                    attribution: citation.attribution,
                    locator: citation.locator)
            }
            events.append(HallieTranscriptEvent(
                timestamp: message.createdAt,
                sessionID: transcriptSessionID,
                eventID: message.id,
                sequence: transcriptSequence,
                client: .app,
                kind: message.role == .user ? .user : .assistant,
                text: message.transcriptText ?? message.text,
                queryDescription: message.queryLine,
                basisLine: message.basisLine,
                responder: message.responder,
                model: message.model,
                route: message.route,
                outcome: message.outcome,
                offeredActions: message.chips.map(\.label),
                mediaEvidence: media,
                knowledgeEvidence: knowledge,
                attachmentOutline: message.attachments.isEmpty
                    ? nil : HallieAttachmentText.lines(message.attachments),
                composedBy: message.composedBy))
        }
        guard !events.isEmpty else { return }
        Task { await HallieConversationRecorder.shared.append(events) }
    }

    private func playCitation(_ citation: HallieTurnExecutor.Citation) {
        guard let record = model.record(forID: citation.recordID) else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "That evidence item is no longer in the catalog."))
            return
        }
        play(record)
    }

    /// Same mechanism as the MFO window's "Show in Catalog": switch the
    /// main window to the Catalog tab and select exactly this record.
    /// The chat window stays where it is (always-on-top), so the row is
    /// visible behind it — Hallie points, the catalog shows.
    private func showCitationInCatalog(_ citation: HallieTurnExecutor.Citation) {
        guard model.canNavigateToRecord(id: citation.recordID) else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "“\(citation.filename)” is no longer in the catalog — "
                    + "it may have been removed or replaced by a re-scan."))
            return
        }
        UserDefaults.standard.set(1, forKey: "selectedTab")
        model.pendingCatalogSelection = citation.recordID
        MainWindowHelper.shared.openMainWindow()
    }

    private func revealCitation(_ citation: HallieTurnExecutor.Citation) {
        guard VolumeReachability.isReachable(path: citation.fullPath) else {
            let volume = MediaVolumeGatePolicy.volumeRoot(
                forPath: citation.fullPath)
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "“\(citation.filename)” is on an offline drive "
                    + "(\(volume)) — mount it and I'll reveal it."))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: citation.fullPath)
        ])
    }

    // MARK: Conversation

    private func greet() {
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "Hi Rick — I'm the Family Archivist. Ask me about anyone "
                + "or anything in the catalog, and I'll show you what we have.",
            chips: Self.starterQuestions.map {
                ArchivistMessage.Chip(
                    label: $0,
                    action: .askText($0, playAfterAnswer: false))
            }))
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        inputHistory.record(text)
        input = ""
        ask(text)
    }

    private func handleInputHistoryKey(
        _ press: KeyPress
    ) -> KeyPress.Result {
        let recalled: String?
        if press.key == .upArrow {
            recalled = inputHistory.previous(current: input)
        } else if press.key == .downArrow {
            recalled = inputHistory.next()
        } else {
            return .ignored
        }
        guard let recalled else { return .ignored }
        input = recalled
        return .handled
    }

    /// Family Tree right-click → "Tell me about this person" (Rick
    /// 2026-08-24). The tree publishes the question; we ask it as if a
    /// chip was tapped. Left pending while a previous answer is still
    /// composing; onChange fires again on the next request.
    private func consumePendingAskRequest() {
        guard let question = model.archivistAskRequest, !isThinking else { return }
        model.archivistAskRequest = nil
        handle(chip: ArchivistMessage.Chip(
            label: question, action: .askText(question, playAfterAnswer: false)))
    }

    private func handle(chip: ArchivistMessage.Chip) {
        // One request owns the conversation state until it completes. Chips
        // remain visible while the local model works, but cannot start a
        // second translation that steals play intent or commits stale output.
        guard !isThinking else { return }
        pendingPersonClarification = nil
        switch chip.action {
        case .askText(let text, let wantsPlayAfter):
            playAfterAnswer = wantsPlayAfter
            ask(text)
        case .applyQuery(let query):
            apply(query: query, announcedAs: chip.label)
        case .playRecord(let id):
            if let rec = model.record(forID: id) { play(rec) }
        case .familyFact(let personID, let kind):
            answerFamilyFact(personID: personID, kind: kind)
        case .kinship(let personID, let relation, let relationWord,
                      let question, let matchedPhrase, let wantsPlayAfter):
            answerKinship(personID: personID, relation: relation,
                          relationWord: relationWord, question: question,
                          matchedPhrase: matchedPhrase,
                          playAfterAnswer: wantsPlayAfter)
        case .resolvedPeople(let question, let spec, let canonicalNames,
                             let playAfterAnswer):
            respond(to: question, spec: spec,
                    resolvedPeople: canonicalNames,
                    forcedPlayAfter: playAfterAnswer)
        case .hallieIdentityChoice(let candidateID):
            guard let pending = pendingHallieClarification,
                  let candidate = pending.clarification.candidates.first(
                    where: { $0.id == candidateID }) else { return }
            messages.append(ArchivistMessage(
                role: .user, text: candidate.label))
            continueHallie(pending: pending, selecting: candidateID)
        case .remoteSelect(let candidateID):
            messages.append(ArchivistMessage(role: .user, text: chip.label))
            selectOnViewer(candidateID)
        case .openFamilyTree(let personName):
            openFamilyTreeTab(focus: personName, personID: nil, surname: nil)
        case .openFamilyTreePerson(let personID, let personName):
            openFamilyTreeTab(
                focus: personName, personID: personID, surname: nil)
        case .openFamilyTreeSurname(let surname):
            openFamilyTreeTab(focus: nil, personID: nil, surname: surname)
        case .getFamilyTree:
            // Same AppStorage hand-off as focus; the tab presents the sheet
            // when the request token changes.
            UserDefaults.standard.set(UUID().uuidString, forKey: "ftGetFamilyTreeRequest")
            UserDefaults.standard.set(5, forKey: "selectedTab")
            MainWindowHelper.shared.openMainWindow()
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Opening Get Family Tree in the Family Tree tab."))
        case .recompileFamilyTree(let thenAsk):
            recompileFamilyTree(thenAsk: thenAsk)
        case .openPeopleTab:
            UserDefaults.standard.set(0, forKey: "selectedTab")
            MainWindowHelper.shared.openMainWindow()
            messages.append(ArchivistMessage(
                role: .assistant, text: "Opening the People tab."))
        }
    }

    /// Hallie's "The family tree is on disk but needs recompiling … I can
    /// do that now" (live miss #8, 2026-08-29): run the same recompile the
    /// Family Tree tab's banner button runs, with its phase captions in
    /// the transcript, then re-ask `thenAsk` so the original question is
    /// answered without another tap. A refused promote is said, not hidden.
    private func recompileFamilyTree(thenAsk question: String?) {
        guard !isThinking, !FamilyTreeRecompileCenter.shared.isRunning else { return }
        isThinking = true
        let messageID = UUID()
        messages.append(ArchivistMessage(
            id: messageID, role: .assistant, text: "Recompiling the family tree…",
            basisLine: "Action: recompile the compiled family tree from the pulls on disk."))
        // The question belongs in Hallie's access-controlled transcript, not
        // the general application diagnostic log.
        appLog.write(ArchivistDiagnosticLine.recompileStarted(willReask: question != nil))
        Task { @MainActor in
            let outcome = await FamilyTreeRecompileCenter.shared.recompile { [self] phase in
                replaceMessageText(id: messageID, with: "Recompiling the family tree… \(phase)")
            }
            isThinking = false
            inputFocused = true
            switch outcome {
            case .promoted:
                replaceMessageText(id: messageID, with: "The family tree is compiled again.")
                appLog.write("[family-tree] Hallie recompile promoted")
                if let question { ask(question) }
            case .nothingPending:
                replaceMessageText(id: messageID, with: "The family tree is already compiled — nothing to do.")
                if let question { ask(question) }
            case .failed:
                replaceMessageText(id: messageID, with: "The recompile did not promote a tree — the log says why. The pull files are unchanged.")
                appLog.write("[family-tree] Hallie recompile did not promote")
            }
        }
    }

    private func replaceMessageText(id: UUID, with text: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var message = messages[index]
        message.text = text
        messages[index] = message
    }

    /// Same cross-tab hook the People tab uses ("Show <name> in Family
    /// Tree"): drop the name into AppStorage, switch the main window to the
    /// Family Tree tab (tag 5), and let that view pick it up.
    private func openFamilyTreeTab(
        focus personName: String?, personID: String?, surname: String?,
        announce: Bool = true
    ) {
        if let personID {
            UserDefaults.standard.set(personID, forKey: "ftHighlightedPersonID")
        } else {
            UserDefaults.standard.removeObject(forKey: "ftHighlightedPersonID")
        }
        if let personName {
            UserDefaults.standard.set(personName, forKey: "ftHighlightedPersonName")
        } else {
            UserDefaults.standard.removeObject(forKey: "ftHighlightedPersonName")
        }
        if let surname {
            UserDefaults.standard.set(surname, forKey: "ftIncomingSearchText")
        }
        UserDefaults.standard.set(5, forKey: "selectedTab")
        MainWindowHelper.shared.openMainWindow()
        guard announce else { return }
        messages.append(ArchivistMessage(
            role: .assistant,
            text: personName.map { "Opening the Family Tree tab focused on \($0)." }
                ?? "Opening the Family Tree tab filtered to “\(surname ?? "")”."))
    }

    private func ask(_ text: String) {
        guard !isThinking else { return }
        // Remote viewer (Phase 1): the master's Hallie answers; its bridge
        // owns any pending which-one, so a typed reply goes straight there.
        if ViewerModeCenter.shared.isViewer {
            messages.append(ArchivistMessage(role: .user, text: text))
            askOnViewer(text)
            return
        }
        if let pending = pendingHallieClarification {
            let folded = PersonResolver.normalize(text)
            // Shared matcher: numbers, exact names, "the one born in 1785",
            // older/younger, ordinals, places, parents, spouses
            // (HallieClarificationReply.swift). A discriminator that fits
            // several narrows the list; one that fits nobody is said, and
            // the same question stays open (live 2026-08-28: "the one born
            // in 1959" used to fall through to the translator).
            switch HallieTurnExecutor.clarificationReply(
                text, from: pending.clarification.candidates) {
            case .selected(let selected):
                messages.append(ArchivistMessage(role: .user, text: text))
                continueHallie(pending: pending, selecting: selected)
                return
            case .narrowed(let subset, let discriminator):
                messages.append(ArchivistMessage(role: .user, text: text))
                let narrowed = pending.narrowed(to: subset) ?? pending
                pendingHallieClarification = narrowed
                appendHallieClarification(
                    narrowed,
                    preface: HallieTurnExecutor.narrowedClarificationPreface(
                        count: narrowed.clarification.candidates.count,
                        discriminator: discriminator))
                return
            case .unmatched(let discriminator):
                messages.append(ArchivistMessage(role: .user, text: text))
                appendHallieClarification(
                    pending,
                    preface: HallieTurnExecutor.unmatchedClarificationPreface(discriminator))
                return
            case .notASelection:
                break
            }
            if ["yes", "y", "yeah", "yep", "correct", "right",
                "that's right", "thats right"]
                .contains(folded) {
                messages.append(ArchivistMessage(role: .user, text: text))
                appendHallieClarification(
                    pending,
                    preface: "I need the name so I don't guess. ")
                return
            }
            if ["cancel", "never mind", "nevermind", "no"]
                .contains(folded) {
                pendingHallieClarification = nil
                messages.append(ArchivistMessage(role: .user, text: text))
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "Okay — I won't guess which person you meant."))
                return
            }
            // A complaint about the list itself ("you presented me a list of
            // people born hundreds of years ago", live 2026-08-28) keeps the
            // question pending: the repair reply re-asks it narrowed, and a
            // typed or tapped name afterwards still selects from it.
            // Any other non-matching reply is a new question.
            if !HallieRepairTurn.isRepair(text) {
                pendingHallieClarification = nil
            }
        }
        messages.append(ArchivistMessage(role: .user, text: text))
        askLocally(text)
    }

    /// The in-process pipeline (master, and a viewer's local-brain
    /// fallback): capture the referent, run the coordinator, commit.
    private func askLocally(_ text: String) {
        // Every question — including "play the first one" and "show more" —
        // goes through the coordinator: follow-ups and capability questions
        // resolve there against conversation memory with no model call, and
        // everything else goes through QueryAST-v2. The old v1 local/search
        // paths must not intercept or broaden it.

        // Capture the sole Catalog referent and its best date BEFORE any
        // translation await. A later row change cannot alter this turn.
        let selectedID = model.hallieCurrentSelectionID
        let selectedDate = selectedID
            .flatMap { model.record(forID: $0) }
            .flatMap { ArchivistTemporalSelectionDateSnapshot.capture(record: $0) }
        let referent = HallieAppTurnCoordinator.CapturedReferent(
            recordID: selectedID,
            temporalDate: selectedDate)
        let records = model.records
        let wantsPlayAfter = playAfterAnswer
        playAfterAnswer = false
        let memory = hallieMemory
        let telling = hallieTelling
        let drill = hallieDrill
        let history = recentHistory()
        let compose = composeWithModel
        let requestID = UUID()
        activeRequestTask?.cancel()
        activeRequestID = requestID
        isThinking = true
        let hosts = OllamaEndpoints.resolved(from: .standard)
        let modelName = ollamaModel
        activeRequestTask = Task { @MainActor in
            defer {
                if activeRequestID == requestID {
                    activeRequestID = nil
                    activeRequestTask = nil
                    isThinking = false
                    inputFocused = true
                }
            }
            do {
                let response = try await HallieAppTurnCoordinator.execute(
                    question: text,
                    records: records,
                    referent: referent,
                    hosts: hosts,
                    modelName: modelName,
                    playAfterAnswer: wantsPlayAfter,
                    memory: memory,
                    composeWithModel: compose,
                    history: history,
                    telling: telling,
                    drill: drill)
                guard !Task.isCancelled,
                      activeRequestID == requestID else { return }
                commitHallie(response, question: text)
            } catch {
                guard !Task.isCancelled,
                      activeRequestID == requestID else { return }
                appLog.write(ArchivistDiagnosticLine.failure(.interpretation, error: error))
                lastMatches = []
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: HallieHelperFailure.message(for: error),
                    basisLine: HallieHelperFailure.basisLine))
            }
        }
    }

    private func appendHallieClarification(
        _ pending: HallieAppTurnCoordinator.PendingClarification,
        preface: String = ""
    ) {
        messages.append(ArchivistMessage(
            role: .assistant,
            text: preface + "Which person do you mean?",
            basisLine: "Basis: the name matches more than one stable identity.",
            chips: pending.clarification.candidates.map {
                ArchivistMessage.Chip(
                    label: $0.label,
                    action: .hallieIdentityChoice($0.id))
            }))
    }

    private func continueHallie(
        pending: HallieAppTurnCoordinator.PendingClarification,
        selecting candidateID: HallieTurnExecutor.CandidateID
    ) {
        guard !isThinking else { return }
        pendingHallieClarification = nil
        let history = recentHistory()
        let requestID = UUID()
        activeRequestTask?.cancel()
        activeRequestID = requestID
        isThinking = true
        activeRequestTask = Task { @MainActor in
            defer {
                if activeRequestID == requestID {
                    activeRequestID = nil
                    activeRequestTask = nil
                    isThinking = false
                    inputFocused = true
                }
            }
            do {
                let response = try await HallieAppTurnCoordinator.continue(
                    pending: pending,
                    selecting: candidateID,
                    history: history)
                guard !Task.isCancelled,
                      activeRequestID == requestID else { return }
                commitHallie(response)
            } catch {
                guard !Task.isCancelled,
                      activeRequestID == requestID else { return }
                appLog.write(ArchivistDiagnosticLine.failure(.continuation, error: error))
                lastMatches = []
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I couldn't continue that choice just now. Please try again.",
                    basisLine: "No catalog query or media action was performed."))
            }
        }
    }

    private func commitHallie(_ response: HallieAppTurnCoordinator.Response, question: String? = nil) {
        // Rick 2026-08-22: "in-app, there's no audio." On by default; the
        // settings sheet has the switch and the voice picker.
        if HallieSpeaker.isEnabled() {
            HallieSpeaker.shared.speak(response.result.prose, about: response.result.catalogPersonName)
        }
        lastResponder = response.responderHost
        // A repair reply re-asks the pending which-one; keep it so the next
        // typed or tapped name still selects from it.
        if response.result.outcome == .repaired, response.pendingClarification == nil {
            // keep pendingHallieClarification as is
        } else {
            pendingHallieClarification = response.pendingClarification
        }
        hallieTelling = response.telling
        hallieDrill = response.drill
        hallieMemory.record(intent: response.executedIntent,
                            result: response.result,
                            question: question)
        let citations = response.citations
        let isFollowUpAction = response.result.route == .followUp
            && response.result.mediaAction != nil
        // Bare "play first" may refer only to evidence actually shown in
        // this answer, never an unseen broad result set. A follow-up media
        // action keeps the previous referent list intact.
        if !isFollowUpAction {
            lastMatches = citations.compactMap {
                model.record(forID: $0.recordID)
            }
        }
        let clarificationChips = response.result.clarification?.candidates.map {
            ArchivistMessage.Chip(
                label: $0.label,
                action: .hallieIdentityChoice($0.id))
        } ?? []
        let offerChips = response.result.offeredActions.map { offer -> ArchivistMessage.Chip in
            let label = HallieTurnExecutor.offerLabel(offer)
            switch offer {
            case .openFamilyTree(let name):
                return ArchivistMessage.Chip(
                    label: label, action: .openFamilyTree(personName: name))
            case .openFamilyTreePerson(let id, let name):
                return ArchivistMessage.Chip(
                    label: label,
                    action: .openFamilyTreePerson(
                        personID: id, personName: name))
            case .openFamilyTreeSurname(let surname):
                return ArchivistMessage.Chip(
                    label: label, action: .openFamilyTreeSurname(surname))
            case .getFamilyTree:
                return ArchivistMessage.Chip(label: label, action: .getFamilyTree)
            case .ask(let question, _):
                return ArchivistMessage.Chip(
                    label: label, action: .askText(question, playAfterAnswer: false))
            case .recompileFamilyTree:
                return ArchivistMessage.Chip(
                    label: label, action: .recompileFamilyTree(thenAsk: question))
            case .openPeopleTab:
                return ArchivistMessage.Chip(label: label, action: .openPeopleTab)
            case .showPossibleDuplicate(let id, let name):
                // Same navigation as a person focus: the record with both
                // parents is what Rick needs to see.
                return ArchivistMessage.Chip(
                    label: label,
                    action: .openFamilyTreePerson(personID: id, personName: name))
            }
        }
        messages.append(ArchivistMessage(
            role: .assistant,
            text: response.result.prose,
            queryLine: response.result.queryDescription,
            basisLine: response.result.basisLine,
            biographyPhoto: response.biographyPhoto,
            attachments: response.result.attachments,
            citations: isFollowUpAction ? [] : citations,
            knowledgeCitations: response.result.knowledgeCitations,
            responder: response.responderHost,
            model: ollamaModel,
            route: Self.transcriptLabel(response.result.route),
            outcome: Self.transcriptLabel(response.result.outcome),
            composedBy: response.result.composedBy.rawValue,
            transcriptText: response.result.transcriptText,
            chips: clarificationChips + offerChips))
        if let action = response.result.mediaAction {
            perform(action)
        } else if response.playAfterAnswer, !lastMatches.isEmpty {
            play(bestOf: lastMatches)
        }
        // "center the family tree on Martha Lamson" (2026-08-29): the user
        // asked for the navigation, so the chip's own path runs without a
        // tap. The prose already says what is happening; no second line.
        if response.result.performsFirstOfferedAction,
           case .openFamilyTreePerson(let personID, let personName)? = response.result.offeredActions.first {
            openFamilyTreeTab(focus: personName, personID: personID, surname: nil, announce: false)
            // AppStorage is only a hand-off request. FamilyTreeLiveModel logs
            // whether the target was actually applied or rejected.
            appLog.write(ArchivistDiagnosticLine.focusRequested)
        }
        // "I can do that now" (live miss #8): the recompile runs without a
        // tap and the question that hit the refused tree is asked again.
        if response.result.performsFirstOfferedAction,
           case .recompileFamilyTree? = response.result.offeredActions.first {
            recompileFamilyTree(thenAsk: question)
        }
    }

    /// A follow-up media action on ALREADY-CITED items ("play the first
    /// one", "reveal it", "show me number 3"). Same honesty gates as the
    /// citation buttons: offline volumes and vanished files are reported.
    private func perform(_ action: HallieTurnExecutor.MediaActionRequest) {
        switch action.kind {
        case .play:
            let records = action.citations.compactMap { model.record(forID: $0.recordID) }
            guard !records.isEmpty else {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "That evidence item is no longer in the catalog."))
                return
            }
            play(bestOf: records)
        case .reveal:
            for citation in action.citations.prefix(10) { revealCitation(citation) }
        case .show:
            if let first = action.citations.first { showCitationInCatalog(first) }
        }
    }

    private static func transcriptLabel(_ route: HallieTurnExecutor.Route) -> String {
        HallieTurnExecutor.label(route)
    }

    /// The last few SOCIAL (question, shown answer) pairs. Archive answers
    /// and evidence never enter free-form conversation history; this also
    /// prevents an ordinary chat sentence from leaking into factual prose.
    private func recentHistory() -> [HallieGroundedComposer.HistoryTurn] {
        var turns: [HallieGroundedComposer.HistoryTurn] = []
        var pendingUser: String?
        for message in messages {
            switch message.role {
            case .user:
                pendingUser = message.text
            case .assistant:
                if let user = pendingUser,
                   message.route == "conversation" || message.route == "smalltalk" {
                    turns.append(.init(user: user, assistant: message.text))
                }
                pendingUser = nil
            }
        }
        return Array(turns.suffix(HallieSocialConversation.maximumHistoryTurns))
    }

    private static func transcriptLabel(_ outcome: HallieTurnExecutor.Outcome) -> String {
        HallieTurnExecutor.label(outcome)
    }

    // MARK: Play (Rick 2026-08-07: "at least 'play the current video'")
    //
    // "play it / play the first one / play number 3" resolve in
    // ArchivistFollowUpResolver against conversation memory (shared with the
    // shell); "play <anything else>" translates the remainder and auto-plays
    // the first result. Smart-player routing via MediaOpener (QuickTime vs
    // VLC by container).

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
        // Remote viewer (Phase 1): the file lives on the master. Stream it
        // (or play an opted-in mount); say honestly when neither is possible.
        if ViewerModeCenter.shared.isViewer {
            playOnViewer(rec)
            return
        }
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

    /// Viewer playback: resolve, prepare an access copy when the master
    /// must transcode, then open the stream (VLC or the system handler)
    /// and step aside like the local path does.
    private func playOnViewer(_ rec: VideoRecord) {
        let filename = rec.filename
        let configuration = MediaStreamResolver.Configuration.fromDefaults(
            masterHostname: ViewerModeCenter.shared.masterDisplayName + ".local")
        Task { @MainActor in
            // Fresh reachability for this attempt (4 s cap), then resolve.
            _ = await ViewerMediaStatus.shared.refresh(configuration: configuration)
            let resolver = MediaStreamResolver.current(designation: model.masterArchive)
            switch resolver.resolve(rec) {
            case .local(let url):
                MediaOpener.open([rec])
                ArchivistWindowFloat.stepAsideForPlayback()
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "▶️ Playing “\(filename)” from the mounted volume (\(url.deletingLastPathComponent().path))."))
            case .stream(let url, let native):
                if !native {
                    let progressID = UUID()
                    messages.append(ArchivistMessage(
                        id: progressID, role: .assistant,
                        text: "\(ViewerModeCenter.shared.masterDisplayName) is preparing “\(filename)” for streaming…"))
                    let result = await MediaStreamClient().prepare(
                        streamURL: url, statusURL: resolver.statusURL(recordID: rec.id),
                        onProgress: { seconds in
                            Task { @MainActor in
                                if let i = messages.firstIndex(where: { $0.id == progressID }) {
                                    messages[i].text = "\(ViewerModeCenter.shared.masterDisplayName) is preparing “\(filename)” for streaming… \(seconds)s"
                                }
                            }
                        })
                    switch result {
                    case .ready: break
                    case .failed(let reason):
                        messages.append(ArchivistMessage(role: .assistant, text: "I couldn't stream “\(filename)”: \(reason)."))
                        return
                    case .timedOut:
                        messages.append(ArchivistMessage(role: .assistant, text: "“\(filename)” is taking too long to prepare on \(ViewerModeCenter.shared.masterDisplayName) — try again in a few minutes."))
                        return
                    }
                }
                MediaOpener.openStream(url)
                ArchivistWindowFloat.stepAsideForPlayback()
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "▶️ Streaming “\(filename)” from \(ViewerModeCenter.shared.masterDisplayName) — click me to bring this chat back on top."))
            case .masterOffline(let master):
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I can't play “\(filename)” right now — \(master) is offline and its volume isn't mounted here."))
            }
        }
    }

    // MARK: Remote viewer — the master's Hallie (Phase 1 §3)

    private var viewerConfiguration: MediaStreamResolver.Configuration {
        MediaStreamResolver.Configuration.fromDefaults(
            masterHostname: ViewerModeCenter.shared.masterDisplayName + ".local")
    }

    private var viewerWho: String? {
        HallieTurnExecutor.Speakers.fromDefaults().ownerName
    }

    /// Ping, route, ask. Master reachable → its bridge; else a local brain
    /// over the synced data (with a transcript note); else an honest line.
    private func askOnViewer(_ text: String) {
        let configuration = viewerConfiguration
        let requestID = UUID()
        activeRequestTask?.cancel()
        activeRequestID = requestID
        isThinking = true
        activeRequestTask = Task { @MainActor in
            let reachable = await ViewerMediaStatus.shared.refresh(configuration: configuration)
            guard !Task.isCancelled, activeRequestID == requestID else { return }
            let master = ViewerModeCenter.shared.masterDisplayName
            switch HallieViewerRouting.decide(masterReachable: reachable,
                                              localBrainInstalled: HallieViewerRouting.localBrainInstalled()) {
            case .master:
                defer {
                    if activeRequestID == requestID {
                        activeRequestID = nil; activeRequestTask = nil; isThinking = false; inputFocused = true
                    }
                }
                let client = HallieRemoteClient(configuration: configuration,
                                                sessionID: HallieRemoteClient.sessionID())
                do {
                    let answer = try await client.ask(text, who: viewerWho)
                    guard !Task.isCancelled, activeRequestID == requestID else { return }
                    commitRemote(answer)
                } catch {
                    guard !Task.isCancelled, activeRequestID == requestID else { return }
                    appLog.write("[viewer] Hallie ask via \(master) failed — \(error.localizedDescription)")
                    messages.append(ArchivistMessage(
                        role: .assistant,
                        text: "I couldn't reach \(master)'s Hallie: \(error.localizedDescription).",
                        basisLine: "No catalog query or media action was performed."))
                }
            case .localBrain:
                appLog.write("[viewer] \(master) unreachable; answering with the local brain over the synced catalog")
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: HallieViewerRouting.localFallbackNote(masterDisplayName: master)))
                activeRequestID = nil; activeRequestTask = nil; isThinking = false
                askLocally(text)
            case .offline:
                appLog.write("[viewer] \(master) unreachable and no local brain — question not answered")
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: HallieViewerRouting.offlineNote(masterDisplayName: master),
                    basisLine: "No catalog query or media action was performed."))
                activeRequestID = nil; activeRequestTask = nil; isThinking = false; inputFocused = true
            }
        }
    }

    /// A which-one chip on a remote answer: the master holds the pending
    /// clarification; we just send the stable identity back.
    private func selectOnViewer(_ candidateID: HallieTurnExecutor.CandidateID) {
        guard !isThinking else { return }
        let configuration = viewerConfiguration
        let requestID = UUID()
        activeRequestID = requestID
        isThinking = true
        activeRequestTask = Task { @MainActor in
            defer {
                if activeRequestID == requestID {
                    activeRequestID = nil; activeRequestTask = nil; isThinking = false; inputFocused = true
                }
            }
            let client = HallieRemoteClient(configuration: configuration, sessionID: HallieRemoteClient.sessionID())
            do {
                let answer = try await client.select(candidateID, who: viewerWho)
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                commitRemote(answer)
            } catch {
                guard !Task.isCancelled, activeRequestID == requestID else { return }
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I couldn't continue that choice with \(ViewerModeCenter.shared.masterDisplayName): \(error.localizedDescription)."))
            }
        }
    }

    /// Same bubble shape as `commitHallie`, from the bridge's answer: the
    /// master's prose/basis/citations, this Mac's voice, chips that either
    /// re-ask or select on the master, and playback through the resolver.
    private func commitRemote(_ answer: HallieRemoteAnswer) {
        if HallieSpeaker.isEnabled() {
            HallieSpeaker.shared.speak(answer.prose)
        }
        let master = ViewerModeCenter.shared.masterDisplayName
        lastResponder = answer.responder.isEmpty ? master : "\(answer.responder) via \(master)"
        let citations: [HallieTurnExecutor.Citation] = answer.citations.compactMap { c in
            guard let id = c.recordID else { return nil }
            let rec = model.record(forID: id)
            return HallieTurnExecutor.Citation(recordID: id, fullPath: rec?.fullPath ?? "",
                                               filename: c.filename.isEmpty ? (rec?.filename ?? "") : c.filename,
                                               playbackSeconds: nil, bases: [])
        }
        lastMatches = citations.compactMap { model.record(forID: $0.recordID) }
        let chips = answer.chips.map { chip -> ArchivistMessage.Chip in
            switch chip.action {
            case .ask(let question):
                return ArchivistMessage.Chip(label: chip.label, action: .askText(question, playAfterAnswer: false))
            case .select(let id):
                return ArchivistMessage.Chip(label: chip.label, action: .remoteSelect(id))
            }
        }
        messages.append(ArchivistMessage(
            role: .assistant,
            text: answer.prose,
            basisLine: answer.basis,
            citations: citations,
            knowledgeCitations: answer.knowledge.map {
                HallieTurnExecutor.KnowledgeCitation(id: $0.id, title: $0.title,
                                                     attribution: $0.attribution.isEmpty ? nil : $0.attribution,
                                                     locator: nil)
            },
            responder: lastResponder,
            model: ollamaModel,
            route: answer.route,
            outcome: answer.outcome,
            composedBy: "master",
            chips: chips))
        if let first = answer.play.first, let id = first.recordID, let rec = model.record(forID: id) {
            play(rec)
        }
    }

    // MARK: General questions (Rick 2026-08-07: "who is hallie mae
    // mcgill", "when was rick born", "the family ancestry")

    /// Tree-answerable questions, handled locally: who-is biographies,
    /// birth/death dates, and the family-ancestry view. Grounded in
    /// the GEDCOM; unknowns answered honestly.
    private func handleGeneralQuestion(_ text: String) -> Bool {
        guard let question = ArchivistQuestionParser.general(text) else {
            return false
        }
        switch question {
        case .ancestry:
            // "family ancestry" / "family tree" → open the rendered tree.
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
        case .lifeDate(let personText, let birth):
            return answerDate(personText: personText,
                              wantsBirth: birth,
                              original: text)
        case .biography(let personText):
            return answerWhoIs(personText: personText,
                original: text)
        }
    }

    /// Legacy family-fact paths: the tree on disk needs a recompile (live
    /// miss #8) → the same offer as Hallie's, performed, then the original
    /// sentence re-asked. False = not that case; say "no tree" as before.
    private func declineForRecompile(original: String) -> Bool {
        let sources = FamilyGraphSharedCache.shared.needsRecompile(
            for: FamilyAssetConfigurationCenter.shared.snapshot(), store: .app)
        guard !sources.isEmpty else { return false }
        let result = HallieLineageAnswer.needsRecompile(sources)
        messages.append(ArchivistMessage(
            role: .assistant, text: result.prose, basisLine: result.basisLine,
            chips: [ArchivistMessage.Chip(
                label: HallieTurnExecutor.offerLabel(.recompileFamilyTree),
                action: .recompileFamilyTree(thenAsk: original))]))
        recompileFamilyTree(thenAsk: original)
        return true
    }

    private func answerDate(personText: String, wantsBirth: Bool,
                            original: String) -> Bool {
        guard let graph = loadFamilyGraph() else {
            if declineForRecompile(original: original) { return true }
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't have the family tree loaded yet, so I can't answer that reliably.",
                basisLine: "Checked: no imported family tree is available."))
            return true
        }
        let resolution = FamilyTreeIdentityResolver(
            graph: graph, profiles: POIProfile.listAll()).resolve(personText)
        guard case .people(let candidates) = resolution else {
            appendProfileAmbiguity(resolution, typedName: personText,
                                   original: original)
            return true
        }
        let answer = ArchivistBiographyPolicy.lifeDate(
            for: personText, birth: wantsBirth,
            candidates: candidates, in: graph)
        appendFamilyAnswer(answer, kind: wantsBirth ? .birth : .death, graph: graph)
        return true
    }

    private func answerWhoIs(personText: String, original: String) -> Bool {
        guard let graph = loadFamilyGraph() else {
            if declineForRecompile(original: original) { return true }
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't have the family tree loaded yet, so I can't answer that reliably.",
                basisLine: "Checked: no imported family tree is available."))
            return true
        }
        let resolution = FamilyTreeIdentityResolver(
            graph: graph, profiles: POIProfile.listAll()).resolve(personText)
        guard case .people(let candidates) = resolution else {
            appendProfileAmbiguity(resolution, typedName: personText,
                                   original: original)
            return true
        }
        let answer = ArchivistBiographyPolicy.biography(
            for: personText, candidates: candidates, in: graph)
        appendFamilyAnswer(answer, kind: .biography, graph: graph)
        return true
    }

    private func appendProfileAmbiguity(
        _ resolution: FamilyTreeIdentityResolution,
        typedName: String,
        original: String,
        playAfterAnswer: Bool = false
    ) {
        guard case .profileAmbiguous(let candidates) = resolution else {
            return
        }
        messages.append(ArchivistMessage(
            role: .assistant,
            text: "Which \(typedName) do you mean?",
            basisLine: "Checked: People profiles and imported family tree (GEDCOM).",
            chips: candidates.prefix(4).map { candidate in
                ArchivistMessage.Chip(
                    label: candidate,
                    action: .askText(original.replacingOccurrences(
                        of: typedName, with: candidate,
                        options: .caseInsensitive),
                        playAfterAnswer: playAfterAnswer))
            }))
    }

    private func answerFamilyFact(personID: String,
                                  kind: ArchivistFamilyFactKind) {
        guard let graph = loadFamilyGraph() else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't have the family tree loaded yet, so I can't answer that reliably.",
                basisLine: "Checked: no imported family tree is available."))
            return
        }
        let answer: ArchivistBiographyAnswer
        switch kind {
        case .biography:
            answer = ArchivistBiographyPolicy.biography(
                personID: personID, in: graph)
        case .birth:
            answer = ArchivistBiographyPolicy.lifeDate(
                personID: personID, birth: true, in: graph)
        case .death:
            answer = ArchivistBiographyPolicy.lifeDate(
                personID: personID, birth: false, in: graph)
        }
        appendFamilyAnswer(answer, kind: kind, graph: graph)
    }

    private func appendFamilyAnswer(_ answer: ArchivistBiographyAnswer,
                                    kind: ArchivistFamilyFactKind,
                                    graph: GedcomFamilyGraph) {
        var chips = answer.candidates.prefix(4).map { candidate in
            ArchivistMessage.Chip(
                label: candidate.label,
                action: .familyFact(personID: candidate.id, kind: kind))
        }
        if case .biography = kind,
           let canonical = answer.catalogPersonName,
           let given = canonical.split(separator: " ").first,
           Self.mayOfferMedia(for: canonical, in: graph) {
            let personQuery = NLQueryComposer.infixString(
                for: NLQueryNormalizer.normalize(
                    NLQuerySpec(people: [canonical])))
            chips.append(ArchivistMessage.Chip(
                label: "Videos of \(given)",
                action: .applyQuery(personQuery)))
        }
        let photo: ArchivistBiographyPhoto?
        if case .biography = kind, let canonical = answer.catalogPersonName {
            photo = ArchivistBiographyPhoto.resolve(
                personName: canonical, profiles: POIProfile.listAll())
        } else {
            photo = nil
        }
        messages.append(ArchivistMessage(role: .assistant,
                                         text: answer.text,
                                         basisLine: answer.basis,
                                         biographyPhoto: photo,
                                         chips: chips))
    }

    // MARK: Kinship (Rick 2026-08-07: "show videos of rick's father")

    /// "<name>'s <relation> …" resolved against the family GEDCOM —
    /// announces the lineage fact, then re-asks with the real name.
    /// Ambiguous possessors counter-ask; unknown facts answer honestly.
    private func handleKinship(_ text: String) -> Bool {
        guard let question = ArchivistQuestionParser.kinship(text) else {
            return false
        }
        // Local clarification must own the pending intent. Leaving it in
        // view state lets an unrelated later question consume it; dropping
        // it from a chip loses the user's original "play …" request.
        let wantsPlayAfter = ArchivistPlayIntentPolicy.take(
            from: &playAfterAnswer)
        guard let graph = loadFamilyGraph() else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't have the family tree loaded yet, so I can't answer that reliably.",
                basisLine: "Checked: no imported family tree is available."))
            return true
        }
        let resolver = FamilyTreeIdentityResolver(
            graph: graph, profiles: POIProfile.listAll())
        var chosen = question.possessors.last!
        var resolution = resolver.resolve(chosen.personText)
        for candidate in question.possessors {
            let candidateResolution = resolver.resolve(candidate.personText)
            switch candidateResolution {
            case .people(let people) where !people.isEmpty:
                chosen = candidate
                resolution = candidateResolution
                break
            case .profileAmbiguous:
                chosen = candidate
                resolution = candidateResolution
                break
            default:
                continue
            }
            break
        }
        let possessorTyped = chosen.personText
        let relationWord = question.relationWord
        let matchedPhrase = chosen.matchedPhrase
        guard case .people(let candidates) = resolution else {
            appendProfileAmbiguity(resolution, typedName: possessorTyped,
                                   original: text,
                                   playAfterAnswer: wantsPlayAfter)
            return true
        }
        switch candidates.count {
        case 0:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't find “\(possessorTyped)” in the family tree — "
                    + "try a fuller name.",
                basisLine: ArchivistBiographyPolicy.gedcomCheck))
            return true
        case 1:
            break
        default:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Which \(possessorTyped) do you mean?",
                basisLine: ArchivistBiographyPolicy.gedcomCheck,
                chips: candidates.prefix(4).map { candidate in
                    let choice = ArchivistBiographyPolicy
                        .disambiguationCandidate(for: candidate)
                    return ArchivistMessage.Chip(
                        label: choice.label,
                        action: .kinship(
                            personID: choice.id,
                            relation: question.relation,
                            relationWord: relationWord,
                            question: text,
                            matchedPhrase: matchedPhrase,
                            playAfterAnswer: wantsPlayAfter))
                }))
            return true
        }

        answerKinship(personID: candidates[0].id, relation: question.relation,
                      relationWord: relationWord, question: text,
                      matchedPhrase: matchedPhrase,
                      playAfterAnswer: wantsPlayAfter)
        return true
    }

    private func answerKinship(personID: String,
                               relation: GedcomFamilyGraph.Relation,
                               relationWord: String,
                               question: String,
                               matchedPhrase: String,
                               playAfterAnswer wantsPlayAfter: Bool) {
        guard let graph = loadFamilyGraph(),
              let possessor = graph.people[personID] else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "That family-tree person is no longer available.",
                basisLine: ArchivistBiographyPolicy.gedcomCheck))
            return
        }
        let relatives = graph.relatives(relation, of: possessor)
        guard !relatives.isEmpty else {
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "The family tree doesn't record a \(relationWord) for "
                    + "\(possessor.name).",
                basisLine: ArchivistBiographyPolicy.gedcomBasis))
            return
        }
        let names = relatives.map(\.name)
        let factText = "\(possessor.name)'s \(relationWord): "
            + names.joined(separator: ", ")
        let continuation = ArchivistQueryPlanner.kinshipContinuation(
            for: question, matchedPhrase: matchedPhrase,
            playAfterAnswer: wantsPlayAfter)
        switch continuation {
        case .factOnly:
            messages.append(ArchivistMessage(
                role: .assistant, text: factText + ".",
                basisLine: ArchivistBiographyPolicy.gedcomBasis))
            for relative in relatives {
                appendFamilyAnswer(
                    ArchivistBiographyPolicy.biography(
                        personID: relative.id, in: graph),
                    kind: .biography, graph: graph)
            }
        case .birthDate, .deathDate:
            messages.append(ArchivistMessage(
                role: .assistant, text: factText + ".",
                basisLine: ArchivistBiographyPolicy.gedcomBasis))
            let wantsBirth = continuation == .birthDate
            for relative in relatives {
                appendFamilyAnswer(
                    ArchivistBiographyPolicy.lifeDate(
                        personID: relative.id, birth: wantsBirth, in: graph),
                    kind: wantsBirth ? .birth : .death, graph: graph)
            }
        case .catalogSearch:
            messages.append(ArchivistMessage(
                role: .assistant,
                text: factText + " — interpreting the remaining catalog constraints…",
                basisLine: ArchivistBiographyPolicy.gedcomBasis))
            continueKinshipCatalogSearch(
                question: question, resolvedNames: names,
                relationWord: relationWord,
                playAfterAnswer: wantsPlayAfter)
        }
    }

    /// Translate only the user's original sentence, then inject the GEDCOM-
    /// resolved identities after the model returns. Retrieved family evidence
    /// never crosses the translator boundary.
    private func continueKinshipCatalogSearch(
        question: String,
        resolvedNames: [String],
        relationWord: String,
        playAfterAnswer wantsPlayAfter: Bool
    ) {
        isThinking = true
        var template = OllamaQueryTranslator()
        template.model = ollamaModel
        let translator = OllamaFailoverTranslator(
            hosts: OllamaEndpoints.resolved(from: .standard),
            template: template,
            onResponder: { host in
                Task { @MainActor in lastResponder = host }
            })
        Task { @MainActor in
            defer {
                isThinking = false
                inputFocused = true
            }
            do {
                let translated = try await translator.translate(question)
                guard let spec = ArchivistQueryPlanner.kinshipCatalogSpec(
                    translated: translated,
                    resolvedNames: resolvedNames,
                    relationWord: relationWord) else {
                    messages.append(ArchivistMessage(
                        role: .assistant,
                        text: "That relationship resolves to too many name "
                            + "parts for one safe catalog search. Ask about "
                            + "one relative at a time so I don't truncate or guess.",
                        basisLine: ArchivistBiographyPolicy.gedcomBasis))
                    return
                }
                respond(to: question, spec: spec,
                        resolvedPeople: resolvedNames,
                        forcedPlayAfter: wantsPlayAfter)
            } catch {
                messages.append(ArchivistMessage(
                    role: .assistant,
                    text: "I resolved the family relationship, but I couldn't "
                        + "safely interpret the remaining catalog constraints "
                        + "(\(error.localizedDescription)). I didn't search or play "
                        + "a broader result because that could be the wrong clip.",
                    basisLine: ArchivistBiographyPolicy.gedcomBasis))
            }
        }
    }

    /// Load from the same authorized source as cards and the Family Tree tab.
    /// The WorldKnowledge floor for the legacy "Videos of X" chip — a
    /// VIDEO offer, so it is the FILM medium's fact (1888) that decides: a
    /// uniquely named tree person whose known death precedes motion
    /// pictures gets no chip. Unknown or ambiguous names, and unknown
    /// death years, keep the chip (never guess).
    static func mayOfferMedia(for canonicalName: String, in graph: GedcomFamilyGraph) -> Bool {
        let matches = graph.people.values.filter {
            $0.name.compare(canonicalName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard matches.count == 1 else { return true }
        if WorldKnowledge.photography.impossibilityNote(person: matches[0], medium: .film) != nil {
            appLog.write(ArchivistDiagnosticLine.filmOfferSuppressed)
            return false
        }
        return true
    }

    private func loadFamilyGraph() -> GedcomFamilyGraph? {
        // Re-check authority on every legacy-path use. A cached graph must not
        // survive an archive disconnect or UUID refusal — the shared cache
        // keys on the snapshot's access + directory + store pointer, so a
        // revoked authority returns nil and drops the cached tree. The
        // promoted artifact is decoded once per process (codex #792).
        FamilyGraphSharedCache.shared.graph(
            for: FamilyAssetConfigurationCenter.shared.snapshot(),
            store: .app)
    }

    /// The archivist's reply policy — resolution first, then intent.
    private func respond(to question: String, spec: NLQuerySpec,
                         resolvedPeople: [String]? = nil,
                         forcedPlayAfter: Bool? = nil) {
        // Disarm the play-after flag FIRST (codex #300: count/ambiguity/
        // empty-compose returns left it armed, and a failed 'play X'
        // would fire on a later unrelated answer). The local carries
        // this answer's intent to the filter branch.
        let wantPlayAfter = forcedPlayAfter ?? playAfterAnswer
        playAfterAnswer = false
        switch ArchivistQueryPlanner.plan(
            question: question,
            spec: spec,
            profiles: POIProfile.listAll(),
            resolvedPeople: resolvedPeople,
            playAfterAnswer: wantPlayAfter) {
        case .search(let query, let isCount, let preface, let wantsPlay):
            finishSearch(
                query: query, isCount: isCount,
                wantPlayAfter: wantsPlay, preface: preface)
        case .personAmbiguity(_, let candidates, let wantsPlay):
            let pending = ArchivistPersonClarification(
                question: question, spec: spec, candidates: candidates,
                playAfterAnswer: wantsPlay)
            pendingPersonClarification = pending
            appLog.write("Archivist clarification: presented person choices count=\(candidates.count)")
            appendPersonClarification(pending)
        case .segmentationAmbiguity(let options, let wantsPlay):
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "Do you mean one person or several people?",
                chips: options.map { option in
                    ArchivistMessage.Chip(
                        label: option.joined(separator: " + "),
                        action: .resolvedPeople(
                            question: question,
                            spec: spec,
                            canonicalNames: option,
                            playAfterAnswer: wantsPlay))
                }))
        case .tooManyPeople(let limit):
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "That names more than \(limit) people at once. "
                    + "Please ask about a smaller group so I don't guess."))
        case .unknownPerson(let asked, let names, let wantsPlay):
            messages.append(ArchivistMessage(
                role: .assistant,
                text: "I don't know anyone called “\(asked)” yet. "
                    + "The family members I know are: \(names.joined(separator: ", ")).",
                chips: names.prefix(4).map { name in
                    ArchivistMessage.Chip(
                        label: name,
                        action: .askText(
                            question.replacingOccurrences(
                                of: asked, with: name,
                                options: .caseInsensitive),
                            playAfterAnswer: wantsPlay))
                }))
        }
    }

    private func appendPersonClarification(
        _ pending: ArchivistPersonClarification,
        requiresExplicitChoice: Bool = false
    ) {
        let names = pending.candidates.joined(separator: " or ")
        let prompt = pending.candidates.count == 1
            ? "Did you mean \(names)?"
            : "Which person do you mean: \(names)?"
        messages.append(ArchivistMessage(
            role: .assistant,
            text: requiresExplicitChoice
                ? "I need the name so I don't guess. \(prompt)"
                : prompt,
            chips: ArchivistMessage.personClarificationChips(for: pending)))
    }

    private func finishSearch(query composed: String,
                              isCount: Bool,
                              wantPlayAfter: Bool,
                              preface: String? = nil) {
        let matches = model.searchIndex.filter(records: model.records,
                                               query: composed)
        lastMatches = matches   // "play the first one" referent

        // 2. COUNT questions get an ANSWER, not a filter.
        if isCount {
            apply(composed: composed, matches: matches.count)
            messages.append(ArchivistMessage(
                role: .assistant,
                text: [preface, countSentence(matches.count)]
                    .compactMap { $0 }.joined(separator: " "),
                queryLine: composed))
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
        var text = [preface, matchSentence(matches.count)]
            .compactMap { $0 }.joined(separator: " ")
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
        // Rick 2026-08-22 (screenshot): the adaptive grid squeezed every
        // chip into ~90 pt — "show m…", "how ma…". A real flow layout sizes
        // each chip to its whole label and wraps to the next line.
        ChipFlow(spacing: 8) {
            ForEach(chips) { chip in
                Button {
                    onTap(chip)
                } label: {
                    Text(chip.label)
                        .font(.system(size: 17))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .help(chip.label)
            }
        }
    }
}

/// Left-to-right, wrapping at the container's width; every subview keeps
/// its natural size (no truncation). macOS 13+ `Layout`.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : min(width, max(maxX, 0)), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
