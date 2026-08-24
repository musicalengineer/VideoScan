import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Hallie on the home network: the HTTP pieces are pure and tested without
/// a socket; the bridge is tested through the real coordinator with fixture
/// dependencies; one live loopback round trip proves the listener.
struct HallieWebTests {

    // MARK: - HTTP parsing

    @Test func parsesARequestLineHeadersQueryAndBody() throws {
        let raw = Data("POST /api/ask?key=abc%20d HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nX-Hallie-Key: pw\r\n\r\nhello".utf8)
        guard case .complete(let request, let consumed) = HallieHTTPRequest.parse(raw) else {
            Issue.record("should parse"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/api/ask")
        #expect(request.query == ["key": "abc d"])
        #expect(request.headers["x-hallie-key"] == "pw")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
        #expect(consumed == raw.count)
    }

    @Test func incompleteAndOversizedRequestsAreHandledSafely() {
        #expect(HallieHTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost".utf8)) == .needMore)
        #expect(HallieHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 9\r\n\r\nshort".utf8)) == .needMore)
        let huge = Data(repeating: UInt8(ascii: "a"), count: HallieHTTPRequest.maximumHeaderBytes + 10)
        #expect(HallieHTTPRequest.parse(huge) == .invalid("headers too large"))
        #expect(HallieHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .invalid("body too large"))
        #expect(HallieHTTPRequest.parse(Data("NOPE\r\n\r\n".utf8)) == .invalid("bad request line"))
    }

    @Test func byteRangesFollowRFC7233() {
        #expect(HallieWebRange.parse("bytes=0-99", length: 1000) == 0..<100)
        #expect(HallieWebRange.parse("bytes=900-", length: 1000) == 900..<1000)
        #expect(HallieWebRange.parse("bytes=-100", length: 1000) == 900..<1000)
        #expect(HallieWebRange.parse("bytes=0-5000", length: 1000) == 0..<1000, "end is clamped")
        #expect(HallieWebRange.parse("bytes=1000-", length: 1000) == nil, "start past the end")
        #expect(HallieWebRange.parse(nil, length: 1000) == nil)
        #expect(HallieWebRange.parse("items=0-1", length: 1000) == nil)
    }

    @Test func onlyHomeNetworkPeersAreAnswered() {
        for ok in ["127.0.0.1", "::1", "192.168.1.40", "10.0.0.7", "172.16.3.3", "172.31.9.9", "169.254.1.1", "fe80::1%en0", "::ffff:192.168.0.5"] {
            #expect(HallieWebPeer.isPrivate(ok), Comment(rawValue: ok))
        }
        for no in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2600:1700::1", "unknown"] {
            #expect(!HallieWebPeer.isPrivate(no), Comment(rawValue: no))
        }
    }

    @Test func responseHeadCarriesLengthAndClose() {
        let head = String(data: HallieHTTPResponse.text(404, "nope").headBytes, encoding: .utf8) ?? ""
        #expect(head.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
        #expect(head.contains("Content-Length: 4\r\n"))
        #expect(head.contains("Connection: close\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test @MainActor
    func attachmentEndpointServesBoundedValidatedImageAndRejectsPoison() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieWebAttachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = root.appendingPathComponent("valid.png")
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        try png.write(to: valid)
        let poison = root.appendingPathComponent("poison.jpg")
        try Data("not an image".utf8).write(to: poison)
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)

        let b = bridge(Recorder())
        let good = await b.attachmentImage(token: b.attachmentToken(for: valid))
        #expect(good.status == 200)
        #expect(good.headers.contains { $0.0 == "Content-Type" && $0.1 == "image/jpeg" })
        if case .data(let bytes) = good.body {
            #expect(!bytes.isEmpty)
        } else {
            Issue.record("attachment must be a validated in-memory thumbnail")
        }
        let poisonResponse = await b.attachmentImage(
            token: b.attachmentToken(for: poison))
        let linkResponse = await b.attachmentImage(
            token: b.attachmentToken(for: link))
        #expect(poisonResponse.status == 404)
        #expect(linkResponse.status == 404)
    }

    // MARK: - Bridge through the real coordinator

    private final class Recorder: @unchecked Sendable {
        var questions: [String] = []
        var speakers: [String?] = []
        var testimonies: [CyberBrainWriter.Testimony] = []
    }

