// PromoteSoundGateJobTests.swift
// The Promote sound gate AT ITS CALL SITE (Rick 2026-11-10): the real
// PromoteToArchiveJob against a sandbox archive, the measurement answered by
// a canned diagnosis (`job.soundMeasure`) so each outcome is deterministic.
// Real decoding is PromoteSoundGateMediaMatrixTests.
//
// The invariants (design §5):
//   I-1  nothing reaches the archive without a pass for the proven bytes;
//   I-2  a stored check is reused only when it is provably about these bytes;
//   I-5  the owner's tag accepts no-track / silent only, and only for the
//        digest it is stored under;
//   I-7  a refusal leaves the archive byte-for-byte as it was;
//   I-8  could-not-check is never a pass and stores no verdict;
//   I-10 the measurement is about the bytes that get copied.
//
// RED before the gate was wired (2026-11-10): every test named REFUSED
// promoted the file. Sandbox only (`test_*`), never /Volumes or App Support.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Promote sound gate — the job refuses before anything is written", .serialized)
@MainActor
struct PromoteSoundGateJobTests {

    typealias H = PromoteIntegrityHarness
    typealias S = MasterArchiveTestSupport

    static let silentPair = S.soundDiagnosis(channels: [-68, -68])
    static let noTrack = S.soundDiagnosis(channels: [], audioStreams: 0)
    static let leftOnly = S.soundDiagnosis(channels: [-18, -.infinity])
    static let damaged = S.soundDiagnosis(channels: [-18, -20],
                                          extraFindings: [.durationMismatch(audioSeconds: 2, videoSeconds: 10)])

    /// One file, one job, the given measurement; runs to the end.
    static func promote(_ model: VideoScanModel, _ rec: VideoRecord,
                        measure: PromoteSoundGate.Measure) async throws -> PromoteToArchiveJob {
        let job = try H.job(model, ids: [rec.id])
        job.soundMeasure = measure
        job.start()
        await job.task?.value
        await job.completionTask?.value
        await consoleSettled()
        return job
    }

    /// The console buffers lines for 0.15 s before publishing them.
    static func consoleSettled() async {
        try? await Task.sleep(for: .milliseconds(260))
    }

