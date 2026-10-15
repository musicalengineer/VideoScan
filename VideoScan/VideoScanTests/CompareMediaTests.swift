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
        let known: Set<String> = ["Timmy Breen", "Donna", "Mark"]
        #expect(VideoScanModel.namesSaid(in: "Happy birthday TIMMY! Donna, get the cake.", known: known) == ["Timmy Breen", "Donna"])
        #expect(VideoScanModel.namesSaid(in: "the markers are on the table", known: known).isEmpty, "'markers' is not Mark")
        #expect(VideoScanModel.namesSaid(in: nil, known: known).isEmpty)
    }

    @Test("folder label: the parent folder, unless it is one every drive has")
    func folderLabel() {
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/MediaExpansion/Timmy 10th Bday Restored/VIDEO_TS/VTS_01_1.VOB") == nil, "VIDEO_TS is generic")
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/LaCie/Timmy 10th Bday/Part-1.mov") == "timmy 10th bday")
        #expect(VideoScanModel.folderLabel(forPath: "/Users/rickb/Movies/clip.mov") == nil)
        #expect(VideoScanModel.folderLabel(forPath: "/Volumes/X/Avid MediaFiles/MXF/1/a.mxf") == nil)
    }

    @Test("a side from a record: your date is reliable, a file date is not; a no-sound stamp is 0 audible seconds; the archive flags ride along")
    @MainActor func sideFromRecord() {
        let r = VideoRecord()
        r.fullPath = "/Volumes/LaCie/Timmy 10th Bday/Part-1.mov"; r.filename = "Part-1.mov"; r.directory = "/Volumes/LaCie/Timmy 10th Bday"
        r.durationSeconds = 78; r.sizeBytes = 92_000_000; r.videoCodec = "h264"; r.audioCodec = "aac"; r.resolution = "640x480"; r.totalBitrate = "9 Mb/s"
        r.userDate = "1996-04-22"
        r.audioFingerprint = AudioFingerprintStamp(computedAt: Date(), engineVersion: 2, contentDigest: "sha256:abc", sizeBytes: 92_000_000,
                                                   outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
        let s = VideoScanModel.relatedSide(r, isArchiveFile: false, isArchived: true, now: Date())
        #expect(s.day == EventDay(year: 1996, month: 4, day: 22) && s.dayIsReliable)
        #expect(s.audibleSeconds == 0 && s.isSilent)
        #expect(s.codec == .delivery && s.frameHeight == 480 && s.bitRate == 9_000_000)
        #expect(s.folderLabel == "timmy 10th bday" && !s.isArchiveFile && s.isArchived)
        #expect(s.digest == nil, "no stored full hash → not checked")
        // A date read from the file NAME is a day, never a reliable one (the
        // resolver's own ranking: you › camera › inferred › file name).
        let named = VideoRecord()
        named.fullPath = "/Volumes/X/1996-04-22 party.mov"; named.filename = "1996-04-22 party.mov"
        let t = VideoScanModel.relatedSide(named, isArchiveFile: false, isArchived: false, now: Date())
        #expect(t.day == EventDay(year: 1996, month: 4, day: 22) && !t.dayIsReliable, "\(String(describing: t.day)) \(t.dayIsReliable)")
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

    @Test("fact rows: a field that differs from the other side is marked; equal ones are not")
    @MainActor func factRows() {
        let r = VideoRecord(); r.videoCodec = "h264"; r.audioCodec = "aac"; r.resolution = "640x480"
        let side = RelatedEvidence.Side(digest: "a7c3" + String(repeating: "0", count: 60), sizeBytes: 92_000_000, durationSeconds: 78, audibleSeconds: 76,
                                        day: EventDay(year: 1996, month: 4, day: 22), dayIsReliable: false, people: ["Timmy"], codec: .delivery, frameHeight: 480)
        let other = RelatedEvidence.Side(digest: "4f1d" + String(repeating: "0", count: 60), sizeBytes: 4_300_000_000, durationSeconds: 2280, audibleSeconds: 2150,
                                         day: EventDay(year: 1996, month: 4, day: 22), dayIsReliable: true, people: ["Timmy"], isArchiveFile: true, isArchived: true, codec: .original, frameHeight: 480)
        let facts = CompareMediaWords.facts(r, side: side, other: other)
        let byName = Dictionary(uniqueKeysWithValues: facts.map { ($0.name, $0) })
        #expect(byName["length"]?.value == "1:18" && byName["length"]?.differs == true)
        #expect(byName["codecs"]?.value == "h264 · aac" && byName["codecs"]?.differs == true)
        #expect(byName["frame"]?.differs == false)
        #expect(byName["SHA-256"]?.value == "a7c3…0000" && byName["SHA-256"]?.differs == true)
        #expect(byName["date"]?.value == "1996-04-22 (file date)" && byName["date"]?.differs == true)
        #expect(byName["people"]?.differs == false)
        #expect(byName["archive"]?.value == "not archived" && byName["archive"]?.differs == true)
        #expect(byName["sound"]?.value == "1:16 audible")
    }
}
