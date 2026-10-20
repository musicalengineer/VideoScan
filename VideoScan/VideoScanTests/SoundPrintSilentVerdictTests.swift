// SoundPrintSilentVerdictTests.swift — every surface that turns a sound-print
// stamp into words says "silent" ONLY for decoded, measured silence
// (2026-10-20: Verify Catalog tier 3 rule `headerSaysSoundPrintHeardNone`
// fired on 32 rows; 8 AVCHD clips had real sound, 6 files never decoded).
//
//   LOGIC  — tier 3 maps each `AudioFingerprintStamp.Hearing` to pass /
//            finding / could-not-check; the Stream column; Compare's side.
//   SCALE  — tier 3 over 100k rows inside a budget.
//   SENSOR — at that scale, the silent findings are EXACTLY the rule-4
//            zero-landmark rows; every not-evidence row is could-not-check.
//   ISOLATION / MEDIA: N/A here — pure functions over values; the media
//            matrix lives in AudioFingerprintBackfillSilenceMediaTests and
//            VideoScanCore's SoundPrintSilenceVerdictTests.
//
// Suites (filter by SUITE): SoundPrintSilentVerdictTier3Tests ·
//   SoundPrintSilentVerdictSurfaceTests · SoundPrintSilentVerdictScaleTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 1_760_900_000)   // 2026-10-20
private let va = StreamType.videoAndAudio.rawValue

private func stamp(version: Int, _ outcome: AudioFingerprintStamp.Outcome = .fingerprinted, landmarks: Int,
                   seconds: Double = 2, size: Int64 = 100) -> AudioFingerprintStamp {
    AudioFingerprintStamp(computedAt: now, engineVersion: version, contentDigest: "v1:x", sizeBytes: size, outcome: outcome,
                          analyzedSeconds: outcome == .noAudio ? 0 : seconds, complete: true,
                          landmarks: outcome == .noAudio ? 0 : landmarks, bytes: outcome == .noAudio ? 0 : 40 + 8 * landmarks)
}

private func vaRow(_ name: String, codec: String, _ s: AudioFingerprintStamp?) -> IntegrityRow {
    var r = IntegrityRow(fullPath: "/Volumes/Projects/AVCHD/BDMV/STREAM/\(name)", sizeBytes: 100)
    r.filename = name
    r.streamTypeRaw = va
    r.audioCodec = codec
    r.contentHash = "v1:x"
    r.durationSeconds = 12
    r.audioFingerprint = s
    return r
}

private func tier3(_ rows: [IntegrityRow]) -> VerifyCatalogTiers.TierOutcome {
    VerifyCatalogTiers.evaluate(3, input: VerifyCatalogTiers.TierInput(
        snapshot: VerifyCatalogSnapshot(rows: rows, events: [], catalogFile: "/nowhere/catalog.json", mountedVolumeRoots: ["/"]),
        previous: nil, constraintFindings: nil, runID: UUID(), now: now))
}

@Suite("Sound print verdicts — Verify Catalog tier 3")
struct SoundPrintSilentVerdictTier3Tests {

