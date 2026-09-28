// VerifyVideoJobTests.swift
// LOGIC + ISOLATION + SCALE + SENSOR dimensions for the Verify Video MFO
// job and its catalog surfaces (Rick 2026-09-23):
//
//   * Job logic via the diagnoseOverride seam: OK / Broken / failed probe
//     / no-video — verdict persistence, summary wording, "a failed probe
//     persists NOTHING", persistence onto a replacement record (rescan).
//   * Center: kind/badge/verb, duplicate-dispatch refusal, START/OUTCOME
//     lines in videoscan.log (InMemoryLogSink — never the real log).
//   * Codable: never-verified records stay byte-identical; verified ones
//     round-trip; clone parity.
//   * ISOLATION: the verdict persistence path never touches the real
//     Application Support tree.
//   * SCALE: `notes:broken` and the red row tint over 100k synthetic
//     records inside an explicit time budget.
//   * SENSORS: the menu item sits right after Verify Audio, carries no
//     ellipsis (nothing opens before the action), is O(selection); the
//     "Trim Master…" item stays retired.
//   * One real job end to end on a synthetic mp4 (media dimension).

import Testing
import Foundation
import SwiftUI
@testable import VideoScan

@MainActor
private func makeRecord(name: String, path: String? = nil,
                        stream: StreamType = .videoAndAudio) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path ?? "/Volumes/T/\(name)"
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.streamTypeRaw = stream.rawValue
    return r
}

private func okDiagnosis() -> VideoVerifyDiagnosis {
    VideoVerifyDiagnosis(findings: [], facts: VerifyVideoFixtures.dickyHealthy,
                         sample: nil, decode: VideoDecodeFacts(coverage: .complete))
}

private func dickyDiagnosis() -> VideoVerifyDiagnosis {
    let f = VerifyVideoFixtures.dickyBroken
    return VideoVerifyDiagnosis(
        findings: VerifyVideoRules.findings(facts: f, sample: nil, decode: nil),
        facts: f, sample: nil, decode: nil)
}

// MARK: - Job logic

@Suite("VerifyVideoJob — logic")
@MainActor
struct VerifyVideoJobLogicTests {

    @Test func okDiagnosisFinishesOKAndPersists() async {
        let model = VideoScanModel()
        let rec = makeRecord(name: "fine.mp4")
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model, diagnoseOverride: { _ in okDiagnosis() })
        job.start()
        await job.task?.value
        #expect(job.state == .finished(summary: "OK — the picture checked out."))
        #expect(rec.videoVerifyStatus == "ok")
        #expect(rec.videoVerifyNote == "")
        #expect(rec.videoVerifyDate != nil)
        #expect(job.diagnosis != nil)
        #expect(job.finishedAt != nil)
        #expect(rec.audioVerifyStatus == "", "Verify Video never writes the audio verdict")
    }

    @Test func brokenDiagnosisSummaryIsThePersistedNote() async {
        let model = VideoScanModel()
        let rec = makeRecord(name: "DickyTheBoysDadBreen-1985.mp4")
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model, diagnoseOverride: { _ in dickyDiagnosis() })
        job.start()
        await job.task?.value
        guard case .finished(let summary) = job.state else {
            Issue.record("expected finished, got \(job.state)"); return
        }
        #expect(rec.videoVerifyStatus == "broken")
        #expect(summary == rec.videoVerifyNote)
        #expect(rec.videoVerifyNote.hasPrefix("Broken video — each frame stored ~2,000× — broken encode; 46 GB for 71 s"))
        #expect(rec.filenameColor == .red && rec.rowColor == .red.opacity(0.15),
                "a broken picture wears the damaged-row red")
    }

    @Test func failedProbePersistsNothing() async {
        let model = VideoScanModel()
        let rec = makeRecord(name: "offline.mp4")
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model, diagnoseOverride: { _ in
            throw VideoVerifyProbeError.probeFailed("the drive went to sleep")
        })
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else {
            Issue.record("expected failed, got \(job.state)"); return
        }
        #expect(message == "Could not check the picture — the drive went to sleep")
        #expect(rec.videoVerifyStatus == "" && rec.videoVerifyDate == nil,
                "couldn't check is not a verdict")
    }

    @Test func noVideoStreamIsAPlainFailureWithNoVerdict() async {
        let model = VideoScanModel()
        let rec = makeRecord(name: "song.m4a", stream: .audioOnly)
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model, diagnoseOverride: { _ in
            throw VideoVerifyProbeError.noVideoStream
        })
        job.start()
        await job.task?.value
        #expect(job.state == .failed(message: "This file has no video stream to check — nothing was recorded."))
        #expect(rec.videoVerifyStatus == "")
    }

    @Test func verdictPersistsToReplacementRecordWithSameID() async throws {
        let model = VideoScanModel()
        let original = makeRecord(name: "rescan.mp4")
        model.records = [original]
        let gate = AsyncSemaphore(limit: 1)
        try await gate.wait()
        let job = VerifyVideoJob(
            record: original, model: model,
            gates: [MediaVolumeGate(root: "/Volumes/T", label: "T", semaphore: gate)],
            diagnoseOverride: { _ in dickyDiagnosis() })
        job.start()
        // Rescan swaps the instance while the job waits for its gate.
        try await Task.sleep(for: .milliseconds(50))
        let replacement = VideoRecord(id: original.id)
        replacement.filename = original.filename
        replacement.fullPath = original.fullPath
        replacement.directory = original.directory
        replacement.streamTypeRaw = original.streamTypeRaw
        model.records = [replacement]
        await gate.signal()
        await job.task?.value
        #expect(replacement.videoVerifyStatus == "broken")
        #expect(original.videoVerifyStatus == "", "the detached instance is not the catalog's")
    }

    @Test func cancelWhileQueuedEndsCancelledAndPersistsNothing() async throws {
        let model = VideoScanModel()
        let rec = makeRecord(name: "queued.mp4")
        model.records = [rec]
        let gate = AsyncSemaphore(limit: 1)
        try await gate.wait()
        let job = VerifyVideoJob(
            record: rec, model: model,
            gates: [MediaVolumeGate(root: "/Volumes/T", label: "T", semaphore: gate)],
            diagnoseOverride: { _ in okDiagnosis() })
        job.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(job.subtitle.hasPrefix("Waiting for T"), "\(job.subtitle)")
        job.cancel()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(rec.videoVerifyStatus == "")
        await gate.signal()
    }

    @Test func pausableLikeVerifyAudio() {
        let job = VerifyVideoJob(record: makeRecord(name: "p.mp4"), model: VideoScanModel())
        #expect(job.canPause)
        #expect(job.isIndeterminate, "no fraction until the decode reports one — honest progress")
    }
}

