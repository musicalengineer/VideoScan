// PromoteSoundGateIsolationTests.swift
// ISOLATION dimension for the Promote sound gate (Rick 2026-11-10): poisoned
// state must never read as "has sound". Two kinds of poison:
//
//   * poisoned FILES through the LIVE measurement (real ffprobe): random
//     bytes, text with a movie extension, a file that vanishes or is
//     replaced while it is being read — each is "could not check", which is
//     not a pass (and stores no verdict, GH #128);
//   * poisoned STORED STATE with a measurement that says silent: a stored
//     "ok" in every shape that must not be believed (no date, a fingerprint
//     of other bytes, a stale stamp, garbage words, a header that claims
//     channels) — none is read: each file is measured and refused.
//
// Sandbox only; no preference, environment variable or real path is touched
// (the ffmpeg-missing case is the pure `uncheckedReason` row in
// PromoteSoundGateTests: changing VS_FFMPEG_PATH here would poison every
// suite running in this process).
//
// RED before the gate was wired (2026-11-10): every file here was promoted.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Promote sound gate — poisoned state never passes", .serialized)
@MainActor
struct PromoteSoundGateIsolationTests {

    typealias H = PromoteIntegrityHarness
    typealias S = MasterArchiveTestSupport

    private func expectUnchecked(_ job: PromoteToArchiveJob, _ rec: VideoRecord, _ sb: S.Sandbox,
                                 before: ArchiveSnapshot.State, _ label: String) throws {
        let o = try #require(H.outcome(job, rec.id), "\(label): no outcome")
        #expect(o.kind == .failed && o.refusalCode == "sound-unchecked", "\(label): \(o.kind) \(o.refusalCode ?? "nil") — \(o.detail)")
        #expect(o.detail.contains("Could not check is not a pass"), "\(label): \(o.detail)")
        #expect(ArchiveSnapshot.take(sb) == before, "\(label): the archive is as it was")
        #expect(rec.audioVerifyStatus.isEmpty && rec.audioVerifyDate == nil, "\(label): no verdict stored")
    }

    @Test("REFUSED (live probe): random bytes and text named .mov cannot be checked — never a pass",
          .timeLimit(.minutes(3)))
    func undecodableFiles() async throws {
        try #require(VerifyAudioTestMedia.toolsAvailable)
        let (sb, model) = try H.setup("sg_iso_files"); defer { sb.cleanup() }
        let random = try H.source(sb, model, name: "test_random.mov", seed: 701)
        let textURL = sb.sources.appendingPathComponent("test_text.mov")
        try Data(String(repeating: "this is not a movie\n", count: 400).utf8).write(to: textURL)
        let text = S.makeRecord(path: textURL.path); model.records.append(text)
        // The catalog's header says these are fine A/V files with two channels.
        for r in [random, text] { r.audioCodec = "aac"; r.audioChannels = "2"; r.isPlayable = "Yes" }
        for (label, rec) in [("random bytes", random), ("text", text)] {
            let before = ArchiveSnapshot.take(sb)
            let job = try H.job(model, ids: [rec.id])
            job.soundMeasure = .live
            job.start(); await job.task?.value; await job.completionTask?.value
            try expectUnchecked(job, rec, sb, before: before, label)
        }
    }

    @Test("REFUSED: the source vanishes while its sound is being read — could not check, nothing written, nothing stored")
    func sourceGoneMidRead() async throws {
        let (sb, model) = try H.setup("sg_iso_gone"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_unplugged.mov", seed: 702)
        let before = ArchiveSnapshot.take(sb)
        let job = try H.job(model, ids: [a.id])
        job.soundMeasure = PromoteSoundGate.Measure { path in
            try? FileManager.default.removeItem(atPath: path)   // the drive goes away mid-read
            throw AudioVerifyProbeError.probeFailed("the file or its volume stopped responding while the audio was being read")
        }
        job.start(); await job.task?.value; await job.completionTask?.value
        try expectUnchecked(job, a, sb, before: before, "unplugged")
    }

    @Test("REFUSED: the source is replaced by a file that 'has sound' while the check runs — a pass for other bytes is not a pass")
    func replacedMidRead() async throws {
        let (sb, model) = try H.setup("sg_iso_swap"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_swapped.mov", seed: 703)
        let before = ArchiveSnapshot.take(sb)
        let job = try H.job(model, ids: [a.id])
        job.soundMeasure = PromoteSoundGate.Measure { path in
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: url)
            _ = try? S.writeBlob(at: url, bytes: 40_000, seed: 9_703)     // a new inode, same size
            return S.soundDiagnosis(channels: [-18, -20])                  // "sound present" — about the NEW file
        }
        job.start(); await job.task?.value; await job.completionTask?.value
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .failed && o.refusalCode == "sound-unchecked", "\(o.refusalCode ?? "nil") — \(o.detail)")
        #expect(ArchiveSnapshot.take(sb) == before)
        #expect(a.audioVerifyStatus.isEmpty, "no verdict from a measurement of a moving file")
    }

