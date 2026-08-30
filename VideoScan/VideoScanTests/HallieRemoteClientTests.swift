// HallieRemoteClientTests.swift
// Phase 1 remote use, slice 3 — Hallie on the viewer (docs/remote_use_design.md §3).
//
// Parity: the viewer's client posts exactly what the iPad page posts and
// shows exactly what the bridge returned — proven against a stub bridge
// behind the REAL HallieWebServer on a loopback ephemeral port (the
// transcript recorded server-side equals the one the client accumulated,
// across two asks and a which-one selection with one persisted session).
// Routing: master reachable → master; unreachable + local brain → local
// fallback; neither → offline. Failures are named (401, timeouts).

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

private func remoteClientTestDefaults(_ suite: String) -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: suite) else {
        preconditionFailure("could not create test defaults suite: \(suite)")
    }
    return defaults
}

private final class RemoteTransportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A bridge stand-in: answers /api/ping and /api/ask the way HallieWebBridge
/// does (passphrase gate, session required, select continues a pending
/// which-one), and records the transcript it produced.
@MainActor
private final class StubBridge {
    let passphrase: String
    var transcript: [(question: String, prose: String)] = []
    var sessions: [String] = []
    var pendingCandidates: [HallieTurnExecutor.CandidateID] = []

    init(passphrase: String) { self.passphrase = passphrase }

    func handle(_ request: HallieHTTPRequest, peer: String) -> HallieHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/ping"):
            return .json(["ok": true, "name": "Hallie", "browse": false])
        case ("POST", "/api/ask"):
            guard (request.headers["x-hallie-key"] ?? "") == passphrase else { return .text(401, "passphrase") }
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let session = object["session"] as? String, !session.isEmpty else {
                return .text(400, "session required")
            }
            sessions.append(session)
            if let select = object["select"] as? [String: Any],
               let id = HallieWebBridge.candidateID(from: select), pendingCandidates.contains(id) {
                pendingCandidates = []
                let prose = "Rick Breen Jr. was born in 1963."
                transcript.append(("<select \(id)>", prose))
                return .json(payload(prose: prose, basis: "Basis: the family tree.", chips: []))
            }
            let text = object["text"] as? String ?? ""
            if text.lowercased().contains("rick") {
                pendingCandidates = [.gedcomPersonID("@I1@"), .gedcomPersonID("@I2@")]
                let prose = "Which person do you mean?"
                transcript.append((text, prose))
                return .json(payload(prose: prose, basis: "Basis: the name matches more than one identity.", chips: [
                    ["label": "Rick Breen Jr. (b. 1963)", "select": HallieWebBridge.selectJSON(.gedcomPersonID("@I1@"))],
                    ["label": "Rick Breen Sr. (b. 1932)", "select": HallieWebBridge.selectJSON(.gedcomPersonID("@I2@"))],
                ]))
            }
            let prose = "Donna appears in 3 videos; here is one."
            transcript.append((text, prose))
            return .json(payload(prose: prose, basis: "Basis: 3 catalog records.", chips: [
                ["label": "Play Cape Cod 1994", "ask": "play cape cod 1994"],
            ], citations: [[
                "id": "6F0E1E2C-2B0A-4C6B-9B0E-1A2B3C4D5E6F", "filename": "capecod.mxf",
                "playable": true, "native": false, "url": "/api/media/6F0E1E2C-2B0A-4C6B-9B0E-1A2B3C4D5E6F",
            ]]))
        default:
            return .text(404, "not here")
        }
    }

    private func payload(prose: String, basis: String, chips: [[String: Any]],
                         citations: [[String: Any]] = []) -> [String: Any] {
        [
            "prose": prose, "basis": basis, "attachments": [],
            "route": "graph", "outcome": "answered", "responder": "RicksM4.local",
            "citations": citations, "chips": chips, "play": [],
            "knowledge": [["id": "bio-1", "title": "Family bible", "attribution": "Donna"]],
            "listening": false,
        ]
    }
}

@MainActor
struct HallieRemoteClientParityTests {

