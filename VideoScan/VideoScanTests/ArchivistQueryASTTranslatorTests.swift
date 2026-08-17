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

    @Test func invalidV2OutputDoesNotWalkTheFleet() async {
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
        #expect(requests.count == 1)
        #expect(requests[0].0.contains("first.local"))
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

        _ = try await failover.translateAST("How old was Timmy here?")

        let requests = await recorder.snapshot()
        let urls = requests.map(\.0)
        #expect(urls.count == 2)
        #expect(urls[0].contains("sick.local"))
        #expect(urls[1].contains("healthy.local"))
        #expect(responder.get() == "healthy.local")
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
