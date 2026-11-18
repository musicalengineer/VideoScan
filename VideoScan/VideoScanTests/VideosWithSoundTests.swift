// VideosWithSoundTests.swift
// Show ▸ Videos with Sound (DECISIONS 2026-11-18, "Videos with Sound returns";
// VideoWithSound.swift, CatalogShowFilterStore.swift).
//
//   LOGIC      the predicate on every stream type; a paired picture half; the
//              legacy cover-art rows; presence only — one-sided, mono, silent,
//              damaged, never-checked and owner-tagged sound all count; it
//              combines with Not Yet Archived, Needs a Date, Hide Other Versions.
//              (The three-way exclusion and persistence are in
//              CatalogShowFilterStoreTests.)
//   TRUTH      from the ffprobe output the scanner reads, through
//              ScanEngine.extractMetadata, to the tick: cover art never makes a
//              song a video, several sound tracks are still "with sound".
//   MEDIA      mp4/h264+aac, mov/prores+pcm, mkv/ffv1+pcm, mxf (OP1a with sound;
//              OP-Atom picture-only), avi/dv+pcm, as ffprobe reports them.
//   ISOLATION  poisoned / missing stream fields: never listed, never a crash.
//   SCALE      100k records inside the Catalog's filter budget.
//   SENSOR     the predicate reads no sound-quality field, is reached only
//              through the filter table, and the menu has no hand-written row.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func rec(_ name: String, stream: StreamType = .videoAndAudio, videoCodec: String = "h264") -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.ext = (name as NSString).pathExtension
    r.fullPath = "/Volumes/T/\(name)"
    r.directory = "/Volumes/T"
    r.streamTypeRaw = stream.rawValue
    r.videoCodec = stream == .videoAndAudio || stream == .videoOnly ? videoCodec : ""
    return r
}

private func open(_ filters: Set<CatalogViewFilter>) -> CatalogRows.State {
    var s = CatalogRows.State()
    s.showDisconnectedMedia = true
    s.filters = filters
    return s
}

private func probe(_ json: String) throws -> FFProbeOutput {
    try JSONDecoder().decode(FFProbeOutput.self, from: Data(json.utf8))
}

/// A record as the scanner writes it from this ffprobe output.
private func scanned(_ name: String, _ json: String) throws -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.ext = (name as NSString).pathExtension
    r.fullPath = "/Volumes/T/\(name)"
    ScanEngine.extractMetadata(probe: try probe(json), into: r)
    return r
}

@Suite("Videos with Sound — a real picture and a sound track, presence only")
struct VideosWithSoundTests {

    // MARK: LOGIC

    @Test("LOGIC: every stream type — only picture + sound is listed")
    func everyStreamType() {
        let table: [(StreamType, Bool)] = [(.videoAndAudio, true), (.videoOnly, false), (.audioOnly, false),
                                           (.noStreams, false), (.ffprobeFailed, false)]
        let all = table.map { rec("\($0.0.rawValue).mov", stream: $0.0) }
        let listed = CatalogRows.rows(all, open([.videosWithSound])).rows
        for (r, (stream, expected)) in zip(all, table) {
            #expect(VideoWithSound.matches(r) == expected, "\(stream)")
            #expect(listed.contains { $0 === r } == expected, "\(stream)")
        }
        // A paired picture half has no sound track of its own: not listed. Its audio half is not a video.
        let v = rec("v.mxf", stream: .videoOnly, videoCodec: "dnxhd"), a = rec("a.mxf", stream: .audioOnly)
        v.pairedWith = a
        a.pairedWith = v
        #expect(CatalogRows.rows([v, a], open([.videosWithSound])).rows.isEmpty)
    }

    @Test("LOGIC: cover art is not a picture — a song catalogued before the attached_pic fix is not listed; a real Motion-JPEG video is")
    func legacyCoverArtRows() {
        // The shapes CoverArtMusicPurge names: audio extension + mjpeg/png + a video stream type.
        let legacy = [rec("song.mp3", videoCodec: "mjpeg"), rec("song.m4a", videoCodec: "png"),
                      rec("SONG.MP3", videoCodec: "MJPEG"), rec("book.m4b", videoCodec: "mjpeg")]
        for r in legacy {
            #expect(CoverArtMusicPurge.isCandidate(r), "\(r.filename): the precondition — the one cover-art rule names it")
            #expect(!VideoWithSound.matches(r), "\(r.filename) is a song with album art")
        }
        // Not cover art: a camera's Motion-JPEG .mov/.avi with sound, and an audio-extension file with a real codec.
        for r in [rec("camera.mov", videoCodec: "mjpeg"), rec("camera.avi", videoCodec: "mjpeg"),
                  rec("music-video.m4a", videoCodec: "h264")] {
            #expect(VideoWithSound.matches(r), "\(r.filename)")
        }
    }