    /// A refused file: failed, the code, nothing in the archive, the claim released.
    static func expectRefused(_ job: PromoteToArchiveJob, _ rec: VideoRecord, code: String,
                              _ sb: S.Sandbox, _ model: VideoScanModel, before: ArchiveSnapshot.State,
                              sourceLocation: SourceLocation = #_sourceLocation) throws -> PromoteToArchiveJob.FileOutcome {
        let o = try #require(H.outcome(job, rec.id), sourceLocation: sourceLocation)
        #expect(o.kind == .failed, "\(o.kind) — \(o.detail)", sourceLocation: sourceLocation)
        #expect(o.refusalCode == code, "\(o.refusalCode ?? "nil") — \(o.detail)", sourceLocation: sourceLocation)
        #expect(ArchiveSnapshot.take(sb) == before, "the archive must be exactly as it was", sourceLocation: sourceLocation)
        #expect(H.partials(sb).isEmpty, sourceLocation: sourceLocation)
        #expect(model.masterArchiveCopy(of: rec) == nil, sourceLocation: sourceLocation)
        let digest = try #require(S.sha256(ofFile: rec.fullPath), sourceLocation: sourceLocation)
        #expect(model.promoteDigestClaim(digest, root: sb.archiveRoot.path) == nil, "the digest claim is released",
                sourceLocation: sourceLocation)
        #expect(model.dashboard.consoleLines.contains { $0.contains("refused [\(code)]") },
                "one REFUSED line with the code", sourceLocation: sourceLocation)
        return o
    }

    static func lines(_ model: VideoScanModel, _ needle: String) -> [String] {
        model.dashboard.consoleLines.filter { $0.contains(needle) }
    }

    // MARK: Refusals

    @Test("REFUSED: a silent track (both channels at −68 dBFS) — the words carry the number and the exact tag; the archive is untouched")
    func silentIsRefused() async throws {
        let (sb, model) = try H.setup("sg_silent"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_title.mov", seed: 601)
        a.userDate = "1994"; a.userDateConfidence = UserDateConfidence.known.rawValue
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        let o = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
        #expect(o.detail.contains("every channel is under -60.0 dBFS (loudest -68.0)"), "\(o.detail)")
        #expect(o.detail.contains("tag it “Silent — checked”"))
        // The finished row says which file and why; the persistent lines name no file.
        #expect(job.subtitle.contains("test_title.mov: Not promoted — the sound track is silent"), "\(job.subtitle)")
        #expect(Self.lines(model, "refused [sound-silent]").allSatisfy { !$0.contains("test_title") })
        #expect(Self.lines(model, "SOUND START").contains { $0.contains("measuring (40000 bytes)") })
        if case .failed = job.state {} else { Issue.record("a batch whose only file was refused is failed: \(job.state)") }
    }

    @Test("REFUSED: no audio track")
    func noTrackIsRefused() async throws {
        let (sb, model) = try H.setup("sg_none"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_picture.mov", seed: 602)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.noTrack))
        let o = try Self.expectRefused(job, a, code: "sound-none", sb, model, before: before)
        #expect(o.detail.hasPrefix("Not promoted — this file has no sound track."))
    }

    @Test("REFUSED: the picture half of a pair — the words name the sound file and point at Combine This Pair…")
    func pairHalfIsRefused() async throws {
        let (sb, model) = try H.setup("sg_half"); defer { sb.cleanup() }
        let v = try H.source(sb, model, name: "test_clip.V01.mxf", seed: 603)
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        let s = try H.source(sb, model, name: "test_clip.A01.mxf", seed: 604)
        s.streamTypeRaw = StreamType.audioOnly.rawValue
        v.pairedWith = s; s.pairedWith = v
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, v, measure: S.measure(Self.noTrack))
        let o = try Self.expectRefused(job, v, code: "sound-pair-half", sb, model, before: before)
        #expect(o.detail.contains("its sound is in test_clip.A01.mxf") && o.detail.contains("Combine This Pair…"), "\(o.detail)")
        #expect(Self.lines(model, "refused [sound-pair-half]").allSatisfy { !$0.contains("test_clip") })
    }

    @Test("REFUSED: damaged sound — even with the owner's tag; the words point at Repair…")
    func damagedIsRefusedEvenTagged() async throws {
        let (sb, model) = try H.setup("sg_damaged"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_short.mov", seed: 605)
        a.tags = [WorkflowTags.silentChecked]
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.damaged))
        let o = try Self.expectRefused(job, a, code: "sound-damaged", sb, model, before: before)
        #expect(o.detail.contains("audio shorter than video (2s vs 10s)") && o.detail.contains("Repair…"), "\(o.detail)")
    }

    @Test("REFUSED: could not check (the probe failed) — even with the tag; no verdict is stored (GH #128)")
    func couldNotCheckIsRefused() async throws {
        let (sb, model) = try H.setup("sg_unchecked"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_offline.mov", seed: 606)
        a.tags = [WorkflowTags.silentChecked]
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(throwing: AudioVerifyProbeError.probeFailed("ffprobe exited with status 1")))
        let o = try Self.expectRefused(job, a, code: "sound-unchecked", sb, model, before: before)
        #expect(o.detail.contains("Could not check is not a pass") && o.detail.contains("ffprobe exited with status 1"), "\(o.detail)")
        #expect(a.audioVerifyStatus.isEmpty && a.audioVerifyDate == nil, "could-not-check stores nothing")
    }

    @Test("REFUSED: a levels pass that did not read every channel is could-not-check, not silence and not a pass")
    func partialMeasurementIsRefused() async throws {
        let (sb, model) = try H.setup("sg_partial"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_gap.mov", seed: 607)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(S.soundDiagnosis(channels: [-.infinity, nil])))
        _ = try Self.expectRefused(job, a, code: "sound-unchecked", sb, model, before: before)
        #expect(a.audioVerifyStatus.isEmpty, "a partial measurement stores no verdict")
    }

    @Test("REFUSED: the file changes while its sound is being measured — the answer is not about the bytes that would be copied")
    func changedDuringMeasurementIsRefused() async throws {
        let (sb, model) = try H.setup("sg_moved"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_moving.mov", seed: 608)
        let before = ArchiveSnapshot.take(sb)
        let touching = PromoteSoundGate.Measure { path in
            // Same size, new bytes and a new mtime, as the levels pass "finishes".
            _ = try? S.writeBlob(at: URL(fileURLWithPath: path), bytes: 40_000, seed: 9_608)
            return S.soundDiagnosis(channels: [-18, -20])
        }
        let job = try H.job(model, ids: [a.id])
        job.soundMeasure = touching
        job.start(); await job.task?.value; await job.completionTask?.value
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .failed && o.refusalCode == "sound-unchecked", "\(o.refusalCode ?? "nil") — \(o.detail)")
        #expect(o.detail.contains("changed while its sound was being checked"))
        #expect(ArchiveSnapshot.take(sb) == before)
        #expect(a.audioVerifyStatus.isEmpty, "a measurement of a moving file stores no verdict")
    }

    @Test("REFUSED: an audio-only file with a silent track — the gate applies to every file Promote copies")
    func silentAudioOnlyIsRefused() async throws {
        let (sb, model) = try H.setup("sg_audio"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_tape.wav", seed: 609)
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        _ = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
    }

    @Test("REFUSED: a header that says 'video + 2 channels' passes nothing — the measurement decides")
    func headerNeverPasses() async throws {
        let (sb, model) = try H.setup("sg_header"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_header.mov", seed: 610)
        a.streamTypeRaw = StreamType.videoAndAudio.rawValue
        a.audioCodec = "pcm_s16le"; a.audioChannels = "2"; a.audioSampleRate = "48000"
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        _ = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
    }

    // MARK: Passes

    @Test("sound on one side promotes as it is; the row and the landed line say which side")
    func oneSidedPromotesWithANote() async throws {
        let (sb, model) = try H.setup("sg_left"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_left.mov", seed: 611)
        let job = try await Self.promote(model, a, measure: S.measure(Self.leftOnly))
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .promoted, "\(o.kind) — \(o.detail)")
        #expect(o.soundNote == "sound on the left side only")
        #expect(model.masterArchiveCopy(of: a) != nil)
        #expect(Self.lines(model, "SOUND OUTCOME").contains { $0.contains("present, left only — 2 ch: L -18.0, R -inf dBFS RMS") })
        #expect(Self.lines(model, "test_left.mov → ").contains { $0.hasSuffix("· sound on the left side only") })
        #expect(S.sha256(ofFile: a.fullPath) == S.sha256(ofFile: try #require(model.masterArchiveCopy(of: a)).fullPath),
                "promoted as it is — the original's bytes, unbalanced")
    }

    @Test("REFUSED without it, PROMOTED with it: the owner's “Silent — checked” tag accepts a silent track, and the OUTCOME line names the tag and the digest")
    func tagAcceptsSilent() async throws {
        let (sb, model) = try H.setup("sg_tag"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_silent_ok.mov", seed: 612)
        let before = ArchiveSnapshot.take(sb)
        let refused = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        _ = try Self.expectRefused(refused, a, code: "sound-silent", sb, model, before: before)

        model.setTag(WorkflowTags.silentChecked, on: [a], present: true)   // the real tag door, inside its debounce window
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .promoted, "\(o.kind) — \(o.detail)")
        #expect(o.soundNote == "silent sound track — you tagged this file “Silent — checked”")
        let digest = try #require(S.sha256(ofFile: a.fullPath))
        #expect(Self.lines(model, "SOUND OUTCOME").contains {
            $0.contains("silent, accepted — owner tag \"Silent — checked\", sha256 \(digest.prefix(12))…")
        }, "\(Self.lines(model, "SOUND OUTCOME"))")
        #expect(model.masterArchiveCopy(of: a)?.tags.contains(WorkflowTags.silentChecked) == true, "the tag rides to the archive copy")
    }

    @Test("the tag taken back before Promote (inside the debounce window) accepts nothing")
    func tagRemovedIsRefused() async throws {
        let (sb, model) = try H.setup("sg_untag"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_untagged.mov", seed: 613)
        model.setTag(WorkflowTags.silentChecked, on: [a], present: true)
        model.setTag(WorkflowTags.silentChecked, on: [a], present: false)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.noTrack))
        _ = try Self.expectRefused(job, a, code: "sound-none", sb, model, before: before)
    }

    @Test("a TAGGED picture half promotes alone, and the OUTCOME line records that a sound partner was catalogued")
    func taggedHalfPromotesAlone() async throws {
        let (sb, model) = try H.setup("sg_half_ok"); defer { sb.cleanup() }
        let v = try H.source(sb, model, name: "test_reel.V01.mxf", seed: 614)
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        let s = try H.source(sb, model, name: "test_reel.A01.mxf", seed: 615)
        s.streamTypeRaw = StreamType.audioOnly.rawValue
        v.pairedWith = s; s.pairedWith = v
        v.tags = [WorkflowTags.silentChecked]
        let job = try await Self.promote(model, v, measure: S.measure(Self.noTrack))
        #expect(H.outcome(job, v.id)?.kind == .promoted)
        #expect(Self.lines(model, "SOUND OUTCOME").contains { $0.hasSuffix("; a sound partner is catalogued") && !$0.contains("test_reel") })
    }

    // MARK: The tag is tied to the bytes (I-5)

    @Test("REFUSED: a tag on a record whose stored fingerprint names OTHER bytes does not cross to this file")
    func tagDoesNotCrossToOtherBytes() async throws {
        let (sb, model) = try H.setup("sg_leak"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_replaced.mov", seed: 616)
        a.tags = [WorkflowTags.silentChecked]
        // The fingerprint (and so the tag row) is of an EARLIER version: other digest, a stamp that no longer matches.
        a.contentFixity = ContentFixity(digest: String(repeating: "e", count: 64), byteCount: a.sizeBytes,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: a.sizeBytes, mtimeNs: 1, ctimeNs: 1))
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        let o = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
        #expect(o.detail.contains("was given to an earlier version of this file"), "\(o.detail)")
        #expect(Self.lines(model, "refused [sound-silent]").contains { $0.contains("owner tag not tied to these bytes") })
    }

    // MARK: Stored checks (I-2)

    /// A real, current whole-file fingerprint for `rec`, taken `ago` seconds back.
    static func fingerprint(_ rec: VideoRecord, computedAt: Date) throws {
        let digest = try #require(S.sha256(ofFile: rec.fullPath))
        let stamp = try #require(FileIdentityStamp.capture(path: rec.fullPath))
        let fixity = ContentFixity(digest: digest, byteCount: rec.sizeBytes, stamp: stamp, computedAt: computedAt)
        try #require(fixity.describesFileNow(FileIdentityStamp.capture(path: rec.fullPath)), "fixture: the fingerprint vouches for the file")
        rec.contentFixity = fixity
    }

    static let neverMeasure = PromoteSoundGate.Measure { _ in
        Issue.record("the measurement ran, but a stored check should have been reused")
        return MasterArchiveTestSupport.soundDiagnosis(channels: [-18, -20])
    }

    @Test("a stored pass that is provably about these bytes is REUSED: no measurement runs, the START line says so")
    func storedPassIsReused() async throws {
        let (sb, model) = try H.setup("sg_reuse"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_verified.mov", seed: 617)
        try await Task.sleep(for: .milliseconds(20))          // past the stamp's racy window
        let now = Date()
        try Self.fingerprint(a, computedAt: now)
        a.audioVerifyStatus = "ok"; a.audioVerifyNote = "one-sided audio (right only)"
        a.audioVerifyDate = now.addingTimeInterval(60)
        let job = try await Self.promote(model, a, measure: Self.neverMeasure)
        let o = try #require(H.outcome(job, a.id))
        #expect(o.kind == .promoted && o.soundNote == "sound on the right side only", "\(o.kind) — \(o.detail)")
        #expect(Self.lines(model, "SOUND START").contains { $0.contains("reusing the stored check of") })
        #expect(Self.lines(model, "SOUND OUTCOME").contains { $0.contains("present, right only [stored]") })
    }

    @Test("REFUSED: a stale stored 'ok' never passes — the file was rewritten to silence after it was checked")
    func staleStoredPassIsMeasuredAgain() async throws {
        let (sb, model) = try H.setup("sg_stale"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_rewritten.mov", seed: 618)
        try await Task.sleep(for: .milliseconds(20))
        let checked = Date()
        try Self.fingerprint(a, computedAt: checked)
        a.audioVerifyStatus = "ok"; a.audioVerifyNote = ""; a.audioVerifyDate = checked.addingTimeInterval(60)
        // Rewritten: same size, same path, different bytes. The stored fingerprint no longer describes it.
        try S.writeBlob(at: URL(fileURLWithPath: a.fullPath), bytes: 40_000, seed: 9_618)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        _ = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
        #expect(Self.lines(model, "SOUND START").allSatisfy { !$0.contains("reusing") })
    }

    @Test("REFUSED: a stored 'ok' OLDER than the fingerprint is not evidence — it may be about an earlier version")
    func verdictOlderThanFingerprintIsMeasuredAgain() async throws {
        let (sb, model) = try H.setup("sg_older"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_older.mov", seed: 619)
        try await Task.sleep(for: .milliseconds(20))
        let hashed = Date()
        try Self.fingerprint(a, computedAt: hashed)
        a.audioVerifyStatus = "ok"; a.audioVerifyNote = ""; a.audioVerifyDate = hashed.addingTimeInterval(-3_600)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(Self.silentPair))
        _ = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
    }

    @Test("REFUSED: stored 'ok' / surround is a header verdict — measured again, and six silent channels are refused")
    func storedSurroundIsMeasuredAgain() async throws {
        let (sb, model) = try H.setup("sg_surround"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_51.mov", seed: 620)
        try await Task.sleep(for: .milliseconds(20))
        let now = Date()
        try Self.fingerprint(a, computedAt: now)
        a.audioVerifyStatus = "ok"; a.audioVerifyNote = "surround audio (6 channels)"; a.audioVerifyDate = now.addingTimeInterval(60)
        let before = ArchiveSnapshot.take(sb)
        let job = try await Self.promote(model, a, measure: S.measure(S.soundDiagnosis(channels: [-70, -72, -.infinity, -90, -75, -80])))
        _ = try Self.expectRefused(job, a, code: "sound-silent", sb, model, before: before)
    }

    // MARK: The one catalog write

    @Test("a complete measurement is stored on the source through Verify Audio's writer — refusal or pass")
    func measurementIsStored() async throws {
        let (sb, model) = try H.setup("sg_stored"); defer { sb.cleanup() }
        let silent = try H.source(sb, model, name: "test_s.mov", seed: 621)
        let good = try H.source(sb, model, name: "test_g.mov", seed: 622)
        _ = try await Self.promote(model, silent, measure: S.measure(Self.silentPair))
        #expect(silent.audioVerifyStatus == "ok" && silent.audioVerifyNote == "silent audio" && silent.audioVerifyDate != nil,
                "\(silent.audioVerifyStatus) / \(silent.audioVerifyNote)")
        _ = try await Self.promote(model, good, measure: S.soundPresent)
        #expect(good.audioVerifyStatus == "ok" && good.audioVerifyNote.isEmpty && good.audioVerifyDate != nil)
        // Never onto an archived record: the copy's verdict is not written by the gate.
        #expect(model.masterArchiveCopy(of: good)?.audioVerifyDate == nil)
    }

    // MARK: A batch, and Stop

    @Test("a mixed batch: the sound-bearing and the tagged file land, the silent and the damaged do not; the summary counts them")
    func mixedBatch() async throws {
        let (sb, model) = try H.setup("sg_batch"); defer { sb.cleanup() }
        let good = try H.source(sb, model, name: "test_b_good.mov", seed: 631)
        let silent = try H.source(sb, model, name: "test_b_silent.mov", seed: 632)
        let tagged = try H.source(sb, model, name: "test_b_tagged.mov", seed: 633)
        let bad = try H.source(sb, model, name: "test_b_bad.mov", seed: 634)
        tagged.tags = [WorkflowTags.silentChecked]
        let byName: [String: AudioVerifyDiagnosis] = [
            "test_b_good.mov": S.soundDiagnosis(channels: [-18, -20]), "test_b_silent.mov": Self.silentPair,
            "test_b_tagged.mov": Self.noTrack, "test_b_bad.mov": Self.damaged,
        ]
        let job = try H.job(model, ids: [good.id, silent.id, tagged.id, bad.id])
        job.soundMeasure = PromoteSoundGate.Measure { path in
            guard let d = byName[(path as NSString).lastPathComponent] else { throw AudioVerifyProbeError.probeFailed("unknown fixture") }
            return d
        }
        job.start(); await job.task?.value; await job.completionTask?.value
        #expect(H.outcome(job, good.id)?.kind == .promoted)
        #expect(H.outcome(job, tagged.id)?.kind == .promoted)
        #expect(H.outcome(job, silent.id)?.refusalCode == "sound-silent")
        #expect(H.outcome(job, bad.id)?.refusalCode == "sound-damaged")
        #expect(S.archivedFiles(sb).count == 2, "\(S.archivedFiles(sb))")
        #expect(S.manifestRows(sb).count == 2)
        #expect(job.subtitle.hasPrefix("Promoted 2 · skipped 0 · failed 2 — test_b_silent.mov: Not promoted"), "\(job.subtitle)")
        #expect(job.subtitle.hasSuffix("(and 1 more refused for their sound)"))
        #expect(model.masterArchiveCopy(of: silent) == nil && model.masterArchiveCopy(of: bad) == nil)
    }

    @Test("Stop during the sound check ends Cancelled with nothing written")
    func stopDuringTheCheck() async throws {
        let (sb, model) = try H.setup("sg_stop"); defer { sb.cleanup() }
        let a = try H.source(sb, model, name: "test_long.mov", seed: 641)
        let before = ArchiveSnapshot.take(sb)
        let job = try H.job(model, ids: [a.id])
        job.soundMeasure = PromoteSoundGate.Measure { _ in
            try await Task.sleep(for: .seconds(60))            // throws CancellationError on Stop
            return MasterArchiveTestSupport.soundDiagnosis(channels: [-18, -20])
        }
        job.start()
        for _ in 0..<2_000 where Self.lines(model, "SOUND START").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!Self.lines(model, "SOUND START").isEmpty, "the sound check started")
        #expect(job.state.isActive && job.subtitle.contains("test_long.mov"), "the row names the file being checked: \(job.subtitle)")
        job.cancel()
        await job.task?.value
        await job.completionTask?.value
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(ArchiveSnapshot.take(sb) == before)
        #expect(a.audioVerifyStatus.isEmpty)
        let digest = try #require(S.sha256(ofFile: a.fullPath))
        #expect(model.promoteDigestClaim(digest, root: sb.archiveRoot.path) == nil)
    }
}