// MARK: - Center

@Suite("VerifyVideo — MFO center", .serialized)
@MainActor
struct VerifyVideoCenterTests {

    @Test func kindWords() {
        #expect(MediaFileOperationKind.verifyVideo.badgeText == "Verify Video")
        #expect(MediaFileOperationKind.verifyVideo.logVerb == "verify video")
        #expect(MediaFileOperationKind.verifyVideo.hasDetailView)
        #expect(MediaFileOperationKind.verifyVideo.rawValue == "verifyVideo")
    }

    @Test func duplicateDispatchIsRefusedAndLogged() async throws {
        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }

        let model = VideoScanModel()
        let rec = makeRecord(name: "dup-\(UUID().uuidString).mp4")
        model.records = [rec]
        let center = MediaFileOperationsCenter()
        let first = center.startVerifyVideo(record: rec, model: model, diagnoseOverride: { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return okDiagnosis()
        })
        #expect(first != nil)
        let second = center.startVerifyVideo(record: rec, model: model, diagnoseOverride: { _ in okDiagnosis() })
        #expect(second == nil)
        #expect(sink.lines.contains { $0.hasPrefix("verify video refused: \(rec.filename)") })
        #expect(sink.lines.contains { $0 == "verify video: \(rec.filename) — check the picture (header, timestamps, full decode)" })
        await first?.task?.value
        // OUTCOME line from the Center's terminal watcher.
        for _ in 0..<50 where !sink.lines.contains(where: { $0.hasPrefix("verify video done: \(rec.filename)") }) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sink.lines.contains { $0 == "verify video done: \(rec.filename) — OK — the picture checked out." })
    }
}

// MARK: - Codable schema

@Suite("VerifyVideo — Codable schema")
@MainActor
struct VerifyVideoCodableTests {

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func neverVerifiedRecordsGainZeroBytes() throws {
        let r = VideoRecord()
        r.filename = "legacy.mov"
        let first = try encoder().encode(VideoRecordDTO(r))
        #expect(!String(decoding: first, as: UTF8.self).contains("videoVerify"))
        let again = try encoder().encode(VideoRecordDTO(try decoder().decode(VideoRecord.self, from: first)))
        #expect(first == again, "legacy catalogs stay byte-identical")
    }

    @Test func verifiedRecordsRoundTripAndClone() throws {
        let r = VideoRecord()
        r.filename = "dicky.mp4"
        r.videoVerifyStatus = "broken"
        r.videoVerifyNote = "Broken video — each frame stored ~2,000× — broken encode; 46 GB for 71 s"
        r.videoVerifyDate = Date(timeIntervalSince1970: 1_790_000_000)
        let data = try encoder().encode(VideoRecordDTO(r))
        let back = try decoder().decode(VideoRecord.self, from: data)
        #expect(back.videoVerifyStatus == "broken")
        #expect(back.videoVerifyNote == r.videoVerifyNote)
        #expect(back.videoVerifyDate == r.videoVerifyDate)
        let clone = r.snapshotClone()
        #expect(clone.videoVerifyStatus == "broken" && clone.videoVerifyNote == r.videoVerifyNote
                && clone.videoVerifyDate == r.videoVerifyDate)
    }
}

