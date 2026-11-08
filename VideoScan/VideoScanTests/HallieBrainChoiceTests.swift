// HallieBrainChoiceTests.swift
//
// Hallie's choice of brain (Rick, 2026-11-07): Local (Ollama) by default,
// Cloud (Anthropic) opt-in, one seam for both.
//
// Five dimensions:
//   Logic       — provider/default resolution, key lookup order (fake
//                 keychain), labels, data classes, plan classification,
//                 START/OUTCOME lines, history policy.
//   Isolation   — injected UserDefaults suites, a fake keychain, a
//                 URLProtocol stub; garbage provider → Local; no key → a
//                 plain error and zero requests; a test host never
//                 resolves Cloud through `.live`.
//   Sensor      — HallieCloudBrainCanarySensorTests (sensor lane).
//   Request shape — the Anthropic body: model, forced tool, wrapped schema,
//                 cached system prompt, the question only, no media, key
//                 only in its header.
//   Scale / media matrix: N/A — the adapter moves one small text request
//                 per question and handles no media (it refuses it).

import Foundation
import Testing
@testable import VideoScan

private func isolatedDefaults() -> UserDefaults {
    let name = "HallieBrainChoiceTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        preconditionFailure("UserDefaults(suiteName:) refused \(name)")
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

private func resolver(_ defaults: UserDefaults, _ keychain: FakeHallieKeychain = FakeHallieKeychain(),
                      session: URLSession = hallieCloudStubSession().session,
                      log: @escaping @Sendable (String) -> Void = { _ in }) -> HallieBrainResolver {
    var r = HallieBrainResolver(defaults: defaults, keychain: keychain, cloudSession: session,
                                allowCloud: true)
    r.log = log
    return r
}

private let keyedKeychain = FakeHallieKeychain(items: [
    FakeHallieKeychain.key("anthropic-api-key", nil): "sk-ant-primary",
])

private let donna1994 = #"{"shape":"presence","payload":{"people":["donna"],"yearStart":1994,"yearEnd":1994}}"#

final class HallieLineSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func write(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

// MARK: - Logic

@Suite("Hallie brain choice — settings and resolution")
struct HallieBrainChoiceLogicTests {

    @Test("defaults: Local, qwen3.8:27b-mlx, cloud model claude-sonnet-5-5")
    func defaults() {
        let d = isolatedDefaults()
        #expect(HallieBrainSettings.provider(d) == .local)
        #expect(HallieBrainSettings.localModel(d) == "qwen3.8:27b-mlx")
        #expect(HallieBrainSettings.cloudModel(d) == "claude-sonnet-5-5")
    }

    @Test("settings round-trip under the documented keys")
    func roundTrip() {
        let d = isolatedDefaults()
        HallieBrainSettings.setProvider(.cloud, d)
        HallieBrainSettings.setCloudModel("  claude-haiku-5-5 ", d)
        #expect(d.string(forKey: "archivist.brainProvider") == "cloud")
        #expect(d.string(forKey: "archivist.cloudModel") == "claude-haiku-5-5")
        #expect(HallieBrainSettings.provider(d) == .cloud)
        HallieBrainSettings.setCloudModel("   ", d)
        #expect(HallieBrainSettings.cloudModel(d) == "claude-haiku-5-5")
    }

    @Test("Local resolves to the Ollama fleet with the configured model")
    func localResolves() throws {
        let d = isolatedDefaults()
        let brain = try resolver(d).backend(hosts: ["RicksUltra.local"], localModel: "qwen3.8:27b-mlx")
        #expect(brain.provider == .local)
        #expect(brain.modelName == "qwen3.8:27b-mlx")
        let inner = try #require((brain as? HallieLoggedBrain)?.inner as? OllamaFailoverTranslator)
        #expect(inner.hosts == ["RicksUltra.local"])
    }

    @Test("Cloud with a key resolves to Anthropic with the chosen model")
    func cloudResolves() throws {
        let d = isolatedDefaults()
        HallieBrainSettings.setProvider(.cloud, d)
        HallieBrainSettings.setCloudModel("claude-opus-5-5", d)
        let brain = try resolver(d, keyedKeychain).backend(hosts: ["RicksUltra.local"], localModel: "qwen")
        #expect(brain.provider == .cloud)
        #expect(brain.modelName == "claude-opus-5-5")
        let inner = try #require((brain as? HallieLoggedBrain)?.inner as? AnthropicBrain)
        #expect(inner.key.value == "sk-ant-primary")
        #expect(inner.key.source == "anthropic-api-key")
    }

    @Test("key lookup order: anthropic-api-key first, then hallie-e1 / anthropic")
    func keyOrder() {
        let both = FakeHallieKeychain(items: [
            FakeHallieKeychain.key("anthropic-api-key", nil): "sk-primary",
            FakeHallieKeychain.key("hallie-e1", "anthropic"): "sk-harness",
        ])
        #expect(AnthropicKeyLocator.locate(in: both)?.value == "sk-primary")
        #expect(both.lookups.all == ["anthropic-api-key|*"])

        let harnessOnly = FakeHallieKeychain(items: [
            FakeHallieKeychain.key("hallie-e1", "anthropic"): "sk-harness",
        ])
        let found = AnthropicKeyLocator.locate(in: harnessOnly)
        #expect(found?.value == "sk-harness")
        #expect(found?.source == "hallie-e1 / anthropic")
        #expect(harnessOnly.lookups.all == ["anthropic-api-key|*", "hallie-e1|anthropic"])

        let blank = FakeHallieKeychain(items: [
            FakeHallieKeychain.key("anthropic-api-key", nil): "  \n",
            FakeHallieKeychain.key("hallie-e1", "anthropic"): "sk-harness",
        ])
        #expect(AnthropicKeyLocator.locate(in: blank)?.value == "sk-harness")
    }

    @Test("the Settings key status reads attributes only, never the secret")
    func presenceWithoutSecret() {
        let chain = FakeHallieKeychain(items: [
            FakeHallieKeychain.key("hallie-e1", "anthropic"): "sk-harness",
        ])
        #expect(AnthropicKeyLocator.presentSource(in: chain) == "hallie-e1 / anthropic")
        #expect(chain.lookups.all.isEmpty)
        let status = HallieBrainProviderSection.keyStatus(source: "hallie-e1 / anthropic")
        #expect(!status.contains("sk-"))
        #expect(HallieBrainProviderSection.keyStatus(source: nil).contains("No key found"))
    }

    @Test("a key never prints")
    func keyRedacted() {
        let key = AnthropicAPIKey(value: "sk-ant-secret-123", source: "anthropic-api-key")
        #expect("\(key)" == "<redacted>")
        #expect(String(reflecting: key) == "<redacted>")
    }

    @Test("labels: Cloud · model, model · host, and the model that answered")
    func labels() {
        let cloud = HallieBrainLabel.cloudResponder(model: "claude-sonnet-5-5")
        #expect(HallieBrainLabel.display(responder: cloud, localModel: "qwen3.8:27b-mlx")
                == "Cloud · claude-sonnet-5-5")
        #expect(HallieBrainLabel.display(responder: "RicksUltra.local", localModel: "qwen3.8:27b-mlx")
                == "qwen3.8:27b-mlx · RicksUltra")
        #expect(HallieBrainLabel.modelName(responder: cloud, localModel: "qwen") == "claude-sonnet-5-5")
        #expect(HallieBrainLabel.modelName(responder: "RicksM4.local", localModel: "qwen") == "qwen")
        #expect(HallieBrainLabel.modelName(responder: nil, localModel: "qwen") == "qwen")
    }

    @Test("data class: transcript and caption evidence is familyMedia; tags and dates are not")
    func citationClasses() {
        func cite(_ bases: [ArchivistEvidenceBasis]) -> HallieTurnExecutor.Citation {
            .init(recordID: UUID(), fullPath: "/v/a.mov", filename: "a.mov",
                  playbackSeconds: nil, bases: bases)
        }
        let tag = ArchivistEvidenceBasis.humanPersonTag(queryIdentity: "donna", taggedName: "Donna",
                                                        confirmedAt: Date())
        let spoken = ArchivistEvidenceBasis.transcriptMention(queryTerm: "cape", snippet: "at the cape",
                                                              model: "whisper")
        let ocr = ArchivistEvidenceBasis.keywordTokens(field: "transcript", queryTerm: "cape",
                                                       matchedTokens: ["cape"], alias: nil,
                                                       matchedValue: "the cape", timestamp: 3)
        #expect(HallieDataClass.of(citations: [cite([tag, .pathYear(year: 1994, fullPath: "/v")])]) == .familyText)
        #expect(HallieDataClass.of(citations: [cite([tag]), cite([spoken])]) == .familyMedia)
        #expect(HallieDataClass.of(citations: [cite([ocr])]) == .familyMedia)
        #expect(HallieDataClass.of(citations: []) == .familyText)
    }

    @Test("derive(from:) classes the plan by its citations, and offering keeps the class")
    func planClassification() {
        let spoken = HallieTurnExecutor.Citation(
            recordID: UUID(), fullPath: "/v/a.mov", filename: "a.mov", playbackSeconds: 2,
            bases: [.transcriptMention(queryTerm: "cape", snippet: "down the cape", model: nil)])
        let result = HallieTurnExecutor.Result(
            route: .presence, outcome: .answered,
            prose: "I found 1 catalog item matching that.",
            basisLine: "", queryDescription: nil, citations: [spoken], catalogPersonName: nil)
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.dataClass == .familyMedia)
        #expect(plan.offering(" Want to see it?").dataClass == .familyMedia)
        #expect(plan.carrying(provenance: " (note)").dataClass == .familyMedia)

        let clean = HallieTurnExecutor.Result(
            route: .presence, outcome: .answered, prose: "I found 3.", basisLine: "",
            queryDescription: nil, citations: [], catalogPersonName: nil)
        #expect(HallieAnswerPlan.derive(from: clean).dataClass == .familyText)
    }

    @Test("history: a cloud brain sees none, a local brain sees all")
    func historyPolicy() {
        let turns = [HallieGroundedComposer.HistoryTurn(user: "q", assistant: "transcript says …")]
        #expect(HallieBrainHistoryPolicy.history(turns, for: .cloud).isEmpty)
        #expect(HallieBrainHistoryPolicy.history(turns, for: .local) == turns)
    }

    @Test("START/OUTCOME name the brain, never the question")
    func loggedLines() async throws {
        let sink = HallieLineSink()
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieToolReply(donna1994))
        let d = isolatedDefaults()
        HallieBrainSettings.setProvider(.cloud, d)
        let brain = try resolver(d, keyedKeychain, session: session, log: { sink.write($0) })
            .backend(hosts: [], localModel: "qwen")
        _ = try await brain.translateAST("show me Donna in 1994")
        let lines = sink.lines
        #expect(lines.count == 2)
        #expect(lines[0] == "[hallie] brain START op=translateAST brain=Cloud · claude-sonnet-5-5")
        #expect(lines[1].hasPrefix("[hallie] brain OUTCOME op=translateAST brain=Cloud · claude-sonnet-5-5 ok ms="))
        #expect(!lines.joined().contains("Donna"))
    }
}

