// HallieBrainBackend.swift
// The one seam Hallie asks a language model through (Rick, 2026-11-07:
// "make it flexible so we can use local or cloud models, but the default
// would be qwen3.8:27b for now").
//
// SHAPE. Two brains implement one protocol:
//   * Local  — OllamaFailoverTranslator (the host walk, probe, repair retry),
//              the default;
//   * Cloud  — AnthropicBrain (Messages API), opt-in in Settings.
// Every asking path (chat window, ask field, web bridge, shell) gets its brain
// from HallieBrainResolver and calls the same five verbs; the decoders, the
// executors and the composer's verifier are shared, so there is one engine and
// one contract: the model TRANSLATES, executors answer from the catalog, the
// verifier rejects any fact not in the plan (DECISIONS 2026-08-14).
//
// C++ analogy: `any HallieBrainBackend` is a pointer to an abstract base class
// with pure-virtual translate/compose; the resolver is the factory.

import Foundation

/// What a request carries, for the remote gate (DECISIONS 2026-10-10: the
/// data-class policy is enforced in the ADAPTER, not the prompt).
///   public      — nothing about the family (a greeting, a schema);
///   familyText  — names, dates, places, filenames, counts, the user's own
///                 typed words: may go to the cloud brain;
///   familyMedia — pixels, audio, frames, embeddings, thumbnails, file bytes,
///                 and text DERIVED from them (transcripts, captions, OCR):
///                 never leaves the house.
enum HallieDataClass: String, Sendable, Equatable, Comparable {
    case `public`, familyText, familyMedia

    private var rank: Int {
        switch self {
        case .public: return 0
        case .familyText: return 1
        case .familyMedia: return 2
        }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// The class of an answer's evidence. Transcript and caption text is
    /// derived from living family's audio and pixels, so it is familyMedia
    /// until Rick rules otherwise (docs/design/people_events.md §8 q6).
    static func of(citations: [HallieTurnExecutor.Citation]) -> HallieDataClass {
        citations.contains { $0.bases.contains(where: \.isMediaDerivedText) }
            ? .familyMedia : .familyText
    }

    /// The class of an answered turn, FAIL-CLOSED by route (codex #254 P1).
    /// Citations alone are not enough: a route may put the media's own text
    /// into its prose without citing it as a basis — the file dossier quotes
    /// "The transcript opens: …" with no transcript basis. So only routes
    /// whose prose is built from cited bases (or from the tree) are judged by
    /// their citations; a route that reads the media's own words by design
    /// (record, event) is always familyMedia, and so is any route not vetted
    /// here. The switch is exhaustive: a new route will not compile until
    /// someone decides its class.
    static func of(result: HallieTurnExecutor.Result) -> HallieDataClass {
        switch result.route {
        case .presence, .cross, .graph, .temporal, .aggregate:
            return of(citations: result.citations)
        case .record, .event:
            return .familyMedia
        case .capability, .help, .smalltalk, .conversation, .telling, .reset, .followUp:
            return .familyMedia
        }
    }
}

extension ArchivistEvidenceBasis {
    /// True when the basis quotes or depends on text read out of the media
    /// itself (speech, captions, on-screen text) rather than catalog fields.
    var isMediaDerivedText: Bool {
        switch self {
        case .transcriptMention, .caption:
            return true
        case .catalogField(let field, _, _), .keywordTokens(let field, _, _, _, _, _):
            let lowered = field.lowercased()
            return ["transcript", "caption", "ocr", "on-screen", "onscreen", "subtitle"]
                .contains { lowered.contains($0) }
        case .humanPersonTag, .inferredDate, .fileDate, .pathYear, .mediaKind, .userPlace:
            return false
        }
    }
}

/// Which kind of brain, for the status line, the log and the gate.
enum HallieBrainProvider: String, Sendable, Equatable, CaseIterable {
    case local, cloud

    var title: String {
        switch self {
        case .local: return "Local (Ollama)"
        case .cloud: return "Cloud (Anthropic)"
        }
    }
}

/// "qwen3.8:27b-mlx · RicksUltra" or "Cloud · claude-sonnet-5-5". The
/// responder string the coordinator already carries ("which host answered")
/// is reused for the cloud brain as `cloud:<model>`, so the existing
/// plumbing (Response.responderHost, the transcript log) needs no new field.
enum HallieBrainLabel {
    static let cloudPrefix = "cloud:"

    static func cloudResponder(model: String) -> String { cloudPrefix + model }

    static func isCloud(responder: String?) -> Bool {
        responder?.hasPrefix(cloudPrefix) ?? false
    }

    /// The model that answered: the cloud model for a cloud responder,
    /// otherwise the configured local model.
    static func modelName(responder: String?, localModel: String) -> String {
        guard let responder, isCloud(responder: responder) else { return localModel }
        return String(responder.dropFirst(cloudPrefix.count))
    }

    static func display(responder: String, localModel: String) -> String {
        if isCloud(responder: responder) {
            return "Cloud · " + modelName(responder: responder, localModel: localModel)
        }
        if responder == HallieAppTurnCoordinator.localResponder { return responder }
        var host = OllamaEndpoints.displayLabel(for: responder)
        if host.lowercased().hasSuffix(".local") { host = String(host.dropLast(6)) }
        return "\(localModel) · \(host)"
    }
}

/// Failures that belong to the brain CHOICE rather than to a transport.
/// Thrown before any network attempt.
enum HallieBrainError: LocalizedError, Equatable {
    /// Cloud is selected and no Anthropic key is in the Keychain.
    case noCloudKey
    /// The remote gate refused a request carrying family media.
    case familyMediaRefused(String)
    /// The cloud model declined to answer (`stop_reason: refusal`).
    case cloudRefused
    /// The cloud reply hit `max_tokens`; its JSON is incomplete and is never
    /// decoded.
    case cloudTruncated