    /// A video whose stored sound check reads `status` / `note`.
    private func checked(_ name: String, status: String = "ok", note: String = "", channels: String = "2") -> VideoRecord {
        let r = rec(name)
        r.isPlayable = "Yes"
        r.audioChannels = channels
        r.audioVerifyStatus = status
        r.audioVerifyNote = note
        r.audioVerifyDate = Date(timeIntervalSince1970: 1_800_000_000)
        return r
    }

    @Test("LOGIC: presence only — one-sided, mono, silent, damaged, unchecked and owner-tagged sound all count")
    func presenceNotQuality() {
        let fragment = { (f: AudioVerifyFinding) in VerifyAudioRules.noteFragment(for: f) }
        let tagged = checked("silent-checked.mov", note: fragment(.silentAudio))
        tagged.sizeBytes = 4_096
        tagged.tags = [WorkflowTags.silentChecked]
        let all = [
            checked("left-only.mov", note: fragment(.channelImbalance(.leftOnly))),
            checked("right-only.mov", note: fragment(.channelImbalance(.rightOnly))),
            checked("mono.mov", note: fragment(.channelImbalance(.mono)), channels: "1"),
            checked("silent.mov", note: fragment(.silentAudio)),
            checked("damaged.mov", status: "damaged", note: "audio will not decode"),
            checked("fine.mov"),
            rec("never-checked.mov"),
            tagged,
        ]
        #expect(CatalogRows.rows(all, open([.videosWithSound])).rows.map(\.id) == all.map(\.id))
        // The silent and damaged ones are ALSO under Videos Missing Sound: the two are separate
        // questions (has a track / the track is missing or bad); the menu never shows both at once.
        #expect(VideoMissingSound.matches(all[3]) && VideoMissingSound.matches(all[4]))
    }

    @Test("LOGIC: it combines with Not Yet Archived, Needs a Date and Hide Other Versions as the other ticks do")
    func combinesWithTheOtherTicks() {
        let dated = rec("dated.mov"), undated = rec("IMG_0001.mov"), archived = rec("IMG_0002.mov")
        let silentFilm = rec("IMG_0003.mov", stream: .videoOnly), song = rec("IMG_0004.mp3", stream: .audioOnly)
        dated.userDate = "1992-06-14"
        dated.userDateConfidence = "known"
        let all = [dated, undated, archived, silentFilm, song]
        var s = open([.videosWithSound])
        #expect(CatalogRows.rows(all, s).rows.map(\.filename) == ["dated.mov", "IMG_0001.mov", "IMG_0002.mov"])
        s.filters = [.videosWithSound, .needsDate]
        #expect(CatalogRows.rows(all, s).rows.map(\.filename) == ["IMG_0001.mov", "IMG_0002.mov"])
        s.filters = [.videosWithSound, .needsDate, .notYetArchived]
        s.engines.notYetArchived = { $0.filename != "IMG_0002.mov" }
        #expect(CatalogRows.rows(all, s).rows.map(\.filename) == ["IMG_0001.mov"])
        // Hide Other Versions picks among what Videos with Sound left: the silent original is
        // not listed, so its copy with sound represents the group.
        let group = UUID()
        func member(_ rank: Int) -> FootageMembership {
            FootageMembership(groupID: group, groupSize: 2, confidence: .likely, role: rank == 0 ? .original : .copy,
                              rank: rank, likelyOriginalID: silentFilm.id, originalInCatalog: true,
                              evidence: ["same name + length"], scannedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              algorithmVersion: 1)
        }
        silentFilm.footage = member(0)
        undated.footage = member(1)
        s.filters = [.videosWithSound, .onePerFootage]
        #expect(CatalogRows.rows(all, s).rows.map(\.filename) == ["dated.mov", "IMG_0001.mov", "IMG_0002.mov"])
        // Nothing ticked: everything.
        s.filters = []
        #expect(CatalogRows.rows(all, s).rows.count == all.count)
    }

    // MARK: TRUTH + MEDIA — from what ffprobe reports to the tick

