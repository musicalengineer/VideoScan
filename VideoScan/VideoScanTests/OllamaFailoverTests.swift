import Foundation
import Testing
@testable import VideoScan

// MARK: - Archivist endpoint failover (2026-08-12)
//
// The Archivist used to point at one hard-coded host — `ricksm5.local`,
// a LAPTOP. Rick hit the obvious failure: it sleeps, leaves the house,
// and runs on battery, so the Archivist hung. The brain moved to the
// mains-powered M4 with the laptop as fallback.
//
// Every test here runs through the `.fake` transport: no network, no
// `.local` resolution, no TCC prompt, and no dependency on which
// machines happen to be awake while the suite runs.
//
// The load-bearing behaviours:
//   * order is honoured, and the first responder wins;
//   * ONLY host-shaped failures fail over — a bad model reply must not
//     walk the whole fleet collecting the same garbage N timeouts deep;
//   * a legacy single-host preference is never silently demoted.
//
// Five-dimension coverage:
//   Logic     — order, retry classification, migration truth table.
//   Isolation — injected UserDefaults suites and a fake transport; no
//               real prefs plist, no real hosts.
//   Sensor    — `badResponseDoesNotWalkTheFleet` pins the retry policy
//               that keeps one bad answer from costing N timeouts.
// Scale / media matrix: N/A — this layer moves one small JSON request.

/// A well-formed ollama chat reply carrying a minimal valid NLQuerySpec.
private let goodReply = """
{"message":{"content":"{\\"people\\":[\\"Donna\\"]}"}}
"""

/// ollama's shape for "this host does not have that model": HTTP 200
/// with an error string in the body.
private let modelMissingReply = """
{"error":"model 'qwen3.6:35b-a3b-nvfp4' not found, try pulling it first"}
"""

/// A reply the model itself botched — valid transport, unusable content.
private let garbageReply = """
{"message":{"content":"I'm sorry, I can't help with that."}}
"""

/// Build a translator whose transport answers per-host from a table, and
/// records the order hosts were dialled in.
private func fakeTranslator(
    hosts: [String],
    responses: [String: OllamaTransportResult],
    dialled: Dialled,
    onResponder: (@Sendable (String) -> Void)? = nil
) -> OllamaFailoverTranslator {
    var template = OllamaQueryTranslator()
    template.transport = .fake { urlString, _ in
        // urlString is "http://<host>:11434/api/{chat,tags}". Failover
        // probes /api/tags first, so the stub answers both: a host whose
        // stubbed CHAT reply is a transport failure is treated as down
        // for the probe too, which is what a sleeping machine looks
        // like. Only the chat call counts as "dialled" — the probe is
        // plumbing, and asserting on it would make every ordering test
        // about probes instead of routing.
        let host = urlString
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: ":").first.map(String.init) ?? ""
        let stub = responses[host] ?? .down("no stub for \(host)")
        if urlString.hasSuffix("/api/tags") {
            return stub.transportError == nil ? .ok("{\"models\":[]}") : stub
        }
        await dialled.record(host)
        return stub
    }
    return OllamaFailoverTranslator(hosts: hosts, template: template, onResponder: onResponder)
}

/// Records dial order across the concurrency boundary the fake crosses.
private actor Dialled {
    private(set) var hosts: [String] = []
    func record(_ h: String) { hosts.append(h) }
    func all() -> [String] { hosts }
}

@Suite("Archivist failover — order and retry policy")
struct OllamaFailoverTests {

    @Test func firstHealthyHostAnswersAndIsReported() async throws {
        let dialled = Dialled()
        let responder = ResponderBox()
        let t = fakeTranslator(
            hosts: ["RicksM4.local", "ricksm5.local"],
            responses: ["RicksM4.local": .ok(goodReply),
                        "ricksm5.local": .ok(goodReply)],
            dialled: dialled,
            onResponder: { host in responder.set(host) }
        )
        _ = try await t.translate("donna 1990s")

        #expect(await dialled.all() == ["RicksM4.local"], "must not dial the fallback")
        #expect(responder.get() == "RicksM4.local")
    }