// MARK: - Isolation

@Suite("Hallie brain choice — isolation")
struct HallieBrainChoiceIsolationTests {

    @Test("a garbage provider value is Local", arguments: ["CLOUD", " cloud", "anthropic", "1", "", "remote"])
    func garbageIsLocal(_ value: String) throws {
        let d = isolatedDefaults()
        d.set(value, forKey: HallieBrainSettings.providerKey)
        #expect(HallieBrainSettings.provider(d) == .local)
        let brain = try resolver(d, keyedKeychain).backend(hosts: ["h"], localModel: "qwen")
        #expect(brain.provider == .local)
    }

    @Test("a non-string provider value is Local")
    func nonStringIsLocal() {
        let d = isolatedDefaults()
        d.set(7, forKey: HallieBrainSettings.providerKey)
        #expect(HallieBrainSettings.provider(d) == .local)
    }

    @Test("Cloud with no key: a plain error, logged, and no request is attempted")
    func missingKey() {
        let d = isolatedDefaults()
        HallieBrainSettings.setProvider(.cloud, d)
        let (session, token) = hallieCloudStubSession()
        let sink = HallieLineSink()
        let r = resolver(d, FakeHallieKeychain(), session: session, log: { sink.write($0) })
        #expect(throws: HallieBrainError.noCloudKey) {
            _ = try r.backend(hosts: ["h"], localModel: "qwen")
        }
        #expect(HallieCloudStubLedger.shared.seen(token).isEmpty)
        #expect(sink.lines.contains { $0.contains("reason=no-key") })
        let message = HallieHelperFailure.message(for: HallieBrainError.noCloudKey)
        #expect(message.contains("Anthropic key"))
        #expect(message.contains("didn't send your question anywhere"))
        #expect(!message.contains("trouble reaching"))
    }

    @Test("Cloud is never chosen as a fallback: Local stays Local even with a key present")
    func noAutomaticCloud() throws {
        let d = isolatedDefaults()
        let brain = try resolver(d, keyedKeychain).backend(hosts: [], localModel: "qwen")
        #expect(brain.provider == .local)
    }

    @Test("a resolver that may not use Cloud pins Local; `.live` in a test host is such a resolver")
    func testHostPinsLocal() throws {
        let d = isolatedDefaults()
        HallieBrainSettings.setProvider(.cloud, d)
        var r = resolver(d, keyedKeychain)
        r.allowCloud = false
        #expect(try r.backend(hosts: [], localModel: "qwen").provider == .local)
        #expect(HallieBrainResolver.live.allowCloud == false)
        #expect(HallieBrainResolver.shell(.cloud).provider == .local)
    }

    @Test("the shell parses --cloud; default is Local")
    func shellFlag() throws {
        #expect(try HallieShellCLI.parse(arguments: ["--hallie"]).brain == .local)
        #expect(try HallieShellCLI.parse(arguments: ["--hallie", "--cloud"]).brain == .cloud)
        #expect(HallieShellCLI.usage.contains("--cloud"))
    }
}

