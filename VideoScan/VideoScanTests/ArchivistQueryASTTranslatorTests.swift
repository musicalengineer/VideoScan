import Foundation
import Testing
@testable import VideoScan

private func astReply(_ content: String) -> OllamaTransportResult {
    let envelope: [String: Any] = ["message": ["content": content]]
    let data = try! JSONSerialization.data(withJSONObject: envelope)
    return .init(data: data, statusCode: 200)
}

private let validASTReply = astReply(
    #"{"shape":"temporal","payload":{"subject":"Timmy","operation":"age","reference":{"kind":"currentSelection"}}}"#)

private actor ASTRequestRecorder {
    private var requests: [(String, Data)] = []

    func record(url: String, body: Data) {
        requests.append((url, body))
    }

    func snapshot() -> [(String, Data)] { requests }
}

private final class ASTResponderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var host: String?

    func set(_ value: String) {
        lock.lock()
        host = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }
}

@Suite("Family Archivist QueryAST translator")
struct ArchivistQueryASTTranslatorTests {
    @Test func possessiveSpeakerPronounsOverrideRequestFormMe() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            // Reproduces the live 2026-08-21 mistranslation: "tell me" won
            // over the actual possessive subject "your father".
            astReply(#"{"shape":"graph","payload":{"people":["me"],"operation":"kinship","relation":"father"}}"#)
        }
        let yours = try await translator.translateAST("tell me about your father")
        #expect(yours == .graph(.init(
            people: ["you"], operation: .kinship, relation: .father)))

        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"graph","payload":{"people":["you"],"operation":"kinship","relation":"father"}}"#)
        }
        let mine = try await translator.translateAST("tell me about my father")
        #expect(mine == .graph(.init(
            people: ["me"], operation: .kinship, relation: .father)))
    }

    @Test func possessiveRepairDoesNotRewriteMultiSubjectCorrection() {
        let ast = ArchivistQueryAST.graph(.init(
            people: ["hallie may"], operation: .kinship, relation: .father))
        let repaired = OllamaQueryTranslator.repairPossessiveSpeakerPronoun(
            in: ast,
            originalQuestion: "that is my father, who was Hallie May's father?")
        #expect(repaired == ast)
    }

    @Test func v2RequestCarriesTypedSchemaAndTranslatorOnlyPrompt() async throws {
        let recorder = ASTRequestRecorder()
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { url, body in
            await recorder.record(url: url, body: body)
            return validASTReply
        }

        let result = try await translator.translateAST("How old was Timmy here?")
        #expect(result == .temporal(.init(
            subject: "Timmy", operation: .age, reference: .currentSelection)))

        let requests = await recorder.snapshot()
        #expect(requests.count == 1)
        let rawBody = try JSONSerialization.jsonObject(with: requests[0].1)
        let body = try #require(rawBody as? [String: Any])
        let format = try #require(body["format"] as? [String: Any])
        let branches = try #require(format["oneOf"] as? [[String: Any]])
        #expect(branches.count == 6)

        let shapes = Set(branches.compactMap { branch -> String? in
            let properties = branch["properties"] as? [String: Any]
            let shape = properties?["shape"] as? [String: Any]
            return (shape?["enum"] as? [String])?.first
        })
        #expect(shapes == ["presence", "temporal", "aggregate",
                           "event", "graph", "cross"])

        let aggregate = try #require(branches.first { branch in
            let properties = branch["properties"] as? [String: Any]
            let shape = properties?["shape"] as? [String: Any]
            return (shape?["enum"] as? [String])?.first == "aggregate"
        })
        let aggregateProperties = try #require(
            aggregate["properties"] as? [String: Any])
        let aggregatePayload = try #require(
            aggregateProperties["payload"] as? [String: Any])
        let aggregateRequired = Set(
            try #require(aggregatePayload["required"] as? [String]))
        #expect(aggregateRequired == ["operation", "anchorPeople"])
        #expect((aggregatePayload["properties"] as? [String: Any])?["limit"] != nil,
                "explicit top-N requests still need a typed bounded field")

        let messages = try #require(body["messages"] as? [[String: Any]])
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.contains("never answer it"))
        #expect(system.contains("Output JSON only"))
        #expect(system.contains("Include limit only when the user explicitly states a count"))
        #expect(!system.contains("or 10"),
                "the translator must not invent an aggregate result count")
        #expect(messages.last?["content"] as? String == "How old was Timmy here?")
        #expect(body["think"] as? Bool == false)
    }

    @Test func strictV2DecodeRejectsInvalidModelOutput() async {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"graph","payload":{"people":["Ellen"],"operation":"kinship","relation":"godparent"}}"#)
        }

        do {
            _ = try await translator.translateAST("How is Ellen related?")
            Issue.record("unknown relation should be rejected")
        } catch let error as NLTranslatorError {
            guard case .badResponse = error else {
                Issue.record("expected badResponse, got \(error)")
                return
            }
            #expect(!error.isRetryableOnAnotherHost)
        } catch {
            Issue.record("expected classified translator error, got \(error)")
        }
    }

    @Test func invalidV2OutputDoesNotWalkTheFleet() async throws {
        let recorder = ASTRequestRecorder()
        var template = OllamaQueryTranslator()
        template.transport = .fake { url, body in
            await recorder.record(url: url, body: body)
            if url.contains("first.local") {
                return astReply(#"{"shape":"presence","payload":{"answer":"Donna was there"}}"#)
            }
            return validASTReply
        }
        var failover = OllamaFailoverTranslator(
            hosts: ["first.local", "second.local"], template: template)
        failover.probeBeforeRequest = false

        do {
            _ = try await failover.translateAST("Was Donna there?")
            Issue.record("invalid first response should throw")
        } catch let error as NLTranslatorError {
            guard case .badResponse = error else {
                Issue.record("expected badResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("expected classified translator error, got \(error)")
        }

        let requests = await recorder.snapshot()
        try #require(requests.count == 2,
                     "one rejected v2 answer earns one same-host repair")
        #expect(requests.allSatisfy { $0.0.contains("first.local") },
                "bad model output must never walk to second.local")

        let firstBody = String(decoding: requests[0].1, as: UTF8.self)
        let repairBody = String(decoding: requests[1].1, as: UTF8.self)
        #expect(!firstBody.contains("PREVIOUS ANSWER WAS REJECTED"))
        #expect(repairBody.contains("PREVIOUS ANSWER WAS REJECTED"),
                "the bounded retry must carry the strict decoder's complaint")
    }

    @Test func v2HostErrorFailsOverAndReportsResponder() async throws {
        let recorder = ASTRequestRecorder()
        let responder = ASTResponderBox()
        var template = OllamaQueryTranslator()
        template.transport = .fake { url, body in
            await recorder.record(url: url, body: body)
            return url.contains("sick.local")
                ? .status(503, "temporarily unavailable")
                : validASTReply
        }
        var failover = OllamaFailoverTranslator(
            hosts: ["sick.local", "healthy.local"],
            template: template,
            onResponder: { responder.set($0) })
        failover.probeBeforeRequest = false
        failover.connectionRetryDelay = .zero

        _ = try await failover.translateAST("How old was Timmy here?")

        let requests = await recorder.snapshot()
        try #require(requests.count == 3,
                     "one transient 5xx retry must precede fleet failover")
        let urls = requests.map(\.0)
        #expect(urls[0].contains("sick.local"))
        #expect(urls[1].contains("sick.local"),
                "a transient 5xx earns one bounded same-host retry")
        #expect(urls[2].contains("healthy.local"))
        #expect(responder.get() == "healthy.local")
    }

    // MARK: - Defaulted temporal reference vs. an explicit year in the question
    //
    // Review finding on top of 828e00da: Homebrew ollama 0.33.2 returns HTTP
    // 501 for structured output, the fallback retry drops `format:`, and the
    // unconstrained model may omit a temporal payload's `reference` entirely
    // — `ArchivistQueryAST.Temporal.init` then defaults it to
    // `.currentSelection` so the turn can decode at all. That default is
    // right for "how old is Tim" but was silently WRONG for "how old was
    // Tim in 1995": the decoder never sees the original question, so it
    // cannot tell the two apart. `OllamaQueryTranslator.repairDefaultedTemporalReference`
    // does that disambiguation after decoding, gated on
    // `ArchivistQueryAST.temporalReferenceDefaultedNote` — which is emitted
    // ONLY when the key was truly absent, never when the model supplied any
    // reference, so a model-supplied answer always wins.

    @Test func unconstrainedTemporalOmissionStaysCurrentSelectionWithNoYearInQuestion() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age"}}"#)
        }
        let result = try await translator.translateAST("how old is Tim")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .currentSelection)))
    }

    /// THE REVIEW FINDING: 828e00da's default silently changed the meaning
    /// of a question that states a year. "how old was Tim in 1995" must
    /// resolve to explicitYear(1995), never currentSelection.
    @Test func aDefaultedTemporalReferenceAdoptsTheSingleYearStatedInTheQuestion() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age"}}"#)
        }
        let result = try await translator.translateAST("how old was Tim in 1995")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .explicitYear(1995))))
    }

    @Test func aDefaultedTemporalReferenceStaysDefaultedWhenTheQuestionNamesTwoYears() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age"}}"#)
        }
        let result = try await translator.translateAST(
            "how old were the boys in 1995 and 2001")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .currentSelection)),
            "ambiguous between two stated years — an 'as of now' answer beats a guess")
    }

    @Test func modelSuppliedCurrentSelectionIsNeverSecondGuessedByAYearInTheQuestion() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age","reference":{"kind":"currentSelection"}}}"#)
        }
        let result = try await translator.translateAST("how old was Tim in 1995, here")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .currentSelection)),
            "the model DID supply a reference — its answer wins even though the text names a year")
    }

    @Test func modelSuppliedExplicitYearIsNeverOverriddenByADifferentYearInTheQuestion() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age","reference":{"kind":"explicitYear","year":1990}}}"#)
        }
        let result = try await translator.translateAST(
            "how old was Tim in 1990, and how old was he in 2001")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .explicitYear(1990))))
    }

    @Test func aYearOutsideTheContractsRangeIsNotAdoptedByTheRepair() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"tim","operation":"age"}}"#)
        }
        let result = try await translator.translateAST("how old was Tim in 3025")
        #expect(result == .temporal(.init(
            subject: "tim", operation: .age, reference: .currentSelection)))
    }

    /// SENSOR pinning the fixed behavior at the exact boundary the review
    /// flagged: Homebrew ollama 0.33.2 returns HTTP 501 for structured
    /// output, so the fallback retry drops `format:` and the unconstrained
    /// model may omit `reference` entirely (828e00da). The resulting
    /// `.currentSelection` default must never stand in for a year the user
    /// actually said.
    @Test func aDefaultedTemporalReferenceNeverOverridesAYearTheUserSaid() async throws {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in
            astReply(#"{"shape":"temporal","payload":{"subject":"donna","operation":"age"}}"#)
        }
        let result = try await translator.translateAST("how old was Donna in 2005")
        #expect(result == .temporal(.init(
            subject: "donna", operation: .age, reference: .explicitYear(2005))),
            "regression: the 828e00da default must not eat an explicit year")
    }

    @Test func existingV1EntryPointStillAcceptsMinimalLegacyReply() async throws {
        let recorder = ASTRequestRecorder()
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { url, body in
            await recorder.record(url: url, body: body)
            return astReply(#"{"people":["Donna"]}"#)
        }

        let spec = try await translator.translate("Donna")
        #expect(spec == NLQuerySpec(people: ["Donna"]))

        let requests = await recorder.snapshot()
        let request = try #require(requests.first)
        let rawBody = try JSONSerialization.jsonObject(with: request.1)
        let body = try #require(rawBody as? [String: Any])
        let format = try #require(body["format"] as? [String: Any])
        #expect(format["properties"] != nil)
        #expect(format["oneOf"] == nil,
                "the existing v1 entry point must keep requesting its v1 schema")
    }
}
