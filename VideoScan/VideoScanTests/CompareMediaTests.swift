// CompareMediaTests.swift
// Compare Media's catalog half — the pure projection (codec generation,
// frame height, bit rate, names said, folder label, the reliable day) and
// the page's words (the band's duration, the fact rows with their diffs).
// The match itself is the engine's (VideoScanCore, its own suite).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Compare Media — projection and words")
struct CompareMediaTests {

    @Test("codec generation: captures are original, re-encodes are delivery, audio decides for audio-only files")
    func codecGeneration() {
        #expect(VideoScanModel.codecGeneration(video: "dvvideo", audio: "pcm_s16le") == .original)
        #expect(VideoScanModel.codecGeneration(video: "prores", audio: "pcm_s24le") == .original)
        #expect(VideoScanModel.codecGeneration(video: "ffv1", audio: "flac") == .original)
        #expect(VideoScanModel.codecGeneration(video: "h264", audio: "aac") == .delivery)
        #expect(VideoScanModel.codecGeneration(video: "mpeg2video", audio: "ac3") == .delivery)
        #expect(VideoScanModel.codecGeneration(video: "", audio: "pcm_s16le") == .original)
        #expect(VideoScanModel.codecGeneration(video: "", audio: "aac") == .delivery)
        #expect(VideoScanModel.codecGeneration(video: "", audio: "") == .unknown)
        #expect(VideoScanModel.codecGeneration(video: "wavpack9", audio: "") == .unknown)
    }

    @Test("frame height and bit rate from the catalog's strings")
    func sizes() {
        #expect(VideoScanModel.frameHeight(fromResolution: "720x480") == 480)
        #expect(VideoScanModel.frameHeight(fromResolution: "1920×1080") == 1080)
        #expect(VideoScanModel.frameHeight(fromResolution: "") == nil && VideoScanModel.frameHeight(fromResolution: "0x0") == nil)
        #expect(VideoScanModel.bitRate(from: "8 Mb/s") == 8_000_000)
        #expect(VideoScanModel.bitRate(from: "1500 kb/s") == 1_500_000)
        #expect(VideoScanModel.bitRate(from: "25000000") == 25_000_000)
        #expect(VideoScanModel.bitRate(from: "") == nil)
    }

    @Test("names said: transcript words that are a person's first name on either side, whole words, any case")
    func namesSaid() {
        let known: Set<String> = ["Alex Tester", "Sam", "Mark"]
        #expect(VideoScanModel.namesSaid(in: "Happy birthday ALEX! Sam, get the cake.", known: known) == ["Alex Tester", "Sam"])
        #expect(VideoScanModel.namesSaid(in: "the markers are on the table", known: known).isEmpty, "'markers' is not Mark")
        #expect(VideoScanModel.namesSaid(in: nil, known: known).isEmpty)
    }

    @Test("folder label: the parent folder, unless it is one every drive has")
    func folderLabel() {
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/MediaExpansion/Test Event 10th Bday Restored/VIDEO_TS/VTS_01_1.VOB") == nil, "VIDEO_TS is generic")
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/LaCie/Test Event 10th Bday/Part-1.mov") == "test event 10th bday")
        #expect(VideoScanModel.folderLabel(forPath: "/Users/rickb/Movies/clip.mov") == nil)
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/X/Avid MediaFiles/MXF/1/a.mxf") == nil)
    }

