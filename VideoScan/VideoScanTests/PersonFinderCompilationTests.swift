import Testing
import Foundation
@testable import VideoScan

// MARK: - PersonFinderCompilation characterization tests
//
// Fills the coverage gap on PersonFinderCompilation.swift (baseline 1.55%)
// left by the overnight refactor verification. Targets the three symbols
// that step 5 of the refactor narrowly widened from private → internal:
//   - pfExtractYear(from:)        — pure regex/filesystem helper
//   - pfClipEntry                 — value type
//   - pfBuildSortedClipEntries    — pure sort, used by pfCompileBuckets
// Plus CompatKey, which is internal by default and has two non-trivial
// pure-function members (shortLabel, preferredExtension).
//
// Style mirrors PersonFinderBoundaryTests.swift: Swift Testing (@Test,
// #expect). C++ analogy: @Test ≈ TEST_F, #expect ≈ EXPECT_TRUE/EXPECT_EQ,
// #expect with throws ≈ EXPECT_THROW.
//
// IMPORTANT: these are CHARACTERIZATION tests — they pin current observable
// behavior. Where the current behavior is surprising (e.g. pfExtractYear's
// first-match-wins on a multi-year path, or its 1950..2039 regex window),
// the test encodes the surprise AND a comment explains why. Do NOT "fix"
// the production code in response to a failing test here without first
// updating the test and getting Rick's sign-off.

struct PersonFinderCompilationTests {

    // MARK: - 1. pfExtractYear

    @Test func pfExtractYearFindsFourDigitYearInPathSegment() {
        // Canonical happy path: a year directory in the middle of the path.
        let path = "/Volumes/Archive/Family/2018/birthday.mov"
        #expect(pfExtractYear(from: path) == 2018)
    }

