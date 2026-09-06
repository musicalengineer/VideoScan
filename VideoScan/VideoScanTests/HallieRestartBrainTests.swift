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

    /// `keep_alive: 0` is ollama's unload signal; without it "restart" would
    /// reload nothing and a wedged model would stay wedged.
    @Test func unloadingSendsKeepAliveZeroAndSwallowsFailure() async {
        actor Seen { var bodies: [String] = []; func add(_ s: String) { bodies.append(s) } }
        let seen = Seen()
        let t = translator { _, body in
            await seen.add(String(data: body, encoding: .utf8) ?? "")
            return .down("gone")
        }
        await t.unloadModel()   // must not throw
        let bodies = await seen.bodies
        #expect(bodies.contains { $0.contains("keep_alive") },
                Comment(rawValue: bodies.joined(separator: " | ").prefix(300).description))
    }
}
