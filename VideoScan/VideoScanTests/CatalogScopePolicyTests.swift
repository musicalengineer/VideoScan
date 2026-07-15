import Foundation
import Testing
@testable import VideoScan

// MARK: - Catalog Scope Policy tests (video-only catalog, 2026-07-15)
//
// Rick's directive: the catalog holds ONLY video and audio with strict
// evidence of belonging to video. These tests pin the PURE half:
//   Logic    — the classification table (every extension class, both
//              polarities), the evidence tiers that count as "linked"
//              and the tier that must NOT (duration+timestamp
//              coincidence, GH #101), extensionless, DRM'd video.
//   Sensor   — the hard invariant: audio already in a recovered/
//              correlated/combined MXF pair is NEVER classified as
//              cruft, even when its evidence would otherwise fail.
//   Scale    — evidence build + classification over 100k synthetic
//              records with an explicit time budget.
// Media matrix: N/A — classification never opens files by design.
// Isolation: N/A here — no global state (settings tests live with the
// scan-integration suite).

@MainActor
private func scopeRec(
    filename: String,
    ext: String? = nil,
    streamTypeRaw: String = StreamType.videoAndAudio.rawValue,
    directory: String = "/Volumes/T/media",
    duration: Double = 0,
    created: Date? = nil,
    timecode: String = "",
    tape: String = ""
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = ext ?? (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = streamTypeRaw
    r.directory = directory
    r.fullPath = directory + "/" + filename
    r.durationSeconds = duration
    r.dateCreatedRaw = created
    r.timecode = timecode
    r.tapeName = tape
    return r
}

private func snap(
    filename: String,
    directory: String = "/Volumes/T/media",
    duration: Double = 0,
    created: Date? = nil,
    timecode: String = "",
    tape: String = ""
) -> CorrelationScorer.Snap {
    CorrelationScorer.Snap(
        id: UUID(), filename: filename, directory: directory,
        durationSeconds: duration, dateCreatedRaw: created,
        timecode: timecode, tapeName: tape)
}

// MARK: Classification table

@Suite("CatalogScopePolicy classification")
struct CatalogScopeClassificationTests {

    @Test("stills are always excluded — full extension class",
          arguments: ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif",
                      "gif", "bmp", "webp",
                      "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"])
    func stillsExcluded(ext: String) {
        #expect(CatalogScopePolicy.classify(
            ext: ext, streamTypeRaw: StreamType.videoOnly.rawValue) == .still)
        #expect(CatalogScopePolicy.extensionAlwaysExcluded(ext))
    }

    @Test("sensor: Canon CR3 stays a still even when probed as a video stream")
    func cr3BeatsStreamType() {
        // CR3 is ISO-BMFF — it passes the magic-byte sniff and ffprobe
        // reports a video stream. Extension classification must win.
        #expect(CatalogScopePolicy.classify(
            ext: "CR3", streamTypeRaw: StreamType.videoOnly.rawValue) == .still)
    }

    @Test("music formats are always excluded — Rick's explicit list",
          arguments: ["mp3", "m4a", "aac", "flac", "ogg", "wma", "opus"])
    func musicExcluded(ext: String) {
        #expect(CatalogScopePolicy.classify(
            ext: ext, streamTypeRaw: StreamType.audioOnly.rawValue) == .music)
        #expect(CatalogScopePolicy.extensionAlwaysExcluded(ext))
    }

    @Test("sensor: cover-art mp3 probing as Video+Audio is still music")
    func coverArtMp3IsMusic() {
        #expect(CatalogScopePolicy.classify(
            ext: "mp3", streamTypeRaw: StreamType.videoAndAudio.rawValue) == .music)
    }

    @Test("video containers are always included",
          arguments: ["mov", "mp4", "mkv", "mxf", "avi", "dv", "mts", "m2ts", "webm"])
    func videoIncluded(ext: String) {
        #expect(CatalogScopePolicy.classify(
            ext: ext, streamTypeRaw: StreamType.videoAndAudio.rawValue) == .video)
        #expect(!CatalogScopePolicy.extensionAlwaysExcluded(ext))
    }

    @Test("DRM'd / unprobeable video extensions stay video (never cruft)")
    func drmVideoStaysVideo() {
        // A FairPlay m4v that ffprobe couldn't open still classifies as
        // video by extension — scope never excludes damaged/locked video.
        #expect(CatalogScopePolicy.classify(
            ext: "m4v", streamTypeRaw: StreamType.ffprobeFailed.rawValue) == .video)
    }

    @Test("extensionless is always included — Avid recovery")
    func extensionlessIncluded() {
        #expect(CatalogScopePolicy.classify(
            ext: "", streamTypeRaw: StreamType.ffprobeFailed.rawValue) == .extensionless)
        #expect(!CatalogScopePolicy.extensionAlwaysExcluded(""))
    }

    @Test("extensionless beats probed stream type — recovered audio essence is never evidence-gated")
    func extensionlessAudioOnlyStaysIncluded() {
        // QA MAJOR 5 (2026-07-15, Manager decision per Rick's standing
        // "extensionless stays eligible (Avid recovery)" rule): recovered
        // extensionless audio essence carries data-recovery names
        // (file0001) whose structural evidence ALWAYS fails — routing it
        // through the ambiguous-audio evidence test excluded exactly the
        // files this app rescues. Extensionless → always included,
        // regardless of what ffprobe saw. RED pre-fix: .ambiguousAudio.
        #expect(CatalogScopePolicy.classify(
            ext: "", streamTypeRaw: StreamType.audioOnly.rawValue) == .extensionless)
        // Whitespace-only extension is the same class after trimming.
        #expect(CatalogScopePolicy.classify(
            ext: " ", streamTypeRaw: StreamType.audioOnly.rawValue) == .extensionless)
    }

    @Test("ambiguous audio class: wav/aif/aiff/aifc/caf and audio-only streams",
          arguments: ["wav", "aif", "aiff", "aifc", "caf"])
    func ambiguousAudioByExtension(ext: String) {
        #expect(CatalogScopePolicy.classify(
            ext: ext, streamTypeRaw: StreamType.audioOnly.rawValue) == .ambiguousAudio)
        // NOT skippable pre-probe — the evidence test needs its metadata.
        #expect(!CatalogScopePolicy.extensionAlwaysExcluded(ext))
    }

    @Test("audio-only MXF is ambiguous (video extension, audio-only stream)")
    func audioOnlyMxfIsAmbiguous() {
        #expect(CatalogScopePolicy.classify(
            ext: "mxf", streamTypeRaw: StreamType.audioOnly.rawValue) == .ambiguousAudio)
    }

    @Test("audio extensions OUTSIDE Rick's music list fall to ambiguous, not music",
          arguments: ["mp2", "alac", "oga", "au", "amr", "snd", "ac3"])
    func nonListedAudioIsAmbiguous(ext: String) {
        // Conservative by design: exclusion on weak evidence is the
        // failure mode this project exists to avoid. Unlinked oddballs
        // are excluded by the evidence test anyway.
        #expect(CatalogScopePolicy.classify(
            ext: ext, streamTypeRaw: StreamType.audioOnly.rawValue) == .ambiguousAudio)
    }

    @Test("classification is case-insensitive")
    func caseInsensitive() {
        #expect(CatalogScopePolicy.classify(
            ext: "MP3", streamTypeRaw: "") == .music)
        #expect(CatalogScopePolicy.classify(
            ext: "WAV", streamTypeRaw: StreamType.audioOnly.rawValue) == .ambiguousAudio)
        #expect(CatalogScopePolicy.extensionAlwaysExcluded("JPG"))
    }
}

