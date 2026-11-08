// HallieCloudBrainCanarySensorTests.swift
//
// The canary for Hallie's cloud brain (DECISIONS 2026-10-10 R6; CLAUDE.md
// rule 13): a request carrying family media must NEVER reach the transport.
// The transport is a URLProtocol stub that records every request it is
// handed; a refused request leaves its ledger empty. A positive control
// proves the stub does see clean traffic, so an empty ledger means "refused",
// not "the stub was never wired".
//
// The source half pins the shape that makes the canary meaningful: one file
// talks to api.anthropic.com, and its only request body comes from
// RemoteSerializer, the one serializer.
//
// Seated in the sensor lane (suite name + this file reads source). No real
// network anywhere.

import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie cloud brain canary sensor")
struct HallieCloudBrainCanarySensor {

    static func hostile(_ part: RemotePart) -> RemoteRequest {
        RemoteRequest(model: "claude-sonnet-5-5",
                      system: [.text("Phrase the plan.", .public)],
                      user: [.text("Who is in this clip?", .familyText), part],
                      tool: nil, maxTokens: 64)
    }

    static let mediaParts: [(String, RemotePart)] = [
        ("image", .image(Data(repeating: 0xFF, count: 64))),
        ("audio", .audio(Data(repeating: 0x01, count: 64))),
        ("video frame", .videoFrame(Data(repeating: 0x02, count: 64))),
        ("embedding", .embedding([0.1, 0.2, 0.3])),
        ("file bytes", .fileBytes(Data(repeating: 0x03, count: 64))),
        ("text", .text("transcript: we're at the cape", .familyMedia)),
    ]

    @Test("every family-media part is refused before the transport sees a byte")
    func familyMediaNeverReachesTheTransport() async {
        for (kind, part) in Self.mediaParts {
            let (session, token) = hallieCloudStubSession()
            let brain = hallieStubbedCloudBrain(session)
            await #expect(throws: HallieBrainError.familyMediaRefused(kind)) {
                _ = try await brain.send(Self.hostile(part))
            }
            #expect(HallieCloudStubLedger.shared.seen(token).isEmpty, "\(kind) reached the transport")
        }
    }

    @Test("media smuggled inside text (data: URI, long base64) is refused too")
    func smuggledMediaTextNeverReachesTheTransport() async {
        let smuggled = [
            "see data:image/jpeg;base64,/9j/4AAQSkZJRg==",
            "frame " + String(repeating: "QUJD", count: 600),
        ]
        for text in smuggled {
            let (session, token) = hallieCloudStubSession()
            let brain = hallieStubbedCloudBrain(session)
            await #expect(throws: HallieBrainError.self) {
                _ = try await brain.send(Self.hostile(.text(text, .familyText)))
            }
            #expect(HallieCloudStubLedger.shared.seen(token).isEmpty)
        }
    }

    @Test("the real composer call site: a familyMedia plan is refused, nothing sent")
    func composeWithFamilyMediaClassSendsNothing() async {
        let (session, token) = hallieCloudStubSession()
        let brain = hallieStubbedCloudBrain(session)
        await #expect(throws: HallieBrainError.familyMediaRefused("text")) {
            _ = try await brain.composePlainText(
                system: "You are Hallie.", user: "[c1] the transcript says …",
                dataClass: .familyMedia)
        }
        #expect(HallieCloudStubLedger.shared.seen(token).isEmpty)
    }

    /// codex #254 P1: the file dossier quotes "The transcript opens: …" in
    /// its prose with no transcript basis, so a citation-only class let the
    /// transcript reach Anthropic. Real executor → derive → composer → stub.
    @Test("a file dossier quoting its transcript never reaches the cloud")
    func recordDossierTranscriptNeverReachesCloud() async {
        let canary = "Private family transcript canary."
        let snapshot = ArchivistRecordDossierSnapshot(presence: ArchivistPresenceRecordSnapshot(
            fullPath: "/fixture.mov", transcript: canary, transcriptModel: "whisper"))
        let result = ArchivistRecordExecutor.execute(
            .init(reference: .currentSelection, operations: [.about]),
            snapshot: snapshot, ownerName: nil)
        #expect(result.prose.contains(canary), "fixture must exercise the quoting path")
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.dataClass == .familyMedia)

        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200, body: #"{"content":[{"type":"text","text":"leaked"}]}"#)
        let brain = hallieStubbedCloudBrain(session)
        let composer = HallieGroundedComposer(personaName: "Hallie Mae") { system, user in
            try await brain.composePlainText(system: system, user: user, dataClass: plan.dataClass)
        }
        let outcome = await composer.compose(plan: plan, history: [])
        #expect(outcome.composedBy == .template)
        #expect(HallieCloudStubLedger.shared.seen(token).isEmpty)
    }

    @Test("positive control: a clean familyText request does reach the stub")
    func cleanRequestReachesTheStub() async throws {
        let (session, token) = hallieCloudStubSession()
        HallieCloudStubLedger.shared.queue(
            token, status: 200,
            body: #"{"content":[{"type":"text","text":"Donna is in 12 videos."}]}"#)
        let brain = hallieStubbedCloudBrain(session)
        let text = try await brain.composePlainText(
            system: "You are Hallie.", user: "[c1] Donna appears in 12 videos.",
            dataClass: .familyText)
        #expect(text == "Donna is in 12 videos.")
        let seen = HallieCloudStubLedger.shared.seen(token)
        #expect(seen.count == 1)
        #expect(seen.first?.request.url?.host == "api.anthropic.com")
    }

    @Test("one file talks to Anthropic, and its only body comes from RemoteSerializer")
    func oneAdapterOneSerializer() throws {
        let talkers = SourceTree.appSources.filter { source in
            let text = (try? String(contentsOf: source.url, encoding: .utf8)) ?? ""
            return text.contains("api.anthropic.com") || text.contains("\"x-api-key\"")
        }.map(\.relative)
        #expect(talkers == ["Hallie/LLM/AnthropicBrain.swift"])

        let url = try #require(SourceTree.appSourceURL(named: "AnthropicBrain.swift"))
        let code = SourceTree.scan(try String(contentsOf: url, encoding: .utf8)).code
        #expect(code.contains("let body = try RemoteSerializer.anthropicMessagesBody(request)"))
        // The single POST is fed that body and nothing else.
        #expect(code.components(separatedBy: "try await post(").count - 1 == 1)
        #expect(code.contains("try await post(body)"))
        #expect(code.components(separatedBy: "httpBody =").count - 1 == 1)
    }
}
