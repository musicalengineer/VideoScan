import Foundation
import Testing
@testable import VideoScan

// MARK: - Catalog scope × scan integration (video-only catalog, 2026-07-15)
//
// Covers the scan-side half of the feature:
//   Logic     — walker admission under the scope toggle (both
//               polarities), the post-scan ambiguous-audio gate.
//   Isolation — settings round-trip through an INJECTED UserDefaults
//               suite; the test host's model never touches the real
//               plist (settings-pollution class).
//   Sensors   — rescan-never-resurrects (the gate re-drops identically
//               on every pass); the pair-protection invariant at the
//               integration level (same-path predecessor in a pair);
//               pre-probe skip means stills/music never reach ffprobe
//               (pinned via walker classification, which runs pre-I/O
//               by design).
//   Scale     — gate over a 100k-record catalog with a time budget.
// Media matrix: N/A — the extension skip is pre-I/O by design; the gate
// consumes probe METADATA and never opens files.

// MARK: Walker admission

@Suite("Catalog scope — walker pre-probe skip")
struct CatalogScopeWalkerTests {

    private let video: Set<String> = ["mov", "mp4", "mxf", "avi", "ogg"]
    private let audio: Set<String> = ["wav", "aif", "aiff", "mp3", "m4a", "caf", "flac"]

    @Test("scope ON: music is rejected even with Scan For Audio Files on")
    func musicRejectedDespiteAudioToggle() {
        // The 81k-music-file lesson: scanAudioFiles admitted mp3s.
        let admission = FilesystemWalker.classifyFile(
            extension: "mp3", videoExtensions: video, audioExtensions: audio,
            scanAudioFiles: true, videoOnlyCatalogScope: true)
        #expect(admission == .reject(.catalogScopeExcluded))
    }

    @Test("scope ON: camera raw is rejected even with Scan Unrecognized File Types on")
    func cr3RejectedDespiteUnknownToggle() {
        // The CR3 lesson: unknown-extension + ISO-BMFF sniff pass let
        // camera raws in. The scope check runs BEFORE that toggle.
        let admission = FilesystemWalker.classifyFile(
            extension: "cr3", videoExtensions: video, audioExtensions: audio,
            scanUnknownExtensions: true, videoOnlyCatalogScope: true)
        #expect(admission == .reject(.catalogScopeExcluded))
    }

    @Test("scope ON: stills are rejected outright", arguments: ["jpg", "heic", "png", "dng"])
    func stillsRejected(ext: String) {
        let admission = FilesystemWalker.classifyFile(
            extension: ext, videoExtensions: video, audioExtensions: audio,
            scanUnknownExtensions: true, videoOnlyCatalogScope: true)
        #expect(admission == .reject(.catalogScopeExcluded))
    }

    @Test("scope ON: ogg is music even though it sits on the video allowlist")
    func oggScopeBeatsVideoAllowlist() {
        let admission = FilesystemWalker.classifyFile(
            extension: "ogg", videoExtensions: video, audioExtensions: audio,
            videoOnlyCatalogScope: true)
        #expect(admission == .reject(.catalogScopeExcluded))
    }

    @Test("scope ON: ambiguous audio still admitted (needs probing for the evidence test)")
    func ambiguousAudioStillAdmitted() {
        let admission = FilesystemWalker.classifyFile(
            extension: "wav", videoExtensions: video, audioExtensions: audio,
            scanAudioFiles: true, videoOnlyCatalogScope: true)
        #expect(admission == .admit)
    }

    @Test("scope ON: video and extensionless admission unchanged")
    func videoAndExtensionlessUnchanged() {
        #expect(FilesystemWalker.classifyFile(
            extension: "mov", videoExtensions: video, audioExtensions: audio,
            videoOnlyCatalogScope: true) == .admit)
        #expect(FilesystemWalker.classifyFile(
            extension: "", videoExtensions: video, audioExtensions: audio,
            probeExtensionless: true, videoOnlyCatalogScope: true) == .admit)
    }

    @Test("scope OFF (legacy escape hatch): admission behaves exactly as before")
    func legacyBehaviorPreserved() {
        // mp3 with the audio toggle on — admitted, the pre-scope contract.
        #expect(FilesystemWalker.classifyFile(
            extension: "mp3", videoExtensions: video, audioExtensions: audio,
            scanAudioFiles: true, videoOnlyCatalogScope: false) == .admit)
        // cr2 is on the known-non-media list — rejected as non-media, NOT
        // as catalog-scope (the reason must stay distinguishable).
        #expect(FilesystemWalker.classifyFile(
            extension: "cr2", videoExtensions: video, audioExtensions: audio,
            scanUnknownExtensions: true, videoOnlyCatalogScope: false)
            == .reject(.nonMediaExtension))
    }
}

