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
    /// Opaque token → image file the app attached to an answer this launch.
    struct AttachmentCapability: Sendable {
        let url: URL
        /// Non-nil when the file came from the authorized family source.
        /// The source must still be current and available when bytes are read.
        let familyRoot: URL?
    }
    var attachmentTokens: [String: AttachmentCapability] = [:]

    struct Session {
        var memory = HallieTurnExecutor.ConversationMemory()
        var history: [HallieGroundedComposer.HistoryTurn] = []
        var telling: HallieTellingMode.Session?
        var drill: HalliePronunciationDrillMode.Session?
        var picker: HalliePronunciationPicker.Offer?
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

    /// Safari plays these straight from the Mac; anything else that is
    /// video goes through the proxy cache (HallieWebProxy) when one is
    /// attached, and is "plays on the Mac only" otherwise.
    static let browserPlayableExtensions: Set<String> = [
        "mp4", "m4v", "mp3", "m4a", "aac", "wav", "aif", "aiff",
    ]
    /// .mov is native ONLY when its codec is H.264/HEVC; ProRes/DV-in-MOV
    /// must go through the proxy like any other tape.
    static let nativeMovCodecs: Set<String> = ["h264", "avc1", "hevc", "hvc1", "h265", "avc"]
    static let proxyableExtensions: Set<String> = [
        "mov", "mxf", "dv", "avi", "mkv", "mts", "m2ts", "ts", "mpg", "mpeg", "wmv", "vob", "3gp", "flv", "webm", "m2v",
    ]

    private var sessions: [String: Session] = [:]
    private let records: @MainActor () -> [VideoRecord]
    private let record: @MainActor (UUID) -> VideoRecord?
    private let configuration: @MainActor () -> Configuration
    private let dependencies: HallieAppTurnCoordinator.Dependencies
    /// Access copies for tapes Safari can't decode; nil = no proxies.
    private let proxy: HallieWebProxyCache?
    /// The HDD one-reader rule, answered by the catalog's volume roles.
    private let isSpinningDisk: @MainActor (String) -> Bool
    /// The Archive Timeline's items (Browse tab). Nil = no Browse.
    private let timeline: (@MainActor () -> [ArchiveTimelineItem])?
    /// Still frames for Browse rows. Nil = placeholders only.
    private let posters: HallieWebPosterCache?
    static let sessionIdleLimit: TimeInterval = 6 * 60 * 60

    init(
        records: @escaping @MainActor () -> [VideoRecord],
        record: @escaping @MainActor (UUID) -> VideoRecord?,
        configuration: @escaping @MainActor () -> Configuration,
        dependencies: HallieAppTurnCoordinator.Dependencies = .live,
        proxy: HallieWebProxyCache? = nil,
        isSpinningDisk: @escaping @MainActor (String) -> Bool = { _ in false },
        timeline: (@MainActor () -> [ArchiveTimelineItem])? = nil,
        posters: HallieWebPosterCache? = nil
    ) {
        self.records = records
        self.record = record
        self.configuration = configuration
        self.dependencies = dependencies
        self.proxy = proxy
        self.isSpinningDisk = isSpinningDisk
        self.timeline = timeline
        self.posters = posters
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
        case ("GET", let path) where path.hasPrefix("/api/media/") && path.hasSuffix("/status"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            let id = String(path.dropFirst("/api/media/".count).dropLast("/status".count))
            return await mediaStatus(recordID: id)
        case ("GET", let path) where path.hasPrefix("/api/media/"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return await media(request, recordID: String(path.dropFirst("/api/media/".count)))
        case ("GET", "/api/ping"):
            return .json(["ok": true, "name": config.archivistName, "browse": timeline != nil])
        case ("GET", "/api/timeline"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return timelineJSON()
        case ("GET", let path) where path.hasPrefix("/api/poster/"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return await poster(recordID: String(path.dropFirst("/api/poster/".count)))
        case ("GET", let path) where path.hasPrefix("/api/attachment/"):
            guard authorized(request, config) else { return .text(401, "passphrase") }
            return await attachmentImage(
                token: String(path.dropFirst("/api/attachment/".count)))
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
            var merged: MergedReply?
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
                // CONJUNCTION (Rick, 2026-09-01): "where was Martha Lamson
                // born and when was she born" is two questions and the AST
                // holds one shape. Same clause loop as the chat window's
                // askLocally: clause N+1 runs against the memory / telling /
                // drill / picker clause N left in the session. The splitter
                // returns nil for anything it is not sure about, so this is
                // a one-element list for nearly every line — and that path
                // is the old one, unchanged.
                let clauses = HallieQuestionSplitter.isEnabled
                    ? (HallieQuestionSplitter.split(text) ?? [text])
                    : [text]
                if clauses.count > 1 {
                    appLog.write("Hallie: split into \(clauses.count) questions (web): "
                        + clauses.map { "\"\($0)\"" }.joined(separator: " | "))
                }
                var executed: [HallieAppTurnCoordinator.Response] = []
                for (index, clause) in clauses.enumerated() {
                    // "play donna at christmas" is recognised inside the
                    // coordinator (pre-translation), same as the chat window.
                    let step = try await HallieAppTurnCoordinator.execute(
                        question: clause,
                        records: records(),
                        referent: .init(recordID: nil, temporalDate: nil),
                        hosts: config.hosts,
                        modelName: config.modelName,
                        playAfterAnswer: false,
                        memory: session.memory,
                        composeWithModel: config.composeWithModel,
                        history: session.history,
                        telling: session.telling,
                        drill: session.drill,
                        picker: session.picker,
                        dependencies: turnDependencies)
                    session.history.append(.init(user: clause, assistant: step.result.prose))
                    if session.history.count > HallieGroundedComposer.historyTurns {
                        session.history.removeFirst(session.history.count - HallieGroundedComposer.historyTurns)
                    }
                    executed.append(step)
                    // A which-one is pending: the next clause would run
                    // against an unresolved subject. Stop here — the
                    // reader's choice resumes only this clause.
                    if step.pendingClarification != nil { break }
                    // The LAST clause is carried below with the full text,
                    // exactly as a single question always was.
                    if index < clauses.count - 1 {
                        Self.carry(step, question: clause, into: &session)
                    }
                }
                guard let reply = Self.merge(executed) else {
                    return .text(500, "no answer")
                }
                merged = reply
                response = reply.last
            }
            Self.carry(response, question: object["text"] as? String, into: &session)
            let isFollowUpAction = response.result.route == .followUp
                && response.result.mediaAction != nil
            let citations = merged?.citations ?? response.citations
            if !isFollowUpAction { session.lastCitations = citations }
            sessions[sessionID] = session
            return .json(payload(for: response, citations: isFollowUpAction ? [] : citations, merged: merged))
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

    /// The state one answer leaves for the next turn — or, inside a split
    /// line, for the next clause. Mirrors the chat window's `commitHallie`
    /// rule for rule, so the second clause sees the same world on the iPad
    /// as it would in the app.
    private static func carry(
        _ response: HallieAppTurnCoordinator.Response,
        question: String?,
        into session: inout Session
    ) {
        if response.result.outcome == .repaired, response.pendingClarification == nil {
            // A repair re-asked the pending which-one; keep it selectable.
        } else {
            session.pendingClarification = response.pendingClarification
        }
        session.telling = response.telling
        session.drill = response.drill
        session.picker = response.picker
        session.memory.record(intent: response.executedIntent, result: response.result,
                              question: question)
    }

    /// One HTTP reply for a line answered in pieces (a split conjunction):
    /// the proses in order, the evidence from every piece, and the LAST
    /// response for everything modal — chips, play, the pending which-one —
    /// because that is the state the session is actually in.
    struct MergedReply: Sendable {
        let prose: String
        let basis: String
        let citations: [HallieTurnExecutor.Citation]
        let knowledge: [HallieTurnExecutor.KnowledgeCitation]
        let attachments: [HallieAttachment]
        let last: HallieAppTurnCoordinator.Response
    }

    /// Pure — no session, no network — so it can be tested on its own.
    /// One response merges to itself, field for field; nil only for none.
    nonisolated static func merge(_ responses: [HallieAppTurnCoordinator.Response]) -> MergedReply? {
        guard let last = responses.last else { return nil }
        if responses.count == 1 {
            return MergedReply(
                prose: HallieAppNavigation.webProse(for: last.result),
                basis: last.result.basisLine,
                citations: last.citations, knowledge: last.result.knowledgeCitations,
                attachments: last.result.attachments, last: last)
        }
        var seenRecords = Set<UUID>()
        var citations: [HallieTurnExecutor.Citation] = []
        var seenKnowledge = Set<String>()
        var knowledge: [HallieTurnExecutor.KnowledgeCitation] = []
        var attachments: [HallieAttachment] = []
        for response in responses {
            for citation in response.citations where seenRecords.insert(citation.recordID).inserted {
                citations.append(citation)
            }
            for item in response.result.knowledgeCitations where seenKnowledge.insert(item.id).inserted {
                knowledge.append(item)
            }
            for attachment in response.result.attachments where !attachments.contains(attachment) {
                attachments.append(attachment)
            }
        }
        return MergedReply(
            prose: responses.map { HallieAppNavigation.webProse(for: $0.result) }
                .joined(separator: "\n\n"),
            basis: responses.map(\.result.basisLine).joined(separator: "\n"),
            citations: citations,
            knowledge: knowledge,
            attachments: attachments,
            last: last)
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

    /// `merged` is set only for a split line; it overrides the prose,
    /// basis, attachments and knowledge with the union across the pieces.
    /// For one clause it is nil (or equal to the response) and the payload
    /// is byte-for-byte what it always was.
    func payload(for response: HallieAppTurnCoordinator.Response,
                 citations: [HallieTurnExecutor.Citation],
                 merged: MergedReply? = nil) -> [String: Any] {
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
            case .openFamilyTreePerson(_, let name):
                chips.append(["label": "Tell me about \(name)", "ask": "tell me about \(name)"])
            case .openFamilyTreeSurname(let surname):
                chips.append(["label": "The \(surname) family", "ask": "who are the \(surname)s"])
            case .getFamilyTree:
                // The sheet is Mac-only; the web client gets the prose alone.
                break
            case .recompileFamilyTree:
                // Recompiling is the Mac app's job (live miss #8); the
                // prose already says what is needed. Never auto-run here.
                break
            case .openPeopleTab:
                // The People tab is Mac-only; the web client gets the prose.
                break
            case .openAppDestination:
                // Main-window navigation is Mac-only.
                break
            case .showPossibleDuplicate(_, let name):
                chips.append(["label": "Tell me about \(name)", "ask": "tell me about \(name)"])
            }
        }
        // The variations picker: the web client has no phoneme playback,
        // so the list rides in the prose and each chip replies by number.
        var prose = merged?.prose ?? HallieAppNavigation.webProse(for: result)
        if let offer = response.picker {
            prose += "\n" + HalliePronunciationPicker.numberedList(offer)
            for (index, candidate) in offer.candidates.enumerated() {
                chips.append(["label": "\(index + 1) \(candidate.respelling)", "ask": "\(index + 1)"])
            }
            chips.append(["label": HalliePronunciationPicker.noneLabel, "ask": HalliePronunciationPicker.noneReplyText])
        }
        let cited = citations.map(citationJSON)
        var play: [[String: Any]] = []
        if let action = result.mediaAction, action.kind == .play {
            play = action.citations.map(citationJSON).filter { ($0["playable"] as? Bool) == true }
        } else if response.playAfterAnswer {
            play = cited.filter { ($0["playable"] as? Bool) == true }.prefix(1).map { $0 }
        }
        return [
            "prose": prose,
            "basis": merged?.basis ?? result.basisLine,
            "attachments": (merged?.attachments ?? result.attachments).map { attachmentJSON($0) },
            "route": HallieTurnExecutor.label(result.route),
            "outcome": HallieTurnExecutor.label(result.outcome),
            "responder": response.responderHost,
            "citations": cited,
            "chips": chips,
            "play": play,
            "knowledge": (merged?.knowledge ?? result.knowledgeCitations).map {
                ["id": $0.id, "title": $0.title, "attribution": $0.attribution ?? ""]
            },
            "listening": response.telling != nil,
        ]
    }

    /// How a record can reach the page: straight from the Mac, through a
    /// proxy, or not at all.
    enum Delivery: Equatable { case native, proxy, none }

    func delivery(for record: VideoRecord) -> Delivery {
        let ext = (record.fullPath as NSString).pathExtension.lowercased()
        guard record.isPlayable != "No" else { return .none }
        if Self.browserPlayableExtensions.contains(ext) { return .native }
        if ext == "mov", Self.nativeMovCodecs.contains(record.videoCodec.lowercased()) { return .native }
        if proxy != nil, Self.proxyableExtensions.contains(ext) || ext == "mov" { return .proxy }
        return .none
    }

    /// Delivery judged from the filename alone — for a citation whose
    /// record is not loadable right now (tests, or a row that vanished).
    func delivery(forFilename filename: String) -> Delivery {
        let ext = (filename as NSString).pathExtension.lowercased()
        if Self.browserPlayableExtensions.contains(ext) { return .native }
        if proxy != nil, Self.proxyableExtensions.contains(ext) || ext == "mov" { return .proxy }
        return ext == "mov" ? .native : .none
    }

    private func citationJSON(_ citation: HallieTurnExecutor.Citation) -> [String: Any] {
        let how = record(citation.recordID).map(delivery(for:)) ?? delivery(forFilename: citation.filename)
        return [
            "id": citation.recordID.uuidString,
            "filename": citation.filename,
            "playable": how != .none,
            "native": how == .native,
            "url": "/api/media/\(citation.recordID.uuidString)",
        ]
    }

    // MARK: - Browse (the Archive Timeline)

    /// The archive as a story: decades → years → items, each item with the
    /// same delivery facts a citation carries, so the page plays it the
    /// same way. Archive only, on purpose: vetted, dated, named.
    private func timelineJSON() -> HallieHTTPResponse {
        guard let timeline else { return .json(["decades": [], "undated": [], "available": false]) }
        let built = ArchiveTimeline.build(items: timeline())
        func item(_ it: ArchiveTimelineItem) -> [String: Any] {
            let how = record(it.id).map(delivery(for:)) ?? delivery(forFilename: it.archiveFilename)
            let kind: String
            switch it.kind {
            case .video: kind = "video"
            case .audio: kind = "audio"
            case .photo: kind = "photo"
            }
            return [
                "id": it.id.uuidString,
                "title": it.title,
                "filename": it.archiveFilename,
                "year": it.year as Any,
                "kind": kind,
                "duration": it.friendlyDuration,
                "people": it.peopleText,
                "verified": it.isVerified,
                "playable": how != .none && it.kind != .photo,
                "native": how == .native,
                "url": "/api/media/\(it.id.uuidString)",
                "poster": posters != nil && it.kind == .video ? "/api/poster/\(it.id.uuidString)" : NSNull(),
            ]
        }
        let decades: [[String: Any]] = built.decades.map { decade in
            [
                "start": decade.start,
                "label": decade.label,
                "count": decade.count,
                "years": decade.years.map { year in
                    ["year": year.year, "items": year.items.map(item)]
                },
            ]
        }
        return .json([
            "available": true,
            "decades": decades,
            "undated": built.undated.map(item),
            "total": built.decades.reduce(0) { $0 + $1.count } + built.undated.count,
        ])
    }

    // MARK: - Posters

    /// 200 + JPEG when the still exists; 202 while it is being made; 404
    /// when it can't be (no file, not a video, or ffmpeg gave up).
    private func poster(recordID: String) async -> HallieHTTPResponse {
        guard let posters, let id = UUID(uuidString: recordID), let record = record(id) else {
            return .text(404, "no poster")
        }
        let ext = (record.fullPath as NSString).pathExtension.lowercased()
        guard Self.browserPlayableExtensions.contains(ext) || Self.proxyableExtensions.contains(ext) || ext == "mov",
              FileManager.default.fileExists(atPath: record.fullPath) else {
            return .text(404, "no poster")
        }
        if await posters.isFailed(id) { return .text(404, "no poster") }
        guard let url = await posters.poster(for: id, sourcePath: record.fullPath,
                                             durationSeconds: record.durationSeconds) else {
            return .json(["state": "preparing"], status: 202)
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else { return .text(404, "no poster") }
        return HallieHTTPResponse(
            status: 200, reason: "OK",
            headers: [("Content-Type", "image/jpeg"), ("Cache-Control", "max-age=86400")],
            body: .file(url, range: 0..<size, totalLength: size))
    }

    // MARK: - Media

    /// JSON for the page's "preparing…" poll.
    private func mediaStatus(recordID: String) async -> HallieHTTPResponse {
        guard let id = UUID(uuidString: recordID), let record = record(id) else {
            return .text(404, "no such item")
        }
        switch delivery(for: record) {
        case .native: return .json(["state": "ready", "native": true])
        case .none: return .json(["state": "unavailable", "reason": "plays on the Mac only"])
        case .proxy:
            guard let proxy else { return .json(["state": "unavailable"]) }
            switch await proxy.status(for: id) {
            case .ready: return .json(["state": "ready", "native": false])
            case .preparing(let started):
                return .json(["state": "preparing", "seconds": Int(Date().timeIntervalSince(started))])
            case .failed(let why): return .json(["state": "failed", "reason": why])
            case .notStarted: return .json(["state": "notStarted"])
            }
        }
    }

    private func media(_ request: HallieHTTPRequest, recordID: String) async -> HallieHTTPResponse {
        guard let id = UUID(uuidString: recordID), let record = record(id) else {
            return .text(404, "no such item")
        }
        var url = URL(fileURLWithPath: record.fullPath)
        var ext = url.pathExtension.lowercased()
        switch delivery(for: record) {
        case .none:
            return .text(415, "this one plays on the Mac only")
        case .proxy:
            guard let proxy else { return .text(415, "this one plays on the Mac only") }
            guard FileManager.default.fileExists(atPath: record.fullPath) else {
                return .text(404, "that file isn't reachable right now (volume offline?)")
            }
            let root = MediaVolumeGatePolicy.volumeRoot(forPath: record.fullPath)
            let spinning = isSpinningDisk(record.fullPath)
            switch await proxy.ensure(recordID: id, sourcePath: record.fullPath,
                                      volumeRoot: root, volumeIsSpinningDisk: spinning) {
            case .ready(let proxyURL):
                url = proxyURL
                ext = "mp4"
            case .preparing(let started):
                return .json(["state": "preparing", "seconds": Int(Date().timeIntervalSince(started))], status: 202)
            case .failed(let why):
                return .text(415, "I couldn't prepare that one for the iPad: \(why)")
            case .notStarted:
                return .json(["state": "preparing", "seconds": 0], status: 202)
            }
        case .native:
            break
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
            interpretTurn: interpretTurn,
            composeConversation: composeConversation,
            loadProfiles: loadProfiles,
            loadGraph: loadGraph,
            loadNeedsRecompile: loadNeedsRecompile,
            loadCyberBrain: loadCyberBrain,
            recordTestimony: recordTestimony,
            recordPhotoCaption: recordPhotoCaption,
            recordPronunciation: recordPronunciation,
            loadDrillStore: loadDrillStore,
            saveDrillStore: saveDrillStore,
            loadLexicon: loadLexicon,
            loadPronunciationGold: loadPronunciationGold,
            excludePhoto: excludePhoto,
            loadSpeakers: { speakers },
            executeRequest: executeRequest,
            continueTurn: continueTurn,
            resolveBiographyPhoto: resolveBiographyPhoto,
            composeAnswer: composeAnswer)
    }
}

// MARK: - Attachments (2026-08-22)
//
// Cards go over as plain JSON the page renders as nested lists; images
// (photos, crests) are served by an opaque per-launch token so the page
// never sees or requests a filesystem path — only files the app itself
// attached can ever be fetched.

extension HallieWebBridge {
    func attachmentJSON(_ attachment: HallieAttachment) -> [String: Any] {
        func person(_ p: HalliePersonCard) -> [String: Any] {
            var j: [String: Any] = ["name": p.name, "id": p.gedcomID]
            if let y = p.years { j["years"] = y }
            if let b = p.birthPlace { j["place"] = b }
            if let url = p.photoURL { j["photo"] = "/api/attachment/" + attachmentToken(for: url) }
            return j
        }
        func node(_ n: HallieTreeCard.Node) -> [String: Any] {
            ["person": person(n.person), "spouses": n.spouses.map(person), "children": n.children.map(node)]
        }
        switch attachment {
        case .photo(let p):
            return ["kind": "photo", "name": p.personName, "caption": p.caption ?? "",
                    "url": "/api/attachment/" + attachmentToken(for: p.fileURL)]
        case .crest(let surname, let url):
            return ["kind": "crest", "surname": surname, "url": "/api/attachment/" + attachmentToken(for: url)]
        case .lineage(let card):
            return ["kind": "lineage", "title": card.title, "root": person(card.root),
                    "line": card.line.rawValue, "reachedAll": card.reachedAll,
                    "generations": card.generations.map { ["label": $0.label, "generation": $0.generation, "people": $0.people.map(person)] }]
        case .tree(let card):
            return ["kind": "tree", "title": card.title, "surname": card.surname ?? "",
                    "depth": card.depth, "roots": card.roots.map(node)]
        case .photoRequest(let name, let folder):
            _ = folder // The remote client must never receive filesystem paths.
            return ["kind": "photoRequest", "name": name]
        }
    }

    func attachmentToken(for url: URL) -> String {
        if let existing = attachmentTokens.first(where: {
            $0.value.url == url
        })?.key { return existing }
        if attachmentTokens.count >= 256 {
            attachmentTokens.removeAll(keepingCapacity: true)
        }
        let token = UUID().uuidString.lowercased()
        let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
        let familyRoot = Self.isDescendant(url, of: configuration.roots.assets)
            ? configuration.roots.assets : nil
        attachmentTokens[token] = AttachmentCapability(
            url: url, familyRoot: familyRoot)
        return token
    }

    func attachmentImage(token: String) async -> HallieHTTPResponse {
        guard let capability = attachmentTokens[token] else {
            return .text(404, "no image")
        }
        if let originalRoot = capability.familyRoot {
            let current = FamilyAssetConfigurationCenter.shared.snapshot()
            guard current.access != .unavailable,
                  current.roots.assets == originalRoot,
                  Self.isDescendant(capability.url, of: originalRoot) else {
                return .text(404, "no image")
            }
        }
        let url = capability.url
        let data = await Task.detached(priority: .utility) {
            FamilyAssetImageValidator.thumbnailJPEGData(url)
        }.value
        guard let data else { return .text(404, "no image") }
        return HallieHTTPResponse(
            status: 200, reason: "OK",
            headers: [("Content-Type", "image/jpeg"),
                      ("Content-Length", String(data.count)),
                      ("Cache-Control", "private, max-age=3600")],
            body: .data(data))
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let child = candidate.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        return child.count > parent.count
            && Array(child.prefix(parent.count)) == parent
    }
}
