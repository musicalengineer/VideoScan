// FileDossierCoverageTests.swift — fresh-eyes coverage review of the file
// dossier view (main 9c86c7369..2c8fa9777, 2026-11-05). RED on 2c8fa9777;
// each test names the line it pins. Reuses FileDossierTests' record (same
// module).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FileDossier — coverage review (red on 2c8fa9777)")
struct FileDossierCoverageTests {

    /// TRUTH — pins TechnicalReading.swift:326-331 (`audioRows`: an empty
    /// codec string becomes "Audio: none — silent file") together with
    /// TechnicalFacts(record:) at TechnicalReading.swift:438-460, which hands
    /// the rules `hasVideo` but never `hasAudio`. ScanEngine's MXF header
    /// fallback (ScanEngine.swift:170-210) writes streamTypeRaw "Video+Audio",
    /// the channel count and the sample rate, but leaves `audioCodec` ""
    /// unless the header carried a bit depth; ffprobe does the same for an
    /// audio stream whose codec it cannot name. The stream list says the file
    /// has sound; the dossier then states the fact "silent file" (rule 1: a
    /// blank field is not evidence of absence).
    @Test func anAudioStreamWithNoCodecNameIsNeverCalledSilent() throws {
        let r = FileDossierTests.dvRecord()
        r.filename = "Reel_07.mxf"; r.fullPath = "/V/avid/Reel_07.mxf"; r.ext = "mxf"
        r.container = "MXF (CDCI)"
        r.videoCodec = "DNxHD"
        r.streamTypeRaw = "Video+Audio"          // the scan counted an audio stream
        r.audioCodec = ""                        // …whose codec it could not name
        r.audioChannels = "8"
        r.audioSampleRate = "48000 Hz"
        r.isPlayable = "Codec unsupported"
        let t = FileDossier.build(record: r, digest: nil, assertions: [], now: FileDossierTests.now).technical
        let audio = try #require(t.line("Audio"))
        #expect(audio.value != "none", "stream_type says Video+Audio; the line says \(audio.value)")
        #expect(audio.reading?.localizedCaseInsensitiveContains("silent") != true, "\(audio.reading ?? "")")
        #expect(audio.value.contains("8 ch") && audio.value.contains("48000 Hz"), "the stored channels and rate are still shown: \(audio.value)")
        #expect(audio.source == TechnicalReading.firstAudioStream)
    }
}