// MARK: Settings isolation

@Suite("Catalog scope — settings (injected defaults)")
struct CatalogScopeSettingsTests {

    private func freshSuite(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test("default is ON when nothing is stored")
    func defaultOn() {
        let d = freshSuite("vs-test-catalogscope-default")
        #expect(CatalogScopeSettings.restored(from: d).videoAndLinkedAudioOnly)
    }

    @Test("escape hatch (catalog everything) round-trips")
    func escapeHatchRoundTrips() {
        let d = freshSuite("vs-test-catalogscope-hatch")
        var s = CatalogScopeSettings()
        s.videoAndLinkedAudioOnly = false
        s.save(to: d)
        #expect(!CatalogScopeSettings.restored(from: d).videoAndLinkedAudioOnly)
    }

    @Test("poisoned state: a stored true is honored, not confused with the default")
    func storedTrueHonored() {
        let d = freshSuite("vs-test-catalogscope-poison")
        d.set(true, forKey: CatalogScopeSettings.videoOnlyKey)
        #expect(CatalogScopeSettings.restored(from: d).videoAndLinkedAudioOnly)
    }
}

// MARK: The post-scan gate

@MainActor
private func gateRec(
    filename: String,
    streamTypeRaw: String,
    directory: String = "/Volumes/Scan/media",
    duration: Double = 0
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = streamTypeRaw
    r.directory = directory
    r.fullPath = directory + "/" + filename
    r.durationSeconds = duration
    return r
}

@MainActor
@Suite("Catalog scope — post-scan ambiguous-audio gate")
struct CatalogScopeGateTests {

    @Test("gate off (escape hatch) is a pure passthrough")
    func gateOffPassthrough() async {
        let model = VideoScanModel()
        model.catalogScopeSettings.videoAndLinkedAudioOnly = false
        let batch = [
            gateRec(filename: "song.mp3", streamTypeRaw: StreamType.audioOnly.rawValue),
            gateRec(filename: "stray.wav", streamTypeRaw: StreamType.audioOnly.rawValue),
        ]
        let outcome = await model.applyCatalogScopeGate(targetRecords: batch, volName: "T")
        #expect(outcome.admitted.count == 2)
        #expect(outcome.unlinkedAudioExcluded == 0)
    }

    @Test("linked Avid audio-only MXF is kept; unlinked wav is not cataloged")
    func linkedKeptUnlinkedDropped() async {
        let model = VideoScanModel()   // test host default: scope ON
        let video = gateRec(filename: "Tape9V01.4B9C1586.8D8520.mxf",
                            streamTypeRaw: StreamType.videoOnly.rawValue,
                            duration: 300)
        let linkedAudio = gateRec(filename: "Tape9A01.4B9C1586.8D8520.mxf",
                                  streamTypeRaw: StreamType.audioOnly.rawValue,
                                  duration: 300)
        let strayWav = gateRec(filename: "session_take4.wav",
                               streamTypeRaw: StreamType.audioOnly.rawValue,
                               directory: "/Volumes/Scan/MusicStuff",
                               duration: 42)
        let outcome = await model.applyCatalogScopeGate(
            targetRecords: [video, linkedAudio, strayWav], volName: "T")
        let admittedNames = Set(outcome.admitted.map(\.filename))
        #expect(admittedNames.contains("Tape9V01.4B9C1586.8D8520.mxf"))
        #expect(admittedNames.contains("Tape9A01.4B9C1586.8D8520.mxf"))
        #expect(!admittedNames.contains("session_take4.wav"))
        #expect(outcome.linkedAudioKept == 1)
        #expect(outcome.unlinkedAudioExcluded == 1)
    }

    @Test("evidence also comes from the EXISTING catalog, not just this batch")
    func catalogVideosProvideEvidence() async {
        let model = VideoScanModel()
        let cataloged = gateRec(filename: "Tape2V01.0000AAAA.8D8520.mxf",
                                streamTypeRaw: StreamType.videoOnly.rawValue,
                                directory: "/Volumes/Other/OMFI", duration: 120)
        model.records.append(cataloged)
        let audio = gateRec(filename: "Tape2A01.0000AAAA.8D8520.mxf",
                            streamTypeRaw: StreamType.audioOnly.rawValue,
                            duration: 120)
        let outcome = await model.applyCatalogScopeGate(targetRecords: [audio], volName: "T")
        #expect(outcome.linkedAudioKept == 1)
        #expect(outcome.admitted.count == 1)
    }

