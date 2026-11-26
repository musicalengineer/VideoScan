import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Rick, 2026-11-15: "log which model, for sure, is failing … what model
/// failed and, if possible why." That afternoon's log had three lines of a
/// failed turn that named no brain, and the one that did cut its reason at
/// 160 characters — before the year the decoder was rejecting.
@Suite("Hallie: the log names the brain, and a failure says why")
struct HallieBrainLogTests {

    private func isolatedDefaults() -> UserDefaults {
        let name = "HallieBrainLogTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName:) refused \(name)")
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func wait(for sink: HallieLineSink, count: Int) async {
        for _ in 0..<200 where sink.lines.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Logic

    @Test("one spelling per brain on every line")
    func labels() {
        #expect(HallieBrainLog.label(provider: .cloud, model: "claude-haiku-5-5") == "Cloud · claude-haiku-5-5")
        #expect(HallieBrainLog.label(provider: .local, model: "qwen3.8:27b-mlx") == "qwen3.8:27b-mlx (local)")
        #expect(HallieBrainLog.windowLabel(provider: .local, model: "qwen3.8:27b-mlx") == "qwen3.8:27b-mlx")
        #expect(HallieBrainLog.windowLabel(provider: .cloud, model: "claude-opus-5-5") == "Cloud · claude-opus-5-5")
        #expect(HallieBrainLog.turnLine(brain: "llama3.3:70b (local)") == "[hallie] turn brain=llama3.3:70b (local)")
        #expect(HallieBrainLog.selectionLine(brain: "Cloud · claude-haiku-5-5")
                == "[hallie] brain set to Cloud · claude-haiku-5-5")
    }

