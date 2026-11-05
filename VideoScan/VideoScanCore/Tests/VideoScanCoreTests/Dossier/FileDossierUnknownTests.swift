// FileDossierUnknownTests.swift — Codex review 2026-11-05 (P0 TRUTH) on the
// dossier's Patterns layer:
//   * FileDossier+Build.swift:99 — a record never probed, or whose probe
//     failed, was read as "no audio, no video", so Speech said "no audio
//     track" and Scene / Era / On-screen said "no picture". Nothing proves
//     that: unknown reads as unknown ("not probed yet" / "probe failed: why").
//   * :147 — the collapsed summary said "nothing analyzed yet" for a record
//     whose only analysis is an `era.none` or a give-up verdict (or Rick's
//     rejection). The analyzer ran; the summary says what it concluded.
// Synthetic records only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FileDossier — unknown is unknown (Codex 11/05)")
struct FileDossierUnknownTests {
    typealias T = FileDossierTests

    static let pictureAndSound = ["Era", "Scene", "Speech", "On-screen dates", "On-screen text"]

    @Test(arguments: [
        ("", "not probed yet"),
        ("ffprobe failed", "probe failed: Damaged MXF file"),
    ])
    func anUnprobedOrFailedProbeNeverClaimsNoAudioOrNoPicture(_ stream: String, _ words: String) throws {
        let r = T.dvRecord()
        r.streamTypeRaw = stream
        if stream == "ffprobe failed" { r.isPlayable = "Damaged MXF file" }
        let p = T.build(r).patterns
        for label in Self.pictureAndSound {
            let line = try #require(p.line(label), "\(label)")
            #expect(!line.value.contains("no audio") && !line.value.contains("no picture"),
                    "\(label) says '\(line.value)' with no probe evidence")
            #expect(line.value == words && line.standing == .missing, "\(label): '\(line.value)'")
        }
    }

    @Test func aFailedProbeWithoutAReasonStillSaysItFailed() {
        let r = T.dvRecord()
        r.streamTypeRaw = "ffprobe failed"
        r.isPlayable = "Yes"
        #expect(T.build(r).patterns.line("Speech")?.value == "probe failed")
    }

    @Test func aProbedFileStillSaysWhatItLacks() {
        let silent = T.dvRecord()
        silent.streamTypeRaw = "Video only"
        #expect(T.build(silent).patterns.line("Speech")?.value == "no audio track")
        let audio = T.dvRecord()
        audio.streamTypeRaw = "Audio only"
        #expect(T.build(audio).patterns.line("Scene")?.value == "no picture (audio only)")
    }

    @Test(arguments: [
        (#"{"reason":"no era window passed the contract"}"#, "no usable era"),
        (#"{"reason":"gave up after 3 tries: frames would not decode","gaveUp":true}"#, "era: given up after 3 tries"),
    ])
    func theSummarySaysTheAnalyzerRan(_ evidence: String, _ words: String) {
        let d = T.build(T.dvRecord(), [T.row(1, "era.none", "none", evidence: evidence)])
        #expect(d.patterns.summary != "nothing analyzed yet")
        #expect(d.patterns.summary == words)
    }

    @Test func theSummaryOfARejectedEraSaysSoNeverTheEra() {
        let rows = [T.row(1, "era.fused", "1990-1995"), T.row(2, "era.fused", "1990-1995", by: "rick", state: "rejected")]
        let summary = T.build(T.dvRecord(), rows).patterns.summary
        #expect(summary == "era rejected by you")
        let bare = T.build(T.dvRecord()).patterns.summary
        #expect(bare == "nothing analyzed yet", "a record nothing ran on still says so")
    }
}
