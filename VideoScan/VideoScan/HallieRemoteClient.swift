// HallieRemoteClient.swift
// Hallie on the viewer (Phase 1, docs/remote_use_design.md §3): the porch
// Mac's chat talks to the MASTER's Hallie web bridge — the same
// `POST /api/ask` the iPad page uses — so answers, citations, memory,
// logs and pronunciations are the master's. Nothing forks: the master
// runs the coordinator exactly as for the iPad, with one session per
// viewer install.
//
// Routing (HallieViewerRouting): the master answers `/api/ping` → ask it;
// the master is unreachable AND a local brain (Ollama binary) is
// installed → the chat falls back to the in-process coordinator over the
// SYNCED catalog/tree (answers are then the viewer's own; the transcript
// says so); neither → an honest offline line.
//
// Voice stays local: the viewer's HallieSpeaker speaks the prose with
// Kokoro when installed here, else the Apple voice (HallieSpeaker already
// makes that choice and logs it).
//
// The transport is injected (same seam as MediaStreamResolver) so parity
// is tested against a stub server without a socket.

import Foundation

/// The bridge's `/api/ask` answer, parsed. Mirrors `HallieWebBridge.payload`
/// field for field so the two can be compared in a parity test.
struct HallieRemoteAnswer: Equatable, Sendable {
    struct Citation: Equatable, Sendable {
        let recordID: UUID?
        let filename: String
        let playable: Bool
        let native: Bool
    }

    struct Chip: Equatable, Sendable {
        enum Action: Equatable, Sendable {
            case ask(String)
            case select(HallieTurnExecutor.CandidateID)
        }
        let label: String
        let action: Action
    }

    struct Knowledge: Equatable, Sendable {
        let id: String
        let title: String
        let attribution: String
    }

    let prose: String
    let basis: String
    let route: String
    let outcome: String
    let responder: String
    let citations: [Citation]
    let play: [Citation]
    let chips: [Chip]
    let knowledge: [Knowledge]
    let attachmentCount: Int
    let listening: Bool

    init?(json object: [String: Any]) {
        guard let prose = object["prose"] as? String else { return nil }
        self.prose = prose
        basis = object["basis"] as? String ?? ""
        route = object["route"] as? String ?? ""
        outcome = object["outcome"] as? String ?? ""
        responder = object["responder"] as? String ?? ""
        func citation(_ c: [String: Any]) -> Citation {
            Citation(recordID: (c["id"] as? String).flatMap(UUID.init(uuidString:)),
                     filename: c["filename"] as? String ?? "",
                     playable: c["playable"] as? Bool ?? false,
                     native: c["native"] as? Bool ?? false)
        }
        citations = (object["citations"] as? [[String: Any]] ?? []).map(citation)
        play = (object["play"] as? [[String: Any]] ?? []).map(citation)
        chips = (object["chips"] as? [[String: Any]] ?? []).compactMap { chip in
            guard let label = chip["label"] as? String else { return nil }
            if let ask = chip["ask"] as? String { return Chip(label: label, action: .ask(ask)) }
            if let select = chip["select"] as? [String: Any],
               let id = HallieRemoteSelect.candidateID(from: select) {
                return Chip(label: label, action: .select(id))
            }
            return nil
        }
        knowledge = (object["knowledge"] as? [[String: Any]] ?? []).compactMap { k in
            guard let id = k["id"] as? String, let title = k["title"] as? String else { return nil }
            return Knowledge(id: id, title: title, attribution: k["attribution"] as? String ?? "")
        }
        attachmentCount = (object["attachments"] as? [Any])?.count ?? 0
        listening = object["listening"] as? Bool ?? false
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        self.init(json: object)
    }
}

/// The bridge's `select` wire shape (`HallieWebBridge.candidateID(from:)`
/// / `selectJSON`), duplicated here because the bridge is main-actor
/// bound and the client parses off it. HallieRemoteClientTests pins the
/// two against each other.
enum HallieRemoteSelect {
    static func candidateID(from select: [String: Any]) -> HallieTurnExecutor.CandidateID? {
        guard let kind = select["kind"] as? String, let id = select["id"] as? String, !id.isEmpty else {
            return nil
        }
        switch kind {
        case "profile": return .profileStableID(id)
        case "gedcom": return .gedcomPersonID(id)
        case "cyberbrain": return .cyberBrainPersonID(id)
        default: return nil
        }
    }