    /// The whole point: the Studio is asleep, so the laptop answers.
    @Test func fallsOverWhenPrimaryIsDown() async throws {
        let dialled = Dialled()
        let responder = ResponderBox()
        let t = fakeTranslator(
            hosts: ["RicksM4.local", "ricksm5.local"],
            responses: ["RicksM4.local": .down("host is down"),
                        "ricksm5.local": .ok(goodReply)],
            dialled: dialled,
            onResponder: { host in responder.set(host) }
        )
        _ = try await t.translate("donna 1990s")

        // Only the LAPTOP is dialled for generation: the Studio is
        // eliminated by the 3s liveness probe and never costs a 20s
        // generation timeout (codex #314). `dialled` records chat calls
        // only, so a skipped host correctly leaves no entry.
        #expect(await dialled.all() == ["ricksm5.local"])
        #expect(responder.get() == "ricksm5.local",
                "the reported responder must be the host that actually answered")
    }

    @Test func fiveHundredFailsOverButFourHundredDoesNot() async throws {
        let d1 = Dialled()
        let t1 = fakeTranslator(
            hosts: ["a.local", "b.local"],
            responses: ["a.local": .status(503, "unavailable"), "b.local": .ok(goodReply)],
            dialled: d1)
        _ = try await t1.translate("x")
        #expect(await d1.all() == ["a.local", "b.local"], "5xx is a host problem — fail over")

        let d2 = Dialled()
        let t2 = fakeTranslator(
            hosts: ["a.local", "b.local"],
            responses: ["a.local": .status(400, "bad request"), "b.local": .ok(goodReply)],
            dialled: d2)
        await #expect(throws: (any Error).self) { try await t2.translate("x") }
        #expect(await d2.all() == ["a.local"],
                "a malformed request is malformed everywhere — do not walk the fleet")
    }

    /// A host that never pulled the model IS a host problem.
    @Test func modelUnavailableFailsOver() async throws {
        let dialled = Dialled()
        let t = fakeTranslator(
            hosts: ["fresh.local", "loaded.local"],
            responses: ["fresh.local": .ok(modelMissingReply),
                        "loaded.local": .ok(goodReply)],
            dialled: dialled)
        _ = try await t.translate("x")
        #expect(await dialled.all() == ["fresh.local", "loaded.local"])
    }

    /// SENSOR. The model replied with prose instead of the schema. Every
    /// host runs the SAME model, so walking the fleet would spend one
    /// timeout per host to collect identical garbage. Stop at the first.
    @Test func badResponseDoesNotWalkTheFleet() async throws {
        let dialled = Dialled()
        let t = fakeTranslator(
            hosts: ["a.local", "b.local", "c.local"],
            responses: ["a.local": .ok(garbageReply),
                        "b.local": .ok(goodReply),
                        "c.local": .ok(goodReply)],
            dialled: dialled)

        await #expect(throws: (any Error).self) { try await t.translate("x") }
        #expect(await dialled.all() == ["a.local"],
                "a model-shaped failure must not become N host timeouts")
    }

    /// SENSOR for codex #315. A malformed HTTP-200 envelope — an HTML
    /// error page from a proxy, a truncated reply — used to escape as a
    /// raw DecodingError, which the walker could not classify and
    /// therefore retried against every host. The envelope being garbage
    /// is a property of the REPLY, not the host.
    @Test func malformedEnvelopeDoesNotWalkTheFleet() async throws {
        let dialled = Dialled()
        let t = fakeTranslator(
            hosts: ["a.local", "b.local", "c.local"],
            responses: ["a.local": .ok("<html>502 Bad Gateway</html>"),
                        "b.local": .ok(goodReply),
                        "c.local": .ok(goodReply)],
            dialled: dialled)

        await #expect(throws: (any Error).self) { try await t.translate("x") }
        #expect(await dialled.all() == ["a.local"],
                "an unparseable envelope must not become N host timeouts")
    }

    /// When everything is down, the error must name the whole walk — an
    /// error mentioning only the last host hides that the primary was
    /// asleep, which is the thing worth knowing.
    @Test func allHostsDownReportsEveryAttempt() async throws {
        let dialled = Dialled()
        let t = fakeTranslator(
            hosts: ["RicksM4.local", "ricksm5.local"],
            responses: ["RicksM4.local": .down("asleep"),
                        "ricksm5.local": .down("off premises")],
            dialled: dialled)

        do {
            _ = try await t.translate("x")
            Issue.record("expected a throw when every host is down")
        } catch let error as NLTranslatorError {
            let text = error.errorDescription ?? ""
            #expect(text.contains("RicksM4.local"))
            #expect(text.contains("ricksm5.local"))
        }
        // Both eliminated at the probe, so neither reached generation.
        #expect(await dialled.all().isEmpty)
    }

    @Test func retryClassificationTruthTable() {
        #expect(NLTranslatorError.unreachable("x").isRetryableOnAnotherHost)
        #expect(NLTranslatorError.modelUnavailable("x").isRetryableOnAnotherHost)
        #expect(NLTranslatorError.serverError(status: 500, detail: "").isRetryableOnAnotherHost)
        #expect(NLTranslatorError.serverError(status: 503, detail: "").isRetryableOnAnotherHost)
        #expect(!NLTranslatorError.serverError(status: 404, detail: "").isRetryableOnAnotherHost)
        #expect(!NLTranslatorError.badResponse("x").isRetryableOnAnotherHost)
    }
}