// MARK: Evidence tiers (reuse of the Correlate machinery)

@Suite("CatalogScopeEvidence — video-linked test")
struct CatalogScopeEvidenceTests {

    @Test("linked: Avid tape/clip filename-key match (the orphan MXF shape)")
    func avidFilenameKeyLinks() {
        // NewTape9V01.4B9C1586.* ↔ NewTape9A01.4B9C1586.* share the
        // filename correlation key — score 4, structural. This is THE
        // orphaned-Avid-pair signature.
        let evidence = CatalogScopeEvidence(videoSnaps: [
            snap(filename: "NewTape9V01.4B9C1586.8D8520.mxf",
                 directory: "/Volumes/Avid/OMFI MediaFiles"),
        ])
        let audio = snap(filename: "NewTape9A01.4B9C1586.8D8520.mxf",
                         directory: "/Volumes/Avid/Somewhere Else")
        #expect(evidence.isVideoLinked(audio))
    }

    @Test("linked: same-folder video sibling + duration match")
    func sameFolderDurationLinks() {
        // directory (1, structural) + duration (3) = 4 ≥ floor — a tier
        // the correlator already scores; we add nothing new.
        let evidence = CatalogScopeEvidence(videoSnaps: [
            snap(filename: "clip_video.mxf",
                 directory: "/Volumes/T/Tape7", duration: 812.4),
        ])
        let audio = snap(filename: "unrelated_name.wav",
                         directory: "/Volumes/T/Tape7", duration: 812.9)
        #expect(evidence.isVideoLinked(audio))
    }

