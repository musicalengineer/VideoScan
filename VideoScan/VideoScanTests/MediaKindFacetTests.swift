import Foundation
import Testing
@testable import VideoScan

// MARK: - Media-kind search grammar and the Codec column (GH #124 layers 1 + 4)
//
// The Show menu's media-kind section (Videos / Audio Only / All Kinds) these
// tests once covered was removed on 2026-11-17 — no filter ticked lists
// everything, and Audio Only is a Show filter (CatalogRowsTests,
// CatalogShowFilterStoreTests hold its membership, migration and persistence).
// What stays here:
//   Logic  — the type:/kind:/codec: search grammar and displayCodec.
//   Sensor — legacy `stream:video` still means strictly videoOnly while
//            `type:video` means video-bearing.
// Scale / isolation / media: N/A — pure functions over one record's fields.

private func kindRec(
    _ filename: String,
    stream: StreamType,
    videoCodec: String = "",
    audioCodec: String = ""
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.fullPath = "/Volumes/T/media/" + filename
    r.directory = "/Volumes/T/media"
    r.videoCodec = videoCodec
    r.audioCodec = audioCodec
    return r
}

// MARK: Search grammar — type: / kind: / codec:

@Suite("Search grammar — type:/kind:/codec: (GH #124)")
struct KindFacetSearchGrammarTests {

    @Test func typeTokenizes() {
        #expect(pfTokenizeSearchQuery("type:video")
                == [.field(name: .mediaKind, value: "video")])
        #expect(pfTokenizeSearchQuery("kind:audio")
                == [.field(name: .mediaKind, value: "audio")])
        #expect(pfTokenizeSearchQuery("codec:mp3")
                == [.field(name: .codec, value: "mp3")])
        // Quoted phrase bypasses field recognition — literal substring.
        #expect(pfTokenizeSearchQuery("\"type:video\"")
                == [.substring("type:video")])
    }

    @Test func mediaKindAliasTable() {
        // type:video = video-BEARING: V+A or video-only.
        #expect(pfMediaKindAliasMatches(value: "video", recordType: .videoAndAudio))
        #expect(pfMediaKindAliasMatches(value: "video", recordType: .videoOnly))
        #expect(!pfMediaKindAliasMatches(value: "video", recordType: .audioOnly))
        // A search is an assertion of confirmed streams — failed/none
        // do NOT match type:video.
        #expect(!pfMediaKindAliasMatches(value: "video", recordType: .ffprobeFailed))
        #expect(!pfMediaKindAliasMatches(value: "video", recordType: .noStreams))
        // Strict spellings.
        #expect(pfMediaKindAliasMatches(value: "video-only", recordType: .videoOnly))
        #expect(!pfMediaKindAliasMatches(value: "video-only", recordType: .videoAndAudio))
        #expect(pfMediaKindAliasMatches(value: "audio", recordType: .audioOnly))
        #expect(pfMediaKindAliasMatches(value: "audio-only", recordType: .audioOnly))
        #expect(pfMediaKindAliasMatches(value: "both", recordType: .videoAndAudio))
        #expect(pfMediaKindAliasMatches(value: "av", recordType: .videoAndAudio))
        #expect(pfMediaKindAliasMatches(value: "failed", recordType: .ffprobeFailed))
        #expect(pfMediaKindAliasMatches(value: "none", recordType: .noStreams))
        // Typo → empty results, not everything (same contract as stream:).
        for st in [StreamType.videoAndAudio, .videoOnly, .audioOnly,
                   .noStreams, .ffprobeFailed] {
            #expect(!pfMediaKindAliasMatches(value: "vidoe", recordType: st))
        }
    }

    // BACK-COMPAT SENSOR: the legacy stream: grammar is untouched —
    // stream:video is still strictly videoOnly. If this fails, saved
    // habits/queries silently changed meaning.
    @Test func legacyStreamGrammarUnchanged() {
        #expect(pfStreamTypeAliasMatches(value: "video", recordType: .videoOnly))
        #expect(!pfStreamTypeAliasMatches(value: "video", recordType: .videoAndAudio))
    }

    @Test func typeTokenMatchesThroughCatalogMatcher() {
        let video = kindRec("v.mov", stream: .videoAndAudio)
        let audio = kindRec("a.mp3", stream: .audioOnly)
        #expect(pfRecordFilenameOrPersonMatch(video, query: "type:video"))
        #expect(!pfRecordFilenameOrPersonMatch(audio, query: "type:video"))
        #expect(pfRecordFilenameOrPersonMatch(audio, query: "type:audio"))
        // Composes with plain tokens (AND).
        #expect(pfRecordFilenameOrPersonMatch(audio, query: "type:audio a.mp3"))
        #expect(!pfRecordFilenameOrPersonMatch(audio, query: "type:audio zzz"))
    }

    @Test func codecFieldMatchesBothCodecFields() {
        // Filename carries NO codec hint, so plain-substring search can't
        // accidentally satisfy these — isolates the codec: field.
        let music = kindRec("track01.m4a", stream: .audioOnly, audioCodec: "mp3")
        let master = kindRec("master.mov", stream: .videoAndAudio,
                             videoCodec: "prores", audioCodec: "pcm_s16le")
        #expect(pfRecordFilenameOrPersonMatch(music, query: "codec:mp3"))
        #expect(pfRecordFilenameOrPersonMatch(master, query: "codec:prores"))
        #expect(pfRecordFilenameOrPersonMatch(master, query: "codec:pcm"))
        #expect(!pfRecordFilenameOrPersonMatch(music, query: "codec:prores"))
        // Case-insensitive.
        #expect(pfRecordFilenameOrPersonMatch(master, query: "codec:PRORES"))
        // SENSOR: plain substring on the catalog bar still deliberately
        // does NOT search codec fields (the 2026-06-08 narrow-matcher
        // decision) — the field prefix is the opt-in.
        #expect(!pfRecordFilenameOrPersonMatch(music, query: "mp3"))
        // Universal search DID always match codecs; unchanged.
        #expect(pfRecordMatchesQuery(music, query: "mp3"))
    }
}

// MARK: displayCodec (layer 4)

@Suite("displayCodec — codec column fallback")
struct DisplayCodecTests {

    @Test func videoCodecWinsWhenPresent() {
        let r = kindRec("m.mov", stream: .videoAndAudio,
                        videoCodec: "h264", audioCodec: "aac")
        #expect(r.displayCodec == "h264")
    }

    @Test func audioCodecFillsInForAudioOnly() {
        let r = kindRec("t.mp3", stream: .audioOnly, audioCodec: "mp3")
        #expect(r.displayCodec == "mp3")
        // MXF header-fallback shape ("PCM 16-bit") surfaces too.
        let mxf = kindRec("half.mxf", stream: .audioOnly, audioCodec: "PCM 16-bit")
        #expect(mxf.displayCodec == "PCM 16-bit")
    }

    @Test func bothEmptyStaysEmpty() {
        let r = kindRec("broken.avi", stream: .ffprobeFailed)
        #expect(r.displayCodec == "")
    }
}