/// Box for the responder callback.
///
/// Lock-protected rather than an actor: `onResponder` is SYNCHRONOUS, so
/// hopping into an actor via `Task { }` to record it left the value
/// unset when the test read it a moment later — the assertion raced the
/// hop, not the code under test. A synchronous callback deserves a
/// synchronous sink.
private final class ResponderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Endpoint list + legacy migration

@Suite("Archivist endpoints — order and migration")
struct OllamaEndpointsTests {

    private func suite(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    /// Fresh install: mains-powered Studio first, laptop second.
    @Test func defaultOrderPutsTheStudioFirst() {
        let d = suite()
        #expect(OllamaEndpoints.resolved(from: d) == ["RicksM4.local", "ricksm5.local"])
    }

    /// THE migration rule, corrected after codex #313. A first cut
    /// promoted any legacy host to the front. But no UI ever wrote that
    /// key, so its presence implies nothing — and Rick's 2026-08-12
    /// directive making the M4 master SUPERSEDES whatever it holds. A
    /// custom legacy host is still worth keeping (it names a machine we
    /// would otherwise forget), so it is appended, never promoted.
    @Test func legacyCustomHostIsAppendedNeverPromoted() {
        let d = suite()
        d.set("ricksm1.local", forKey: OllamaEndpoints.legacyHostKey)
        #expect(OllamaEndpoints.resolved(from: d)
                == ["RicksM4.local", "ricksm5.local", "ricksm1.local"])
    }

    /// SENSOR — the regression codex caught. The old default was
    /// ricksm5.local; if that value lingers in the legacy key it must
    /// NOT put the laptop ahead of the Studio, which is the exact
    /// outcome Rick moved the model to avoid.
    @Test func lingeringLegacyM5NeverOutranksTheM4() {
        let d = suite()
        d.set("ricksm5.local", forKey: OllamaEndpoints.legacyHostKey)
        let resolved = OllamaEndpoints.resolved(from: d)
        #expect(resolved == ["RicksM4.local", "ricksm5.local"])
        #expect(resolved.first == "RicksM4.local", "the designated primary must lead")
        #expect(resolved.filter { $0.lowercased() == "ricksm5.local" }.count == 1,
                "no duplicate laptop entry")
    }

    @Test func explicitListWinsOutright() {
        let d = suite()
        d.set("ricksm1.local", forKey: OllamaEndpoints.legacyHostKey)
        OllamaEndpoints.save(["studio.local", "RicksM4.local"], to: d)
        #expect(OllamaEndpoints.resolved(from: d) == ["studio.local", "RicksM4.local"])
    }

    /// An empty list would leave the Archivist nowhere to ask and no way
    /// to tell why, so it falls back rather than returning nothing.
    @Test func emptyOrWipedListFallsBackToDefaults() {
        let d = suite()
        OllamaEndpoints.save([], to: d)
        #expect(OllamaEndpoints.resolved(from: d) == OllamaEndpoints.defaultHosts)

        d.set("   ,  , ", forKey: OllamaEndpoints.hostsKey)
        #expect(OllamaEndpoints.resolved(from: d) == OllamaEndpoints.defaultHosts)
    }

    /// Normalization trims and de-duplicates but PRESERVES scheme and
    /// port. An earlier version stripped both, which quietly destroyed
    /// the cloud case Rick asked for: `https://ollama.example.com`
    /// became `ollama.example.com` and was then dialled over plain http
    /// on port 11434.
    @Test func normalizationPreservesSchemeAndPort() {
        #expect(OllamaEndpoints.normalize("  RicksM4.local/ ") == "RicksM4.local")
        #expect(OllamaEndpoints.normalize("https://ollama.example.com/")
                == "https://ollama.example.com")
        #expect(OllamaEndpoints.normalize("   ") == nil)
        #expect(OllamaEndpoints.parse("a.local\nb.local, a.local") == ["a.local", "b.local"])
    }

    /// The URL rules that make one list serve both local boxes and cloud
    /// servers.
    @Test func chatURLsCoverLocalAndCloud() {
        let url = { OllamaEndpoints.chatURLString(for: $0, defaultPort: 11434) }
        #expect(url("RicksM4.local") == "http://RicksM4.local:11434/api/chat")
        #expect(url("RicksM4.local:1234") == "http://RicksM4.local:1234/api/chat")
        // A TLS endpoint answers on its own front door — appending
        // :11434 to it would break the request.
        #expect(url("https://ollama.example.com") == "https://ollama.example.com/api/chat")
        #expect(url("http://box.lan:9000") == "http://box.lan:9000/api/chat")
    }

    @Test func displayLabelShortensCloudURLs() {
        #expect(OllamaEndpoints.displayLabel(for: "https://ollama.example.com")
                == "ollama.example.com")
        #expect(OllamaEndpoints.displayLabel(for: "RicksM4.local") == "RicksM4.local")
    }

    @Test func saveRoundTripsThroughResolve() {
        let d = suite()
        OllamaEndpoints.save(["one.local", "two.local", "three.local"], to: d)
        #expect(OllamaEndpoints.resolved(from: d) == ["one.local", "two.local", "three.local"])
    }
}