    @Test("invariant sensor: same-path predecessor in a pair ⇒ fresh record admitted before scoring")
    func pairedPredecessorProtectsFreshInstance() async {
        // A previously recovered pair lives in the catalog. The rescan's
        // fresh instance at the same path carries NO pair fields yet
        // (commitScanResults rewires them after the merge) and would fail
        // the evidence test on its own — it must still be admitted.
        let model = VideoScanModel()
        let oldAudio = gateRec(filename: "half.wav",
                               streamTypeRaw: StreamType.audioOnly.rawValue)
        let partner = gateRec(filename: "half_video.mxf",
                              streamTypeRaw: StreamType.videoOnly.rawValue,
                              directory: "/Volumes/Elsewhere")
        oldAudio.pairedWith = partner
        oldAudio.pairGroupID = UUID()
        partner.pairedWith = oldAudio
        model.records.append(contentsOf: [oldAudio, partner])

        let freshInstance = gateRec(filename: "half.wav",
                                    streamTypeRaw: StreamType.audioOnly.rawValue)
        #expect(freshInstance.fullPath == oldAudio.fullPath)

        let outcome = await model.applyCatalogScopeGate(
            targetRecords: [freshInstance], volName: "T")
        #expect(outcome.admitted.count == 1)
        #expect(outcome.pairProtectedKept == 1)
        #expect(outcome.unlinkedAudioExcluded == 0)
    }

    @Test("sensor: rescan never resurrects — the gate re-drops identically on every pass")
    func rescanNeverResurrects() async {
        let model = VideoScanModel()
        let recordCountBefore = model.records.count
        func freshStray() -> VideoRecord {
            gateRec(filename: "stray_audio.wav",
                    streamTypeRaw: StreamType.audioOnly.rawValue,
                    directory: "/Volumes/Scan/Loose", duration: 77)
        }
        // First scan: dropped.
        let first = await model.applyCatalogScopeGate(
            targetRecords: [freshStray()], volName: "T")
        #expect(first.admitted.isEmpty)
        // Rescan (fresh instance, new UUID — exactly what a rescan makes):
        // dropped again. Nothing creeps back.
        let second = await model.applyCatalogScopeGate(
            targetRecords: [freshStray()], volName: "T")
        #expect(second.admitted.isEmpty)
        #expect(model.records.count == recordCountBefore)  // gate never mutates the catalog
    }

    @Test("stills/music reaching the gate are excluded (belt and braces)")
    func strayStillOrMusicExcluded() async {
        let model = VideoScanModel()
        let mp3 = gateRec(filename: "cover_art.mp3",
                          streamTypeRaw: StreamType.videoAndAudio.rawValue)
        let cr3 = gateRec(filename: "IMG_0042.cr3",
                          streamTypeRaw: StreamType.videoOnly.rawValue)
        let outcome = await model.applyCatalogScopeGate(
            targetRecords: [mp3, cr3], volName: "T")
        #expect(outcome.admitted.isEmpty)
        #expect(outcome.stillOrMusicExcluded == 2)
    }

    @Test("scale: gate over a 100k-record catalog stays within budget")
    func gateAtCatalogScale() async {
        let model = VideoScanModel()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        for i in 0..<100_000 {
            catalog.append(gateRec(
                filename: "Tape\(i % 500)V01.\(String(format: "%08X", i)).mxf",
                streamTypeRaw: i % 5 == 0
                    ? StreamType.videoOnly.rawValue
                    : StreamType.videoAndAudio.rawValue,
                directory: "/Volumes/V\(i % 30)/OMFI",
                duration: Double(60 + i % 3600)))
        }
        // ONE @Published assignment — per-element appends would publish
        // 100k times and measure SwiftUI plumbing, not the gate.
        model.records = catalog
        var batch: [VideoRecord] = []
        for i in 0..<5_000 {
            batch.append(gateRec(
                filename: "session_\(i).wav",
                streamTypeRaw: StreamType.audioOnly.rawValue,
                directory: "/Volumes/Music/\(i % 100)",
                duration: Double(i % 900)))
        }
        let start = ContinuousClock.now
        let outcome = await model.applyCatalogScopeGate(targetRecords: batch, volName: "T")
        let elapsed = start.duration(to: .now)
        #expect(outcome.admitted.isEmpty)
        #expect(outcome.unlinkedAudioExcluded == 5_000)
        #expect(elapsed < .seconds(10),
                "gate over 100k catalog + 5k audio took \(elapsed) — budget 10s")
    }
}