    @Test("the selected brain follows the settings the resolver reads")
    func selectedFollowsSettings() {
        let d = isolatedDefaults()
        #expect(HallieBrainLog.selectedLabel(defaults: d, allowCloud: true)
                == "\(HallieBrain.defaultModel) (local)")
        d.set("llama3.3:70b", forKey: ArchivistEndpointSettings.modelKey)
        #expect(HallieBrainLog.selectedLabel(defaults: d, allowCloud: true) == "llama3.3:70b (local)")
        // The window passes the model it will ask with; that wins over the stored one.
        #expect(HallieBrainLog.selectedLabel(defaults: d, localModel: "qwen3.8:27b-mlx", allowCloud: true)
                == "qwen3.8:27b-mlx (local)")
        HallieBrainSettings.setProvider(.cloud, d)
        #expect(HallieBrainLog.selectedLabel(defaults: d, localModel: "qwen3.8:27b-mlx", allowCloud: true)
                == "Cloud · claude-sonnet-5-5")
        HallieBrainSettings.setCloudModel("claude-opus-5-5", d)
        #expect(HallieBrainLog.selectedLabel(defaults: d, allowCloud: true) == "Cloud · claude-opus-5-5")
    }

    // MARK: Isolation

    @Test("a test host, a garbage provider and a blank model all read as Local with a real name",
          arguments: ["CLOUD", "anthropic", "", " cloud"])
    func poisonedSettings(_ provider: String) {
        let d = isolatedDefaults()
        d.set(provider, forKey: HallieBrainSettings.providerKey)
        #expect(HallieBrainLog.selectedLabel(defaults: d, localModel: "   ", allowCloud: true)
                == "\(HallieBrain.defaultModel) (local)")
        HallieBrainSettings.setProvider(.cloud, d)
        #expect(HallieBrainLog.selectedLabel(defaults: d, allowCloud: false)
                == "\(HallieBrain.defaultModel) (local)")
    }

    // MARK: Truth — the failing line

    @Test("a rejected cloud reply: the line names the model, the field and the offending value")
    func failedCloudCallSaysWhy() async throws {
        let sink = HallieLineSink()
        let (session, token) = hallieCloudStubSession()
        // "from 1850" is the reader's own year, so the decoder still refuses it — twice.
        let bad = #"{"payload":{"people":["thankful pratt"],"keywords":["shrewsbury","brattleboro","stukely","quebec"],"mediaKind":"video","yearStart":1850,"yearEnd":1850},"shape":"presence"}"#
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieStructuredReply(bad))
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieStructuredReply(bad))
        let brain = HallieLoggedBrain(
            inner: hallieStubbedCloudBrain(session, model: "claude-opus-5-5"),
            write: { sink.write($0) })
        await #expect(throws: NLTranslatorError.self) {
            _ = try await brain.interpretTurn("videos of thankful pratt from 1850")
        }
        let failed = try #require(sink.lines.last)
        #expect(failed.hasPrefix("[hallie] brain OUTCOME op=interpretTurn brain=Cloud · claude-opus-5-5 failed ms="))
        #expect(failed.contains("must be in 1900...2099"))
        // The value itself — 160 characters stopped short of it on 2026-11-15.
        #expect(failed.contains("1850"))
        #expect(!failed.contains("\n"))
    }

    @Test("the live question now passes on a cloud brain, in one request")
    func liveQuestionPassesOnCloud() async throws {
        let sink = HallieLineSink()
        let (session, token) = hallieCloudStubSession()
        let reply = #"{"payload":{"people":["thankful pratt"],"yearStart":1761,"yearEnd":1849},"shape":"presence"}"#
        HallieCloudStubLedger.shared.queue(token, status: 200, body: hallieStructuredReply(reply))
        let brain = HallieLoggedBrain(
            inner: hallieStubbedCloudBrain(session), write: { sink.write($0) })
        let value = try await brain.interpretTurn("tell me of thankful pratt")
        guard case .archive(.presence(let payload)) = value else {
            Issue.record("expected presence, got \(value)")
            return
        }
        #expect(payload.people == ["thankful pratt"])
        #expect(payload.yearStart == nil && payload.yearEnd == nil)
        #expect(HallieCloudStubLedger.shared.seen(token).count == 1)
        #expect(sink.lines.last?.contains(" ok ms=") == true)
    }

    @Test("a cancelled call is named as one, with how long it ran")
    func cancellationIsNamed() {
        let reason = HallieBrainLog.failureReason(CancellationError(), afterMs: 6003)
        #expect(reason == "cancelled after 6003 ms (the caller's time limit, or Stop)")
    }

    @Test("a reason is one line and bounded, however long the error is")
    func reasonIsBounded() {
        let long = NLTranslatorError.badResponse(String(repeating: "x\n", count: 5_000))
        let reason = HallieBrainLog.failureReason(long, afterMs: 1)
        #expect(reason.count == HallieBrainLog.reasonLimit)
        #expect(!reason.contains("\n"))
    }

    @Test("after a local failure, one more line says what the server holds")
    func afterFailureLine() async {
        struct Failing: HallieBrainBackend {
            var provider: HallieBrainProvider { .local }
            var modelName: String { "llama3.3:70b" }
            var displayName: String { "fake" }
            func translate(_ text: String) async throws -> NLQuerySpec { throw CancellationError() }
            func translateAST(_ text: String) async throws -> ArchivistQueryAST { throw CancellationError() }
            func interpretTurn(_ text: String) async throws -> HallieTurnInterpretation { throw CancellationError() }
            func composePlainText(system: String, user: String,
                                  dataClass: HallieDataClass) async throws -> String { throw CancellationError() }
            func warmUp() async {}
        }
        let sink = HallieLineSink()
        var brain = HallieLoggedBrain(inner: Failing(), write: { sink.write($0) })
        brain.afterFailure = {
            HallieBrainLog.residentLine(
                host: "127.0.0.1:11434", wanted: "llama3.3:70b",
                resident: [.init(name: "qwen3.8:27b-mlx", bytes: 1, digest: "")])
        }
        _ = try? await brain.composePlainText(system: "", user: "", dataClass: .familyText)
        await wait(for: sink, count: 3)
        let lines = sink.lines
        #expect(lines.count == 3)
        #expect(lines[1].contains("brain=llama3.3:70b (local) failed"))
        #expect(lines[1].contains("cancelled after"))
        #expect(lines[2] == "[hallie-brain] after the failure, 127.0.0.1:11434: "
                + "“llama3.3:70b” NOT loaded; in memory: qwen3.8:27b-mlx")
    }

    /// Codex #450 round 1 (P2): a familyMedia refusal promises zero dials,
    /// but the after-failure line probed the first host's /api/ps.
    @Test("a familyMedia refusal runs no after-failure probe: nothing is dialled")
    func refusalDialsNoAfterFailureProbe() async throws {
        struct Refusing: HallieBrainBackend {
            var provider: HallieBrainProvider { .local }
            var modelName: String { "qwen3.8:27b-mlx" }
            var displayName: String { "fake" }
            func translate(_ text: String) async throws -> NLQuerySpec { throw CancellationError() }
            func translateAST(_ text: String) async throws -> ArchivistQueryAST { throw CancellationError() }
            func interpretTurn(_ text: String) async throws -> HallieTurnInterpretation { throw CancellationError() }
            func composePlainText(system: String, user: String,
                                  dataClass: HallieDataClass) async throws -> String {
                throw HallieBrainError.familyMediaRefused("text, to an Ollama host off this Mac")
            }
            func warmUp() async {}
        }
        let sink = HallieLineSink()
        var brain = HallieLoggedBrain(inner: Refusing(), write: { sink.write($0) })
        brain.afterFailure = { "[hallie-brain] PROBED" }
        _ = try? await brain.composePlainText(system: "", user: "", dataClass: .familyMedia)
        // The probe, if launched, is detached; give it ample time to land.
        try await Task.sleep(for: .milliseconds(300))
        #expect(sink.lines.count == 2, "\(sink.lines)")
        #expect(!sink.lines.contains { $0.contains("PROBED") })
    }

    @Test("what the server holds: loaded, another model, nothing")
    func residentLines() {
        let host = "127.0.0.1:11434"
        #expect(HallieBrainLog.residentLine(
            host: host, wanted: "a", resident: [.init(name: "a", bytes: 1, digest: "")])
            .hasSuffix("“a” loaded; in memory: a"))
        #expect(HallieBrainLog.residentLine(host: host, wanted: "a", resident: [])
            .hasSuffix("“a” NOT loaded; nothing in memory (or the server did not answer)"))
    }

    @Test("the turn-failed line and the phrased line both name the brain")
    func failureAndPhrasedLines() {
        let line = ArchivistDiagnosticLine.failure(
            .interpretation, error: NLTranslatorError.badResponse("x"), brain: "Cloud · claude-haiku-5-5")
        #expect(line == "[hallie] interpretation failed reason=bad-response brain=Cloud · claude-haiku-5-5")
        #expect(HallieBrainLog.phrasedLine(
            route: "graph", outcome: "answered", composedBy: "template",
            brain: "llama3.3:70b (local)", note: "template: model timeout", dropped: 0)
            == "Hallie: phrased graph/answered by template brain=llama3.3:70b (local) (template: model timeout; dropped 0)")
        #expect(HallieBrainLog.phrasedLine(
            route: "graph", outcome: "answered", composedBy: "model",
            brain: nil, note: "model", dropped: 1)
            == "Hallie: phrased graph/answered by model (model; dropped 1)")
    }

    @Test("the record names whoever wrote the words")
    func recordedResponder() {
        let none = HallieAppTurnCoordinator.localResponder
        // The 16:11:30 answer of 2026-11-15: no translation, phrased by Cloud Sonnet.
        #expect(HallieBrainLog.recordedResponder(
            turn: none, composedByModel: true, composer: "cloud:claude-sonnet-5-5") == "cloud:claude-sonnet-5-5")
        // A template answer was written by no model.
        #expect(HallieBrainLog.recordedResponder(
            turn: none, composedByModel: false, composer: "cloud:claude-sonnet-5-5") == none)
        // A translated turn keeps its translator.
        #expect(HallieBrainLog.recordedResponder(
            turn: "127.0.0.1:11434", composedByModel: true, composer: "ricksm4.local") == "127.0.0.1:11434")
        #expect(HallieBrainLog.recordedResponder(turn: none, composedByModel: true, composer: nil) == none)
        #expect(HallieBrainLog.recordedResponder(turn: none, composedByModel: true, composer: "") == none)
    }

    // MARK: Scale

    @Test("100k labels and reasons inside the budget")
    func scale() {
        let error = NLTranslatorError.badResponse(String(repeating: "y", count: 2_000))
        let load = TimingBudget.sampleLoad()
        let elapsed = ContinuousClock().measure {
            for index in 0..<100_000 {
                _ = HallieBrainLog.label(provider: index.isMultiple(of: 2) ? .cloud : .local, model: "m")
                _ = HallieBrainLog.failureReason(error, afterMs: index)
            }
        }
        expectWithinTimingBudget(
            "Hallie brain log: 100k labels and failure reasons",
            measured: elapsed, budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
    }
}