    @Test func sameTranscriptBothEndsThroughALoopbackServer() async throws {
        let bridge = StubBridge(passphrase: "porch")
        let server = HallieWebServer { request, peer in bridge.handle(request, peer: peer) }
        try server.start(port: 0)
        defer { server.stop() }
        let configuration = MediaStreamResolver.Configuration(masterHostname: "localhost", port: Int(server.port), passphrase: "porch")
        // "localhost.local" does not resolve; point the base at loopback.
        let base = try #require(URL(string: "http://127.0.0.1:\(server.port)"))
        let transport: MediaHTTPTransport = { request in
            guard let requestURL = request.url else { throw URLError(.badURL) }
            var rewritten = request
            let relative = requestURL.path + (requestURL.query.map { "?" + $0 } ?? "")
            guard let rewrittenURL = URL(string: relative, relativeTo: base)?.absoluteURL else {
                throw URLError(.badURL)
            }
            rewritten.url = rewrittenURL
            return try await MediaHTTP.urlSession(rewritten)
        }
        let session = "viewer-test-session"
        let client = HallieRemoteClient(configuration: configuration, sessionID: session, transport: transport)

        #expect(await MasterReachabilityProbe(transport: transport).isReachable(configuration))

        var clientTranscript: [(question: String, prose: String)] = []
        let a1 = try await client.ask("where is donna", who: "Rick Breen")
        clientTranscript.append(("where is donna", a1.prose))
        #expect(a1.basis == "Basis: 3 catalog records.")
        #expect(a1.route == "graph" && a1.outcome == "answered" && a1.responder == "RicksM4.local")
        #expect(a1.citations == [.init(recordID: UUID(uuidString: "6F0E1E2C-2B0A-4C6B-9B0E-1A2B3C4D5E6F"),
                                       filename: "capecod.mxf", playable: true, native: false)])
        #expect(a1.chips == [.init(label: "Play Cape Cod 1994", action: .ask("play cape cod 1994"))])
        #expect(a1.knowledge == [.init(id: "bio-1", title: "Family bible", attribution: "Donna")])

        let a2 = try await client.ask("when was rick born", who: "Rick Breen")
        clientTranscript.append(("when was rick born", a2.prose))
        #expect(a2.chips.count == 2)
        guard case .select(let jr) = a2.chips[0].action else { Issue.record("expected a select chip"); return }
        #expect(jr == .gedcomPersonID("@I1@"))

        let a3 = try await client.select(jr, who: "Rick Breen")
        clientTranscript.append(("<select \(jr)>", a3.prose))
        #expect(a3.prose == "Rick Breen Jr. was born in 1963.")

        // Parity: the master's transcript IS the viewer's transcript.
        #expect(bridge.transcript.map(\.question) == clientTranscript.map(\.question))
        #expect(bridge.transcript.map(\.prose) == clientTranscript.map(\.prose))
        // One session throughout, so the master's memory follows the viewer.
        #expect(Set(bridge.sessions) == [session])
        #expect(bridge.sessions.count == 3)
    }

    @Test func requestBodyMatchesTheIPadPage() throws {
        let body = HallieRemoteClient.requestBody(text: "hi", select: nil, session: "s1", who: "Rick Breen")
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["session"] as? String == "s1")
        #expect(object["who"] as? String == "Rick Breen")
        #expect(object["text"] as? String == "hi")
        #expect(object["select"] == nil)

        let select = HallieRemoteClient.requestBody(text: nil, select: .profileStableID("abc"), session: "s1", who: nil)
        let so = try #require(JSONSerialization.jsonObject(with: select) as? [String: Any])
        #expect(so["text"] == nil && so["who"] == nil)
        #expect((so["select"] as? [String: String]) == HallieWebBridge.selectJSON(.profileStableID("abc")))
        let selectObject = try #require(so["select"] as? [String: Any])
        #expect(HallieWebBridge.candidateID(from: selectObject) == .profileStableID("abc"))
        // The client's copy of the wire shape equals the bridge's, both ways.
        for id in [HallieTurnExecutor.CandidateID.profileStableID("p"), .gedcomPersonID("@I9@"), .cyberBrainPersonID("c")] {
            #expect(HallieRemoteSelect.json(id) == HallieWebBridge.selectJSON(id))
            #expect(HallieRemoteSelect.candidateID(from: HallieWebBridge.selectJSON(id)) == id)
        }
    }

    @Test func failuresAreNamed() async {
        let cfg = MediaStreamResolver.Configuration(masterHostname: "RicksM4", port: 8765, passphrase: "x")
        let refused = HallieRemoteClient(configuration: cfg, sessionID: "s", transport: { _ in (401, Data("passphrase".utf8)) })
        await #expect(throws: HallieRemoteClient.Failure.refused("passphrase refused — check Hallie's web passphrase in settings")) {
            _ = try await refused.ask("hi", who: nil)
        }
        let dead = HallieRemoteClient(configuration: cfg, sessionID: "s", transport: { _ in throw URLError(.timedOut) })
        await #expect(throws: HallieRemoteClient.Failure.unreachable) { _ = try await dead.ask("hi", who: nil) }
        let junk = HallieRemoteClient(configuration: cfg, sessionID: "s", transport: { _ in (200, Data("<html>".utf8)) })
        await #expect(throws: HallieRemoteClient.Failure.badAnswer(200)) { _ = try await junk.ask("hi", who: nil) }
        // The passphrase travels as the header the bridge checks.
        let seen = HeaderBox()
        let ok = HallieRemoteClient(configuration: cfg, sessionID: "s", transport: { request in
            seen.value = request.value(forHTTPHeaderField: "X-Hallie-Key")
            return (200, Data("{\"prose\":\"hello\"}".utf8))
        })
        let answer = try? await ok.ask("hi", who: nil)
        #expect(answer?.prose == "hello")
        #expect(seen.value == "x")
    }

    @Test func invalidEndpointRejectsAskAndSelectionWithoutTransport() async {
        let calls = RemoteTransportCounter()
        let transport: MediaHTTPTransport = { _ in
            calls.increment()
            return (200, Data("{\"prose\":\"must not arrive\"}".utf8))
        }

        for configuration in [
            MediaStreamResolver.Configuration(masterHostname: "http://router", port: 8765, passphrase: "x"),
            MediaStreamResolver.Configuration(masterHostname: "RicksM4", port: 0, passphrase: "x"),
        ] {
            let client = HallieRemoteClient(configuration: configuration, sessionID: "stale", transport: transport)
            #expect(client.askURL.isFileURL)
            await #expect(throws: HallieRemoteClient.Failure.invalidConfiguration) {
                _ = try await client.ask("where is donna", who: "Rick")
            }
            await #expect(throws: HallieRemoteClient.Failure.invalidConfiguration) {
                _ = try await client.select(.gedcomPersonID("@I1@"), who: "Rick")
            }
        }
        #expect(calls.value == 0, "neither a fresh ask nor a stale clarification may reach transport")
    }

    @Test func sessionIDPersistsInTheViewersOwnDefaults() {
        let suite = "HallieRemoteClientTests.\(UUID().uuidString)"
        let defaults = remoteClientTestDefaults(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = HallieRemoteClient.sessionID(defaults)
        #expect(first.hasPrefix("viewer-"))
        #expect(HallieRemoteClient.sessionID(defaults) == first)
    }

    @Test func routingPrefersTheMasterThenALocalBrainThenSaysOffline() {
        #expect(HallieViewerRouting.decide(masterReachable: true, localBrainInstalled: true) == .master)
        #expect(HallieViewerRouting.decide(masterReachable: true, localBrainInstalled: false) == .master)
        #expect(HallieViewerRouting.decide(masterReachable: false, localBrainInstalled: true) == .localBrain)
        #expect(HallieViewerRouting.decide(masterReachable: false, localBrainInstalled: false) == .offline)
        #expect(HallieViewerRouting.localBrainInstalled(fileExists: { _ in false }) == false)
        #expect(HallieViewerRouting.localBrainInstalled(fileExists: { $0 == "/opt/homebrew/bin/ollama" }) == true)
        #expect(HallieViewerRouting.offlineNote(masterDisplayName: "RicksM4").hasPrefix("RicksM4 is offline"))
        #expect(HallieViewerRouting.localFallbackNote(masterDisplayName: "RicksM4").contains("this Mac's own brain"))
    }

    final class HeaderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