// MARK: - Isolation

@Suite("VerifyVideo — persistence isolation", .serialized)
@MainActor
struct VerifyVideoIsolationTests {

    @Test func verdictPersistenceNeverWritesTheRealCatalog() async throws {
        #expect(TestEnvironment.isTestHost,
                "test host detection broke — the save below would hit the REAL catalog")
        let before = AppSupportSnapshot.take()
        let model = VideoScanModel()
        let rec = makeRecord(name: "iso-\(UUID().uuidString).mp4")
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model, diagnoseOverride: { _ in dickyDiagnosis() })
        job.start()
        await job.task?.value
        model.saveCatalogNow()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rec.videoVerifyStatus == "broken", "the poisoned write did happen in memory")
        #expect(AppSupportSnapshot.take() == before,
                "verdict persistence touched the REAL Application Support tree from a test")
    }
}

// MARK: - Scale

@Suite("VerifyVideo — scale", .serialized)
@MainActor
struct VerifyVideoScaleTests {

    @Test func notesBrokenAndRowTintOver100kRecords() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.filename = "clip\(i).mp4"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue   // an unprobed row is red for its own reason
            if i % 10 == 0 {
                r.videoVerifyStatus = "broken"
                r.videoVerifyNote = "Broken video — each frame stored ~2,000× — broken encode"
            } else if i % 10 == 1 {
                r.videoVerifyStatus = "warning"
                r.videoVerifyNote = "Video warning — gap of 5.0 s in the timestamps"
            }
            records.append(r)
        }
        let clock = ContinuousClock()
        var matched = 0
        var red = 0
        let elapsed = clock.measure {
            for r in records {
                if pfNotesFieldMatches(value: "broken", rec: r) { matched += 1 }
                if r.filenameColor == .red { red += 1 }
            }
        }
        #expect(matched == 10_000, "notes:broken finds exactly the broken rows")
        #expect(red == 10_000, "warnings are not painted red")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(5)), "100k notes:+tint pass took \(elapsed) (Debug budget 5 s)")
    }
}

// MARK: - Source sensors (menu)

@Suite("VerifyVideo — catalog menu sensor")
struct VerifyVideoMenuSensorTests {

    private func tableSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/CatalogContent+Table.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func verifyVideoSitsRightAfterVerifyAudio() throws {
        let s = try tableSource()
        let audio = try #require(s.range(of: ".accessibilityIdentifier(\"catalog.row.verifyAudio\")"))
        let next = try #require(s.range(of: "verifyVideoMenuItem(activeRecs: activeRecs)",
                                         range: audio.upperBound..<s.endIndex))
        let between = s[audio.upperBound..<next.lowerBound]
        #expect(!between.contains("Button("), "nothing may sit between Verify Audio and Verify Video")
    }

    @Test func labelHasNoEllipsisLikeVerifyAudio() throws {
        let s = try tableSource()
        #expect(s.contains("\"Verify Video\")"))
        #expect(s.contains("\"Verify Audio\")"))
        #expect(!s.contains("Verify Video…") && !s.contains("Verify Audio…"),
                "macOS: '…' only when a dialog opens first — both verbs start a job directly")
    }

    @Test func menuBuilderIsOSelectionNotORecords() throws {
        let s = try tableSource()
        let start = try #require(s.range(of: "private func verifyVideoMenuItem("))
        let end = try #require(s.range(of: "/// Verify Audio + repair-lifecycle", range: start.upperBound..<s.endIndex))
        let body = s[start.upperBound..<end.lowerBound]
        #expect(!body.contains("model.records") && !body.contains("records.filter"),
                "NO O(records) work in a menu builder")
    }

    @Test func trimMasterMenuItemStaysRetired() throws {
        let s = try tableSource()
        #expect(!s.contains("Button(\"Trim Master…\")"))
        #expect(!s.contains("catalog.row.trimMaster"))
    }
}

// MARK: - Media: one real job end to end

@Suite("VerifyVideoJob — real media", .serialized)
@MainActor
struct VerifyVideoJobMediaTests {

    @Test(.timeLimit(.minutes(2)))
    func realMp4RunsThroughTheJobAndPersistsOK() async throws {
        try #require(VerifyVideoTestMedia.toolsAvailable)
        let dir = try VerifyVideoTestMedia.makeScratchDir("job")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyVideoTestMedia.generate(
            into: dir, name: "test_vv_job.mp4", videoCodec: "libx264",
            extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let model = VideoScanModel()
        let rec = makeRecord(name: "test_vv_job.mp4", path: path)
        model.records = [rec]
        let job = VerifyVideoJob(record: rec, model: model)
        job.start()
        await job.task?.value
        #expect(job.state == .finished(summary: "OK — the picture checked out."), "\(job.state)")
        #expect(rec.videoVerifyStatus == "ok")
        #expect(job.fraction == 1)
    }
}