    @MainActor
    private func bridge(_ recorder: Recorder, passphrase: String = "") -> HallieWebBridge {
        let deps = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { [recorder] question, _, _ in
                recorder.questions.append(question)
                return .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture")
            },
            loadProfiles: { [.init(stableID: "donna", canonicalName: "Donna")] },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            recordTestimony: { [recorder] in recorder.testimonies.append($0) },
            loadSpeakers: { .init(ownerName: "WRONG", archivistName: "Hallie Mae") },
            executeRequest: { [recorder] _, context in
                recorder.speakers.append(context.speakers.ownerName)
                return HallieTurnExecutor.Result(
                    route: .presence, outcome: .answered,
                    prose: "I found 1 catalog item matching that.",
                    basisLine: "Basis: fixture", queryDescription: "shape=presence",
                    citations: [.init(recordID: UUID(), fullPath: "/v/cape.mp4", filename: "cape.mp4",
                                      playbackSeconds: nil, bases: [])],
                    catalogPersonName: "Donna")
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
        return HallieWebBridge(
            records: { [] },
            record: { _ in nil },
            configuration: {
                .init(passphrase: passphrase, archivistName: "Hallie Mae", archivistPersonName: nil,
                      hosts: ["fixture.invalid"], modelName: "fixture-model", composeWithModel: false)
            },
            dependencies: deps)
    }

    private func post(_ path: String, _ object: [String: Any], headers: [String: String] = [:]) -> HallieHTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: object)
        var all = ["content-length": String(body.count)]
        for (k, v) in headers { all[k.lowercased()] = v }
        return HallieHTTPRequest(method: "POST", path: path, query: [:], headers: all, body: body)
    }

    private func json(_ response: HallieHTTPResponse) -> [String: Any] {
        guard case .data(let data) = response.body else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @MainActor
    @Test func askRunsTheCoordinatorWithTheDevicesPersonAndReturnsCitations() async throws {
        let recorder = Recorder()
        let bridge = bridge(recorder)
        let response = await bridge.handle(
            post("/api/ask", ["session": "ipad-1", "who": "Donna Breen", "text": "show me the cape"]),
            peer: "192.168.1.40")
        #expect(response.status == 200)
        let body = json(response)
        #expect(body["prose"] as? String == "I found 1 catalog item matching that.")
        #expect(body["route"] as? String == "presence")
        #expect(recorder.questions == ["show me the cape"])
        #expect(recorder.speakers == ["Donna Breen"], "the device's person is 'I', not the Mac's owner")
        let citations = body["citations"] as? [[String: Any]] ?? []
        #expect(citations.count == 1)
        #expect(citations.first?["filename"] as? String == "cape.mp4")
        #expect(citations.first?["playable"] as? Bool == true)
        #expect((citations.first?["url"] as? String)?.hasPrefix("/api/media/") == true)
    }

    @MainActor
    @Test func tellingWorksOverTheWebAndIsAttributedToTheDevicesPerson() async throws {
        let recorder = Recorder()
        let bridge = bridge(recorder)
        let opened = json(await bridge.handle(
            post("/api/ask", ["session": "ipad-2", "who": "Donna Breen", "text": "let me tell you about my mom"]),
            peer: "10.0.0.3"))
        #expect((opened["prose"] as? String)?.hasPrefix("Oh, please do — I'd love to hear about my mom.") == true)
        #expect(opened["listening"] as? Bool == true)
        _ = await bridge.handle(post("/api/ask", ["session": "ipad-2", "who": "Donna Breen", "text": "Elaine"]), peer: "10.0.0.3")
        _ = await bridge.handle(post("/api/ask", ["session": "ipad-2", "who": "Donna Breen", "text": "She taught school for thirty years."]), peer: "10.0.0.3")
        let closed = json(await bridge.handle(post("/api/ask", ["session": "ipad-2", "who": "Donna Breen", "text": "that's all"]), peer: "10.0.0.3"))
        #expect((closed["prose"] as? String)?.contains("told by Donna Breen today") == true)
        #expect(closed["listening"] as? Bool == false)
        #expect(recorder.testimonies.map(\.text) == ["Elaine is my mom.", "She taught school for thirty years."])
        #expect(recorder.testimonies.allSatisfy { $0.speakerName == "Donna Breen" && $0.subjectName == "Elaine" })
        #expect(recorder.questions.isEmpty, "listening never calls the model")
    }

    @MainActor
    @Test func passphraseGatesTheAPIButNotThePage() async throws {
        let bridge = bridge(Recorder(), passphrase: "maple")
        let page = await bridge.handle(HallieHTTPRequest(method: "GET", path: "/", query: [:], headers: [:], body: Data()), peer: "127.0.0.1")
        #expect(page.status == 200)
        if case .data(let data) = page.body {
            #expect(String(data: data, encoding: .utf8)?.contains("<title>Hallie Mae</title>") == true)
        }
        let denied = await bridge.handle(post("/api/ask", ["session": "s", "who": "x", "text": "hi"]), peer: "127.0.0.1")
        #expect(denied.status == 401)
        let allowed = await bridge.handle(post("/api/ask", ["session": "s", "who": "x", "text": "hi"], headers: ["X-Hallie-Key": "maple"]), peer: "127.0.0.1")
        #expect(allowed.status == 200)
        let media = await bridge.handle(HallieHTTPRequest(method: "GET", path: "/api/media/\(UUID().uuidString)", query: ["key": "maple"], headers: [:], body: Data()), peer: "127.0.0.1")
        #expect(media.status == 404, "unknown record, but the key was accepted")
    }

    @MainActor
    @Test func malformedAsksAreRejectedWithoutRunningAnything() async throws {
        let recorder = Recorder()
        let bridge = bridge(recorder)
        #expect(await bridge.handle(post("/api/ask", ["who": "x", "text": "hi"]), peer: "127.0.0.1").status == 400)
        #expect(await bridge.handle(post("/api/ask", ["session": "s", "who": "x"]), peer: "127.0.0.1").status == 400)
        #expect(await bridge.handle(HallieHTTPRequest(method: "GET", path: "/api/nope", query: [:], headers: [:], body: Data()), peer: "127.0.0.1").status == 404)
        #expect(recorder.questions.isEmpty)
    }

    // MARK: - Live loopback

    @MainActor
    @Test func theListenerAnswersARealRequestOnLoopback() async throws {
        let server = HallieWebServer { request, _ in
            request.path == "/api/ping" ? .json(["ok": true]) : .text(404, "no")
        }
        try server.start(port: 0)
        defer { server.stop() }
        #expect(server.port != 0)
        let url = URL(string: "http://127.0.0.1:\(server.port)/api/ping")!
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == "{\"ok\":true}")
    }
}