    @Test("a side from a record: your date is reliable, a file date is not; a no-sound stamp is 0 audible seconds; the archive flags ride along")
    @MainActor func sideFromRecord() {
        let r = VideoRecord()
        r.fullPath = "/Volumes/LaCie/Test Event 10th Bday/Part-1.mov"; r.filename = "Part-1.mov"; r.directory = "/Volumes/LaCie/Test Event 10th Bday"
        r.durationSeconds = 78; r.sizeBytes = 92_000_000; r.videoCodec = "h264"; r.audioCodec = "aac"; r.resolution = "640x480"; r.totalBitrate = "9 Mb/s"
        r.userDate = "1996-03-15"
        r.audioFingerprint = AudioFingerprintStamp(computedAt: Date(), engineVersion: 2, contentDigest: "sha256:abc", sizeBytes: 92_000_000,
                                                   outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
        let s = VideoScanModel.relatedSide(r, isArchiveFile: false, isArchived: true, now: Date())
        #expect(s.day == EventDay(year: 1996, month: 3, day: 15) && s.dayIsReliable)
        #expect(s.audibleSeconds == 0 && s.isSilent)
        #expect(s.codec == .delivery && s.frameHeight == 480 && s.bitRate == 9_000_000)
        #expect(s.folderLabel == "test event 10th bday" && !s.isArchiveFile && s.isArchived)
        #expect(s.digest == nil, "no stored full hash → not checked")
        // A date read from the file NAME is a day, never a reliable one (the
        // resolver's own ranking: you › camera › inferred › file name).
        let named = VideoRecord()
        named.fullPath = "/Volumes/X/1996-03-15 party.mov"; named.filename = "1996-03-15 party.mov"
        let t = VideoScanModel.relatedSide(named, isArchiveFile: false, isArchived: false, now: Date())
        #expect(t.day == EventDay(year: 1996, month: 3, day: 15) && !t.dayIsReliable, "\(String(describing: t.day)) \(t.dayIsReliable)")
    }

    @Test("the band's duration words")
    func durationWords() {
        let a = RelatedEvidence.Side(digest: "x", sizeBytes: 1, durationSeconds: 2280), b = RelatedEvidence.Side(digest: "x", sizeBytes: 1, durationSeconds: 2280)
        #expect(CompareMediaWords.duration(.sameEvent, RelatedEvidence(a: a, b: b)) == "byte for byte · 38:00")
        let vob = RelatedEvidence.Side(digest: "y", sizeBytes: 1, durationSeconds: 2250)
        #expect(CompareMediaWords.duration(.sameEvent, RelatedEvidence(a: vob, b: b)) == "37:30 of 38:00")
        #expect(CompareMediaWords.duration(.clipFromSameEvent(clip: .a, seconds: 78, offsetSeconds: 376), RelatedEvidence(a: a, b: b)) == "1:18 of 38:00 · at 6:16")
        #expect(CompareMediaWords.duration(.differentCapture(sharedSeconds: 19), RelatedEvidence(a: a, b: b)) == "19 s of shared sound")
        #expect(CompareMediaWords.duration(.differentCapture(sharedSeconds: 0), RelatedEvidence(a: a, b: b)) == "no shared sound")
        #expect(CompareMediaWords.duration(.differentEvents, RelatedEvidence(a: a, b: b)) == "no shared minute")
    }

    @Test("codex 10/15 F5: 'byte for byte' only for a true identical copy — equal stored digests with different sizes are not")
    func durationWordsRequireEqualSizesForByteIdentity() {
        let a = RelatedEvidence.Side(digest: "x", sizeBytes: 1, durationSeconds: 2280), b = RelatedEvidence.Side(digest: "x", sizeBytes: 2, durationSeconds: 2280)
        let e = RelatedEvidence(a: a, b: b, audio: .sameRecording)
        #expect(!CompareMediaWords.duration(RelatedLadder.judge(e).band, e).contains("byte for byte"))
    }

    @Test("codex 10/15 F6: the strip answers each pixel from prefix sums — O(width) per draw, correct at the edges")
    func stripBins() {
        let active = [false, true, true, false, false, true]
        let bins = SoundStripBins(active: active, matched: 1..<3, durationSeconds: 6)
        #expect(bins.seconds == 6)
        #expect(bins.anyAudible(0, 1) == false && bins.anyAudible(0, 2) == true && bins.anyAudible(3, 5) == false && bins.anyAudible(5, 6) == true)
        #expect(bins.anyAudible(6, 9) == false, "beyond the map is silent")
        #expect(bins.anyMatched(0, 1) == false && bins.anyMatched(0, 2) == true && bins.anyMatched(2, 3) == true && bins.anyMatched(3, 6) == false)
        let longer = SoundStripBins(active: [true], matched: nil, durationSeconds: 100)
        #expect(longer.seconds == 100 && longer.anyAudible(50, 60) == false, "duration beyond the map counts as seconds, silent")
    }

    @Test("codex 10/15 F2: a year-only user date reaches the side as its year")
    @MainActor func yearOnlyDate() {
        let r = VideoRecord(); r.fullPath = "/Volumes/X/a.mov"; r.filename = "a.mov"; r.userDate = "1988"; r.durationSeconds = 2100
        let s = VideoScanModel.relatedSide(r, isArchiveFile: false, isArchived: false, now: Date())
        #expect(s.year == 1988 && s.day == nil, "\(String(describing: s.year)) \(String(describing: s.day))")
    }

    @Test("codex r2 F3: a non-finite or negative duration never traps the strip — the map's length wins")
    func nonfiniteDurationUsesMapLength() {
        let active = [false, true, true, false, false, true]
        #expect(SoundStripBins(active: active, matched: 1..<3, durationSeconds: .nan).seconds == 6)
        #expect(SoundStripBins(active: active, matched: nil, durationSeconds: .infinity).seconds == 6)
        #expect(SoundStripBins(active: active, matched: nil, durationSeconds: -5).seconds == 6)
        #expect(SoundStripBins(active: [], matched: nil, durationSeconds: .nan).seconds == 1)
    }

    @Test("fact rows: a field that differs from the other side is marked; equal ones are not")
    @MainActor func factRows() {
        let r = VideoRecord(); r.videoCodec = "h264"; r.audioCodec = "aac"; r.resolution = "640x480"
        let side = RelatedEvidence.Side(digest: "a7c3" + String(repeating: "0", count: 60), sizeBytes: 92_000_000, durationSeconds: 78, audibleSeconds: 76,
                                        day: EventDay(year: 1996, month: 3, day: 15), dayIsReliable: false, people: ["Alex"], codec: .delivery, frameHeight: 480)
        let other = RelatedEvidence.Side(digest: "4f1d" + String(repeating: "0", count: 60), sizeBytes: 4_300_000_000, durationSeconds: 2280, audibleSeconds: 2150,
                                         day: EventDay(year: 1996, month: 3, day: 15), dayIsReliable: true, people: ["Alex"], isArchiveFile: true, isArchived: true, codec: .original, frameHeight: 480)
        let facts = CompareMediaWords.facts(r, side: side, other: other)
        let byName = Dictionary(uniqueKeysWithValues: facts.map { ($0.name, $0) })
        #expect(byName["length"]?.value == "1:18" && byName["length"]?.differs == true)
        #expect(byName["codecs"]?.value == "h264 · aac" && byName["codecs"]?.differs == true)
        #expect(byName["frame"]?.differs == false)
        #expect(byName["SHA-256"]?.value == "a7c3…0000" && byName["SHA-256"]?.differs == true)
        #expect(byName["date"]?.value == "1996-03-15 (file date)" && byName["date"]?.differs == true)
        #expect(byName["people"]?.differs == false)
        #expect(byName["archive"]?.value == "not archived" && byName["archive"]?.differs == true)
        #expect(byName["sound"]?.value == "1:16 audible")
    }
}