// MARK: - Request shape (URLProtocol stub; no network)

@Suite("Hallie cloud brain — request shape")
struct HallieCloudRequestShapeTests {

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("translateAST: model, forced tool, wrapped schema, cached system, the question only")
    func translateBody() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieToolReply(donna1994))
        let ast = try await hallieStubbedCloudBrain(session).translateAST("show me Donna in 1994")
        guard case .presence(let presence) = ast else {
            Issue.record("expected presence, got \(ast)"); return
        }
        #expect(presence.people == ["donna"])

        let seen = HallieCloudStubLedger.shared.seen(token)
        #expect(seen.count == 1)
        let request = try #require(seen.first)
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.request.value(forHTTPHeaderField: "x-api-key") == hallieFakeCloudKey.value)
        #expect(request.request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")

        let body = try json(request.body)
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["max_tokens"] as? Int == 1024)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "hallie_answer")
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["answer"])
        let answer = try #require((schema["properties"] as? [String: Any])?["answer"] as? [String: Any])
        #expect((answer["oneOf"] as? [Any])?.count == 6)
        let choice = try #require(body["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == "hallie_answer")

        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect((system[0]["text"] as? String)?.hasPrefix(
            String(OllamaQueryTranslator.astSystemPrompt.prefix(60))) == true)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "show me Donna in 1994")

        let raw = String(bytes: request.body, encoding: .utf8) ?? ""
        for forbidden in ["\"image\"", "\"document\"", "\"source\"", "base64", hallieFakeCloudKey.value] {
            #expect(!raw.contains(forbidden), "body carries \(forbidden)")
        }
    }

    @Test("interpretTurn decodes the conversation branch through the shared decoder")
    func interpretConversation() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: hallieToolReply(#"{"shape":"conversation","payload":{"kind":"casual"}}"#))
        let value = try await hallieStubbedCloudBrain(session).interpretTurn("thanks, that's kind of you")
        #expect(value == .conversation(.casual))
    }

    @Test("a rejected answer earns one repair retry with the complaint in the system prompt")
    func repairRetry() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: hallieToolReply(#"{"shape":"presence","payload":{"mediaKind":"HD"}}"#))
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieToolReply(donna1994))
        _ = try await hallieStubbedCloudBrain(session).translateAST("show me Donna in 1994")
        let seen = HallieCloudStubLedger.shared.seen(token)
        #expect(seen.count == 2)
        let second = try json(seen[1].body)
        let text = ((second["system"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("YOUR PREVIOUS ANSWER WAS REJECTED"))
    }

    @Test("an answer given as a JSON string is still judged by the decoder")
    func stringAnswer() throws {
        let root = try json(Data(hallieToolReply(#""{\"people\":[\"donna\"]}""#).utf8))
        let (_, data) = try AnthropicBrain.toolAnswer(root)
        #expect(String(bytes: data, encoding: .utf8) == #"{"people":["donna"]}"#)
        #expect(throws: NLTranslatorError.self) {
            _ = try AnthropicBrain.toolAnswer(["content": [["type": "text", "text": "hi"]]])
        }
    }

    @Test("compose: no tools, 320 tokens, plain text back")
    func composeBody() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: #"{"content":[{"type":"text","text":"Donna is in 3 videos. [c1]"}]}"#)
        let text = try await hallieStubbedCloudBrain(session).composePlainText(
            system: "You are Hallie.", user: "[c1] Donna is in 3 videos.", dataClass: .familyText)
        #expect(text == "Donna is in 3 videos. [c1]")
        let body = try json(try #require(HallieCloudStubLedger.shared.seen(token).first).body)
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(body["max_tokens"] as? Int == 320)
    }

    @Test("HTTP errors classify without echoing the key; overload retries once")
    func errors() async {
        let (s401, t401) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            t401, status: 401,
            body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        do {
            _ = try await hallieStubbedCloudBrain(s401).translate("videos of Donna")
            Issue.record("401 should throw")
        } catch let error as NLTranslatorError {
            guard case .serverError(401, let detail) = error else {
                Issue.record("expected serverError 401, got \(error)"); return
            }
            #expect(!detail.contains(hallieFakeCloudKey.value))
            #expect(HallieHelperFailure.kind(of: error) == .badRequest(status: 401))
        } catch { Issue.record("unexpected \(error)") }
        #expect(HallieCloudStubLedger.shared.seen(t401).count == 1)

        let (s404, t404) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            t404, status: 404,
            body: #"{"type":"error","error":{"type":"not_found_error","message":"model: nope"}}"#)
        await #expect(throws: NLTranslatorError.self) {
            _ = try await hallieStubbedCloudBrain(s404, model: "nope").translate("x")
        }

        let (s529, t529) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            t529, status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#)
        await #expect(throws: NLTranslatorError.self) {
            _ = try await hallieStubbedCloudBrain(s529).translate("x")
        }
        #expect(HallieCloudStubLedger.shared.seen(t529).count == 2)
    }
}