    @Test("linked: timecode + duration reaches the bar structurally")
    func timecodeDurationLinks() {
        let evidence = CatalogScopeEvidence(videoSnaps: [
            snap(filename: "v.mxf", directory: "/Volumes/A",
                 duration: 100, timecode: "01:02:03:04"),
        ])
        let audio = snap(filename: "a.wav", directory: "/Volumes/B",
                         duration: 100, timecode: "01:02:03:04")
        #expect(evidence.isVideoLinked(audio))
    }

    @Test("negative sensor (GH #101): duration + timestamp coincidence is NOT linked")
    func durationTimestampCoincidenceDoesNotLink() {
        // Score 6 (duration 3 + timestamp 3) clears the correlator floor
        // but carries NO structural signal — the exact coincidence class
        // that paired Rick's Donna_by_decade demo with an unrelated Avid
        // orphan. Must never count as evidence of belonging to video.
        let t = Date(timeIntervalSince1970: 700_000_000)
        let evidence = CatalogScopeEvidence(videoSnaps: [
            snap(filename: "vacation_video.mov", directory: "/Volumes/A/x",
                 duration: 300, created: t),
        ])
        let audio = snap(filename: "song_take3.wav", directory: "/Volumes/B/y",
                         duration: 300.5, created: t.addingTimeInterval(2))
        #expect(!evidence.isVideoLinked(audio))
    }

    @Test("negative: unrelated audio with no shared signal is not linked")
    func unrelatedAudioNotLinked() {
        let evidence = CatalogScopeEvidence(videoSnaps: [
            snap(filename: "birthday_1987.mov", directory: "/Volumes/A", duration: 500),
        ])
        let audio = snap(filename: "mixdown_final.wav", directory: "/Volumes/B", duration: 42)
        #expect(!evidence.isVideoLinked(audio))
    }

    @Test("negative: empty video pool never links anything")
    func emptyPoolNeverLinks() {
        let evidence = CatalogScopeEvidence(videoSnaps: [])
        #expect(!evidence.isVideoLinked(snap(filename: "a.wav", duration: 10)))
    }

    @Test("sensor: the GH-#101 structural-signal bar is ONE shared constant with pinned contents")
    func structuralSignalBarIsSharedAndPinned() {
        // QA MINOR 8 (2026-07-15): the set was duplicated in findBestPair
        // and CatalogScopeEvidence — a drift in either copy would silently
        // change what counts as "evidence of belonging to video" or what
        // Find A/V Pair may propose. Pin the contents AND the sharing.
        #expect(CorrelationScorer.structuralSignals
                == ["filename", "directory", "timecode", "tape"])
        #expect(CatalogScopeEvidence.structuralSignals
                == CorrelationScorer.structuralSignals,
                "the evidence test must consume the SAME constant, not a copy")
    }
}

// MARK: The hard invariant (regression sensor)

@MainActor
@Suite("CatalogScopePolicy pair-protection invariant")
struct CatalogScopePairInvariantTests {

