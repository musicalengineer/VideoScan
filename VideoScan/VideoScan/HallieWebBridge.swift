// HallieWebBridge.swift
// Turns HTTP requests from the family's devices into coordinator turns and
// back into JSON. One session per device (a random id the page keeps in
// localStorage), each with its own conversation memory, composer history,
// pending clarification, and "let me tell you about…" state — exactly the
// state the chat window keeps, just keyed by device.
//
// Who is talking is per device too ("Donna" on the iPad): it becomes
// `Speakers.ownerName` for that turn, so "my dad" means Donna's dad and
// anything she tells Hallie is recorded "told by Donna".

import Foundation
import VideoScanCore

@MainActor
final class HallieWebBridge {

    struct Session {
        var memory = HallieTurnExecutor.ConversationMemory()
        var history: [HallieGroundedComposer.HistoryTurn] = []
        var telling: HallieTellingMode.Session?
        var pendingClarification: HallieAppTurnCoordinator.PendingClarification?
        var lastCitations: [HallieTurnExecutor.Citation] = []
        var lastSeen = Date()
    }

    struct Configuration {
        var passphrase: String
        var archivistName: String
        var archivistPersonName: String?
        var hosts: [String]
        var modelName: String
        var composeWithModel: Bool
    }

    /// Safari can play these straight from the Mac. Everything else is
    /// offered honestly as "plays on the Mac only" — no transcoding.
    static let browserPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aif", "aiff",
    ]

    private var sessions: [String: Session] = [:]
    private let records: @MainActor () -> [VideoRecord]
    private let record: @MainActor (UUID) -> VideoRecord?
    private let configuration: @MainActor () -> Configuration
    private let dependencies: HallieAppTurnCoordinator.Dependencies
    static let sessionIdleLimit: TimeInterval = 6 * 60 * 60

    init(
        records: @escaping @MainActor () -> [VideoRecord],
        record: @escaping @MainActor (UUID) -> VideoRecord?,
        configuration: @escaping @MainActor () -> Configuration,
        dependencies: HallieAppTurnCoordinator.Dependencies = .live
    ) {
        self.records = records
        self.record = record
        self.configuration = configuration
        self.dependencies = dependencies
    }

    // MARK: - Routing

    func handle(_ request: HallieHTTPRequest, peer: String) async -> HallieHTTPResponse {
        let config = configuration()
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(HallieWebPage.html(archivistName: config.archivistName))
        case ("POST", "/api/ask"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return await ask(request, config: config)
        case ("GET", let path) where path.hasPrefix("/api/media/"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return media(request, recordID: String(path.dropFirst("/api/media/".count)))
        case ("GET", "/api/ping"):
            return .json(["ok": true, "name": config.archivistName])
        default:
            return .text(404, "not here")
        }
    }

    private func authorized(_ request: HallieHTTPRequest, _ config: Configuration) -> Bool {
        let required = config.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !required.isEmpty else { return true }
        let offered = request.headers["x-hallie-key"] ?? request.query["key"] ?? ""
        return offered == required
    }

    // MARK: - Ask

    private func ask(_ request: HallieHTTPRequest, config: Configuration) async -> HallieHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let sessionID = object["session"] as? String, !sessionID.isEmpty,
              sessionID.count <= 80 else {
            return .text(400, "session required")
        }
        let who = ((object["who"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        pruneIdleSessions()
        var session = sessions[sessionID] ?? Session()
        session.lastSeen = Date()

        let turnDependencies = dependencies.replacingSpeakers(
            HallieTurnExecutor.Speakers(
                ownerName: who.isEmpty ? nil : who,
                archivistName: config.archivistName,
                archivistPersonName: config.archivistPersonName))

        do {
            let response: HallieAppTurnCoordinator.Response
            if let select = object["select"] as? [String: Any],
               let pending = session.pendingClarification,
               let candidateID = Self.candidateID(from: select) {
                session.pendingClarification = nil
                response = try await HallieAppTurnCoordinator.continue(
                    pending: pending, selecting: candidateID,
                    history: session.history, dependencies: turnDependencies)
            } else {
                guard let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text.count <= 2_000 else {
                    return .text(400, "text required")
                }
                if ArchivistConversationCommand.detect(text) == .reset {
                    session = Session()
                    session.lastSeen = Date()
                }
                // "play donna at christmas" is recognised inside the
                // coordinator (pre-translation), same as the chat window.
                response = try await HallieAppTurnCoordinator.execute(
                    question: text,
                    records: records(),
                    referent: .init(recordID: nil, temporalDate: nil),
                    hosts: config.hosts,
                    modelName: config.modelName,
                    playAfterAnswer: false,
                    memory: session.memory,
                    composeWithModel: config.composeWithModel,
                    history: session.history,
                    telling: session.telling,
                    dependencies: turnDependencies)
                session.history.append(.init(user: text, assistant: response.result.prose))
                if session.history.count > HallieGroundedComposer.historyTurns {
                    session.history.removeFirst(session.history.count - HallieGroundedComposer.historyTurns)
                }
            }
            session.pendingClarification = response.pendingClarification
            session.telling = response.telling
            session.memory.record(intent: response.executedIntent, result: response.result)
            let isFollowUpAction = response.result.route == .followUp
                && response.result.mediaAction != nil
            if !isFollowUpAction { session.lastCitations = response.citations }
            sessions[sessionID] = session
            return .json(payload(for: response, citations: isFollowUpAction ? [] : response.citations))
        } catch {
            sessions[sessionID] = session
            return .json([
                "prose": "I couldn't safely interpret that question: \(error.localizedDescription)",
                "basis": "No catalog query or media action was performed.",
                "route": "error", "outcome": "interpretation-failed",
                "citations": [], "chips": [], "play": [],
            ])
        }
    }

    private func pruneIdleSessions() {
        let cutoff = Date().addingTimeInterval(-Self.sessionIdleLimit)
        sessions = sessions.filter { $0.value.lastSeen > cutoff }
    }

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

    static func selectJSON(_ id: HallieTurnExecutor.CandidateID) -> [String: String] {
        switch id {
        case .profileStableID(let value): return ["kind": "profile", "id": value]
        case .gedcomPersonID(let value): return ["kind": "gedcom", "id": value]
        case .cyberBrainPersonID(let value): return ["kind": "cyberbrain", "id": value]
        }
    }

    func payload(for response: HallieAppTurnCoordinator.Response,
                 citations: [HallieTurnExecutor.Citation]) -> [String: Any] {
        let result = response.result
        var chips: [[String: Any]] = []
        if let clarification = result.clarification {
            for candidate in clarification.candidates {
                chips.append(["label": candidate.label, "select": Self.selectJSON(candidate.id)])
            }
        }
        for offer in result.offeredActions {
            switch offer {
            case .ask(let question, let label):
                chips.append(["label": label, "ask": question])
            case .openFamilyTree(let name):
                chips.append(["label": "Tell me about \(name)", "ask": "tell me about \(name)"])
            case .openFamilyTreeSurname(let surname):
                chips.append(["label": "The \(surname) family", "ask": "who are the \(surname)s"])
            }
        }
        let cited = citations.map(citationJSON)
        var play: [[String: Any]] = []
        if let action = result.mediaAction, action.kind == .play {
            play = action.citations.map(citationJSON).filter { ($0["playable"] as? Bool) == true }
        } else if response.playAfterAnswer {
            play = cited.filter { ($0["playable"] as? Bool) == true }.prefix(1).map { $0 }
        }
        return [
            "prose": result.prose,
            "basis": result.basisLine,
            "route": HallieTurnExecutor.label(result.route),
            "outcome": HallieTurnExecutor.label(result.outcome),
            "responder": response.responderHost,
            "citations": cited,
            "chips": chips,
            "play": play,
            "knowledge": result.knowledgeCitations.map {
                ["id": $0.id, "title": $0.title, "attribution": $0.attribution ?? ""]
            },
            "listening": response.telling != nil,
        ]
    }

    private func citationJSON(_ citation: HallieTurnExecutor.Citation) -> [String: Any] {
        let ext = (citation.filename as NSString).pathExtension.lowercased()
        let playable = Self.browserPlayableExtensions.contains(ext)
            && (record(citation.recordID)?.isPlayable ?? "") != "No"
        return [
            "id": citation.recordID.uuidString,
            "filename": citation.filename,
            "playable": playable,
            "url": "/api/media/\(citation.recordID.uuidString)",
        ]
    }

    // MARK: - Media

    private func media(_ request: HallieHTTPRequest, recordID: String) -> HallieHTTPResponse {
        guard let id = UUID(uuidString: recordID), let record = record(id) else {
            return .text(404, "no such item")
        }
        let url = URL(fileURLWithPath: record.fullPath)
        let ext = url.pathExtension.lowercased()
        guard Self.browserPlayableExtensions.contains(ext) else {
            return .text(415, "this one plays on the Mac only")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else {
            return .text(404, "that file isn't reachable right now (volume offline?)")
        }
        let type = Self.contentType(for: ext)
        if let range = HallieWebRange.parse(request.headers["range"], length: size) {
            return HallieHTTPResponse(
                status: 206, reason: "Partial Content",
                headers: [("Content-Type", type), ("Accept-Ranges", "bytes"),
                          ("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)")],
                body: .file(url, range: range, totalLength: size))
        }
        if request.headers["range"] != nil {
            return HallieHTTPResponse(
                status: 416, reason: "Range Not Satisfiable",
                headers: [("Content-Range", "bytes */\(size)")], body: .data(Data()))
        }
        return HallieHTTPResponse(
            status: 200, reason: "OK",
            headers: [("Content-Type", type), ("Accept-Ranges", "bytes")],
            body: .file(url, range: 0..<size, totalLength: size))
    }

    static func contentType(for ext: String) -> String {
        switch ext {
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }
}

extension HallieAppTurnCoordinator.Dependencies {
    /// The same dependencies with a different "I" — the device's person.
    func replacingSpeakers(_ speakers: HallieTurnExecutor.Speakers) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: startLocalBrain,
            translateAST: translateAST,
            loadProfiles: loadProfiles,
            loadGraph: loadGraph,
            loadCyberBrain: loadCyberBrain,
            recordTestimony: recordTestimony,
            loadSpeakers: { speakers },
            executeRequest: executeRequest,
            continueTurn: continueTurn,
            resolveBiographyPhoto: resolveBiographyPhoto,
            composeAnswer: composeAnswer)
    }
}
