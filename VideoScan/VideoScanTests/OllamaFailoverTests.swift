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
        // urlString is "http://<host>:11434/api/chat"
        let host = urlString
            .replacingOccurrences(of: "http://", with: "")
            .split(separator: ":").first.map(String.init) ?? ""
        await dialled.record(host)
        return responses[host] ?? .down("no stub for \(host)")
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
            onResponder: { host in Task { await responder.set(host) } }
        )
        _ = try await t.translate("donna 1990s")

        #expect(await dialled.all() == ["RicksM4.local"], "must not dial the fallback")
        #expect(await responder.get() == "RicksM4.local")
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
            onResponder: { host in Task { await responder.set(host) } }
        )
        _ = try await t.translate("donna 1990s")

        #expect(await dialled.all() == ["RicksM4.local", "ricksm5.local"])
        #expect(await responder.get() == "ricksm5.local",
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
        #expect(await dialled.all().count == 2)
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

/// Box for the responder callback, which fires off-actor.
private actor ResponderBox {
    private var value: String?
    func set(_ v: String) { value = v }
    func get() -> String? { value }
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

    /// THE migration rule. `@AppStorage` does not persist a default until
    /// the user changes it, so the presence of the legacy key means
    /// someone deliberately chose that host. A deliberate choice must
    /// not be demoted by a new default — it goes to the FRONT.
    @Test func legacyHostMigratesToTheFrontNotTheBack() {
        let d = suite()
        d.set("ricksm1.local", forKey: OllamaEndpoints.legacyHostKey)
        #expect(OllamaEndpoints.resolved(from: d)
                == ["ricksm1.local", "RicksM4.local", "ricksm5.local"])
    }

    /// A legacy host that is already a default must not appear twice.
    @Test func legacyHostAlreadyInDefaultsIsNotDuplicated() {
        let d = suite()
        d.set("ricksm5.local", forKey: OllamaEndpoints.legacyHostKey)
        #expect(OllamaEndpoints.resolved(from: d) == ["ricksm5.local", "RicksM4.local"])
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

    /// Hand-edited values are forgiving: schemes, ports, trailing
    /// slashes, newlines, and duplicates all get cleaned up. A pasted
    /// "http://host:11434" would otherwise become part of the hostname
    /// and never resolve.
    @Test func hostStringsAreNormalized() {
        #expect(OllamaEndpoints.normalize("  http://RicksM4.local:11434/ ") == "RicksM4.local")
        #expect(OllamaEndpoints.normalize("https://x.local") == "x.local")
        #expect(OllamaEndpoints.normalize("   ") == nil)
        #expect(OllamaEndpoints.parse("a.local\nb.local, a.local") == ["a.local", "b.local"])
    }

    @Test func saveRoundTripsThroughResolve() {
        let d = suite()
        OllamaEndpoints.save(["one.local", "two.local", "three.local"], to: d)
        #expect(OllamaEndpoints.resolved(from: d) == ["one.local", "two.local", "three.local"])
    }
}