// MARK: - Liveness probe (codex #314)

@Suite("Archivist liveness — probe before generate")
struct OllamaLivenessProbeTests {

    /// THE point of the probe. codex asked for a shorter per-host
    /// timeout so a sleeping primary stops making the app look hung.
    /// Shrinking the single timeout would have been the wrong fix — it
    /// would abort a HEALTHY M4 cold-loading a 21.9 GB model. Two
    /// budgets instead: liveness is a round trip (3s), generation is a
    /// computation (20s), and they are checked separately.
    @Test func probeAndGenerationHaveSeparateBudgets() {
        let t = OllamaQueryTranslator()
        #expect(t.probeTimeoutSeconds < t.timeoutSeconds,
                "liveness must be cheaper than generation")
        #expect(t.probeTimeoutSeconds <= 5, "a dead host must be cheap to discover")
        #expect(t.timeoutSeconds >= 20, "a cold 35B load must not be cut off")
    }

    /// A down host must be skipped on the PROBE — never reaching the
    /// generation request, which is where the long timeout lives.
    @Test func deadPrimaryIsSkippedWithoutASlowGenerationCall() async throws {
        let chatCalls = Dialled()
        var template = OllamaQueryTranslator()
        template.transport = .fake { urlString, _ in
            if urlString.contains("dead.local") { return .down("asleep") }
            if urlString.hasSuffix("/api/tags") { return .ok("{\"models\":[]}") }
            await chatCalls.record("live.local")
            return .ok(goodReply)
        }
        let t = OllamaFailoverTranslator(hosts: ["dead.local", "live.local"], template: template)
        _ = try await t.translate("x")

        #expect(await chatCalls.all() == ["live.local"],
                "the dead host must never reach the generation call")
    }

    /// A host that is UP but whose probe endpoint 500s is still a host
    /// problem — fail over rather than asking it to generate.
    @Test func probeServerErrorFailsOver() async throws {
        let chatCalls = Dialled()
        var template = OllamaQueryTranslator()
        template.transport = .fake { urlString, _ in
            if urlString.contains("sick.local") {
                return urlString.hasSuffix("/api/tags") ? .status(503) : .ok(goodReply)
            }
            if urlString.hasSuffix("/api/tags") { return .ok("{\"models\":[]}") }
            await chatCalls.record("ok.local")
            return .ok(goodReply)
        }
        let t = OllamaFailoverTranslator(hosts: ["sick.local", "ok.local"], template: template)
        _ = try await t.translate("x")
        #expect(await chatCalls.all() == ["ok.local"])
    }

    /// The probe must be skippable: with one host and no fallback the
    /// extra round trip buys nothing.
    @Test func probeCanBeDisabled() async throws {
        let chatCalls = Dialled()
        var template = OllamaQueryTranslator()
        template.transport = .fake { urlString, _ in
            if urlString.hasSuffix("/api/tags") { return .down("probe should not run") }
            await chatCalls.record("solo.local")
            return .ok(goodReply)
        }
        var t = OllamaFailoverTranslator(hosts: ["solo.local"], template: template)
        t.probeBeforeRequest = false
        _ = try await t.translate("x")
        #expect(await chatCalls.all() == ["solo.local"])
    }

    /// The settings light and the router must not drift: both ask the
    /// same `/api/tags` question of the same endpoint.
    @Test func probeURLMatchesTheChatEndpointsHost() {
        let tags = { OllamaEndpoints.tagsURLString(for: $0, defaultPort: 11434) }
        #expect(tags("RicksM4.local") == "http://RicksM4.local:11434/api/tags")
        #expect(tags("https://ollama.example.com") == "https://ollama.example.com/api/tags")
        #expect(tags("box.lan:9000") == "http://box.lan:9000/api/tags")
    }
}
