// BackgroundPayloadCodecTests.swift — the one serializer (design §3.3, §6 logic).
//
// Dimensions: LOGIC (round trips, refusals in words). Scale/media/isolation
// n/a — a few hundred bytes per payload, no files.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("BackgroundPayloadCodec — round trips and refusals in words")
struct BackgroundPayloadCodecTests {

    @Test("JobRequest, ServiceStatus and JobProgressSnapshot round-trip through the envelope")
    func roundTrips() throws {
        let request = JobRequest(kind: .noop, lane: "models", parameters: ["units": "7"],
                                 resources: JobResourceProfile(peakMemoryBytes: 1 << 30, needsResidentModel: true, secondsPerUnitEstimate: 2.5),
                                 requestedAt: Date(timeIntervalSince1970: 1_800_000_000), requestedBy: "cli")
        let back = try BackgroundPayloadCodec.decode(JobRequest.self, from: try BackgroundPayloadCodec.encode(request))
        #expect(back == request)

        let snapshot = JobProgressSnapshot(id: request.id, kind: .noop, lane: "models", title: "No-op job", subtitle: "unit 3 of 7",
                                           completedUnits: 3, totalUnits: 7, skippedUnits: 1, failedUnits: 0,
                                           state: .paused(reason: "thermal"), startedAt: Date(timeIntervalSince1970: 1_800_000_001), finishedAt: nil)
        let status = ServiceStatus(processIdentifier: 4242, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   backoff: .paused(reason: "thermal"), jobs: [snapshot], idleSeconds: 12)
        let statusBack = try BackgroundPayloadCodec.decode(ServiceStatus.self, from: try BackgroundPayloadCodec.encode(status))
        #expect(statusBack == status)
        #expect(statusBack.jobs[0].fraction == 3.0 / 7.0)
        #expect(statusBack.summaryLine.contains("paused (thermal)"))
        #expect(statusBack.summaryLine.contains("1 active of 1 job(s)"))

        let reply = try BackgroundPayloadCodec.decode(EnqueueReply.self, from: try BackgroundPayloadCodec.encode(EnqueueReply.refused(Refusal("no"))))
        #expect(reply == .refused(Refusal("no")))
    }

    @Test("the envelope carries this build's schema and the payload's type name")
    func envelopeShape() throws {
        let data = try BackgroundPayloadCodec.encode(JobID(rawValue: "abc"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schema"] as? Int == BackgroundProtocolVersion.current)
        #expect(object?["kind"] as? String == "JobID")
    }

    @Test("a schema mismatch is refused in words that name both versions")
    func schemaMismatch() throws {
        let other = BackgroundProtocolVersion.current + 1
        let data = Data("{\"schema\":\(other),\"kind\":\"JobID\",\"body\":{\"rawValue\":\"x\"}}".utf8)
        let error = #expect(throws: Refusal.self) { try BackgroundPayloadCodec.decode(JobID.self, from: data) }
        #expect(error?.words.contains("schema \(other)") == true)
        #expect(error?.words.contains("schema \(BackgroundProtocolVersion.current)") == true)
    }

    @Test("a payload of the wrong kind is refused, not decoded into the wrong type")
    func kindMismatch() throws {
        let data = try BackgroundPayloadCodec.encode(JobID(rawValue: "abc"))
        let error = #expect(throws: Refusal.self) { try BackgroundPayloadCodec.decode(JobRequest.self, from: data) }
        #expect(error?.words == "expected a JobRequest payload, got JobID")
    }

    @Test("bytes that are not an envelope (a partial file) are refused in words")
    func garbage() {
        let partial = Data("{\"schema\":1,\"kind\":\"JobReq".utf8)
        let error = #expect(throws: Refusal.self) { try BackgroundPayloadCodec.decode(JobRequest.self, from: partial) }
        #expect(error?.words.hasPrefix("not a background payload") == true)
    }

    @Test("the names derive from the app's bundle identifier")
    func names() {
        #expect(BackgroundServiceNames.helperBundleIdentifier(appBundleIdentifier: "Rick-Breen.VideoScan") == "Rick-Breen.VideoScan.Background")
        #expect(BackgroundServiceNames.launchdPlistName(appBundleIdentifier: "Rick-Breen.VideoScan") == "Rick-Breen.VideoScan.Background.plist")
        #expect(BackgroundServiceNames.appBundleIdentifier(helperBundleIdentifier: "Rick-Breen.VideoScan.Background") == "Rick-Breen.VideoScan")
        #expect(BackgroundServiceNames.appBundleIdentifier(helperBundleIdentifier: "Rick-Breen.VideoScan") == nil)
    }
}
