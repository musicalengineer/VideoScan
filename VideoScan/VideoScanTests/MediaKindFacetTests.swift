import Foundation
import Testing
@testable import VideoScan

// MARK: - Media-kind facet tests (GH #124 layer 1 + 4)
//
// Five-dimension coverage:
//   Logic     — facet truth table (all five StreamTypes × three facets),
//               pfApplyKindFacet composition, type:/kind:/codec: search
//               grammar, displayCodec derivation.
//   Scale     — 100k synthetic records through the facet filter with an
//               explicit time budget (the facet IS the search-working-set
//               shrink, so it must stay cheap).
//   Isolation — persistence tests run against a throwaway
//               UserDefaults(suiteName:), never the real plist; the
//               poisoned-state test feeds a corrupted stored token.
//   Sensor    — default-view sensor pins `.videoBearing` as the shipped
//               default (the whole point of #124); a back-compat sensor
//               pins that legacy `stream:video` still means strictly
//               videoOnly while the new `type:video` means video-bearing.
// Media matrix: N/A — pure catalog metadata, no file I/O.

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

// MARK: Truth table

@Suite("Media-kind facet — truth table")
struct KindFacetTruthTableTests {

    // The full 5×3 truth table in one place. videoBearing keeps
    // ffprobeFailed / noStreams VISIBLE by design — damaged Avid MXFs
    // are the recovery mission; only audioOnly is hidden by default.
    @Test func fullTruthTable() {
        let expectations: [(StreamType, Bool, Bool, Bool)] = [
            // streamType        videoBearing audioOnly everything
            (.videoAndAudio,     true,        false,    true),
            (.videoOnly,         true,        false,    true),
            (.audioOnly,         false,       true,     true),
            (.noStreams,         true,        false,    true),
            (.ffprobeFailed,     true,        false,    true),
        ]
        for (st, vb, ao, ev) in expectations {
            #expect(CatalogKindFacet.videoBearing.matches(st) == vb,
                    "videoBearing(\(st))")
            #expect(CatalogKindFacet.audioOnly.matches(st) == ao,
                    "audioOnly(\(st))")
            #expect(CatalogKindFacet.everything.matches(st) == ev,
                    "everything(\(st))")
        }
    }

    @Test func applyFacetFiltersRecords() {
        let recs = [
            kindRec("a.mov", stream: .videoAndAudio),
            kindRec("b.mxf", stream: .videoOnly),
            kindRec("c.mp3", stream: .audioOnly),
            kindRec("d.bin", stream: .noStreams),
            kindRec("e.mxf", stream: .ffprobeFailed),
        ]
        #expect(pfApplyKindFacet(recs, facet: .videoBearing).map(\.filename)
                == ["a.mov", "b.mxf", "d.bin", "e.mxf"])
        #expect(pfApplyKindFacet(recs, facet: .audioOnly).map(\.filename)
                == ["c.mp3"])
        // .everything is the identity — same instances, same order.
        #expect(pfApplyKindFacet(recs, facet: .everything).map(\.id)
                == recs.map(\.id))
    }

    // SENSOR (default view): the shipped default is videoBearing. If this
    // flips, the catalog opens on 80k music rows again — the exact
    // regression #124 exists to prevent.
    @Test func defaultFacetIsVideoBearing() {
        #expect(CatalogKindFacetSetting().facet == .videoBearing)
        #expect(CatalogKindFacet.allCases.contains(.videoBearing))
    }

    // The badge base honors the facet leg (purge/set-aside legs pinned in
    // CatalogSetAsideMigrationTests) — with the default facet an
    // audio-only record never enters the search-hit count base.
    @Test func badgeBaseHonorsFacet() {
        let video = kindRec("v.mov", stream: .videoAndAudio)
        let audio = kindRec("a.mp3", stream: .audioOnly)
        let base = pfSearchBadgeBase([video, audio],
                                     showRemoved: false, showSetAside: false,
                                     showSuperseded: false, kindFacet: .videoBearing)
        #expect(base.map(\.id) == [video.id])
        let all = pfSearchBadgeBase([video, audio],
                                    showRemoved: false, showSetAside: false,
                                    showSuperseded: false, kindFacet: .everything)
        #expect(all.count == 2)
    }
}

// MARK: Persistence (explicit-save pattern, injected defaults)

@Suite("Media-kind facet — persistence", .serialized)
struct KindFacetPersistenceTests {

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "vs-test-kindfacet-\(name)-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func roundTripEachCase() {
        let d = scratchDefaults("roundtrip")
        for facet in CatalogKindFacet.allCases {
            var s = CatalogKindFacetSetting()
            s.facet = facet
            s.save(to: d)
            #expect(CatalogKindFacetSetting.restored(from: d).facet == facet)
        }
    }

    // Never-set key keeps the videoBearing default (fresh install /
    // upgrade-in-place both open on videos).
    @Test func absentKeyRestoresDefault() {
        let d = scratchDefaults("absent")
        #expect(CatalogKindFacetSetting.restored(from: d).facet == .videoBearing)
    }

    // POISONED STATE: a corrupted / future-version token must fall back
    // to the default, not crash and not clear other prefs.
    @Test func poisonedValueFallsBackToDefault() {
        let d = scratchDefaults("poisoned")
        d.set("definitely-not-a-facet", forKey: CatalogKindFacetSetting.facetKey)
        #expect(CatalogKindFacetSetting.restored(from: d).facet == .videoBearing)
        // Non-string garbage too (a number where a string belongs).
        d.set(42, forKey: CatalogKindFacetSetting.facetKey)
        #expect(CatalogKindFacetSetting.restored(from: d).facet == .videoBearing)
    }

    // The raw tokens are a persistence contract — renaming a case breaks
    // every existing plist. Pin the spellings.
    @Test func persistedTokensAreStable() {
        #expect(CatalogKindFacet.videoBearing.rawValue == "videoBearing")
        #expect(CatalogKindFacet.audioOnly.rawValue == "audioOnly")
        #expect(CatalogKindFacet.everything.rawValue == "everything")
    }
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
        // type:video = video-BEARING (facet spelling): V+A or video-only.
        #expect(pfMediaKindAliasMatches(value: "video", recordType: .videoAndAudio))
        #expect(pfMediaKindAliasMatches(value: "video", recordType: .videoOnly))
        #expect(!pfMediaKindAliasMatches(value: "video", recordType: .audioOnly))
        // A search is an assertion of confirmed streams — failed/none
        // do NOT match type:video even though the view facet shows them.
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

// MARK: Scale — 100k facet filter budget

@Suite("Media-kind facet — scale")
struct KindFacetScaleTests {

    // 100k synthetic records, ~78% audio-only (Rick's real ratio).
    // Budget: the facet filter is ONE pass with an enum compare — it must
    // stay far under a keystroke's perceptual budget even in Debug.
    @Test func facetFilter100kWithinBudget() {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let stream: StreamType = i % 4 == 0 ? .videoAndAudio : .audioOnly
            recs.append(kindRec("f\(i).\(stream == .audioOnly ? "mp3" : "mov")",
                                stream: stream))
        }
        let start = Date()
        let filtered = pfApplyKindFacet(recs, facet: .videoBearing)
        let elapsed = Date().timeIntervalSince(start)
        #expect(filtered.count == 25_000)
        #expect(elapsed < 0.5,
                "facet over 100k records took \(elapsed)s — budget 0.5s (Debug)")
        // SENSOR at production scale: the default view drops every
        // audio-only row and keeps everything else.
        #expect(filtered.allSatisfy { $0.streamType != .audioOnly })
    }
}