    @Test("sensor: audio in an existing correlated pair is NEVER cruft, even with failing evidence")
    func pairedAudioNeverClassified() {
        // A wav with zero linkage evidence — on its own it would be
        // .ambiguousAudio and set aside as unlinked. Pairing protects it
        // BEFORE any scoring.
        let audio = scopeRec(filename: "orphan.wav",
                             streamTypeRaw: StreamType.audioOnly.rawValue)
        let video = scopeRec(filename: "partner.mxf",
                             streamTypeRaw: StreamType.videoOnly.rawValue)
        audio.pairedWith = video
        audio.pairGroupID = UUID()
        video.pairedWith = audio

        #expect(CatalogScopePolicy.isPairProtected(audio))
        #expect(CatalogScopePolicy.classifyRecord(audio) == nil)
        #expect(CatalogScopePolicy.setAsideReason(for: audio,
                                                  isVideoLinked: { _ in false }) == nil)
    }

    @Test("sensor: a decoded-but-unresolved pair reference still protects")
    func pendingPairedWithIDProtects() {
        // Right after catalog decode, pairedWith is not yet rewired —
        // only pendingPairedWithID is set. Protection must hold there
        // too, or a migration running before pair resolution could set
        // aside half of a recovered pair.
        let audio = scopeRec(filename: "half.mxf",
                             streamTypeRaw: StreamType.audioOnly.rawValue)
        audio.pendingPairedWithID = UUID()
        #expect(CatalogScopePolicy.classifyRecord(audio) == nil)
    }

    @Test("sensor: Combine outputs are protected via combinedFromPairID")
    func combinedOutputProtected() {
        let combined = scopeRec(filename: "recovered_pair.mov",
                                streamTypeRaw: StreamType.audioOnly.rawValue)
        combined.combinedFromPairID = UUID()
        #expect(CatalogScopePolicy.classifyRecord(combined) == nil)
    }

    @Test("unpaired records classify normally (protection is not a blanket)")
    func unpairedStillClassified() {
        let music = scopeRec(filename: "song.mp3",
                             streamTypeRaw: StreamType.audioOnly.rawValue)
        #expect(CatalogScopePolicy.classifyRecord(music) == .music)
        #expect(CatalogScopePolicy.setAsideReason(for: music,
                                                  isVideoLinked: { _ in false }) == .musicFormat)
    }

    @Test("ambiguous audio with passing evidence is kept")
    func linkedAudioKept() {
        let wav = scopeRec(filename: "tape7.wav",
                           streamTypeRaw: StreamType.audioOnly.rawValue)
        #expect(CatalogScopePolicy.setAsideReason(for: wav,
                                                  isVideoLinked: { _ in true }) == nil)
    }

    @Test("ambiguous audio with failing evidence is unlinked-audio")
    func unlinkedAudioSetAside() {
        let wav = scopeRec(filename: "scratch.wav",
                           streamTypeRaw: StreamType.audioOnly.rawValue)
        #expect(CatalogScopePolicy.setAsideReason(for: wav,
                                                  isVideoLinked: { _ in false }) == .unlinkedAudio)
    }
}

// MARK: Scale (100k records, explicit time budget)

@Suite("CatalogScopePolicy scale")
struct CatalogScopeScaleTests {

    @Test("evidence build + classification over 100k synthetic records under budget")
    func hundredKUnderBudget() {
        // 20k video-only + 60k ambiguous audio + 20k music/stills — the
        // realistic worst case (Rick's catalog is ~103k with ~81k audio).
        var videos: [CorrelationScorer.Snap] = []
        videos.reserveCapacity(20_000)
        for i in 0..<20_000 {
            videos.append(snap(
                filename: "Tape\(i % 300)V01.\(String(format: "%08X", i)).mxf",
                directory: "/Volumes/V\(i % 40)/OMFI MediaFiles",
                duration: Double(60 + i % 3600)))
        }
        var audios: [CorrelationScorer.Snap] = []
        audios.reserveCapacity(60_000)
        for i in 0..<60_000 {
            // Every 4th audio shares the Avid key with a video (linked);
            // the rest are music-archive strays in foreign folders.
            if i % 4 == 0 {
                audios.append(snap(
                    filename: "Tape\((i / 4) % 300)A01.\(String(format: "%08X", i / 4)).mxf",
                    directory: "/Volumes/AudioDump/\(i % 100)",
                    duration: Double(60 + (i / 4) % 3600)))
            } else {
                audios.append(snap(
                    filename: "session_\(i).wav",
                    directory: "/Volumes/Music/\(i % 500)",
                    duration: Double(i % 900)))
            }
        }

        let start = ContinuousClock.now

        // Extension classification for the always-excluded 20k.
        var stillCount = 0, musicCount = 0
        for i in 0..<20_000 {
            switch CatalogScopePolicy.classify(
                ext: i % 2 == 0 ? "cr3" : "mp3",
                streamTypeRaw: StreamType.videoOnly.rawValue) {
            case .still: stillCount += 1
            case .music: musicCount += 1
            default: break
            }
        }

        let evidence = CatalogScopeEvidence(videoSnaps: videos)
        var linked = 0
        for a in audios where evidence.isVideoLinked(a) { linked += 1 }

        let elapsed = start.duration(to: .now)
        #expect(stillCount == 10_000)
        #expect(musicCount == 10_000)
        #expect(linked == 15_000)   // exactly the i%4==0 Avid-key set
        // Budget: indexed pools keep this well under a second on Apple
        // Silicon; 5 s is the generous CI bound (M1 under load).
        #expect(elapsed < .seconds(5),
                "100k classification + evidence took \(elapsed) — budget 5s")
    }
}