/// Browse: the Archive Timeline as JSON, same delivery facts as citations.
struct HallieWebBrowseTests {
    @Test @MainActor func timelineJSONIsDecadesYearsItemsWithDeliveryFacts() async throws {
        let items = [
            ArchiveTimelineItem(id: UUID(), title: "Cape Cod", archiveFilename: "1993-07-xx_Cape-Cod.dv",
                                relPath: "1990s/1993/1993-07-xx_Cape-Cod.dv", year: 1993, kind: .video,
                                durationSeconds: 600, peopleText: "Donna, Rick", isVerified: true),
            ArchiveTimelineItem(id: UUID(), title: "Christmas", archiveFilename: "2004-12-25_Christmas.mp4",
                                relPath: "2000s/2004/2004-12-25_Christmas.mp4", year: 2004, kind: .video,
                                durationSeconds: 120, peopleText: "", isVerified: false),
            ArchiveTimelineItem(id: UUID(), title: "Grandma", archiveFilename: "grandma.jpg",
                                relPath: "Undated/grandma.jpg", year: nil, kind: .photo,
                                durationSeconds: 0, peopleText: "", isVerified: true),
        ]
        let proxy = HallieWebProxyCache(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("browse-\(UUID().uuidString)"), runner: { _ in })
        let bridge = HallieWebBridge(
            records: { [] }, record: { _ in nil },
            configuration: { .init(passphrase: "", archivistName: "Hallie Mae", archivistPersonName: nil,
                                   hosts: [], modelName: "x", composeWithModel: false) },
            dependencies: .live, proxy: proxy, timeline: { items })
        let response = await bridge.handle(
            HallieHTTPRequest(method: "GET", path: "/api/timeline", query: [:], headers: [:], body: Data()),
            peer: "192.168.0.9")
        #expect(response.status == 200)
        guard case .data(let data) = response.body,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("no JSON"); return
        }
        #expect(json["available"] as? Bool == true)
        #expect(json["total"] as? Int == 3)
        let decades = json["decades"] as? [[String: Any]] ?? []
        #expect(decades.map { $0["label"] as? String } == ["1990s", "2000s"])
        let first = ((decades.first?["years"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first
        #expect(first?["title"] as? String == "Cape Cod")
        #expect(first?["playable"] as? Bool == true, "DV goes through the proxy")
        #expect(first?["native"] as? Bool == false)
        #expect(first?["verified"] as? Bool == true)
        #expect(first?["duration"] as? String != nil)
        let undated = json["undated"] as? [[String: Any]] ?? []
        #expect(undated.first?["kind"] as? String == "photo")
        #expect(undated.first?["playable"] as? Bool == false, "photos aren't played")

        let ping = await bridge.handle(HallieHTTPRequest(method: "GET", path: "/api/ping", query: [:], headers: [:], body: Data()), peer: "127.0.0.1")
        if case .data(let d) = ping.body { #expect(String(data: d, encoding: .utf8)?.contains("\"browse\":true") == true) }
        let page = await bridge.handle(HallieHTTPRequest(method: "GET", path: "/", query: [:], headers: [:], body: Data()), peer: "127.0.0.1")
        if case .data(let d) = page.body { #expect(String(data: d, encoding: .utf8)?.contains("Browse the archive") == true) }
    }
}
