import Foundation
import Synchronization
import Testing
@testable import VideoScan

// MARK: - The Local brain's data-class gate (GH #450)
//
// The host list in Settings ▸ Hallie accepts a full URL, so a row can name a
// cloud Ollama (`https://ollama.example.com`). That row runs under
// Provider = Local, and before #450 the Local brain ignored `dataClass`:
// a familyMedia plan (transcript / caption claims) could be phrased by a
// server outside the house. Rule 13 and DECISIONS 2026-10-10 (R6: the
// data-class policy is enforced in the ADAPTER) say it never leaves.
//
// "Local" here means THIS Mac: loopback or one of this Mac's own names —
// never a host the URL merely spells (`https://…`, `localhost@evil`, a
// `localhost.` look-alike). familyText and public may still go to any
// listed host, exactly as they may go to the Cloud brain.
//
// Five dimensions:
//   Logic     — the locality truth table; the per-class routing.
//   Isolation — a fake transport and injected host names; nothing dials,
//               and the answer never depends on which Mac runs the suite.
//   Sensor    — familyMediaNeverDialsAnHTTPSHost is the canary: the fake
//               transport records every URL, and a familyMedia compose to
//               a non-local host must record none.
// Scale / media matrix: N/A — one small request, no media.

/// Records every URL the fake transport is asked for, probes included.
private actor Dialled {
    private(set) var urls: [String] = []
    func record(_ u: String) { urls.append(u) }
    func all() -> [String] { urls }
}

private let composedReply = #"{"message":{"content":"Donna was there."}}"#

private func gatedBrain(hosts: [String], dialled: Dialled,
                        thisMac: Set<String>? = nil) -> OllamaFailoverTranslator {
    var template = OllamaQueryTranslator()
    template.transport = .fake { urlString, _ in
        await dialled.record(urlString)
        if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
        return .ok(composedReply)
    }
    var brain = OllamaFailoverTranslator(hosts: hosts, template: template)
    brain.connectionRetryDelay = .zero
    if let thisMac { brain.thisMacNames = thisMac }
    return brain
}

@Suite("Hallie Local brain — data-class gate (GH #450)")
struct HallieLocalBrainGateTests {

