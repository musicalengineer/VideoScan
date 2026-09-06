import Foundation
import Testing
@testable import VideoScan

/// The Restart button in Archivist Brain settings (Rick, 2026-09-06).
///
/// The failure it exists for: Homebrew ollama ships without
/// `libollama_xgrammar.dylib`, so its MLX runner answers every
/// schema-bearing request with HTTP 501. Hallie recovers by dropping the
/// schema — and `OllamaStructuredOutputCapability` memoizes that refusal for
/// the life of the PROCESS, on purpose, so one bad host does not cost a
/// doomed round trip every turn. The consequence Rick hit: fixing ollama did
/// not help, because VideoScan had already stopped asking. Relaunching the
/// app was the only cure. These pin the pieces that make a button the cure
/// instead.
@Suite("Restarting the brain")
struct HallieRestartBrainTests {

    // MARK: forgetting the latch

    @Test func forgettingAnEndpointMakesTheTranslatorWillingToAskAgain() async {
        let capability = OllamaStructuredOutputCapability()
        let endpoint = "http://127.0.0.1:11434/api/chat"
        #expect(!(await capability.isUnsupported(endpoint)))
        await capability.recordUnsupported(endpoint)
        #expect(await capability.isUnsupported(endpoint))
        await capability.forget(endpoint)
        #expect(!(await capability.isUnsupported(endpoint)),
                "a restart must undo the memo, or the button changes nothing")
    }

    /// Keyed by endpoint, not host: the same machine can serve two builds on
    /// two ports and forgetting one must not clear the other.
    @Test func forgettingOneEndpointLeavesTheOtherAlone() async {
        let capability = OllamaStructuredOutputCapability()
        let good = "http://127.0.0.1:11434/api/chat"
        let other = "http://127.0.0.1:11435/api/chat"
        await capability.recordUnsupported(good)
        await capability.recordUnsupported(other)
        await capability.forget(good)
        #expect(!(await capability.isUnsupported(good)))
        #expect(await capability.isUnsupported(other))
    }

    // MARK: the probe that tells the truth after a restart

    private func translator(
        _ handler: @escaping @Sendable (String, Data) async -> OllamaTransportResult
    ) -> OllamaQueryTranslator {
        var t = OllamaQueryTranslator()
        t.host = "127.0.0.1"
        t.transport = .fake(handler)
        return t
    }

    @Test func aServerThatCanConstrainOutputProbesAvailable() async {
        let t = translator { _, _ in
            .ok(#"{"message":{"content":"{\"ok\":true}"}}"#)
        }
        #expect(await t.structuredOutputProbe() == .available)
    }

    /// codex #1141: answering is not the same as OBEYING. A host that
    /// accepts `format:` and then replies with prose has not demonstrated
    /// enforcement, and reporting that to Rick as working would send him
    /// back to a server that is still ignoring the schema.
    @Test func aReplyThatIgnoresTheSchemaIsUnverifiedNotAvailable() async {
        let prose = translator { _, _ in
            .ok(#"{"message":{"content":"Sure! ok is true."}}"#)
        }
        #expect(await prose.structuredOutputProbe() == .unverified)
    }

    /// The live shape that motivated it: a thinking model leaking preamble
    /// ahead of otherwise-valid JSON. Enforcement means the reply IS the
    /// object, not that one can be found inside it.
    @Test func jsonBuriedAfterPreambleIsUnverified() async {
        let leaky = translator { _, _ in
            .ok(#"{"message":{"content":" true.{\n  \"ok\": true\n}"}}"#)
        }
        #expect(await leaky.structuredOutputProbe() == .unverified)
    }

    /// Right shape, wrong type: `ok` must be a boolean.
    @Test func aWrongTypedFieldIsUnverified() async {
        let wrong = translator { _, _ in
            .ok(#"{"message":{"content":"{\"ok\":\"yes\"}"}}"#)
        }
        #expect(await wrong.structuredOutputProbe() == .unverified)
    }

    /// The live shape: HTTP 501 with ollama's own wording.
    @Test func aServerWithoutXgrammarProbesRefused() async {
        let t = translator { _, _ in
            .status(501, #"{"error":"structured output is unavailable"}"#)
        }
        #expect(await t.structuredOutputProbe() == .refused)
    }

    @Test func aDeadServerProbesUnreachableNotRefused() async {
        let t = translator { _, _ in .down("connection refused") }
        #expect(await t.structuredOutputProbe() == .unreachable,
                "a dead host must not be reported as a build problem")
    }

    /// The probe must ask independently of the memo — that is the entire
    /// point of pressing Restart. A translator whose capability cache says
    /// "unsupported" must still send a schema when probed.
    @Test func theProbeIgnoresARememberedRefusal() async {
        let capability = OllamaStructuredOutputCapability()
        var t = translator { url, body in
            #expect(url.hasSuffix("/api/chat"))
            // The probe must actually carry a schema, or it proves nothing.
            let sent = String(data: body, encoding: .utf8) ?? ""
            #expect(sent.contains("format"), Comment(rawValue: sent.prefix(300).description))
            return .ok(#"{"message":{"content":"{\"ok\":true}"}}"#)
        }
        t.structuredOutputCapability = capability
        await capability.recordUnsupported(
            OllamaEndpoints.chatURLString(for: "127.0.0.1", defaultPort: 11434))
        #expect(await t.structuredOutputProbe() == .available)
    }

    // MARK: unloading

    /// `keep_alive: 0` is ollama's unload signal — at the ROOT of the
    /// payload. A nested one under `options` is ignored.
    ///
    /// THIS TEST USED TO BE UNABLE TO FAIL (codex #1141). It asserted that
    /// the body contained the substring "keep_alive", which is true of every
    /// request the translator has ever sent — `sendChatRequest` hardcodes
    /// `"keep_alive": "30m"` to keep the model resident between turns. So it
    /// passed against a shipped `unloadModel` that evicted nothing while the
    /// settings pane cheerfully reported the model reloaded. It now decodes
    /// the body and pins the actual value, which is the only version of this
    /// assertion worth having.
    @Test func unloadingSendsRootKeepAliveZeroWithNoMessages() async throws {
        actor Seen { var bodies: [Data] = []; func add(_ d: Data) { bodies.append(d) } }
        let seen = Seen()
        let t = translator { _, body in
            await seen.add(body)
            return .down("gone")
        }
        await t.unloadModel()   // must not throw

        let bodies = await seen.bodies
        let payload = try #require(
            bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.first)

        // The root value, numerically zero — not "30m", not a string.
        let keepAlive = try #require(payload["keep_alive"])
        #expect((keepAlive as? NSNumber)?.doubleValue == 0,
                Comment(rawValue: "root keep_alive was \(keepAlive)"))

        // And NOT smuggled into options, where ollama would ignore it.
        let options = payload["options"] as? [String: Any] ?? [:]
        #expect(options["keep_alive"] == nil,
                "a nested keep_alive is ignored by ollama and must not stand in for the root one")

        // Empty messages: an unload must not generate first.
        let messages = try #require(payload["messages"] as? [Any])
        #expect(messages.isEmpty, Comment(rawValue: "\(messages.count) messages sent with the unload"))
    }

    /// The counterpart: an ORDINARY request must still keep the model
    /// resident. The unload override must not leak into normal turns.
    @Test func anOrdinaryRequestStillKeepsTheModelResident() async throws {
        actor Seen { var bodies: [Data] = []; func add(_ d: Data) { bodies.append(d) } }
        let seen = Seen()
        let t = translator { _, body in
            await seen.add(body)
            return .ok(#"{"message":{"content":"{\"ok\":true}"}}"#)
        }
        _ = await t.structuredOutputProbe()
        let payload = try #require(
            (await seen.bodies).compactMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }.first)
        #expect(payload["keep_alive"] as? String == "30m")
        #expect((payload["messages"] as? [Any])?.isEmpty == false)
    }
}
