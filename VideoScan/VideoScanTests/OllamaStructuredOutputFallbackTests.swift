import Foundation
import Testing
@testable import VideoScan

// MARK: - Structured output missing from the host's ollama BUILD (2026-09-03)
//
// THE INCIDENT. Hallie could not answer a single question on Rick's M4,
// two days before a family demo. Homebrew ollama 0.33.2's MLX runner
// ships without `libollama_xgrammar.dylib`; the server says so once at
// startup —
//
//   "Structured output is unavailable — xgrammar library not found at
//    …/mlx_metal_v3/libollama_xgrammar.dylib"
//
// — and thereafter answers HTTP 501 to any `/api/chat` carrying a
// `format` key. Every schema-constrained translation is exactly that, so
// every turn failed. 0.33.2 IS current stable: there was no upgrade out.
//
// WHAT MADE IT HARD TO SEE. The refusal was landing in `.modelUnavailable`
// (the fleet reports its LAST error, and the walk ended on a host that
// genuinely lacked the model), so videoscan.log read
// `[hallie] interpretation failed reason=model-unavailable` while the
// model sat loaded and answered plain requests in under a second.
//
// THE FIX UNDER TEST, in three parts:
//   1. one same-host retry with `format:` omitted (`think:false` and the
//      strict decoder unchanged — nothing is loosened);
//   2. a per-endpoint, process-lifetime, memory-only capability memo so
//      later turns skip the doomed ~700 ms round trip;
//   3. an honest classification that names the host and the build.
//
// Five-dimension coverage:
//   Logic     — fallback fires, classification, ordering vs missing-model.
//   Isolation — every test injects its OWN capability memo and a fake
//               transport; nothing touches `.shared`, the network, or
//               real prefs. A poisoned memo is proven not to survive.
//   Sensor    — `sensorFallbackYieldsADecodableASTFromARealisticReply`
//               pins that the unconstrained path still produces a usable
//               AST, and `regressionFourOhFourStillFailsOver` pins that
//               the missing-model failover (codex #320.2) is untouched.
//   Scale / media matrix: N/A — one small JSON request, no media, no
//               record iteration.

/// Ollama 0.33.2's verbatim refusal body.
private let structuredOutputRefusal = #"{"error":"structured output is unavailable"}"#

/// A well-formed chat reply carrying a minimal valid NLQuerySpec.
private let goodSpecReply = """
{"message":{"content":"{\\"people\\":[\\"Donna\\"],\\"keywords\\":[],\\"transcript\\":[],\\"intent\\":\\"filter\\"}"}}
"""

/// What the model actually returns when asked WITHOUT a schema: clean
/// JSON, no ``` fences, no `</think>` leakage (verified against the live
/// host, all three of Rick's models being MLX).
private let unconstrainedASTReply = """
{"message":{"content":"{\\"shape\\":\\"presence\\",\\"payload\\":{\\"people\\":[\\"Donna\\"],\\"yearStart\\":1994,\\"yearEnd\\":1994}}"}}
"""

/// Records every chat request: which host, and whether it carried a schema.
private actor ChatCalls {
    struct Call: Sendable, Equatable {
        var host: String
        var carriedFormat: Bool
    }
    private(set) var calls: [Call] = []
    func record(_ call: Call) { calls.append(call) }
    var hosts: [String] { calls.map(\.host) }
    var formatFlags: [Bool] { calls.map(\.carriedFormat) }
}

private func hostComponent(of urlString: String) -> String {
    URL(string: urlString)?.host ?? urlString
}

private func carriesFormatKey(_ body: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else { return false }
    return object["format"] != nil
}

/// A translator whose transport refuses schema-bearing chat requests the
/// way ollama 0.33.2 does, and answers unconstrained ones normally.
/// `refusingHosts` empty means "every host refuses".
private func translatorRefusingStructuredOutput(
    host: String = "ricksm4.local",
    refusingHosts: Set<String> = [],
    reply: String = unconstrainedASTReply,
    refusalBody: String = structuredOutputRefusal,
    refusalStatus: Int = 501,
    calls: ChatCalls,
    memo: OllamaStructuredOutputCapability
) -> OllamaQueryTranslator {
    var t = OllamaQueryTranslator()
    t.host = host
    t.structuredOutputCapability = memo
    t.transport = .fake { urlString, body in
        if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
        let host = hostComponent(of: urlString)
        let carriedFormat = carriesFormatKey(body)
        await calls.record(.init(host: host, carriedFormat: carriedFormat))
        let refuses = refusingHosts.isEmpty || refusingHosts.contains(host)
        if carriedFormat && refuses { return .status(refusalStatus, refusalBody) }
        return .ok(reply)
    }
    return t
}