    @Test("REFUSED: every poisoned stored 'ok' is measured again — and the measurement says silent")
    func poisonedStoredVerdicts() async throws {
        let (sb, model) = try H.setup("sg_iso_stored"); defer { sb.cleanup() }
        typealias Poison = (label: String, apply: @MainActor (VideoRecord) throws -> Void)
        let future = Date().addingTimeInterval(3_600)
        let poisons: [Poison] = [
            ("ok, no fingerprint at all", { r in
                r.audioVerifyStatus = "ok"; r.audioVerifyDate = future }),
            ("ok, no date", { r in
                try PromoteSoundGateJobTests.fingerprint(r, computedAt: Date())
                r.audioVerifyStatus = "ok"; r.audioVerifyDate = nil }),
            ("ok, the fingerprint is of other bytes", { r in
                r.contentFixity = ContentFixity(digest: String(repeating: "c", count: 64), byteCount: r.sizeBytes,
                                                stamp: FileIdentityStamp(device: 9, inode: 9, size: r.sizeBytes, mtimeNs: 9, ctimeNs: 9))
                r.audioVerifyStatus = "ok"; r.audioVerifyDate = future }),
            ("ok, garbage note", { r in
                try PromoteSoundGateJobTests.fingerprint(r, computedAt: Date())
                r.audioVerifyStatus = "ok"; r.audioVerifyNote = "\u{0}\u{FFFD}; ; DROP TABLE"; r.audioVerifyDate = future }),
            ("ok, 'sound present' typed by nobody's rule", { r in
                try PromoteSoundGateJobTests.fingerprint(r, computedAt: Date())
                r.audioVerifyStatus = "ok"; r.audioVerifyNote = "sound present"; r.audioVerifyDate = future }),
            ("OK in capitals (not the stored word)", { r in
                try PromoteSoundGateJobTests.fingerprint(r, computedAt: Date())
                r.audioVerifyStatus = "OK"; r.audioVerifyDate = future }),
            ("never checked, the header claims 6 channels at 48 kHz", { r in
                r.audioCodec = "pcm_s24le"; r.audioChannels = "6"; r.audioSampleRate = "48000"; r.isPlayable = "Yes" }),
            ("a full report card that says the sound is fine", { r in
                var card = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: r.sizeBytes, headline: "Looks healthy",
                                           checks: [MediaCheck(kind: .sound, verdict: .ok, sentence: "Sound is fine.")])
                card.soundMeasuredSilent = false
                r.mediaReportCard = card }),
            ("a near-miss tag: 'Silent - checked' with a hyphen, and 'Silent OK'", { r in
                r.tags = ["Silent - checked", "Silent OK", "silent"] }),
        ]
        try await Task.sleep(for: .milliseconds(20))
        for (i, poison) in poisons.enumerated() {
            let rec = try H.source(sb, model, name: "test_poison_\(i).mov", seed: UInt64(710 + i))
            try await Task.sleep(for: .milliseconds(15))        // past the stamp's racy window
            try poison.apply(rec)
            let before = ArchiveSnapshot.take(sb)
            let measured = Counter()
            let job = try H.job(model, ids: [rec.id])
            job.soundMeasure = PromoteSoundGate.Measure { _ in
                measured.bump()
                return S.soundDiagnosis(channels: [-68, -68])
            }
            job.start(); await job.task?.value; await job.completionTask?.value
            let o = try #require(H.outcome(job, rec.id), "\(poison.label): no outcome")
            #expect(measured.value == 1, "\(poison.label): the sound was measured in this run")
            #expect(o.kind == .failed && o.refusalCode == "sound-silent", "\(poison.label): \(o.kind) \(o.refusalCode ?? "nil") — \(o.detail)")
            #expect(ArchiveSnapshot.take(sb) == before, "\(poison.label): the archive is as it was")
        }
    }

    /// A tiny thread-safe counter (the measurement closure is @Sendable).
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }
}