    @Test("RED 2026-10-20: group B (pre-4 zero-landmark print on an AC-3 header) and group C (v2 'no sound' on an AAC header, 0 samples) are COULD NOT CHECK, never needs-decision")
    func groupsBAndCAreCouldNotCheck() {
        let b = vaRow("00085.MTS", codec: "ac3", stamp(version: 2, landmarks: 0, seconds: 1.504))
        let c = vaRow("IMG_0164.MOV", codec: "aac", stamp(version: 2, .noAudio, landmarks: 0))
        let out = tier3([b, c])
        #expect(out.findings.isEmpty, "got \(out.findings.map(\.words))")
        #expect(out.tier.needsDecision == 0)
        #expect(out.tier.couldNotCheck == 2)
        #expect(out.tier.result == .couldNotCheck(2))
        #expect(out.tier.summary == "2 sound prints could not tell sound from silence (a failed decode, or made before silence was measured) — Fingerprint Sound looks again",
                Comment(rawValue: out.tier.summary))
    }

    @Test("group A (rule-4 measured silence) still needs a decision with the same words; a print with landmarks passes; a real no-sound stamp the header contradicts still needs a decision")
    func groupAStillFires() {
        let a = vaRow("Fog 02.dv", codec: "pcm_s16le", stamp(version: 4, landmarks: 0, seconds: 3))
        let heard = vaRow("00085b.MTS", codec: "ac3", stamp(version: 2, landmarks: 40))
        let contradicted = vaRow("no_codec.mov", codec: "", stamp(version: 3, .noAudio, landmarks: 0))
        let out = tier3([a, heard, contradicted])
        #expect(out.findings.map(\.recordID) == [a.id, contradicted.id])
        #expect(out.findings.first?.words == "the header says Video+Audio, but the sound print heard nothing (silent)")
        #expect(out.findings.first?.rule == VerifyCatalogTiers.silentPrintRule)
        #expect(out.findings.last?.words == "the header says Video+Audio, but the sound print recorded no audio — Fingerprint Sound again")
        #expect(out.tier.checked == 3 && out.tier.couldNotCheck == 0)
    }

    @Test("the reason words come from the hearing, never from the landmark count: notEvidence and heardSound have none")
    func reasonWordsPerHearing() {
        #expect(VerifyCatalogTiers.silentPrintReason(.measuredSilence) == "but the sound print heard nothing (silent)")
        #expect(VerifyCatalogTiers.silentPrintReason(.noAudioTrack) == "but the sound print recorded no audio — Fingerprint Sound again")
        #expect(VerifyCatalogTiers.silentPrintReason(.notEvidence) == nil)
        #expect(VerifyCatalogTiers.silentPrintReason(.heardSound) == nil)
    }

    @Test("QA P2: a person's 'Silent — checked' settles the row even when the stamp is not evidence (pre-4 zero-landmark, v2 decode failure); so does a Live Photo motion clip")
    func personCheckedPreFourStillSettles() {
        var checkedB = vaRow("00085.MTS", codec: "ac3", stamp(version: 2, landmarks: 0, seconds: 1.504))
        checkedB.silenceCheckedByPerson = true
        var checkedC = vaRow("IMG_0164.MOV", codec: "aac", stamp(version: 2, .noAudio, landmarks: 0))
        checkedC.silenceCheckedByPerson = true
        var live = IntegrityRow(fullPath: "/Volumes/X/Pictures/Photos Library.photoslibrary/originals/A/live.mov", sizeBytes: 100)
        live.filename = "live.mov"; live.streamTypeRaw = va; live.audioCodec = "aac"; live.contentHash = "v1:x"; live.durationSeconds = 2.5
        live.audioFingerprint = stamp(version: 2, landmarks: 0, seconds: 2.5)
        let out = tier3([checkedB, checkedC, live])
        #expect(out.findings.isEmpty && out.tier.couldNotCheck == 0, "\(out.findings.map(\.words)) cnc=\(out.tier.couldNotCheck)")
        #expect(out.tier.result == .ok && out.tier.checked == 3 && out.tier.passed == 3)
        #expect(out.tier.summary.contains("2 silent clips checked by a person"), Comment(rawValue: out.tier.summary))
        #expect(out.tier.summary.contains("1 \(VerifyCatalogTiers.livePhotoSilentWords)"), Comment(rawValue: out.tier.summary))
    }

    @Test("QA P3c: when there ARE decisions, the summary still names what could not be checked")
    func summaryKeepsCouldNotCheckBesideDecisions() {
        let a = vaRow("Fog 02.dv", codec: "pcm_s16le", stamp(version: 4, landmarks: 0, seconds: 3))
        let b = vaRow("00085.MTS", codec: "ac3", stamp(version: 2, landmarks: 0, seconds: 1.504))
        let none = vaRow("none.mov", codec: "aac", nil)
        let out = tier3([a, b, none])
        #expect(out.tier.result == .needsDecision(1) && out.tier.couldNotCheck == 2)
        #expect(out.tier.summary == "1 headers say sound the print never heard · 1 Video+Audio files have no current sound print yet — Fingerprint Sound · 1 sound prints could not tell sound from silence (a failed decode, or made before silence was measured) — Fingerprint Sound looks again",
                Comment(rawValue: out.tier.summary))
    }
}