    @Test func pfExtractYearUnderscoreBoundedYearDoesNotMatch() {
        // Characterization SURPRISE: the regex uses \b (word boundary), and
        // NSRegularExpression treats '_' as a WORD character (POSIX default).
        // So "vacation_1999_clip.mov" has the digits surrounded by word
        // characters on BOTH sides → no word boundary → no match. The file
        // doesn't exist on disk either, so the creation-date fallback also
        // returns 0. This is a real gotcha for Rick's archive: filenames like
        // "birthday_1995_take2.mov" will get year=0 ("Unknown" decade).
        // Pin it as-is — fixing it requires a regex change that affects
        // production bucketing. Do NOT "fix" the production code in
        // response to this test failing.
        let path = "/tmp/vacation_1999_clip.mov"
        #expect(pfExtractYear(from: path) == 0,
                "Underscore-bounded year does not satisfy \\b; got \(pfExtractYear(from: path))")
    }

    @Test func pfExtractYearHyphenBoundedYearMatches() {
        // Companion to the underscore case above: '-' is NOT a word
        // character, so "/clips/1995-summer-trip.mov" DOES match. Pin both
        // sides so the asymmetric \b behavior is visible side-by-side.
        let path = "/clips/1995-summer-trip.mov"
        #expect(pfExtractYear(from: path) == 1995)
    }

    @Test func pfExtractYearMultiYearPathReturnsFirstMatch() {
        // Characterization: the regex uses firstMatch in a left-to-right
        // scan of the path string. If a path has multiple year-like
        // substrings, the LEFTMOST one wins, regardless of whether it's
        // the more semantically meaningful year. Pin this — Rick's archive
        // includes paths like "/2020-imported/2018-summer/..." where the
        // import-year wins over the content-year. Caller must dedupe
        // upstream if that's not desired.
        let path = "/Volumes/Disk/2020-archive/2018-summer/clip.mov"
        #expect(pfExtractYear(from: path) == 2020,
                "Leftmost matching year wins; got \(pfExtractYear(from: path))")
    }

    @Test func pfExtractYearReturnsZeroWhenNoYearAndNoFile() {
        // No year-like substring AND the path doesn't exist on disk, so
        // the creation-date fallback returns 0 too. Pin the sentinel —
        // pfDecadeLabel branches on `year > 0` to return "Unknown".
        let path = "/no/year/anywhere/in/this/clip.mov"
        #expect(pfExtractYear(from: path) == 0)
    }

    @Test func pfExtractYearRegexLowerBoundIs1950() {
        // Regex is \b(19[5-9]\d|20[0-3]\d)\b — so 1949 is OUT, 1950 is IN.
        // Pin both sides of the boundary so a future regex widening is
        // visible.
        let pathOut = "/Volumes/Disk/1949/clip.mov"
        let pathIn  = "/Volumes/Disk/1950/clip.mov"
        #expect(pfExtractYear(from: pathOut) == 0,
                "1949 is outside the regex window; expected 0 fallback")
        #expect(pfExtractYear(from: pathIn) == 1950)
    }

    @Test func pfExtractYearRegexUpperBoundIs2039() {
        // 2039 is IN; 2040 is OUT. The 20[0-3]\d window deliberately stops
        // at 2039 to avoid the regex matching arbitrary 4-digit numbers
        // that happen to fall in the 2040+ range. When Rick lives long
        // enough to scan footage shot in 2040, this needs widening — leave
        // a breadcrumb.
        let pathIn  = "/Volumes/Disk/2039/clip.mov"
        let pathOut = "/Volumes/Disk/2040/clip.mov"
        #expect(pfExtractYear(from: pathIn) == 2039)
        #expect(pfExtractYear(from: pathOut) == 0,
                "2040 is outside the current regex window")
    }

    @Test func pfExtractYearRequiresWordBoundary() {
        // \b prevents 5-or-more-digit runs from matching. "20181225" looks
        // like a YYYYMMDD timestamp; the regex must NOT pull "2018" out of
        // it. Characterization: pin the \b behavior.
        let path = "/Volumes/Disk/20181225_clip.mov"
        // 20181225 has no \b around the first 4 digits — the run is
        // a single digit sequence. But the trailing "1225" doesn't match
        // either pattern, so the regex tries the leading "2018" with
        // a word boundary check. The "2" sits at a non-word→word edge
        // (after "/"), satisfying the left \b; the right \b after "2018"
        // needs a non-word char, but "1" is a word char, so no match.
        // Net: no year match. Pin this — it's the safe behavior.
        #expect(pfExtractYear(from: path) == 0,
                "Embedded year in a longer digit run must not match; got \(pfExtractYear(from: path))")
    }

    // MARK: - 2. pfClipEntry construction

    @Test func pfClipEntryStoresAllThreeFields() {
        // Plain value-type round-trip; pin the field names and types so
        // a future tuple-conversion or rename is caught.
        let e = pfClipEntry(clipPath: "/tmp/clip.mov", year: 2010, decade: "2010s")
        #expect(e.clipPath == "/tmp/clip.mov")
        #expect(e.year == 2010)
        #expect(e.decade == "2010s")
    }

    // MARK: - 3. pfBuildSortedClipEntries

    @Test func pfBuildSortedClipEntriesReturnsEmptyForEmptyInput() {
        let entries = pfBuildSortedClipEntries(results: [], outputDir: "/tmp/out")
        #expect(entries.isEmpty)
    }

    @Test func pfBuildSortedClipEntriesSkipsResultsWithNoClipFiles() {
        // A pfVideoResult with empty `clipFiles` (or all-empty strings)
        // must contribute zero entries. This is the common case before
        // extraction has run — pin it so the sort doesn't crash on a
        // mid-pipeline call.
        let r = pfVideoResult(filename: "a.mov", filePath: "/tmp/2018/a.mov",
                              durationSeconds: 10, fps: 30,
                              totalHits: 0, segments: [])
        let entries = pfBuildSortedClipEntries(results: [r], outputDir: "/tmp/out")
        #expect(entries.isEmpty)
    }

    @Test func pfBuildSortedClipEntriesSkipsEmptyClipFileNames() {
        // pfExtractAllClips pre-allocates `clipFiles = Array(repeating: "", count: N)`
        // and only fills in successful extractions. Empty-string slots are
        // failed extractions and must be filtered out of the compilation list.
        var r = pfVideoResult(filename: "a.mov", filePath: "/tmp/2018/a.mov",
                              durationSeconds: 10, fps: 30, totalHits: 0,
                              segments: [])
        r.clipFiles = ["", "ok.mov", ""]
        let entries = pfBuildSortedClipEntries(results: [r], outputDir: "/out")
        #expect(entries.count == 1, "Only non-empty names should produce entries")
        #expect(entries.first?.clipPath == "/out/ok.mov")
        #expect(entries.first?.year == 2018)
    }

    @Test func pfBuildSortedClipEntriesSortsByYearAscending() {
        // Two results from different years, each contributing one clip.
        // Expected ordering: 1999 before 2010 before 2025 (sorted ascending).
        var r1 = pfVideoResult(filename: "old.mov", filePath: "/v/2025/x.mov",
                               durationSeconds: 1, fps: 30, totalHits: 0,
                               segments: [])
        r1.clipFiles = ["c1.mov"]
        var r2 = pfVideoResult(filename: "older.mov", filePath: "/v/1999/y.mov",
                               durationSeconds: 1, fps: 30, totalHits: 0,
                               segments: [])
        r2.clipFiles = ["c2.mov"]
        var r3 = pfVideoResult(filename: "mid.mov", filePath: "/v/2010/z.mov",
                               durationSeconds: 1, fps: 30, totalHits: 0,
                               segments: [])
        r3.clipFiles = ["c3.mov"]

        let entries = pfBuildSortedClipEntries(results: [r1, r2, r3],
                                               outputDir: "/out")
        #expect(entries.count == 3)
        #expect(entries.map(\.year) == [1999, 2010, 2025],
                "Years must be ascending; got \(entries.map(\.year))")
    }

    @Test func pfBuildSortedClipEntriesTieBreaksByClipPathAscending() {
        // Two clips sharing the same year (because both paths contain
        // /2018/, AND both belong to the same pfVideoResult) — tie broken
        // lexicographically by clipPath. Important: the comparator uses
        // FULL clipPath (outputDir + name), so the outputDir prefix is
        // shared and only the name segment varies.
        var r = pfVideoResult(filename: "a.mov", filePath: "/v/2018/a.mov",
                              durationSeconds: 1, fps: 30, totalHits: 0,
                              segments: [])
        r.clipFiles = ["zzz.mov", "aaa.mov", "mmm.mov"]
        let entries = pfBuildSortedClipEntries(results: [r], outputDir: "/out")
        #expect(entries.count == 3)
        #expect(entries.map(\.clipPath) == ["/out/aaa.mov", "/out/mmm.mov", "/out/zzz.mov"],
                "Same-year entries sort ascending by clipPath; got \(entries.map(\.clipPath))")
    }

    @Test func pfBuildSortedClipEntriesYearZeroSortsFirst() {
        // A result whose path doesn't contain a year-like substring and
        // whose file doesn't exist on disk gets year=0 (see
        // pfExtractYearReturnsZeroWhenNoYearAndNoFile). Year=0 sorts
        // BEFORE any positive year. Pin this — it puts "unknown date"
        // clips at the start of the compilation, which is the current
        // (debatable) UX choice. If we ever want them at the END,
        // change here AND update the comparator.
        var rUnknown = pfVideoResult(filename: "u.mov",
                                     filePath: "/no/year/u.mov",
                                     durationSeconds: 1, fps: 30,
                                     totalHits: 0, segments: [])
        rUnknown.clipFiles = ["unk.mov"]
        var rKnown = pfVideoResult(filename: "k.mov",
                                   filePath: "/v/2010/k.mov",
                                   durationSeconds: 1, fps: 30,
                                   totalHits: 0, segments: [])
        rKnown.clipFiles = ["kno.mov"]

        let entries = pfBuildSortedClipEntries(results: [rUnknown, rKnown],
                                               outputDir: "/out")
        #expect(entries.count == 2)
        #expect(entries[0].year == 0)
        #expect(entries[1].year == 2010)
    }

    // MARK: - 4. CompatKey value semantics
    //
    // CompatKey is the bucket-grouping key for stream-copy concat. Two
    // clips can be concat-copied iff their CompatKey values are equal.
    // The struct is Hashable (auto-synthesized), so equality and hashing
    // must agree on every field. Pin both.

    @Test func compatKeyEqualityIsFieldwise() {
        let a = Self.makeCompatKey()
        let b = Self.makeCompatKey()
        #expect(a == b, "Identical field values must compare equal")
    }

    @Test func compatKeyDifferingOnVCodecIsNotEqual() {
        let a = Self.makeCompatKey()
        let b = Self.makeCompatKey(vCodec: "hevc")
        #expect(a != b, "Different vCodec must produce inequality")
    }

    @Test func compatKeyDifferingOnHasAudioIsNotEqual() {
        // hasAudio flip is the most common cross-archive mismatch in
        // Rick's collection (audio-only DV-tapes vs camera footage).
        // If the synthesized equality ever omits hasAudio, audio-bearing
        // and audio-less clips would silently bucket together — a hard
        // ffmpeg failure later. Pin it explicitly.
        let a = Self.makeCompatKey(hasAudio: true)
        let b = Self.makeCompatKey(hasAudio: false)
        #expect(a != b)
    }

    @Test func compatKeyHashingAgreesWithEquality() {
        // Hashable contract: a == b ⇒ a.hashValue == b.hashValue. We can't
        // assert the inverse (hash collisions are legal), but we CAN
        // assert that equal values hash equal — and that two values
        // differing in one field generally hash differently (probabilistic,
        // but Swift's auto-synthesis combines all stored fields).
        let a = Self.makeCompatKey()
        let b = Self.makeCompatKey()
        var hasher1 = Hasher(); a.hash(into: &hasher1)
        var hasher2 = Hasher(); b.hash(into: &hasher2)
        #expect(hasher1.finalize() == hasher2.finalize(),
                "Equal CompatKeys must produce equal hashes")
    }

    @Test func compatKeyShortLabelForH264_1080p_2997_AAC() {
        // Most common real-world case: 1080p29.97 h264 + 48kHz stereo AAC.
        // pfSanitize strips the "/" in "30000/1001" so the rate-resolution
        // path goes through the abs-distance branches. Pin the label format
        // — filenames downstream depend on this exact string.
        let k = Self.makeCompatKey(
            vCodec: "h264", width: 1920, height: 1080,
            fpsRational: "30000/1001",
            aCodec: "aac", aSampleRate: 48000, aChannels: 2,
            hasAudio: true
        )
        #expect(k.shortLabel == "h264_1080p2997_aac48k_2ch",
                "shortLabel for canonical h264 1080p29.97 + AAC; got \(k.shortLabel)")
    }

    @Test func compatKeyShortLabelHandlesNoAudio() {
        // Video-only orphan MXFs (Rick's main recovery use-case) produce
        // hasAudio=false. The label slot becomes "noaudio".
        //
        // CHARACTERIZATION SURPRISE: 30 fps gets labeled "2997", not "30",
        // because the 29.97 check fires before the 30 check, and the
        // ±0.05 fps tolerance makes 30.0 register as 29.97. This means
        // true-30fps and 29.97-drop-frame footage WILL bucket together —
        // probably correct in practice (both label as 2997, share a bucket)
        // but worth pinning so a future re-ordering of the if-cascade
        // doesn't silently change bucket boundaries.
        let k = Self.makeCompatKey(
            vCodec: "h264", width: 1920, height: 1080,
            fpsRational: "30/1",
            hasAudio: false
        )
        #expect(k.shortLabel == "h264_1080p2997_noaudio",
                "30fps falls inside the 29.97 ±0.05 window; got \(k.shortLabel)")
    }

    @Test func compatKeyShortLabelTrue30fpsRequiresExplicit30Round() {
        // To actually get the "30" label, fpsRational must round far enough
        // from 29.97 — e.g. "60/2" = 30.0 still hits the 29.97 branch first.
        // Only ratios that produce f > 30.02 would skip the 29.97 check.
        // Pin: there is NO ratio in the standard frame-rate family that
        // yields the "30" label. The branch is effectively dead for
        // typical inputs. This is a code-smell to file as an issue
        // separately — do NOT fix here.
        let k = Self.makeCompatKey(
            vCodec: "h264", width: 1920, height: 1080,
            fpsRational: "60/2",   // = 30.0
            hasAudio: false
        )
        #expect(k.shortLabel == "h264_1080p2997_noaudio",
                "60/2 also falls in 29.97 window; got \(k.shortLabel)")
    }

    @Test func compatKeyShortLabelHandlesVFR() {
        // fpsRational "0/0" is the VFR / unknown sentinel from
        // pfProbeCompatKey. Pin that the label says "vfr" — useful for
        // diagnostics when ffmpeg later complains about timestamps.
        let k = Self.makeCompatKey(
            vCodec: "h264", width: 1280, height: 720,
            fpsRational: "0/0",
            hasAudio: false
        )
        #expect(k.shortLabel.contains("vfr"),
                "Expected 'vfr' in label for 0/0 fps; got \(k.shortLabel)")
    }

    @Test func compatKeyPreferredExtensionMp4ForH264YUV420pAAC() {
        // The mp4-eligible triple: h264 + yuv420p + aac. Pin the .mp4
        // selection so a future expansion to include hevc-in-mp4 etc.
        // doesn't silently drop this case.
        let k = Self.makeCompatKey(
            vCodec: "h264", pixFmt: "yuv420p",
            aCodec: "aac", hasAudio: true
        )
        #expect(k.preferredExtension == "mp4")
    }

    @Test func compatKeyPreferredExtensionMovForProRes() {
        // ProRes is NOT in the mp4-eligible codec set, so it must fall
        // back to .mov. ProRes is rare in Rick's archive but the .mov
        // fallback is the safety net for "anything weird" — pin it.
        let k = Self.makeCompatKey(
            vCodec: "prores", pixFmt: "yuv422p10le",
            aCodec: "pcm_s24le", hasAudio: true
        )
        #expect(k.preferredExtension == "mov")
    }

    @Test func compatKeyPreferredExtensionMovForExoticPixFmt() {
        // h264 in mp4 is fine BUT only with mp4-eligible pix_fmt. An
        // h264 stream in yuv422p (rare but legal) must fall to .mov.
        let k = Self.makeCompatKey(
            vCodec: "h264", pixFmt: "yuv422p",
            aCodec: "aac", hasAudio: true
        )
        #expect(k.preferredExtension == "mov",
                "h264 + yuv422p must fall back to .mov; got \(k.preferredExtension)")
    }

    // MARK: - Helpers

    /// Build a CompatKey with sensible defaults. Tests override only the
    /// fields they care about. Keeping this in one place lets the test
    /// suite survive a CompatKey field addition by only updating the
    /// defaults here.
    static func makeCompatKey(
        vCodec: String = "h264",
        vProfile: String = "High",
        pixFmt: String = "yuv420p",
        width: Int = 1920,
        height: Int = 1080,
        sar: String = "1:1",
        fpsRational: String = "30000/1001",
        colorSpace: String = "bt709",
        colorRange: String = "tv",
        aCodec: String = "aac",
        aSampleRate: Int = 48000,
        aChannels: Int = 2,
        aLayout: String = "stereo",
        hasAudio: Bool = true
    ) -> CompatKey {
        CompatKey(
            vCodec: vCodec, vProfile: vProfile, pixFmt: pixFmt,
            width: width, height: height, sar: sar,
            fpsRational: fpsRational,
            colorSpace: colorSpace, colorRange: colorRange,
            aCodec: aCodec, aSampleRate: aSampleRate,
            aChannels: aChannels, aLayout: aLayout,
            hasAudio: hasAudio
        )
    }

    // MARK: - Documented gaps (NOT tested here, deferred to follow-up)
    //
    //   • pfDecadeLabel(for:) — still `private` in PersonFinderCompilation.swift.
    //     Trivial pure function (year/10*10 + "s"), but widening was not
    //     pre-authorized by step 5. Skip until visibility is opened or the
    //     function is pulled into a future widening pass.
    //
    //   • pfFileSize(at:) — `private`. Filesystem helper; would need a
    //     tmpdir-based fixture. Defer.
    //
    //   • pfExtractClip / pfExtractAllClips — spawn AVAssetExportSession
    //     against AVURLAsset; require a real-ish video fixture. Out of
    //     scope for characterization; covered indirectly by
    //     PersonFinderLifecycleTests when extraction runs.
    //
    //   • pfProbeCompatKey / pfBucketByCompat / pfCompileBuckets /
    //     pfStreamCopyConcat / pfMergeBucketsToSingleFile / pfRunFFmpeg —
    //     all spawn ffmpeg or ffprobe subprocesses. Per qa plan, these
    //     need an injectable probe seam; skip until that lands.
    //
    //   • PersonFinderModel extension methods (startCompilation,
    //     cancelCompilation, runCompilation, compileAndCleanup) — drive
    //     the ffmpeg pipeline end-to-end. Same skip reason as above.
}
