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

    /// The browser cannot control the Mac's window. A direct navigation ask
    /// must therefore be an honest app-only answer, not "Opening…" with the
    /// native action silently discarded from the JSON payload.
    @MainActor
    @Test func webNavigationNeverClaimsTheMacActionOccurred() async throws {
        let recorder = Recorder()
        let response = await bridge(recorder).handle(
            post("/api/ask", [
                "session": "ipad-navigation", "who": "Donna Breen",
                "text": "open the Archive tab",
            ]),
            peer: "192.168.1.40")
        let body = json(response)
        #expect(response.status == 200)
        #expect(body["prose"] as? String ==
            "The Archive tab can only be opened in the VideoScan app on the Mac; this web chat can't control that window.")
        #expect(!(body["prose"] as? String ?? "").contains("Opening"))
        #expect((body["chips"] as? [[String: Any]])?.isEmpty == true,
                "the Mac-only action is not encoded as an executable web chip")
        #expect(recorder.questions.isEmpty,
                "the deterministic navigation request never reaches a model")
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

    // MARK: Serve-time containment follows symlinks in every ancestor (codex #1298, 2026-09-11)

    @Test @MainActor
    func attachmentInsideAReplacedAncestorFolderIsRefusedAtServeTime() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_HallieWebAncestorLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let familyRoot = base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true)
        let people = familyRoot.appendingPathComponent("People", isDirectory: true)
        let pdf = people.appendingPathComponent("Mary_OConnor/certificate.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
        // Elsewhere, a same-shaped tree the archive must never serve from.
        let outside = base.appendingPathComponent("outside/People", isDirectory: true)
        let outsidePDF = outside.appendingPathComponent("Mary_OConnor/certificate.pdf")
        try FileManager.default.createDirectory(at: outsidePDF.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: outsidePDF)

        let configuration = FamilyAssetConfiguration(
            roots: .init(assets: familyRoot, thumbnailCache: base.appendingPathComponent("thumbs", isDirectory: true)),
            access: .readOnly, legacyGEDCOMDirectory: nil)
        let deps = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture") },
            loadProfiles: { [] }, loadGraph: { nil }, loadCyberBrain: { nil },
            recordTestimony: { _ in },
            loadSpeakers: { .init(ownerName: "Rick", archivistName: "Hallie Mae") },
            executeRequest: { _, _ in
                HallieTurnExecutor.Result(
                    route: .presence, outcome: .declined, prose: "fixture",
                    basisLine: "Basis: fixture", queryDescription: nil, citations: [], catalogPersonName: nil)
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
        let b = HallieWebBridge(
            records: { [] }, record: { _ in nil },
            configuration: {
                .init(passphrase: "", archivistName: "Hallie Mae", archivistPersonName: nil,
                      hosts: ["fixture.invalid"], modelName: "fixture-model", composeWithModel: false)
            },
            dependencies: deps,
            familyConfiguration: { configuration })

        // Attached while `People/` is a real folder: served, and the token
        // is bound to the family root (temporaryDirectory is itself reached
        // through /var → /private/var, so the resolved check must hold here).
        let token = b.attachmentToken(for: pdf)
        #expect(b.attachmentTokens[token]?.familyRoot == familyRoot)
        #expect(await b.attachmentImage(token: token).status == 200)

        // Now the ANCESTOR is replaced by a link out of the archive. The
        // unresolved path is unchanged and lexically inside; the file it
        // names now lives outside. A leaf-only symlink check passes it.
        try FileManager.default.removeItem(at: people)
        try FileManager.default.createSymbolicLink(at: people, withDestinationURL: outside)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        #expect(!HallieWebBridge.isResolvedDescendant(pdf, of: familyRoot))
        #expect(await b.attachmentImage(token: token).status == 404)
        // Re-attaching the same path reuses the token (de-duplicated by
        // URL); it stays refused rather than being re-minted unbound.
        #expect(b.attachmentToken(for: pdf) == token)
        #expect(await b.attachmentImage(token: token).status == 404)

        // Pure rule: a link that stays inside the root still contains.
        try FileManager.default.removeItem(at: people)
        let realPeople = familyRoot.appendingPathComponent("People-real/Mary_OConnor", isDirectory: true)
        try FileManager.default.createDirectory(at: realPeople, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: people, withDestinationURL: realPeople.deletingLastPathComponent())
        #expect(HallieWebBridge.isResolvedDescendant(pdf, of: familyRoot))
        #expect(!HallieWebBridge.isResolvedDescendant(familyRoot, of: familyRoot))
    }

    // MARK: Every token is pinned to the real file it was minted for (codex #1369, 2026-09-12)

    /// Fixture bridge: no passphrase, fixture dependencies, and the family
    /// archive at `familyRoot` (a temp directory — the shared center is
    /// never read).
    @MainActor
    private func archiveBridge(familyRoot: URL, thumbs: URL) -> HallieWebBridge {
        let configuration = FamilyAssetConfiguration(
            roots: .init(assets: familyRoot, thumbnailCache: thumbs),
            access: .readOnly, legacyGEDCOMDirectory: nil)
        let deps = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture") },
            loadProfiles: { [] }, loadGraph: { nil }, loadCyberBrain: { nil },
            recordTestimony: { _ in },
            loadSpeakers: { .init(ownerName: "Rick", archivistName: "Hallie Mae") },
            executeRequest: { _, _ in
                HallieTurnExecutor.Result(
                    route: .presence, outcome: .declined, prose: "fixture",
                    basisLine: "Basis: fixture", queryDescription: nil, citations: [], catalogPersonName: nil)
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
        return HallieWebBridge(
            records: { [] }, record: { _ in nil },
            configuration: {
                .init(passphrase: "", archivistName: "Hallie Mae", archivistPersonName: nil,
                      hosts: ["fixture.invalid"], modelName: "fixture-model", composeWithModel: false)
            },
            dependencies: deps,
            familyConfiguration: { configuration })
    }

    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    /// A People-tab reference photo lives in App Support, OUTSIDE the
    /// family archive, so the archive-root containment check does not
    /// apply to it. Its token must still be bound to the real file it was
    /// minted for: when an ancestor folder is later swapped for a link
    /// pointing elsewhere, the same path names a different file and the
    /// token is refused — and serves again once the real folder is back.
    @Test @MainActor
    func attachmentOutsideTheArchiveIsRefusedWhenAnAncestorIsSwappedAfterIssuance() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_HallieWebOutsideAncestorLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let familyRoot = base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: familyRoot.appendingPathComponent("People"), withIntermediateDirectories: true)
        // The reference photo, outside the archive.
        let people = base.appendingPathComponent("support/people", isDirectory: true)
        let cover = people.appendingPathComponent("donna/cover.png")
        try FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: cover)
        // Elsewhere, a same-shaped tree with a perfectly valid image.
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let decoy = elsewhere.appendingPathComponent("donna/cover.png")
        try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: decoy)

        let b = archiveBridge(familyRoot: familyRoot, thumbs: base.appendingPathComponent("thumbs", isDirectory: true))
        let token = b.attachmentToken(for: cover)
        #expect(b.attachmentTokens[token]?.familyRoot == nil)
        #expect(await b.attachmentImage(token: token).status == 200)

        // Swap the ANCESTOR: `support/people` becomes a link to `elsewhere`.
        // The leaf is a regular, valid PNG — a leaf-only check passes it.
        try FileManager.default.removeItem(at: people)
        try FileManager.default.createSymbolicLink(at: people, withDestinationURL: elsewhere)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(await b.attachmentImage(token: token).status == 404)
        // De-duplicated by URL, the token stays refused rather than re-minted.
        #expect(b.attachmentToken(for: cover) == token)
        #expect(await b.attachmentImage(token: token).status == 404)

        // The real folder restored: the path names the file it was minted
        // for again, and the token serves.
        try FileManager.default.removeItem(at: people)
        try FileManager.default.createDirectory(at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: cover)
        #expect(await b.attachmentImage(token: token).status == 200)
    }

    /// Three hundred documents attached in one launch: the map stays
    /// bounded at `maxAttachmentTokens`, and only the OLDEST tokens are
    /// evicted, one per mint past the cap — the links a page still shows
    /// (the newest 256, five full gallery answers) keep serving. A
    /// wholesale clear at the cap invalidated all of them at once.
    @Test @MainActor
    func threeHundredTokensEvictOnlyTheOldestAndKeepTheNewestServing() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_HallieWebTokenCap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let familyRoot = base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true)
        let folder = familyRoot.appendingPathComponent("People/Mary_OConnor", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func pdf(_ i: Int) -> URL { folder.appendingPathComponent(String(format: "letter-%03d.pdf", i)) }
        for i in 0..<300 { try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf(i)) }

        let cap = HallieWebBridge.maxAttachmentTokens
        #expect(cap == 256)
        let b = archiveBridge(familyRoot: familyRoot, thumbs: base.appendingPathComponent("thumbs", isDirectory: true))
        var tokens: [String] = []
        for i in 0..<300 { tokens.append(b.attachmentToken(for: pdf(i))) }
        #expect(Set(tokens).count == 300)
        #expect(b.attachmentTokens.count == cap)
        // The 44 oldest are gone; the 45th (index 44) and everything newer serve.
        let evicted = 300 - cap
        #expect(b.attachmentTokens[tokens[evicted - 1]] == nil)
        #expect(b.attachmentTokens[tokens[evicted]] != nil)
        #expect(await b.attachmentImage(token: tokens[0]).status == 404)
        #expect(await b.attachmentImage(token: tokens[evicted]).status == 200)
        #expect(await b.attachmentImage(token: tokens[299]).status == 200)
        // Re-attaching an evicted file mints a fresh token and evicts
        // exactly one more — the oldest survivor — never the newest.
        let again = b.attachmentToken(for: pdf(0))
        #expect(again != tokens[0])
        #expect(b.attachmentTokens.count == cap)
        #expect(b.attachmentTokens[tokens[evicted]] == nil)
        #expect(b.attachmentTokens[tokens[evicted + 1]] != nil)
        #expect(await b.attachmentImage(token: again).status == 200)
        #expect(await b.attachmentImage(token: tokens[299]).status == 200)
        // A live token is reused, not re-minted, so it never moves in the order.
        #expect(b.attachmentToken(for: pdf(299)) == tokens[299])
        #expect(b.attachmentTokens.count == cap)
    }

    // MARK: Validation → read window (codex #1374, 2026-09-12)

    /// The serve-time check passes, and THEN an ancestor is swapped before
    /// the bytes are read. The reader opens the real path the token was
    /// minted for and re-resolves it after the read, so the decoy's bytes
    /// are never served: 404, and the body is not the decoy. Without the
    /// hook the original bytes come back; once the real folder is
    /// restored they do again.
    @Test @MainActor
    func anAncestorSwappedBetweenValidationAndReadNeverChangesTheBytesServed() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_HallieWebReadWindow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let familyRoot = base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: familyRoot.appendingPathComponent("People"), withIntermediateDirectories: true)
        let people = base.appendingPathComponent("support/people", isDirectory: true)
        let letter = people.appendingPathComponent("donna/letter.pdf")
        let original = Data("%PDF-1.4\n% ORIGINAL\n%%EOF\n".utf8)
        try FileManager.default.createDirectory(at: letter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: letter)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let decoyBytes = Data("%PDF-1.4\n% DECOY\n%%EOF\n".utf8)
        let decoy = elsewhere.appendingPathComponent("donna/letter.pdf")
        try FileManager.default.createDirectory(at: decoy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try decoyBytes.write(to: decoy)

        let b = archiveBridge(familyRoot: familyRoot, thumbs: base.appendingPathComponent("thumbs", isDirectory: true))
        let token = b.attachmentToken(for: letter)
        func body(_ r: HallieHTTPResponse) -> Data? {
            if case .data(let d) = r.body { return d } else { return nil }
        }
        let before = await b.attachmentImage(token: token)
        #expect(before.status == 200)
        #expect(body(before) == original)

        // The swap lands AFTER validation, BEFORE the read.
        b.attachmentReadHook = {
            try? FileManager.default.removeItem(at: people)
            try? FileManager.default.createSymbolicLink(at: people, withDestinationURL: elsewhere)
        }
        let during = await b.attachmentImage(token: token)
        #expect(during.status == 404)
        #expect(body(during) != decoyBytes)
        #expect(FileManager.default.fileExists(atPath: letter.path)) // the swap did happen
        b.attachmentReadHook = nil
        // Still swapped: the pre-read check refuses it outright.
        #expect(await b.attachmentImage(token: token).status == 404)

        // Real folder restored: the original bytes serve again.
        try FileManager.default.removeItem(at: people)
        try FileManager.default.createDirectory(at: letter.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: letter)
        let after = await b.attachmentImage(token: token)
        #expect(after.status == 200)
        #expect(body(after) == original)

        // Pure rule: bytes read through a path whose resolution has moved are dropped.
        #expect(HallieWebBridge.bytesPinned(to: letter.path) { _ in original } == original)
        try FileManager.default.removeItem(at: people)
        try FileManager.default.createSymbolicLink(at: people, withDestinationURL: elsewhere)
        #expect(HallieWebBridge.bytesPinned(to: letter.path) { _ in decoyBytes } == nil)
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

// MARK: - One reply for a split line (HallieWebBridge.merge)
//
// Rick, 2026-09-01: "where was Martha Lamson born and when was she born"
// runs as two coordinator turns on the iPad path, but HTTP answers once.
// `merge` is the pure join; the loop around it lives in `ask` and is
// exercised by the eval harness, not here.

struct HallieWebMergeTests {

    @MainActor
    private func bridge() -> HallieWebBridge {
        HallieWebBridge(
            records: { [] }, record: { _ in nil },
            configuration: {
                .init(passphrase: "", archivistName: "Hallie Mae",
                      archivistPersonName: nil, hosts: [], modelName: "fixture",
                      composeWithModel: false)
            },
            dependencies: .live)
    }

    private func coordinatorResponse(
        _ result: HallieTurnExecutor.Result,
        responderHost: String = "local (no model)"
    ) -> HallieAppTurnCoordinator.Response {
        HallieAppTurnCoordinator.Response(
            result: result,
            responderHost: responderHost, biographyPhoto: nil,
            capturedReferentID: nil, citations: result.citations,
            pendingClarification: nil, playAfterAnswer: false,
            executedIntent: nil)
    }

    private func response(prose: String, basis: String,
                          citing: [(UUID, String)]) -> HallieAppTurnCoordinator.Response {
        let citations = citing.map {
            HallieTurnExecutor.Citation(recordID: $0.0, fullPath: $0.1,
                                        filename: ($0.1 as NSString).lastPathComponent,
                                        playbackSeconds: nil, bases: [])
        }
        return coordinatorResponse(
            HallieTurnExecutor.Result(
                route: .presence, outcome: .answered, prose: prose, basisLine: basis,
                queryDescription: nil, citations: citations, catalogPersonName: nil),
            responderHost: "fixture")
    }

    private func navigationResponse(
        _ destination: HallieAppNavigation.Destination
    ) -> HallieAppTurnCoordinator.Response {
        coordinatorResponse(HallieAppNavigation.answer(destination))
    }

    @Test func oneResponseMergesToItselfFieldForField() throws {
        let id = UUID()
        let only = response(prose: "Born in Sudbury.", basis: "Basis: tree", citing: [(id, "/v/a.mp4")])
        let merged = try #require(HallieWebBridge.merge([only]))
        #expect(merged.prose == "Born in Sudbury.")
        #expect(merged.basis == "Basis: tree")
        #expect(merged.citations == only.citations)
        #expect(merged.attachments.isEmpty)
        #expect(merged.last.responderHost == "fixture")
    }

    @Test func nothingExecutedMergesToNothing() {
        #expect(HallieWebBridge.merge([]) == nil)
    }

    @Test func twoResponsesJoinProseAndUnionCitationsInOrderWithoutDuplicates() throws {
        let shared = UUID()
        let second = UUID()
        let first = response(prose: "Born in Sudbury.", basis: "Basis: tree",
                             citing: [(shared, "/v/a.mp4")])
        let last = response(prose: "Born in 1712.", basis: "Basis: census",
                            citing: [(second, "/v/b.mp4"), (shared, "/v/a.mp4")])
        let merged = try #require(HallieWebBridge.merge([first, last]))
        #expect(merged.prose == "Born in Sudbury.\n\nBorn in 1712.")
        #expect(merged.basis == "Basis: tree\nBasis: census")
        #expect(merged.citations.map(\.recordID) == [shared, second],
                "first clause's evidence first; the repeat is dropped, not re-listed")
        #expect(merged.last.result.prose == "Born in 1712.",
                "chips, play and the pending which-one come from the LAST piece")
    }


    @Test func mergedWebReplyQualifiesNavigationInEitherClauseOrder() throws {
        let ordinary = response(prose: "I found Donna.", basis: "Basis: catalog", citing: [])
        for responses in [
            [navigationResponse(.people), ordinary],
            [ordinary, navigationResponse(.archive)],
        ] {
            let merged = try #require(HallieWebBridge.merge(responses))
            #expect(!merged.prose.contains("Opening"))
            #expect(merged.prose.contains("can only be opened in the VideoScan app on the Mac"))
            #expect(merged.prose.contains("I found Donna."))
        }
    }

    /// Cycle-3 sensor: the outer web splitter can hand `merge` ONE response
    /// whose result was already joined by the coordinator. Sanitizing that
    /// response must replace navigation promises sentence-by-sentence, not
    /// replace the whole result and discard the other clause.
    @MainActor
    @Test func oneJoinedResponsePreservesOtherProseAndQualifiesEveryNavigation() throws {
        let ordinary = response(
            prose: "I found Donna.", basis: "Basis: catalog", citing: []).result
        let peopleOnly =
            "The People tab can only be opened in the VideoScan app on the Mac; this web chat can't control that window."
        let archiveOnly =
            "The Archive tab can only be opened in the VideoScan app on the Mac; this web chat can't control that window."
        let cases: [(HallieTurnExecutor.Result, String)] = [
            (HallieTurnExecutor.joinedTwoQuestionAnswer(
                HallieAppNavigation.answer(.people), ordinary),
             peopleOnly + "\n\nI found Donna."),
            (HallieTurnExecutor.joinedTwoQuestionAnswer(
                ordinary, HallieAppNavigation.answer(.archive)),
             "I found Donna.\n\n" + archiveOnly),
            (HallieTurnExecutor.joinedTwoQuestionAnswer(
                HallieAppNavigation.answer(.people),
                HallieAppNavigation.answer(.archive)),
             peopleOnly + "\n\n" + archiveOnly),
        ]
        let web = bridge()

        for (result, expected) in cases {
            let response = coordinatorResponse(result)
            let merged = try #require(HallieWebBridge.merge([response]))
            #expect(merged.prose == expected)
            #expect(!merged.prose.contains("Opening"))

            let payload = web.payload(for: response, citations: [], merged: merged)
            #expect(payload["prose"] as? String == expected)
            #expect((payload["chips"] as? [[String: Any]])?.isEmpty == true,
                    "neither Mac-only navigation is executable from the web")
        }
    }
}