    var errorDescription: String? {
        switch self {
        case .noCloudKey:
            return "Cloud brain selected but no Anthropic API key was found in the Keychain "
                + "(service \(AnthropicKeyLocator.primaryService))"
        case .familyMediaRefused(let what):
            return "refused to send family media to the cloud brain (\(what))"
        case .cloudRefused:
            return "the cloud brain declined to answer that question"
        case .cloudTruncated:
            return "the cloud brain's answer was cut off before it was complete"
        }
    }
}

/// The five verbs every brain answers. Throwing is fine — callers fall back
/// exactly as they always have for the local translator.
protocol HallieBrainBackend: NLQueryTranslating {
    var provider: HallieBrainProvider { get }
    /// The model tag this brain asks ("qwen3.8:27b-mlx", "claude-sonnet-5-5").
    var modelName: String { get }
    func translateAST(_ text: String) async throws -> ArchivistQueryAST
    func interpretTurn(_ text: String) async throws -> HallieTurnInterpretation
    /// `dataClass` is what the prompt carries; a remote brain refuses
    /// `.familyMedia` before anything is sent.
    func composePlainText(system: String, user: String,
                          dataClass: HallieDataClass) async throws -> String
    /// Pre-load. Never throws; the outcome is a log line.
    func warmUp() async
}

extension OllamaFailoverTranslator: HallieBrainBackend {
    var provider: HallieBrainProvider { .local }
    var modelName: String { template.model }

    /// The local brain runs on Rick's own machines, so every class may go
    /// to it. (A host row written as an https:// URL is a remote Ollama —
    /// pre-existing behaviour, tracked separately.)
    func composePlainText(system: String, user: String,
                          dataClass: HallieDataClass) async throws -> String {
        try await composePlainText(system: system, user: user)
    }
}

/// START/OUTCOME for every brain call, through the one log sink, naming the
/// brain — never the question, the prompt or the reply.
struct HallieLoggedBrain: HallieBrainBackend {
    let inner: any HallieBrainBackend
    /// Injected so tests can read the lines; production writes appLog.
    var write: @Sendable (String) -> Void = { appLog.write($0) }

    var displayName: String { inner.displayName }
    var provider: HallieBrainProvider { inner.provider }
    var modelName: String { inner.modelName }

    var brainLabel: String {
        provider == .cloud ? "Cloud · \(modelName)" : "\(modelName) (local)"
    }

    private func logged<T>(_ op: String, _ body: () async throws -> T) async throws -> T {
        let clock = ContinuousClock()
        let started = clock.now
        write("[hallie] brain START op=\(op) brain=\(brainLabel)")
        do {
            let value = try await body()
            let ms = Int((clock.now - started) / .milliseconds(1))
            write("[hallie] brain OUTCOME op=\(op) brain=\(brainLabel) ok ms=\(ms)")
            return value
        } catch {
            let ms = Int((clock.now - started) / .milliseconds(1))
            let reason = String(error.localizedDescription.prefix(160))
            write("[hallie] brain OUTCOME op=\(op) brain=\(brainLabel) failed ms=\(ms) reason=\(reason)")
            throw error
        }
    }

    func translate(_ text: String) async throws -> NLQuerySpec {
        try await logged("translate") { try await inner.translate(text) }
    }
    func translateAST(_ text: String) async throws -> ArchivistQueryAST {
        try await logged("translateAST") { try await inner.translateAST(text) }
    }
    func interpretTurn(_ text: String) async throws -> HallieTurnInterpretation {
        try await logged("interpretTurn") { try await inner.interpretTurn(text) }
    }
    func composePlainText(system: String, user: String,
                          dataClass: HallieDataClass) async throws -> String {
        try await logged("compose class=\(dataClass.rawValue)") {
            try await inner.composePlainText(system: system, user: user, dataClass: dataClass)
        }
    }
    func warmUp() async { await inner.warmUp() }
}

/// What prior turns a brain may see. Hallie's earlier answers can quote a
/// transcript snippet or a caption (familyMedia), and a HistoryTurn does not
/// record where its words came from — so a remote brain gets NO history; it
/// phrases from the current plan or question alone. Local brains keep the
/// full history, as before. (Tagging history with a data class would let
/// Cloud see the safe turns; tracked as a follow-up, not guessed at here.)
enum HallieBrainHistoryPolicy {
    static func history(
        _ history: [HallieGroundedComposer.HistoryTurn],
        for brain: Result<any HallieBrainBackend, any Error>
    ) -> [HallieGroundedComposer.HistoryTurn] {
        guard case .success(let backend) = brain else { return history }
        return Self.history(history, for: backend.provider)
    }

    static func history(
        _ history: [HallieGroundedComposer.HistoryTurn],
        for provider: HallieBrainProvider
    ) -> [HallieGroundedComposer.HistoryTurn] {
        provider == .cloud ? [] : history
    }
}
