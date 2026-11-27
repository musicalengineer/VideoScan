// ArchiveAngelStaleSoundVerdictPrepareTests.swift
// Codex re-review #302 (2026-11-16), findings 2 and 3: a record whose stored
// sound verdict does not describe it ("mono audio" on a record that is not
// one channel) is routed to Prepare — and Prepare must then CHECK it, not
// reuse the session's cached diagnosis as "Already verified".
//
// Through the real ArchiveAngelJob on generated media (tones; no family
// media), the diagnosis cache seeded the way a session leaves it:
//
//   MEDIA      a left-only stereo mp4; an mp4 with a silent stereo first
//              audio stream and a live mono second one
//   LOGIC      reusableDiagnosis refuses a verdict readiness calls not-checked
//   ISOLATION  sandbox model, ledger and buffer; the cache poisoned with a
//              complete diagnosis of some other sound
//   TRUTH      what Prepare stores and makes is what the file's sound is

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — Prepare checks a file whose stored sound verdict does not describe it", .serialized)
@MainActor
struct ArchiveAngelStaleSoundVerdictPrepareTests {
    static let ffmpeg = ToolLocator.ffmpegPath
    typealias F = SoundStandingFixture

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let center: MediaFileOperationsCenter
        let buffer: URL
    }

    private func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    private func generate(_ name: String, in dir: URL, audioArgs: [String]) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let r = await ProcessRunner.runProcess(
            executable: Self.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4"]
                + audioArgs + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "4", url.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture \(name): \(r.stderr)")
        return url
    }

    /// Two channels, sound on the left only.
    private func leftOnlyClip(in dir: URL) async throws -> URL {
        try await generate("test_stale_left.mp4", in: dir, audioArgs: [
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-af", "pan=stereo|c0=c0|c1=0*c0", "-ac", "2",
        ])
    }

    /// First audio stream: two silent channels. Second: one live channel.
    private func silentStereoThenLiveMonoClip(in dir: URL) async throws -> URL {
        try await generate("test_stale_mixed.mp4", in: dir, audioArgs: [
            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
        ])
    }

    /// The record a scan would make: the FIRST audio stream's channel count.
    private func record(_ url: URL, firstStreamChannels: Int) -> VideoRecord {
        let r = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "1995", starRating: 2)
        r.durationSeconds = 600
        r.videoCodec = "h264"
        r.audioCodec = "aac"
        r.audioChannels = String(firstStreamChannels)
        r.isPlayable = "Yes"
        return r
    }

    private func prepare(_ rec: VideoRecord, _ b: Bench) async throws -> ArchiveAngelPlan.Entry {
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: 1, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: [rec.id])
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("Prepare did not finish: \(job.state) — \(job.plan.log.suffix(6))")
            throw CancellationError()
        }
        return try #require(job.plan.entries.first { $0.id == rec.id })
    }

    private func step(_ entry: ArchiveAngelPlan.Entry, _ kind: ArchiveAngelPlan.StepKind) -> ArchiveAngelPlan.StepOutcome {
        entry.steps.first { $0.kind == kind } ?? ArchiveAngelPlan.StepOutcome(kind: kind)
    }

    // MARK: LOGIC

    @Test("LOGIC: a cached diagnosis is reused only when the stored verdict describes the record")
    func reuseNeedsAStandingVerdict() {
        let mono = F.diagnosis(.mono)
        typealias O = ArchiveAngelAudioOutcome
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: mono, standing: .note("mono audio")) != nil)
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: mono, standing: .fine) != nil)
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: mono, standing: .unbalanced("one-sided audio (left only)")) != nil)
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: mono, standing: .notChecked) == nil,
                "the stored verdict does not describe this record: verify now")
        // Unchanged rules: nothing stored, nothing cached, a not-checked diagnosis.
        #expect(O.reusableDiagnosis(storedStatus: "", cached: mono, standing: .fine) == nil)
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: nil, standing: .fine) == nil)
        #expect(O.reusableDiagnosis(storedStatus: "ok", cached: F.diagnosis(.trueStereo, complete: false), standing: .fine) == nil)
    }

    // MARK: Finding 2

    @Test("a stored 'mono' verdict on a two-channel left-only file: Prepare verifies it fresh and makes the balanced copy — the cached mono diagnosis is not 'Already verified'",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func staleMonoIsVerifiedFreshAndBalanced() async throws {
        let b = try bench("stale_mono_left"); defer { b.sb.cleanup() }
        let rec = record(try await leftOnlyClip(in: b.sb.sources), firstStreamChannels: 2)
        // What an earlier version of this file left behind: a complete mono
        // verdict on the record AND in the session's diagnosis cache.
        let mono = F.diagnosis(.mono)
        VerifyAudioJob.write(mono, onto: rec, copies: [rec], stored: .none, at: Date())
        b.center.storeVerifyDiagnosis(mono, forRecordID: rec.id)
        b.model.records = [rec]
        #expect(rec.audioVerifyStatus == "ok" && rec.audioVerifyNote == "mono audio")
        #expect(ArchiveReadiness.assess(record: rec).sound == .notChecked)
        #expect(F.row(rec).route == .prepare)

        let entry = try await prepare(rec, b)
        let verify = step(entry, .verifyAudio), balance = step(entry, .balanceAudio), access = step(entry, .accessCopy)
        #expect(verify.state == .done, "verified now, not reused: \(verify.state) — \(verify.note)")
        #expect(!verify.note.contains("Already verified"), "\(verify.note)")
        #expect(verify.note.contains("left channel only"), "\(verify.note)")
        #expect(rec.audioVerifyNote == "one-sided audio (left only)", "the stored verdict now describes the file: \(rec.audioVerifyNote)")
        #expect(balance.state == .done && balance.recordID != nil, "\(balance.state) — \(balance.note)")
        #expect(access.state == .done && access.note.contains("from balanced audio"), "\(access.note)")
        #expect(entry.status == .ready)
        // The balanced companion really is balanced.
        let balanced = try #require(b.model.records.first { $0.id == balance.recordID })
        let after = try await VerifyAudioProbe.diagnose(path: balanced.fullPath)
        #expect(after.balanceAnalysis?.classification == .dualMono, "\(String(describing: after.balanceAnalysis?.classification))")
    }

    // MARK: Finding 3 (declined as a code change; the behaviour is pinned)

    @Test("a silent stereo first stream with a live mono second stream reads 'not checked' (the scan stores the first stream's count) — it is not stuck: Prepare verifies it fresh as mono, skips the balance, and the gate accepts it",
          .enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func monoOnTheSecondStreamGoesThroughPrepareAndIsNotStuck() async throws {
        let b = try bench("stale_mono_mixed"); defer { b.sb.cleanup() }
        let url = try await silentStereoThenLiveMonoClip(in: b.sb.sources)
        let rec = record(url, firstStreamChannels: 2)
        // The state after any earlier Verify Audio of this very file.
        let real = try await VerifyAudioProbe.diagnose(path: url.path)
        #expect(real.findings == [.channelImbalance(.mono)], "\(real.findings)")
        #expect(real.shape.audioStreams == 2 && real.balanceAnalysis?.programStreamCount == 1)
        VerifyAudioJob.write(real, onto: rec, copies: [rec], stored: .none, at: Date())
        b.center.storeVerifyDiagnosis(real, forRecordID: rec.id)
        b.model.records = [rec]

        // PINNED (known limit): a true, complete mono verdict reads "not
        // checked" because the record's channel count is the first stream's.
        #expect(rec.audioVerifyNote == "mono audio" && rec.audioChannels == "2")
        #expect(ArchiveReadiness.assess(record: rec).sound == .notChecked)
        let row = F.row(rec)
        #expect(row.statusWords == "Needs audio checked" && row.route == .prepare, "never the direct route")

        // Not stuck: Prepare checks it, finds mono, balances nothing, finishes.
        let entry = try await prepare(rec, b)
        let verify = step(entry, .verifyAudio), balance = step(entry, .balanceAudio), access = step(entry, .accessCopy)
        #expect(verify.state == .done && verify.note == ArchiveAngelAudioOutcome.monoIsFineNote, "\(verify.state) — \(verify.note)")
        #expect(balance.state == .skipped && balance.note == ArchiveAngelAudioOutcome.monoIsFineNote, "\(balance.state) — \(balance.note)")
        #expect(access.state == .done, "\(access.state) — \(access.note)")
        #expect(entry.status == .ready, "the prepared row is reviewable: \(entry.status)")
        #expect(rec.audioVerifyStatus == "ok" && rec.audioVerifyNote == "mono audio")

        // And Promote's gate, measuring the file itself, accepts it with nothing to add.
        let decision = PromoteSoundGate.decide(finding: PromoteSoundGate.finding(from: real), mark: .absent,
                                               soundPartnerName: nil, recordedYear: nil, digestPrefix: "")
        guard case .promote(let rowNote, _) = decision else { Issue.record("the gate refuses: \(decision)"); return }
        #expect(rowNote == nil)
    }
}