    static func json(_ id: HallieTurnExecutor.CandidateID) -> [String: String] {
        switch id {
        case .profileStableID(let value): return ["kind": "profile", "id": value]
        case .gedcomPersonID(let value): return ["kind": "gedcom", "id": value]
        case .cyberBrainPersonID(let value): return ["kind": "cyberbrain", "id": value]
        }
    }
}

/// The client. One value per viewer install: the session id is persisted
/// so the master's conversation memory survives relaunches, like the
/// iPad page's `hallie.session`.
struct HallieRemoteClient: Sendable {
    static let sessionKey = "viewer.hallieSession"

    enum Failure: LocalizedError, Equatable {
        case unreachable
        case refused(String)
        case badAnswer(Int)

        var errorDescription: String? {
            switch self {
            case .unreachable: return "the master did not answer"
            case .refused(let why): return why
            case .badAnswer(let status): return "the master answered HTTP \(status) without a Hallie reply"
            }
        }
    }

    let configuration: MediaStreamResolver.Configuration
    let sessionID: String
    let transport: MediaHTTPTransport

    init(configuration: MediaStreamResolver.Configuration,
         sessionID: String,
         transport: @escaping MediaHTTPTransport = MediaHTTP.urlSession) {
        self.configuration = configuration
        self.sessionID = sessionID
        self.transport = transport
    }

    /// The persisted session id, minted on first use.
    static func sessionID(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: sessionKey), !existing.isEmpty { return existing }
        let fresh = "viewer-" + UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: sessionKey)
        return fresh
    }

    var askURL: URL { configuration.baseURL.appendingPathComponent("api/ask") }

    /// Exactly the JSON the iPad page posts. `who` is the family member
    /// talking (the archivist's owner name on this Mac), so the master
    /// resolves "my dad" against the same tree pin.
    static func requestBody(text: String?, select: HallieTurnExecutor.CandidateID?,
                            session: String, who: String?) -> Data {
        var payload: [String: Any] = ["session": session]
        if let who, !who.isEmpty { payload["who"] = who }
        if let text { payload["text"] = text }
        if let select { payload["select"] = HallieRemoteSelect.json(select) }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    func ask(_ text: String, who: String?) async throws -> HallieRemoteAnswer {
        try await post(Self.requestBody(text: text, select: nil, session: sessionID, who: who))
    }

    func select(_ candidate: HallieTurnExecutor.CandidateID, who: String?) async throws -> HallieRemoteAnswer {
        try await post(Self.requestBody(text: nil, select: candidate, session: sessionID, who: who))
    }

    private func post(_ body: Data) async throws -> HallieRemoteAnswer {
        var request = URLRequest(url: askURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.passphrase.isEmpty {
            request.setValue(configuration.passphrase, forHTTPHeaderField: "X-Hallie-Key")
        }
        // A Hallie turn can take a while on the master (model composition);
        // generous, but bounded.
        request.timeoutInterval = 120
        let status: Int
        let data: Data
        do {
            (status, data) = try await transport(request)
        } catch {
            throw Failure.unreachable
        }
        switch status {
        case 200:
            guard let answer = HallieRemoteAnswer(data: data) else { throw Failure.badAnswer(status) }
            return answer
        case 401: throw Failure.refused("passphrase refused — check Hallie's web passphrase in settings")
        case 400: throw Failure.refused(String(data: data, encoding: .utf8) ?? "bad request")
        default: throw Failure.badAnswer(status)
        }
    }
}

/// Where a viewer's question goes.
enum HallieViewerRouting {
    enum Route: Equatable, Sendable {
        /// The master's bridge (answers, memory, logs are the master's).
        case master
        /// In-process coordinator over the synced data — only when the
        /// master is unreachable AND this Mac has a brain.
        case localBrain
        /// Neither: say so.
        case offline
    }

    static func decide(masterReachable: Bool, localBrainInstalled: Bool) -> Route {
        if masterReachable { return .master }
        return localBrainInstalled ? .localBrain : .offline
    }

    /// The same binary search OllamaLocalServerBootstrap performs.
    static let ollamaSearchPaths = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]

    static func localBrainInstalled(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        ollamaSearchPaths.contains(where: fileExists)
    }

    /// The transcript line for a fallback answer, so a viewer never
    /// mistakes its own brain for the master's.
    static func localFallbackNote(masterDisplayName: String) -> String {
        "\(masterDisplayName) is offline — answered by this Mac's own brain over the last synced catalog."
    }

    static func offlineNote(masterDisplayName: String) -> String {
        "\(masterDisplayName) is offline and this Mac has no brain installed — I can't answer until it's back. The catalog and tree you see are the last synced copy."
    }
}