@Suite("Sound print verdicts — Stream column and Compare", .serialized)
@MainActor
struct SoundPrintSilentVerdictSurfaceTests {

    private func record(_ s: AudioFingerprintStamp, codec: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/Projects/AVCHD/BDMV/STREAM/00085.MTS"; r.filename = "00085.MTS"
        r.sizeBytes = 100
        r.streamTypeRaw = va
        r.audioCodec = codec
        r.audioFingerprint = s
        return r
    }

    @Test("Stream column: '· silent' only for rule-4 measured silence; a pre-4 zero-landmark print and a v2 decode-failure stamp show the header alone")
    func streamColumn() {
        #expect(CatalogFileFacts.stream(record(stamp(version: 4, landmarks: 0), codec: "pcm_s16le")).value == "Video+Audio · silent")
        let b = CatalogFileFacts.stream(record(stamp(version: 2, landmarks: 0), codec: "ac3"))
        #expect(b.value == "Video+Audio" && !CatalogFileFacts.isSilent(b))
        let c = CatalogFileFacts.stream(record(stamp(version: 2, .noAudio, landmarks: 0), codec: "aac"))
        #expect(c.value == "Video+Audio" && !CatalogFileFacts.isSilent(c))
    }

    @Test("Compare's side: measured silence and a real no-sound track = 0 audible ('no sound'); a print that is not evidence = nil ('no fingerprint yet'), never 'no sound'")
    func compareSide() {
        func audible(_ s: AudioFingerprintStamp, _ codec: String) -> Double? {
            VideoScanModel.relatedSide(record(s, codec: codec), isArchiveFile: false, isArchived: false, now: now).audibleSeconds
        }
        #expect(audible(stamp(version: 4, landmarks: 0), "pcm_s16le") == 0)
        #expect(audible(stamp(version: 3, .noAudio, landmarks: 0), "") == 0)
        #expect(audible(stamp(version: 2, landmarks: 0), "ac3") == nil, "group B: the print may have heard real sound")
        #expect(audible(stamp(version: 2, .noAudio, landmarks: 0), "aac") == nil, "group C: a failed decode")
        #expect(audible(stamp(version: 2, landmarks: 40, seconds: 10), "ac3") == 10)

        let heard = AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 1.5,
                                     activeSeconds: [true, true], hashes: [], times: [], secondsAboveSilenceCeiling: 2)
        #expect(VideoScanModel.printAudibleSeconds(heard) == nil, "heard too little to print is not 'no sound'")
        #expect(VideoScanModel.soundStrip(heard) == nil, "and not a drawn silence either")
    }

    @Test("QA P3a: a zero-landmark print with no measurement (pre-bitmap, or any sidecar blob) draws NO strip — unknown, never silence; measured silence draws quiet; a print with landmarks draws its bitmap")
    func unmeasuredStripIsNotSilence() {
        func fp(_ active: [Bool], landmarks: Int = 0, loud: Int? = nil, seconds: Double = 3) -> AudioFingerprint {
            AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds, activeSeconds: active,
                             hashes: Array(repeating: 1, count: landmarks), times: Array(repeating: 0, count: landmarks),
                             secondsAboveSilenceCeiling: loud)
        }
        #expect(VideoScanModel.soundStrip(fp([])) == nil, "pre-bitmap, zero landmarks: unknown")
        #expect(VideoScanModel.soundStrip(fp([false, false, false])) == nil, "a sidecar blob's quiet-looking bitmap is gain-relative: unknown")
        #expect(VideoScanModel.soundStrip(fp([true, true, true], loud: 0)) == [false, false, false], "measured silence draws quiet")
        #expect(VideoScanModel.soundStrip(fp([true, false, true], landmarks: 4)) == [true, false, true])
        #expect(VideoScanModel.soundStrip(fp([], landmarks: 4)) == [true, true, true], "pre-bitmap print that heard: all audible")
    }

    @Test("QA P3a: Compare only offers a stamp that heard sound for the match — a not-evidence or measured-silent stamp gives no sidecar key")
    func fingerprintKeyOnlyForEvidence() {
        #expect(VideoScanModel.fingerprintKey(record(stamp(version: 2, landmarks: 40), codec: "ac3")) != nil)
        #expect(VideoScanModel.fingerprintKey(record(stamp(version: 2, landmarks: 0), codec: "ac3")) == nil, "pre-4 zero-landmark: not evidence")
        #expect(VideoScanModel.fingerprintKey(record(stamp(version: 4, landmarks: 0), codec: "pcm_s16le")) == nil, "silence has nothing to match")
        #expect(VideoScanModel.fingerprintKey(record(stamp(version: 2, .noAudio, landmarks: 0), codec: "aac")) == nil)
    }
}

