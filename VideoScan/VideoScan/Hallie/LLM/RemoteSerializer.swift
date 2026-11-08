// RemoteSerializer.swift
// THE one serializer for anything Hallie sends off this Mac (DECISIONS
// 2026-10-10 R6: "the data-class policy is enforced in the adapter, not the
// prompt; RemoteSerializer is the one serializer; a poisoned-transport canary
// sensor"). Rule 13: nothing of living immediate family — pixels, audio,
// frames, face embeddings — goes to a cloud model.
//
// HOW THE GATE HOLDS. A remote request is built from typed parts. Media parts
// (image, audio, frame, embedding, file bytes) are familyMedia BY TYPE, and a
// text part carries the class its caller declared. `anthropicMessagesBody`
// walks every part first and THROWS on any familyMedia before a single byte
// is encoded; the transport only ever receives what this function returns.
// A text part that smells of smuggled media (a data: URI, a long base64 run)
// is refused too — a belt under the typed braces.
//
// Memory: one request body, bounded by the prompt (a schema, a plan, a
// question — tens of KB); nothing is streamed or cached here.

import Foundation

/// One piece of what a remote request would carry.
enum RemotePart: Sendable {
    case text(String, HallieDataClass)
    /// Pixels: a photo, a thumbnail, a poster.
    case image(Data)
    case audio(Data)
    case videoFrame(Data)
    /// Face or frame embeddings.
    case embedding([Float])
    /// Raw bytes of a media file.
    case fileBytes(Data)

    var dataClass: HallieDataClass {
        switch self {
        case .text(_, let declared): return declared
        case .image, .audio, .videoFrame, .embedding, .fileBytes: return .familyMedia
        }
    }

    var kindName: String {
        switch self {
        case .text: return "text"
        case .image: return "image"
        case .audio: return "audio"
        case .videoFrame: return "video frame"
        case .embedding: return "embedding"
        case .fileBytes: return "file bytes"
        }
    }
}

struct RemoteRequest: Sendable {
    var model: String
    var system: [RemotePart]
    var user: [RemotePart]
    /// Structured outputs: the cloud brain's equivalent of Ollama's
    /// `format:` (2026-11-08; a forced tool call is a 400 on the 5.5
    /// models). The FULL Hallie schema, as JSON bytes so the request stays
    /// Sendable; the body builder sends Anthropic a sanitized copy.
    var outputSchema: Data?
    var maxTokens: Int
}

enum RemoteSerializer {

    /// Text longer than this made only of base64 characters is treated as
    /// encoded media. Real prompts (schemas, plans, questions) never contain
    /// a 2 KB unbroken run of [A-Za-z0-9+/=].
    static let base64RunLimit = 2048

    /// Refuse anything familyMedia, by type or by smell. Called by the body
    /// builder before encoding; exposed so tests can pin it directly.
    static func gate(_ request: RemoteRequest) throws {
        for part in request.system + request.user {
            if part.dataClass == .familyMedia {
                throw HallieBrainError.familyMediaRefused(part.kindName)
            }
            if case .text(let text, _) = part, let why = smugglingReason(text) {
                throw HallieBrainError.familyMediaRefused(why)
            }
        }
    }

    static func smugglingReason(_ text: String) -> String? {
        let lowered = text.lowercased()
        for scheme in ["data:image/", "data:audio/", "data:video/", "data:application/octet-stream"]
        where lowered.contains(scheme) {
            return "text carries a \(scheme) URI"
        }
        var run = 0
        for scalar in text.unicodeScalars {
            let isBase64 = (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z")
                || (scalar >= "0" && scalar <= "9") || scalar == "+" || scalar == "/" || scalar == "="
            run = isBase64 ? run + 1 : 0
            if run >= base64RunLimit { return "text carries a base64 run of \(base64RunLimit)+ characters" }
        }
        return nil
    }

    /// The Anthropic Messages API body. Gate first, then encode.
    static func anthropicMessagesBody(_ request: RemoteRequest) throws -> Data {
        try gate(request)
        let systemText = request.system.compactMap(textOf).joined(separator: "\n\n")
        let userBlocks: [[String: Any]] = request.user.compactMap(textOf).map {
            ["type": "text", "text": $0]
        }
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            // Prompt caching: the translator's system prompt is ~3k tokens
            // and identical every turn; the breakpoint covers the system.
            "system": [["type": "text", "text": systemText,
                        "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": userBlocks]],
        ]
        // Never `tools`/`tool_choice`, `temperature`/`top_p`/`top_k`, an
        // assistant prefill or a `thinking` override: each is a 400 on the
        // 5.5 models. Thinking stays at the model default.
        if let schemaData = request.outputSchema {
            guard let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
                throw CocoaError(.coderInvalidValue)
            }
            body["output_config"] = ["format": ["type": "json_schema",
                                                "schema": AnthropicSchemaSanitizer.sanitize(schema)]]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func textOf(_ part: RemotePart) -> String? {
        if case .text(let text, _) = part { return text }
        return nil
    }
}
