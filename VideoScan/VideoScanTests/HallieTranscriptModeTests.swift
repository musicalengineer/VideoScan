// HallieTranscriptModeTests.swift
// Design §3.7 step 8 — HallieTranscriptEvent.mode is additive: a new line
// round-trips it, an old line without it decodes with nil, and the two
// bounding copies keep it.

import Foundation
import Testing
@testable import VideoScan

@Suite("Transcript mode field (design §3.7 step 8)")
struct HallieTranscriptModeTests {
    @Test func newLinesRoundTripAndOldLinesDecodeWithoutIt() throws {
        let event = HallieTranscriptEvent(
            sessionID: UUID(), sequence: 1, client: .shell, kind: .assistant,
            text: "John Hastings was born in Kenilworth.", route: "graph", outcome: "answered",
            mode: "tree")
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(HallieTranscriptEvent.self, from: data)
        #expect(decoded.mode == "tree")
        #expect(decoded.route == "graph")

        // An older log line: the same JSON with no "mode" key at all.
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "mode")
        let legacy = try JSONDecoder().decode(
            HallieTranscriptEvent.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.mode == nil)
        #expect(legacy.text == event.text)
        #expect(legacy.outcome == "answered")

        // The bounding copies carry it.
        #expect(event.strippedForLog().mode == "tree")
        #expect(event.boundedForLog().mode == "tree")
        // User and system events default to none.
        let user = HallieTranscriptEvent(sessionID: UUID(), sequence: 2, client: .app, kind: .user, text: "hi")
        #expect(user.mode == nil)
    }
}