    @Test("familyMedia compose to an https host is refused and nothing is dialled")
    func familyMediaNeverDialsAnHTTPSHost() async {
        let dialled = Dialled()
        let brain = gatedBrain(hosts: ["https://ollama.example.com"], dialled: dialled)
        await #expect(throws: HallieBrainError.self) {
            _ = try await brain.composePlainText(system: "s", user: "transcript: we're at the cape",
                                                 dataClass: .familyMedia)
        }
        #expect(await dialled.all().isEmpty, "a familyMedia compose must not reach a non-local host at all")
    }

    @Test("familyMedia compose skips the cloud row and is answered by this Mac")
    func familyMediaGoesOnlyToThisMac() async throws {
        let dialled = Dialled()
        let brain = gatedBrain(hosts: ["https://ollama.example.com", "127.0.0.1:11434"], dialled: dialled)
        let text = try await brain.composePlainText(system: "s", user: "u", dataClass: .familyMedia)
        #expect(text == "Donna was there.")
        let urls = await dialled.all()
        #expect(!urls.isEmpty)
        #expect(urls.allSatisfy { $0.hasPrefix("http://127.0.0.1:11434/") }, "\(urls)")
    }

    @Test("familyText and public may go to a listed remote host, as they may go to Cloud")
    func familyTextAndPublicFollowTheListedOrder() async throws {
        for dataClass in [HallieDataClass.familyText, .public] {
            let dialled = Dialled()
            let brain = gatedBrain(hosts: ["https://ollama.example.com"], dialled: dialled)
            let text = try await brain.composePlainText(system: "s", user: "u", dataClass: dataClass)
            #expect(text == "Donna was there.")
            #expect(await dialled.all().contains("https://ollama.example.com/api/chat"), "\(dataClass)")
        }
    }
    @Test("locality truth table: only loopback and this Mac's own names are local")
    func localityTruthTable() {
        let names: Set<String> = ["localhost", "127.0.0.1", "::1", "ricksultra", "ricksultra.local"]
        let local = ["127.0.0.1:11434", "localhost", "http://localhost:11434", "[::1]:11434",
                     "RicksUltra.local", "http://RicksUltra.local:11434", "RicksUltra.local.", "127.0.0.2"]
        let remote = ["https://ollama.example.com", "http://ollama.example.com:11434", "ollama.example.com",
                      "http://localhost@evil.example", "localhost.example.com", "https://ricksultra.example.com",
                      "RicksM4.local", "192.168.1.20", ""]
        for e in local { #expect(OllamaEndpoints.isOnThisMac(e, thisMacNames: names), "\(e) is this Mac") }
        for e in remote { #expect(!OllamaEndpoints.isOnThisMac(e, thisMacNames: names), "\(e) is not this Mac") }
    }

    /// Codex #450 round 1: `[0:0:0:0:0:0:0:1]` is `::1`, but a string
    /// compare refused it, breaking the local brain. IP literals are now
    /// compared as ADDRESSES (inet_pton): 127/8, ::1 and IPv4-mapped
    /// ::ffff:127/8 are loopback. Shorthand IPv4 (`127.1`, `2130706433`)
    /// is not an inet_pton address, so it stays refused — fail closed.
    @Test("every spelling of a loopback address is this Mac; other addresses are not")
    func loopbackAddressSpellings() {
        let names: Set<String> = ["localhost", "127.0.0.1", "::1"]   // the production base set
        let local = ["[0:0:0:0:0:0:0:1]:11434", "http://[0:0:0:0:0:0:0:1]:11434", "[::1]",
                     "http://[::1]:11434", "[0000:0000:0000:0000:0000:0000:0000:0001]", "127.0.0.2",
                     "http://127.255.255.254:11434", "[::ffff:127.0.0.1]:11434",
                     "http://[0:0:0:0:0:ffff:7f00:1]:11434"]
        let remote = ["[::2]", "[::]", "0.0.0.0", "[::ffff:192.168.1.20]", "10.0.0.1", "128.0.0.1",
                      "[fe80::1]", "126.255.255.255", "127.0.0.1.evil.example", "http://127.0.0.1@evil.example",
                      "127.1", "2130706433"]
        for e in local { #expect(OllamaEndpoints.isOnThisMac(e, thisMacNames: names), "\(e) is this Mac") }
        for e in remote { #expect(!OllamaEndpoints.isOnThisMac(e, thisMacNames: names), "\(e) is not this Mac") }
    }

    /// Codex #450 round 1: the gate checked only the FIRST URL, and the
    /// session followed redirects — this Mac's /api/chat answering 307 to a
    /// remote host would have carried the family-media POST (307 keeps the
    /// method and body) off the Mac. Driven through the PRODUCTION
    /// transport (`.urlSession` on the session `OllamaHTTP.makeSession`
    /// builds) with a URLProtocol stub standing in for the network.
    @Test("a 307 from this Mac's /api/chat to a remote host is never followed: zero requests reach it")
    func familyMediaRedirectOffThisMacIsRefused() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RedirectingOllamaStub.self]
        var template = OllamaQueryTranslator()
        template.session = OllamaHTTP.makeSession(configuration: config)
        template.timeoutSeconds = 5
        template.probeTimeoutSeconds = 5
        var brain = OllamaFailoverTranslator(hosts: ["127.0.0.1:11434"], template: template)
        brain.thisMacNames = ["127.0.0.1"]
        brain.connectionRetryDelay = .zero
        await #expect(throws: (any Error).self, "the call fails closed") {
            _ = try await brain.composePlainText(system: "s", user: "MARKER-450 transcript: we're at the cape",
                                                 dataClass: .familyMedia)
        }
        let seen = RedirectingOllamaStub.seen.withLock { $0 }
        #expect(seen.contains("http://127.0.0.1:11434/api/chat"), "the stub saw the chat request: \(seen)")
        #expect(!seen.contains { $0.contains(RedirectingOllamaStub.remoteHost) },
                "no request may reach the redirect's destination: \(seen)")
    }

    @Test("a fleet Mac row is not this Mac: familyMedia goes only to the Mac running the app")
    func anotherMacOnTheLANIsNotLocal() async throws {
        let dialled = Dialled()
        let brain = gatedBrain(hosts: ["RicksM4.local", "RicksUltra.local"], dialled: dialled,
                               thisMac: ["localhost", "127.0.0.1", "::1", "ricksultra", "ricksultra.local"])
        _ = try await brain.composePlainText(system: "s", user: "u", dataClass: .familyMedia)
        let urls = await dialled.all()
        #expect(!urls.isEmpty && urls.allSatisfy { $0.contains("RicksUltra.local") }, "\(urls)")

        let refused = Dialled()
        let offMac = gatedBrain(hosts: ["RicksM4.local"], dialled: refused, thisMac: ["localhost", "127.0.0.1"])
        await #expect(throws: HallieBrainError.self) {
            _ = try await offMac.composePlainText(system: "s", user: "u", dataClass: .familyMedia)
        }
        #expect(await refused.all().isEmpty)
    }

    @Test("an empty host list falls back to the template host, and the gate still applies to it")
    func emptyHostListUsesTheGatedTemplateHost() async {
        let dialled = Dialled()
        var brain = gatedBrain(hosts: [], dialled: dialled, thisMac: ["127.0.0.1"])
        brain.template.host = "https://ollama.example.com"
        await #expect(throws: HallieBrainError.self) {
            _ = try await brain.composePlainText(system: "s", user: "u", dataClass: .familyMedia)
        }
        #expect(await dialled.all().isEmpty)
    }

    @Test("any history makes a compose familyMedia; Cloud's stripped history leaves the class alone")
    func historyCarriesTheMediaClass() {
        let turn = HallieGroundedComposer.HistoryTurn(user: "who was at the cape?",
                                                      assistant: "The transcript opens: we're at the cape")
        #expect(HallieBrainHistoryPolicy.dataClass(.familyText, carrying: []) == .familyText)
        #expect(HallieBrainHistoryPolicy.dataClass(.public, carrying: []) == .public)
        #expect(HallieBrainHistoryPolicy.dataClass(.familyText, carrying: [turn]) == .familyMedia)
        #expect(HallieBrainHistoryPolicy.dataClass(.familyMedia, carrying: []) == .familyMedia)
        let cloud = HallieBrainHistoryPolicy.history([turn], for: .cloud)
        #expect(HallieBrainHistoryPolicy.dataClass(.familyText, carrying: cloud) == .familyText)
    }
}

/// Stands in for an Ollama on this Mac whose /api/chat redirects off it.
/// Records the URL of every request started, including any redirected one.
private final class RedirectingOllamaStub: URLProtocol {
    static let remoteHost = "remote-450.example"
    static let seen = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.seen.withLock { $0.append(url.absoluteString) }
        if url.host == Self.remoteHost || url.path == "/api/tags" {
            let body = url.path == "/api/tags" ? #"{"models":[]}"# : composedReply
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: ok, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let target = "https://\(Self.remoteHost)/api/chat"
        let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target])!
        var next = request
        next.url = URL(string: target)
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        // A refused redirect leaves the 307 as the final response.
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
