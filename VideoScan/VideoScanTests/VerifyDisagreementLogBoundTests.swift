// VerifyDisagreementLogBoundTests.swift
// Codex review 2026-10-02, finding 8 (P2): Verify's persistent
// "DATE DISAGREES" line joined EVERY disagreement — 50k filename-bearing
// entries in one videoscan.log message on a large archive. The console
// already capped its sample at 20; the persistent line now carries the
// total count plus the same 20-entry sample, never more.
//
// Swaps the global appLog for an in-memory sink (serialized suite).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Codex 2026-10-02 #8 — Verify's disagreement log line is bounded", .serialized)
@MainActor
struct VerifyDisagreementLogBoundTests {

    @Test("50,000 disagreements → the line carries the total and exactly 20 entries")
    func boundedAt50k() {
        let lines = (0..<50_000).map { "30_Video/1990-1999/1994/1994-xx-xx_test_clip_\($0).mov — catalog says 1990 but its index says 1994" }
        let line = VerifyArchiveCopiesJob.dateDisagreementLogLine(lines)
        #expect(line.contains("(50000)"), "\(line)")
        #expect(line.components(separatedBy: " | ").count == 20, "20 sample entries")
        #expect(line.contains("49980 more"), "\(line)")
        #expect(line.utf8.count < 20 * 120 + 200, "bounded: \(line.utf8.count) bytes")
        #expect(!line.contains("test_clip_20.mov"), "entry 21 is not in the sample")
    }

    @Test("a real Verify run over 25 disagreeing copies logs ONE bounded line (25 total, 20 named)")
    func realRunBounded() async throws {
        let (sb, model) = try PromoteIntegrityHarness.setup("verify_bound")
        defer { sb.cleanup() }
        var ids: [UUID] = []
        for i in 0..<25 {
            ids.append(try PromoteIntegrityHarness.source(sb, model, name: "test_v\(i).mov", seed: UInt64(500 + i), bytes: 2_000 + i).id)
        }
        _ = try await PromoteIntegrityHarness.run(model, ids: ids) { plan in
            for id in ids { plan.archiveDateOverrides[id] = .year(1947); plan.archiveDateSources[id] = .typed }
        }
        for id in ids {
            let src = try #require(model.record(forID: id))
            let copy = try #require(model.masterArchiveCopy(of: src))
            copy.userDate = "1990"; copy.userDateConfidence = UserDateConfidence.known.rawValue
        }
        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let job = VerifyArchiveCopiesJob(model: model)
        job.start(); await job.task?.value
        #expect(job.tally.dateDisagreements == 25)
        #expect(job.dateDisagreementLines.count == 25, "the UI keeps every line")
        let logged = sink.lines.filter { $0.contains("DATE DISAGREES") }
        #expect(logged.count == 1, "\(logged)")
        let line = try #require(logged.first)
        #expect(line.contains("(25)"), "\(line)")
        #expect(line.components(separatedBy: " | ").count == 20, "\(line)")
        #expect(line.contains("5 more"), "\(line)")
    }
}
