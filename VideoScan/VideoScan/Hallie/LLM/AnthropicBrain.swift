// AnthropicBrain.swift
// Hallie's opt-in cloud brain: the Anthropic Messages API (2026-11-07).
//
// SAME CONTRACT AS THE LOCAL BRAIN. It is asked the same questions with the
// same system prompts and the same JSON schemas (OllamaQueryTranslator's
// statics), and its reply goes through the same strict decoders
// (HallieBrainDecoding), the same executors and the same verifier. Ollama
// constrains output with `format:`; here the equivalent is structured
// outputs (`output_config.format` json_schema) carrying a sanitized copy of
// the very same schema, and the reply is a text block whose text is the JSON
// object the decoder expects. (2026-11-08: this replaced a forced tool call;
// `tool_choice` "tool"/"any" is a 400 on claude-sonnet-5-5 and opus-5-5.)
//
// A reply that stopped for `refusal` or `max_tokens` is never decoded — a
// partial JSON object is not an answer — it becomes a HallieBrainError.
//
// WHAT LEAVES THE MAC. Every body is built by RemoteSerializer, which refuses
// familyMedia before encoding. The question is the user's own words
// (familyText); a composed answer carries the approved plan, classed by its
// evidence (HallieAnswerPlan.dataClass). The key is read from the Keychain by
// the resolver and travels only in the `x-api-key` header.
//
// NEVER AN AUTOMATIC FAILOVER TARGET. The resolver builds this brain only
// when Rick chose Cloud in Settings; the local walk never falls through here.

import Foundation

struct AnthropicBrain: HallieBrainBackend {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    var model: String
    var key: AnthropicAPIKey
    /// Injected so tests route through a URLProtocol stub; never real network
    /// in a test.
    var session: URLSession = .shared
    var timeoutSeconds: Double = 30
    /// Called with `cloud:<model>` when a reply arrives.
    var onResponder: (@Sendable (String) -> Void)?
    /// One same-model retry with the decoder's complaint in the prompt, as
    /// the local walk does (2026-08-25).
    var repairOnBadResponse = true
    /// One retry after a 429 / 5xx / 529 / transport blip.
    var transientRetries = 1
    var transientRetryDelay: Duration = .seconds(1)

    var provider: HallieBrainProvider { .cloud }
    var modelName: String { model }
    var displayName: String { "Cloud · \(model)" }

    // MARK: Verbs

    func translate(_ text: String) async throws -> NLQuerySpec {
        try await structured(text, schema: OllamaQueryTranslator.responseSchema,
                             system: OllamaQueryTranslator.systemPrompt,
                             decode: HallieBrainDecoding.spec)
    }

    func translateAST(_ text: String) async throws -> ArchivistQueryAST {
        try await structured(text, schema: OllamaQueryTranslator.astResponseSchema,
                             system: OllamaQueryTranslator.astSystemPrompt) {
            try HallieBrainDecoding.ast(content: $0, data: $1, question: text)
        }
    }

    func interpretTurn(_ text: String) async throws -> HallieTurnInterpretation {
        try await structured(text, schema: OllamaQueryTranslator.interpretationResponseSchema,
                             system: OllamaQueryTranslator.interpretationSystemPrompt) {
            try HallieBrainDecoding.interpretation(content: $0, data: $1, question: text)
        }
    }

    func composePlainText(system: String, user: String,
                          dataClass: HallieDataClass) async throws -> String {
        let request = RemoteRequest(
            model: model,
            system: [.text(system, .public)],
            user: [.text(user, dataClass)],
            outputSchema: nil,
            maxTokens: 320)
        let root = try await send(request)
        // A refusal's text is not a composed answer; the composer falls back
        // to its template. (Truncated prose at 320 tokens is still prose.)
        if (root["stop_reason"] as? String) == "refusal" { throw HallieBrainError.cloudRefused }
        let text = Self.textBlocks(root)
        guard !text.isEmpty else { throw NLTranslatorError.badResponse("empty message content") }
        return text
    }

    /// Nothing to load: the model is always resident on Anthropic's side.
    func warmUp() async {}

    // MARK: Structured output (output_config json_schema)