@Suite("Hallie — ollama build without structured output")
struct OllamaStructuredOutputFallbackTests {

    // MARK: Logic — the fallback itself

    /// The headline repro: 501 + that body, on the FIRST schema-bearing
    /// request, must not end the turn. Ask again without `format:` and
    /// let the existing strict decoder judge the reply.
    @Test func refusalFallsBackOnTheSameHostAndSucceeds() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        let t = translatorRefusingStructuredOutput(calls: calls, memo: memo)

        let ast = try await t.translateAST("show me Donna in 1994")

        guard case .presence(let payload) = ast else {
            Issue.record("expected a presence AST, got \(ast)")
            return
        }
        #expect(payload.people == ["Donna"])
        #expect(await calls.formatFlags == [true, false],
                "exactly one schema attempt, then exactly one unconstrained retry")
    }

    /// The same recovery must cover every schema-constrained entry point,
    /// not just the one I happened to test — v1 translate and the turn
    /// interpreter go through the identical machinery.
    @Test func fallbackCoversTheV1TranslatorToo() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        let t = translatorRefusingStructuredOutput(
            reply: goodSpecReply, calls: calls, memo: memo)

        let spec = try await t.translate("anything with Donna")

        #expect(spec.people == ["Donna"])
        #expect(await calls.formatFlags == [true, false])
    }

    /// Plain-text composition never sent a schema, so it never hit this
    /// bug — and must not grow a pointless extra round trip from the fix.
    @Test func unconstrainedCallersAreUnaffected() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        let t = translatorRefusingStructuredOutput(
            reply: #"{"message":{"content":"Donna was there."}}"#,
            calls: calls, memo: memo)

        let text = try await t.composePlainText(system: "s", user: "u")

        #expect(text == "Donna was there.")
        #expect(await calls.formatFlags == [false], "one request, no schema")
        #expect(await memo.isUnsupported(
            OllamaEndpoints.chatURLString(for: "ricksm4.local", defaultPort: 11434)) == false,
            "a call that never sent a schema learns nothing about the capability")
    }

    /// The retry drops ONLY `format`. `think:false` is what keeps a
    /// reasoning model from spending its whole budget thinking, and
    /// dropping it here would trade one broken turn for a slower one.
    @Test func theRetryKeepsThinkFalseAndTheBoundedContext() async throws {
        let bodies = FakeBodies()
        let memo = OllamaStructuredOutputCapability()
        var t = OllamaQueryTranslator()
        t.structuredOutputCapability = memo
        t.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            await bodies.record(body)
            return carriesFormatKey(body)
                ? .status(501, structuredOutputRefusal)
                : .ok(unconstrainedASTReply)
        }

        _ = try await t.translateAST("show me Donna in 1994")

        let retry = try #require(await bodies.all.last)
        let object = try #require(
            try JSONSerialization.jsonObject(with: retry) as? [String: Any])
        #expect(object["format"] == nil)
        #expect(object["think"] as? Bool == false)
        #expect(object["stream"] as? Bool == false)
        let options = try #require(object["options"] as? [String: Any])
        #expect(options["num_ctx"] as? Int == OllamaQueryTranslator.defaultContextTokens)
    }

    /// REGRESSION SENSOR (2026-09-03, ruling on the repair-hint branch).
    /// A prose "emit every key an example shows" suffix was appended to the
    /// system prompt on the schema-dropped retry only. It was pulled before
    /// merge: it claimed "every example below" when the AST prompt's
    /// presence examples show DIFFERENT optional fields, so a model reading
    /// it literally could take "emit every key an example shows" as license
    /// to fill in optional fields nobody asked for — and the live check on
    /// that branch proved it did not even help the thing it was for (the
    /// model repeated the same invalid field with or without it). The
    /// dropped-schema retry must therefore send the IDENTICAL system prompt
    /// as the schema-bearing attempt — dropping `format:` changes only
    /// what's negotiated with the server, never what the model is told.
    @Test func droppingTheSchemaNeverAltersTheSystemPrompt() async throws {
        let bodies = FakeBodies()
        let memo = OllamaStructuredOutputCapability()
        var t = OllamaQueryTranslator()
        t.structuredOutputCapability = memo
        t.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            await bodies.record(body)
            return carriesFormatKey(body)
                ? .status(501, structuredOutputRefusal)
                : .ok(unconstrainedASTReply)
        }

        _ = try await t.translateAST("show me Donna in 1994")

        let sent = await bodies.all
        try #require(sent.count == 2)
        func systemContent(_ body: Data) throws -> String {
            let object = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(object["messages"] as? [[String: Any]])
            return try #require(messages.first?["content"] as? String)
        }
        let firstSystem = try systemContent(sent[0])
        let retrySystem = try systemContent(sent[1])
        #expect(firstSystem == retrySystem,
                "dropping the schema must not change a single byte of the system prompt")
    }

    /// A schema-less reply that the strict decoder refuses is STILL a
    /// failure. The fallback buys another attempt, never a lower bar.
    @Test func fallbackDoesNotLowerTheDecodingBar() async {
        let memo = OllamaStructuredOutputCapability()
        var t = OllamaQueryTranslator()
        t.structuredOutputCapability = memo
        t.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            return carriesFormatKey(body)
                ? .status(501, structuredOutputRefusal)
                : .ok(#"{"message":{"content":"I'm sorry, I can't help with that."}}"#)
        }

        await #expect(throws: NLTranslatorError.self) {
            _ = try await t.translateAST("show me Donna in 1994")
        }
    }

    // MARK: Isolation — the capability memo

    /// Cost, not correctness: after the first discovery every later turn
    /// must skip the refused round trip. Rick would feel three extra
    /// prefills a question.
    @Test func laterTurnsSkipTheDoomedRoundTrip() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        let t = translatorRefusingStructuredOutput(calls: calls, memo: memo)

        for _ in 0..<3 { _ = try await t.translateAST("show me Donna in 1994") }

        #expect(await calls.formatFlags == [true, false, false, false],
                "one refused schema attempt ever; turns 2 and 3 go straight out unconstrained")
    }

    /// A capability learned about one machine says nothing about another.
    /// Rick's fleet is heterogeneous — the M5 Ultra arriving this month
    /// will not be running the same Homebrew build as the M4.
    @Test func theMemoIsPerHostAndDoesNotLeak() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        var broken = translatorRefusingStructuredOutput(
            host: "broken.local", refusingHosts: ["broken.local"],
            calls: calls, memo: memo)
        broken.host = "broken.local"
        var healthy = broken
        healthy.host = "healthy.local"

        _ = try await broken.translateAST("show me Donna in 1994")
        _ = try await healthy.translateAST("show me Donna in 1994")

        #expect(await calls.calls == [
            .init(host: "broken.local", carriedFormat: true),
            .init(host: "broken.local", carriedFormat: false),
            .init(host: "healthy.local", carriedFormat: true),
        ], "the healthy host must still be offered a schema")
    }

    /// The same machine can serve two ollama builds on two ports. The
    /// memo is keyed by endpoint, so one port's answer is not attributed
    /// to the other.
    @Test func theMemoIsKeyedByEndpointNotByBareHostname() async {
        let memo = OllamaStructuredOutputCapability()
        let a = OllamaEndpoints.chatURLString(for: "box.local", defaultPort: 11434)
        let b = OllamaEndpoints.chatURLString(for: "box.local:9000", defaultPort: 11434)
        #expect(a != b)
        await memo.recordUnsupported(a)
        #expect(await memo.isUnsupported(a))
        #expect(await memo.isUnsupported(b) == false)
    }

    /// POISONED STATE. A memo asserting "unsupported" for a host that in
    /// fact supports structured output must not be able to disable it
    /// forever: the memo is memory-only, so a fresh instance — which is
    /// what a fresh process gets — re-probes and uses the schema again.
    /// This is the guarantee that makes "Rick upgrades Homebrew and it
    /// just works on next launch" true, with nothing to clear.
    @Test func aPoisonedMemoCannotOutliveTheProcess() async throws {
        let healthyEndpoint =
            OllamaEndpoints.chatURLString(for: "healthy.local", defaultPort: 11434)

        let poisoned = OllamaStructuredOutputCapability()
        await poisoned.recordUnsupported(healthyEndpoint)
        let firstRunCalls = ChatCalls()
        var t = translatorRefusingStructuredOutput(
            host: "healthy.local", refusingHosts: ["nobody.local"],
            calls: firstRunCalls, memo: poisoned)
        t.host = "healthy.local"
        _ = try await t.translateAST("show me Donna in 1994")
        #expect(await firstRunCalls.formatFlags == [false],
                "while poisoned, the schema is skipped")

        // A new process = a new memo. Nothing was persisted to inherit.
        let freshCalls = ChatCalls()
        let fresh = OllamaStructuredOutputCapability()
        #expect(await fresh.isUnsupported(healthyEndpoint) == false)
        var t2 = translatorRefusingStructuredOutput(
            host: "healthy.local", refusingHosts: ["nobody.local"],
            calls: freshCalls, memo: fresh)
        t2.host = "healthy.local"
        _ = try await t2.translateAST("show me Donna in 1994")
        #expect(await freshCalls.formatFlags == [true],
                "a fresh process must offer the schema again")
    }

    /// `recordUnsupported` reports first-time-ness; that boolean is the
    /// entire "log once per host, not once per turn" mechanism.
    @Test func recordUnsupportedReportsOnlyTheFirstTime() async {
        let memo = OllamaStructuredOutputCapability()
        #expect(await memo.recordUnsupported("http://a/api/chat") == true)
        #expect(await memo.recordUnsupported("http://a/api/chat") == false)
        #expect(await memo.recordUnsupported("http://b/api/chat") == true)
        await memo.reset()
        #expect(await memo.recordUnsupported("http://a/api/chat") == true)
    }

    // MARK: Logic — honest classification

    @Test func refusalClassifiesAsStructuredOutputNotModelUnavailable() {
        let err = OllamaQueryTranslator.classify(
            status: 501, body: Data(structuredOutputRefusal.utf8), host: "ricksm4.local")
        guard case .structuredOutputUnsupported(let host, _) = err else {
            Issue.record("expected structuredOutputUnsupported, got \(err)")
            return
        }
        #expect(host == "ricksm4.local")
        #expect(!err.isRetryableOnAnotherHost,
                "same Homebrew formula on every host — the walk cannot help")
        #expect(!err.isRepairable, "no prompt hint can install a missing dylib")
    }

    /// ORDERING PIN. `readsAsMissingModel` fires on "model" + "unavailable".
    /// A refusal that happens to name the model would satisfy it, and the
    /// structured-output test must be consulted first or we are straight
    /// back to the misleading `reason=model-unavailable`.
    @Test func structuredOutputClaimNamingTheModelIsNotAMissingModel() {
        let body = #"{"error":"model qwen3.8:27b-mlx: structured output is unavailable"}"#
        #expect(OllamaQueryTranslator.readsAsMissingModel(
            "model qwen3.8:27b-mlx: structured output is unavailable"),
            "precondition: this wording DOES look like a missing model in isolation")
        let err = OllamaQueryTranslator.classify(
            status: 501, body: Data(body.utf8), host: "ricksm4.local")
        if case .structuredOutputUnsupported = err {} else {
            Issue.record("ordering regressed — got \(err)")
        }
    }

    /// The predicate keys on wording, not on 501, because the same missing
    /// library has surfaced as a 400 and as an HTTP-200 error string.
    @Test func theRefusalIsRecognisedByWordingNotByStatusAlone() async throws {
        for (status, body) in [
            (501, structuredOutputRefusal),
            (400, #"{"error":"structured outputs are not supported by this runner"}"#),
            (500, #"{"error":"xgrammar library not found"}"#),
        ] {
            let calls = ChatCalls()
            let memo = OllamaStructuredOutputCapability()
            let t = translatorRefusingStructuredOutput(
                refusalBody: body, refusalStatus: status, calls: calls, memo: memo)
            _ = try await t.translateAST("show me Donna in 1994")
            #expect(await calls.formatFlags == [true, false],
                    "status \(status) with structured-output wording must fall back")
        }
    }

    /// And stays narrow: an ordinary 501 or 5xx keeps its own meaning and
    /// its own retry policy.
    @Test func ordinaryServerErrorsAreUnchanged() {
        let plain = OllamaQueryTranslator.classify(status: 501, body: Data("nope".utf8))
        if case .serverError(let status, _) = plain {
            #expect(status == 501)
        } else {
            Issue.record("a 501 without the wording must stay serverError, got \(plain)")
        }
        #expect(plain.isRetryableOnAnotherHost)
        #expect(!OllamaQueryTranslator.readsAsStructuredOutputUnsupported(
            "context length exceeded"))
        #expect(!OllamaQueryTranslator.readsAsStructuredOutputUnsupported(
            "model 'qwen3.8:27b' not found, try pulling it first"))
    }

    /// The log line must say what is actually wrong. "model-unavailable"
    /// is what cost the diagnosis two hours.
    @Test func theDiagnosticReasonNamesTheBuildAndTheHost() {
        let line = ArchivistDiagnosticLine.failure(
            .interpretation,
            error: NLTranslatorError.structuredOutputUnsupported(
                host: "ricksm4.local", detail: "HTTP 501"))
        #expect(line == "[hallie] interpretation failed"
            + " reason=structured-output-unsupported host=ricksm4.local")
        #expect(!line.contains("model-unavailable"))
    }

    /// The spoken/typed reply must not send Rick to check a host that is
    /// answering fine.
    @Test func theUserVisibleReasonAgreesWithTheLog() {
        let message = HallieHelperFailure.message(
            for: NLTranslatorError.structuredOutputUnsupported(
                host: "ricksm4.local", detail: "HTTP 501"))
        #expect(message.contains("ricksm4.local"))
        #expect(!message.contains("trouble reaching"))
        #expect(message.contains("didn't search the archive"))
    }

    // MARK: Sensor

    /// SENSOR. The whole fix rests on one empirical claim: with `format`
    /// dropped and `think:false` kept, the model returns clean JSON that
    /// the strict decoder accepts — no ``` fences, no `</think>` leakage.
    /// If a prompt or model change ever breaks that, this fails here
    /// rather than in front of Rick's family.
    @Test func sensorFallbackYieldsADecodableASTFromARealisticReply() async throws {
        let memo = OllamaStructuredOutputCapability()
        let calls = ChatCalls()
        let realistic = """
        {"message":{"content":"{\\n  \\"shape\\": \\"graph\\",\\n  \\"payload\\": \
        {\\n    \\"people\\": [\\"Donna\\"],\\n    \\"operation\\": \\"kinship\\", \
        \\n    \\"relation\\": \\"mother\\"\\n  }\\n}"}}
        """
        let t = translatorRefusingStructuredOutput(
            reply: realistic, calls: calls, memo: memo)

        let ast = try await t.translateAST("who is Donna's mother?")

        guard case .graph(let graph) = ast else {
            Issue.record("expected a graph AST, got \(ast)")
            return
        }
        #expect(graph.people == ["Donna"])
        #expect(graph.operation == .kinship)
        #expect(graph.relation == .mother)
        #expect(await calls.formatFlags == [true, false])
    }

    // MARK: Regression pins — the failover behaviour I must not break

    /// codex #320.2, restated here so a future edit to the classifier
    /// trips over it in THIS file too. A genuine missing model is still
    /// `.modelUnavailable` and still fails over.
    @Test func regressionFourOhFourIsStillModelUnavailable() {
        let err = OllamaQueryTranslator.classify(
            status: 404, body: Data(#"{"error":"model 'qwen3.8:27b' not found"}"#.utf8),
            host: "bare.local")
        if case .modelUnavailable = err {} else {
            Issue.record("expected modelUnavailable, got \(err)")
        }
        #expect(err.isRetryableOnAnotherHost)
    }

    /// End to end: a 404 primary still hands the turn to a healthy
    /// secondary. The structured-output work must not have quietly
    /// changed who gets walked.
    @Test func regressionFourOhFourStillFailsOver() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        var template = OllamaQueryTranslator()
        template.structuredOutputCapability = memo
        template.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            let host = hostComponent(of: urlString)
            await calls.record(.init(host: host, carriedFormat: carriesFormatKey(body)))
            if host == "bare.local" {
                return .status(404, #"{"error":"model not found, try pulling it first"}"#)
            }
            return .ok(goodSpecReply)
        }
        let fleet = OllamaFailoverTranslator(
            hosts: ["bare.local", "loaded.local"], template: template)

        let spec = try await fleet.translate("anything with Donna")

        #expect(spec.people == ["Donna"])
        #expect(await calls.hosts == ["bare.local", "loaded.local"])
    }

    /// The complement, and the point of item 1 in the fix: a
    /// structured-output refusal must be recovered ON THIS HOST and must
    /// NOT walk the fleet. Walking it would cost a probe plus a
    /// generation timeout per host to rediscover the same missing dylib —
    /// and, as in the incident, end on some other host's error.
    @Test func refusalIsRecoveredLocallyAndNeverWalksTheFleet() async throws {
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        var template = OllamaQueryTranslator()
        template.structuredOutputCapability = memo
        template.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            let host = hostComponent(of: urlString)
            let carriedFormat = carriesFormatKey(body)
            await calls.record(.init(host: host, carriedFormat: carriedFormat))
            if host == "primary.local" && carriedFormat {
                return .status(501, structuredOutputRefusal)
            }
            return .ok(goodSpecReply)
        }
        let fleet = OllamaFailoverTranslator(
            hosts: ["primary.local", "secondary.local"], template: template)

        let spec = try await fleet.translate("anything with Donna")

        #expect(spec.people == ["Donna"])
        #expect(await calls.hosts == ["primary.local", "primary.local"],
                "the secondary must never be dialled — same build, same missing dylib")
    }
}