    @Test("TRUTH: cover art never makes a song a video; several sound tracks are still one video with sound",
          arguments: [
            // (file, ffprobe streams, listed)
            ("song.mp3", #"[{"codec_type":"audio","codec_name":"mp3","channels":2},{"codec_type":"video","codec_name":"mjpeg","width":1200,"height":1200,"disposition":{"attached_pic":1}}]"#, false),
            ("song.m4a", #"[{"codec_type":"video","codec_name":"png","width":600,"height":600,"disposition":{"attached_pic":1}},{"codec_type":"audio","codec_name":"aac","channels":2}]"#, false),
            ("cover-only.jpg.mp4", #"[{"codec_type":"video","codec_name":"mjpeg","width":1200,"height":1200,"disposition":{"attached_pic":1}}]"#, false),
            ("cover-then-video.mp4", #"[{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}},{"codec_type":"video","codec_name":"h264","width":1920,"height":1080,"disposition":{"attached_pic":0}},{"codec_type":"audio","codec_name":"aac","channels":2}]"#, true),
            ("four-tracks.mov", #"[{"codec_type":"video","codec_name":"prores","width":1920,"height":1080},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1}]"#, true),
            ("data-and-timecode.mov", #"[{"codec_type":"video","codec_name":"h264","width":1280,"height":720},{"codec_type":"data","codec_name":"tmcd"}]"#, false),
            ("nothing.bin", #"[]"#, false),
          ])
    func fromTheProbeToTheTick(file: String, streams: String, listed: Bool) throws {
        let r = try scanned(file, #"{"format":{"format_name":"mov,mp4,m4a"},"streams":"# + streams + "}")
        #expect(VideoWithSound.matches(r) == listed, "\(file): scanned as \(r.streamTypeRaw)")
        #expect(r.videoCodec != "mjpeg" && r.videoCodec != "png", "\(file): cover art leaked into the video fields")
    }

    @Test("MEDIA: the media matrix as ffprobe reports it — mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv",
          arguments: [
            ("clip.mp4", "mov,mp4,m4a,3gp,3g2,mj2", #"[{"codec_type":"video","codec_name":"h264","width":1920,"height":1080},{"codec_type":"audio","codec_name":"aac","channels":2}]"#, true),
            ("master.mov", "mov,mp4,m4a,3gp,3g2,mj2", #"[{"codec_type":"video","codec_name":"prores","width":1920,"height":1080},{"codec_type":"audio","codec_name":"pcm_s24le","channels":2}]"#, true),
            ("preserve.mkv", "matroska,webm", #"[{"codec_type":"video","codec_name":"ffv1","width":720,"height":486},{"codec_type":"audio","codec_name":"pcm_s16le","channels":2}]"#, true),
            ("op1a.mxf", "mxf", #"[{"codec_type":"video","codec_name":"dnxhd","width":1920,"height":1080},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1},{"codec_type":"audio","codec_name":"pcm_s24le","channels":1}]"#, true),
            ("opatom-picture.mxf", "mxf", #"[{"codec_type":"video","codec_name":"dnxhd","width":1920,"height":1080}]"#, false),
            ("opatom-sound.mxf", "mxf", #"[{"codec_type":"audio","codec_name":"pcm_s24le","channels":1}]"#, false),
            ("tape.avi", "avi", #"[{"codec_type":"video","codec_name":"dvvideo","width":720,"height":480},{"codec_type":"audio","codec_name":"pcm_s16le","channels":2}]"#, true),
            ("tape-12bit.dv", "dv", #"[{"codec_type":"video","codec_name":"dvvideo","width":720,"height":480},{"codec_type":"audio","codec_name":"pcm_s16le","channels":2},{"codec_type":"audio","codec_name":"pcm_s16le","channels":2}]"#, true),
          ])
    func mediaMatrix(file: String, format: String, streams: String, listed: Bool) throws {
        let r = try scanned(file, #"{"format":{"format_name":""# + format + #""},"streams":"# + streams + "}")
        #expect(VideoWithSound.matches(r) == listed, "\(file): scanned as \(r.streamTypeRaw)")
        #expect(CatalogRows.rows([r], open([.videosWithSound])).rows.count == (listed ? 1 : 0))
    }

    // MARK: ISOLATION

    @Test("ISOLATION: poisoned or missing stream fields are never listed and never crash")
    func poisonedStreamFields() {
        let long = String(repeating: "v", count: 10_000)
        for raw in ["", " ", "VIDEOANDAUDIO", "videoAndAudio ", "video+audio", "\u{0}", "🎬", long, "null"] {
            let r = rec("poisoned.mov")
            r.streamTypeRaw = raw
            #expect(!VideoWithSound.matches(r), "streamTypeRaw \(raw.prefix(20).debugDescription)")
        }
        // Valid stream type, junk around it: a picture + sound file stays listed unless it is the cover-art shape.
        for (ext, codec, listed) in [("", "", true), ("", "mjpeg", true), ("\u{0}", "\u{0}", true), (long, long, true),
                                     ("MP3", "mJpEg", false), ("mp3", "", true)] {
            let r = rec("x.mov")
            r.ext = ext
            r.videoCodec = codec
            #expect(VideoWithSound.matches(r) == listed, "ext \(ext.prefix(8).debugDescription) codec \(codec.prefix(8).debugDescription)")
        }
        // A whole poisoned catalog through the rows function: nothing listed, nothing thrown.
        let junk = (0..<200).map { i -> VideoRecord in
            let r = VideoRecord()
            r.streamTypeRaw = i % 2 == 0 ? "" : "garbage-\(i)"
            return r
        }
        #expect(CatalogRows.rows(junk, open([.videosWithSound])).rows.isEmpty)
        #expect(CatalogRows.rows([], open([.videosWithSound])).rows.isEmpty)
    }
}

// MARK: - SCALE

@Suite("Videos with Sound — 100k records inside the filter budget")
struct VideosWithSoundScaleTests {

    /// Budget: the Catalog's filter pass at 100k rows — 1.0 s with the tick
    /// alone (the ceiling CatalogRowsScaleTests gives Videos Missing Sound),
    /// 2.0 s with every other filter on too.
    @Test("SCALE: 100k records — Videos with Sound alone, and with every other filter on")
    func hundredThousandRows() {
        let kinds: [StreamType] = [.videoAndAudio, .videoOnly, .audioOnly, .videoAndAudio, .ffprobeFailed]
        let all = (0..<100_000).map { i -> VideoRecord in
            let coverArt = i % 17 == 0
            let r = rec(coverArt ? "song \(i).mp3" : "IMG_\(i).mov", stream: kinds[i % kinds.count],
                        videoCodec: coverArt ? "mjpeg" : "h264")
            if i % 7 == 0 { r.userDate = "1992"; r.userDateConfidence = "known" }
            return r
        }
        let expected = all.filter { $0.streamType == .videoAndAudio && $0.ext != "mp3" }.count
        var s = open([.videosWithSound])
        var t0 = Date()
        let listed = CatalogRows.rows(all, s)
        var elapsed = Date().timeIntervalSince(t0)
        #expect(listed.rows.count == expected && expected > 35_000)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 1.0), "Videos with Sound took \(elapsed)s for 100k records")

        s.filters = [.videosWithSound, .needsDate, .notYetArchived, .onePerFootage]
        s.engines.notYetArchived = { $0.sizeBytes == 0 }
        t0 = Date()
        let narrowed = CatalogRows.rows(all, s)
        elapsed = Date().timeIntervalSince(t0)
        #expect(narrowed.rows.count > 1_000 && narrowed.rows.count < expected)
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 2.0), "every filter took \(elapsed)s for 100k records")
    }
}

// MARK: - SENSOR

@Suite("Videos with Sound — one rule, one path (sensor)")
struct VideosWithSoundSensorTests {

    @Test("SENSOR: the rule reads presence only — no sound check, no standing — and the one cover-art rule")
    func theRuleReadsPresenceOnly() throws {
        let code = SourceTree.strippingComments(try SourceTree.appCode(named: "VideoWithSound.swift"))
        for quality in ["audioVerify", "SoundStanding", "storedSoundStanding", "audioChannels", "VideoMissingSound"] {
            #expect(!code.contains(quality), "Videos with Sound reads \(quality): it must be presence only")
        }
        #expect(code.contains("CoverArtMusicPurge.isCandidate"), "cover art must be excluded by the one existing rule")
        #expect(!code.contains("attached_pic") && !code.contains("\"mjpeg\""), "a second cover-art rule")
    }

    @Test("SENSOR: the tick is reached only through the filter table; the menu has no hand-written row; one kind list")
    func oneFilterPath() throws {
        let store = SourceTree.strippingComments(try SourceTree.appCode(named: "CatalogShowFilterStore.swift"))
        #expect(store.contains("case .videosWithSound:    return VideoWithSound.matches"))
        #expect(store.contains("static let kinds: [CatalogViewFilter] = [.audioOnly, .videosWithSound, .videosMissingSound]"))
        let toolbar = SourceTree.strippingComments(try SourceTree.appCode(named: "CatalogToolbar.swift"))
        #expect(!toolbar.contains("videosWithSound") && !toolbar.contains("Videos with Sound"),
                "the Show menu builds its ticks from CatalogViewFilter.allCases, never by hand")
        for source in SourceTree.appSources {
            let name = source.url.lastPathComponent
            guard name != "CatalogShowFilterStore.swift", name != "VideoWithSound.swift" else { continue }
            let code = SourceTree.strippingComments(try String(contentsOf: source.url, encoding: .utf8))
            #expect(!code.contains("VideoWithSound.matches"), "\(name) applies Videos with Sound outside the filter table")
        }
    }
}
