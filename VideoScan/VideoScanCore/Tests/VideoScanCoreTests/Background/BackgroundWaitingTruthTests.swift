// BackgroundWaitingTruthTests.swift — what is left of the 11/03 checklist
// review (Codex cycle #220) after 2026-11-04 removed the keyboard backoff,
// the deferred unit and the idle exit (Rick: the helper owns its schedule).
// Those tests (F3 deferral, F5 idle exit) went with the behaviour; what
// stays is that the `waiting` field still decodes and still reads as
// waiting — an older helper may still send it.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Background truth — an older helper's `waiting` still decodes and still says waiting")
struct BackgroundWaitingTruthTests {

    @Test("COMPAT F3: a status payload from a build without `waiting` still decodes (additive field, same schema)")
    func olderPayloadDecodes() throws {
        let job = JobProgressSnapshot(id: JobID(rawValue: "J"), kind: .noop, lane: "default", title: "t", subtitle: "",
                                      completedUnits: 0, totalUnits: 1, skippedUnits: 0, failedUnits: 0,
                                      state: .running, startedAt: nil, finishedAt: nil)
        let data = try BackgroundPayloadCodec.encode(job)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var body = try #require(object["body"] as? [String: Any])
        body.removeValue(forKey: "waiting")
        object["body"] = body
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try BackgroundPayloadCodec.decode(JobProgressSnapshot.self, from: old)
        #expect(decoded.waiting == nil)
        #expect(decoded == job)
    }

    @Test("TRUE: a payload with `waiting` set (an older helper) is never shown running — outline glyph, waiting words")
    func olderWaitingPayloadIsNotRunning() {
        var job = JobProgressSnapshot(id: JobID(rawValue: "J"), kind: .era, lane: "model", title: "Machine era (8B)", subtitle: "",
                                      completedUnits: 3, totalUnits: 9, skippedUnits: 0, failedUnits: 0,
                                      state: .running, startedAt: Date(), finishedAt: nil)
        job.waiting = "you're at the Mac"
        let p = BackgroundMenuPresentation.from(ServiceStatus(processIdentifier: 1, startedAt: Date(), backoff: .trickle,
                                                              jobs: [job], idleSeconds: 0))
        #expect(p.icon == .waiting)
        #expect(p.jobs.first?.words.hasSuffix("waiting — you're at the Mac") == true, "\(p.jobs.first?.words ?? "-")")
    }
}