/// Captures raw request bodies for the "what exactly did we resend?" test.
private actor FakeBodies {
    private(set) var all: [Data] = []
    func record(_ body: Data) { all.append(body) }
}

// MARK: - Log volume (serialized: swaps the global appLog)

@Suite("Hallie — structured-output capability is logged once per host", .serialized)
struct OllamaStructuredOutputLoggingTests {

    /// Replace `appLog` around an ASYNC body. The shared `withAppLog` is
    /// synchronous; this suite is `.serialized` for the same reason that
    /// one is — the global swap is not concurrency-safe.
    private func withAppLogAsync<R>(
        _ sink: LogSink, _ body: () async throws -> R
    ) async rethrows -> R {
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        return try await body()
    }

    /// One clear line per host per run. Per-turn would bury the rest of
    /// the `[hallie]` trail — which is the trail the next diagnosis needs.
    @Test func theCapabilityIsLoggedOnceNotPerTurn() async throws {
        let sink = InMemoryLogSink()
        let calls = ChatCalls()
        let memo = OllamaStructuredOutputCapability()
        var t = OllamaQueryTranslator()
        t.host = "ricksm4.local"
        t.structuredOutputCapability = memo
        t.transport = .fake { urlString, body in
            if urlString.hasSuffix("/api/tags") { return .ok(#"{"models":[]}"#) }
            await calls.record(.init(host: hostComponent(of: urlString),
                                     carriedFormat: carriesFormatKey(body)))
            return carriesFormatKey(body)
                ? .status(501, structuredOutputRefusal)
                : .ok(unconstrainedASTReply)
        }

        try await withAppLogAsync(sink) {
            for _ in 0..<4 { _ = try await t.translateAST("show me Donna in 1994") }
        }

        let matching = sink.lines.filter { $0.contains("structured output unsupported") }
        #expect(matching.count == 1, "one line per host per run, got \(sink.lines)")
        let line = try #require(matching.first)
        #expect(line.hasPrefix("[hallie] "))
        #expect(line.contains("ricksm4.local"))
        #expect(!line.lowercased().contains("model unavailable"))
    }
}