@Suite("Sound print verdicts — scale + sensor (100k rows)", .serialized)
struct SoundPrintSilentVerdictScaleTests {

    /// 100k Video+Audio rows, ten shapes in rotation. SENSOR: tier 3's
    /// silent findings are EXACTLY the rule-4 zero-landmark rows; the two
    /// not-evidence shapes are could-not-check. Budget (Debug, M4 Max): 2 s.
    @Test(.timeLimit(.minutes(1)))
    func tier3At100k() throws {
        var rows: [IntegrityRow] = []
        rows.reserveCapacity(100_000)
        var expectedSilent = Set<UUID>()
        for i in 0..<100_000 {
            let s: AudioFingerprintStamp
            let codec: String
            switch i % 10 {
            case 0: s = stamp(version: 2, landmarks: 0, seconds: 1.5); codec = "ac3"           // B, old
            case 1: s = stamp(version: 2, .noAudio, landmarks: 0); codec = "aac"               // C, old
            case 2: s = stamp(version: 3, landmarks: 0, seconds: 4); codec = "aac"             // B, v3
            case 3: s = stamp(version: 4, landmarks: 0, seconds: 3); codec = "pcm_s16le"       // A, measured
            default: s = stamp(version: i % 2 == 0 ? 2 : 4, landmarks: 50, seconds: 10); codec = "aac"
            }
            var r = IntegrityRow(fullPath: "/Volumes/D\(i % 10)/f\(i % 100)/clip_\(i).mov", sizeBytes: 100)
            r.filename = "clip_\(i).mov"
            r.streamTypeRaw = va
            r.audioCodec = codec
            r.contentHash = "v1:x"
            r.durationSeconds = 12
            r.audioFingerprint = s
            if i % 10 == 3 { expectedSilent.insert(r.id) }
            rows.append(r)
        }
        let load = TimingBudget.sampleLoad()
        let clock = ContinuousClock()
        var out: VerifyCatalogTiers.TierOutcome?
        let measured = clock.measure { out = tier3(rows) }
        let result = try #require(out)
        let silent = result.findings.filter { $0.words.hasSuffix("heard nothing (silent)") }
        #expect(Set(silent.map(\.recordID)) == expectedSilent, "silent ⇔ decoded and measured (rule 4)")
        #expect(result.findings.count == 10_000)
        #expect(result.tier.couldNotCheck == 30_000, "B (v2 and v3) and C are could-not-check")
        #expect(result.tier.checked == 70_000)
        expectWithinTimingBudget("tier 3 over 100k Video+Audio rows", measured: measured,
                                 budget: PerformanceLane.debugCeiling(.seconds(2)), loadBefore: load)
    }
}