    /// Room for the JSON object plus whatever thinking the model does by
    /// default (measured 0 thinking tokens on sonnet-5-5, 2026-11-08). Only
    /// tokens used are billed.
    static let structuredMaxTokens = 2048

    static func structuredRequest(model: String, text: String, schema: [String: Any],
                                  system: String) throws -> RemoteRequest {
        RemoteRequest(
            model: model,
            system: [.text(system, .public)],
            user: [.text(text, .familyText)],
            outputSchema: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
            maxTokens: structuredMaxTokens)
    }

    private func structured<T>(
        _ text: String, schema: [String: Any], system: String,
        decode: (String, Data) throws -> T
    ) async throws -> T {
        var hint: String?
        while true {
            let prompt = system + (hint.map(OllamaQueryTranslator.repairSuffix(for:)) ?? "")
            let request = try Self.structuredRequest(
                model: model, text: text, schema: schema, system: prompt)
            do {
                let root = try await send(request)
                let (content, data) = try Self.structuredAnswer(root)
                return try decode(content, data)
            } catch let error as NLTranslatorError {
                // HallieBrainError (refusal, truncation, gate) is not caught
                // here: no repair retry is spent on it.
                guard repairOnBadResponse, hint == nil, error.isRepairable,
                      case .badResponse(let rejection) = error,
                      !Task.isCancelled else { throw error }
                hint = rejection
            }
        }
    }

    /// The structured reply's JSON, as text and bytes for the shared
    /// decoders. `refusal` / `max_tokens` throw BEFORE any text is read, so a
    /// partial object never reaches a decoder.
    static func structuredAnswer(_ root: [String: Any]) throws -> (String, Data) {
        switch root["stop_reason"] as? String {
        case "refusal": throw HallieBrainError.cloudRefused
        case "max_tokens": throw HallieBrainError.cloudTruncated
        default: break
        }
        let text = textBlocks(root)
        guard !text.isEmpty else {
            throw NLTranslatorError.badResponse("no JSON text block in the reply")
        }
        return (text, Data(text.utf8))
    }

    static func textBlocks(_ root: [String: Any]) -> String {
        (root["content"] as? [[String: Any]] ?? [])
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Transport

    /// Serialize (the gate runs here, BEFORE any network), send, classify.
    /// Internal, not private: the canary sensor drives a hostile request
    /// straight through it.
    func send(_ request: RemoteRequest) async throws -> [String: Any] {
        let body = try RemoteSerializer.anthropicMessagesBody(request)
        var tries = 0
        while true {
            tries += 1
            do {
                let root = try await post(body)
                onResponder?(HallieBrainLabel.cloudResponder(model: model))
                return root
            } catch let error as NLTranslatorError {
                guard tries <= transientRetries, Self.isTransient(error),
                      !Task.isCancelled else { throw error }
                try await Task.sleep(for: transientRetryDelay)
            }
        }
    }

    static func isTransient(_ error: NLTranslatorError) -> Bool {
        switch error {
        case .unreachable: return true
        case .serverError(let status, _): return status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    private func post(_ body: Data) async throws -> [String: Any] {
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeoutSeconds)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(key.value, forHTTPHeaderField: "x-api-key")
        urlRequest.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NLTranslatorError.unreachable("api.anthropic.com: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.classify(status: status, body: data, model: model) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NLTranslatorError.badResponse(
                "unparseable response envelope: \(String(bytes: data.prefix(160), encoding: .utf8) ?? "<binary>")")
        }
        return root
    }

    /// Anthropic error bodies are {"type":"error","error":{"type","message"}}.
    /// The request's headers are never echoed, so no key can appear here.
    static func classify(status: Int, body: Data, model: String) -> NLTranslatorError {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let type = error?["type"] as? String ?? "error"
        let message = String((error?["message"] as? String ?? "").prefix(160))
        switch status {
        case 401, 403:
            return .serverError(status: status,
                                detail: "Anthropic refused the key (\(type)); check the Keychain item")
        case 404:
            return .modelUnavailable("\(model) (\(type): \(message))")
        default:
            return .serverError(status: status, detail: "\(type): \(message)")
        }
    }
}
