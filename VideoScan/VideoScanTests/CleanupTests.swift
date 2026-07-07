import Testing
import Foundation
@testable import VideoScan

// MARK: - Clean Up Video tests (v1 — "VHS Quick Clean")
//
// Core coverage for the recipe model + ffmpeg engine's PURE surfaces, per
// the feature dispatch (2026-07-07):
//   1. CleanupRecipe Codable round-trip (future recipes ship as JSON —
//      the round-trip is load-bearing, not decorative).
//   2. Recipe → filtergraph for an interlaced source.
//   3. Deinterlace auto-skip on a progressive source.
//   4. Each step toggled off individually.
//   5. Output-name collision uniquify (`_cleaned 2` style).
//   6. Provenance fields (cleanupRecipeID/Version) round-trip through the
//      VideoRecordDTO encode → VideoRecord decode path, and legacy JSON
//      (no keys) decodes as nil.
//
// The five-dimension suite (scale / media matrix / isolation / sensor) is
// the testing agent's follow-up; these are the logic-dimension core.

struct CleanupTests {

    // MARK: Fixtures

    private var recipe: CleanupRecipe { CleanupRecipeRegistry.vhsQuickClean }

    /// Interlaced NTSC-style source (ffprobe field_order "tt").
    private var interlacedSource: CleanupSource {
        CleanupSource(path: "/tmp/tape.mov",
                      durationSeconds: 63.5,
                      fieldOrder: "tt",
                      hasAudio: true)
    }

    private var progressiveSource: CleanupSource {
        CleanupSource(path: "/tmp/clip.mp4",
                      durationSeconds: 10,
                      fieldOrder: "progressive",
                      hasAudio: true)
    }

    /// True when `a` and `b` appear adjacent, in order, in `args`.
    private func adjacent(_ args: [String], _ a: String, _ b: String) -> Bool {
        guard let i = args.firstIndex(of: a), i + 1 < args.count else { return false }
        return args[i + 1] == b
    }

    // MARK: - 1. Codable round-trip

    @Test("built-in recipe survives a JSON encode → decode round-trip intact")
    func recipeCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(CleanupRecipe.self, from: encoded)
        #expect(decoded == recipe)
        #expect(decoded.id == "vhs-quick-clean")
        #expect(decoded.version == 1)
        #expect(decoded.steps.count == 4)
        #expect(decoded.steps.map(\.kind) ==
                [.deinterlace, .cropBottomNoise, .denoise, .colorTouchUp])
    }

    @Test("a recipe authored as a raw JSON file decodes (the future ship-as-JSON path)")
    func recipeDecodesFromHandAuthoredJSON() throws {
        let json = """
        {
          "id": "test-recipe",
          "version": 3,
          "displayName": "Test Recipe",
          "familyDescription": "Just for tests.",
          "steps": [
            { "kind": "denoise",
              "parameters": { "hqdn3d": "1:1:2:2" },
              "enabled": true,
              "familyLabel": "Reduce speckle and grain" },
            { "kind": "deinterlace",
              "parameters": {},
              "enabled": false,
              "familyLabel": "Fix comb lines from old tapes" }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(CleanupRecipe.self,
                                               from: Data(json.utf8))
        #expect(decoded.id == "test-recipe")
        #expect(decoded.version == 3)
        #expect(decoded.steps.count == 2)
        #expect(decoded.steps[0].kind == .denoise)
        #expect(decoded.steps[0].parameters["hqdn3d"] == "1:1:2:2")
        #expect(decoded.steps[1].enabled == false)
    }

    // MARK: - 2. Filtergraph — interlaced source

    @Test("interlaced NTSC source compiles to the full four-step graph in recipe order")
    func filterGraphInterlaced() {
        let graph = CleanupFFmpegEngine.filterGraph(recipe: recipe, source: interlacedSource)
        #expect(graph ==
            "bwdif=mode=send_field:parity=auto," +
            "crop=iw:ih-8:0:0,pad=iw:ih+8:0:0:black," +
            "hqdn3d=2:1.5:3:2.25," +
            "eq=contrast=1.02:saturation=1.05")
    }

    @Test("every interlaced/unknown field_order gets the deinterlace chain; only progressive skips",
          arguments: [
            ("tt", true), ("bb", true), ("tb", true), ("bt", true),
            ("unknown", true), ("", true),
            ("progressive", false), ("Progressive", false), (" progressive ", false)
          ])
    func deinterlaceGating(fieldOrder: String, expectBwdif: Bool) {
        let source = CleanupSource(path: "/tmp/x.mov", durationSeconds: 1,
                                   fieldOrder: fieldOrder, hasAudio: false)
        let graph = CleanupFFmpegEngine.filterGraph(recipe: recipe, source: source) ?? ""
        #expect(graph.contains("bwdif") == expectBwdif,
                "field_order=\(fieldOrder) → bwdif expected=\(expectBwdif); got: \(graph)")
    }

    // MARK: - 3. Progressive auto-skip (recipe still runs)

    @Test("progressive source skips deinterlace but keeps the other three steps")
    func filterGraphProgressiveSkipsDeinterlace() {
        let graph = CleanupFFmpegEngine.filterGraph(recipe: recipe, source: progressiveSource)
        #expect(graph ==
            "crop=iw:ih-8:0:0,pad=iw:ih+8:0:0:black," +
            "hqdn3d=2:1.5:3:2.25," +
            "eq=contrast=1.02:saturation=1.05")
    }

    // MARK: - 4. Each step toggled off

    @Test("disabling one step removes exactly its chain segment",
          arguments: [CleanupStepKind.deinterlace, .cropBottomNoise, .denoise, .colorTouchUp])
    func stepToggledOff(kind: CleanupStepKind) {
        var toggled = recipe
        toggled.steps = toggled.steps.map { step in
            var s = step
            if s.kind == kind { s.enabled = false }
            return s
        }
        let graph = CleanupFFmpegEngine.filterGraph(recipe: toggled,
                                                    source: interlacedSource) ?? ""
        let markers: [CleanupStepKind: String] = [
            .deinterlace: "bwdif",
            .cropBottomNoise: "crop=",
            .denoise: "hqdn3d",
            .colorTouchUp: "eq="
        ]
        for (stepKind, marker) in markers {
            #expect(graph.contains(marker) == (stepKind != kind),
                    "with \(kind.rawValue) off, marker \(marker) presence wrong; got: \(graph)")
        }
    }

    @Test("all steps disabled → no filtergraph, and args carry no -vf")
    func allStepsOffMeansNoVF() {
        var off = recipe
        off.steps = off.steps.map { var s = $0; s.enabled = false; return s }
        #expect(CleanupFFmpegEngine.filterGraph(recipe: off, source: interlacedSource) == nil)
        let args = CleanupFFmpegEngine.ffmpegArgs(recipe: off,
                                                  source: interlacedSource,
                                                  input: "/tmp/in.mov",
                                                  output: "/tmp/out.mov")
        #expect(!args.contains("-vf"))
    }

    // MARK: - ffmpeg args (ProRes LT + verbatim audio copy)

    @Test("args pin ProRes 422 LT hardware encode, verbatim audio copy, progress pipe")
    func ffmpegArgsShape() {
        let args = CleanupFFmpegEngine.ffmpegArgs(recipe: recipe,
                                                  source: interlacedSource,
                                                  input: "/tmp/in.mov",
                                                  output: "/tmp/out_cleaned.mov")
        #expect(adjacent(args, "-c:v", "prores_videotoolbox"))
        #expect(adjacent(args, "-profile:v", "1"), "profile 1 = ProRes 422 LT")
        #expect(adjacent(args, "-pix_fmt", "yuv422p10le"))
        #expect(adjacent(args, "-hwaccel", "videotoolbox"))
        // Audio: stream-copied untouched (feature spec) — the sanctioned
        // exception to the transcode presets' no-copy rule.
        #expect(adjacent(args, "-c:a", "copy"))
        #expect(adjacent(args, "-map", "0:v:0"))
        #expect(args.contains("0:a:0"))
        #expect(adjacent(args, "-progress", "pipe:2"))
        #expect(args.last == "/tmp/out_cleaned.mov")
        // Never re-encodes audio.
        #expect(!args.contains("pcm_s24le"))
        #expect(!args.contains("aac_at"))
    }

    @Test("video-only source maps no audio stream and passes no audio codec")
    func ffmpegArgsVideoOnly() {
        let source = CleanupSource(path: "/tmp/v.mxf", durationSeconds: 5,
                                   fieldOrder: "bb", hasAudio: false)
        let args = CleanupFFmpegEngine.ffmpegArgs(recipe: recipe,
                                                  source: source,
                                                  input: "/tmp/v.mxf",
                                                  output: "/tmp/v_cleaned.mov")
        #expect(!args.contains("0:a:0"))
        #expect(!args.contains("-c:a"))
    }

    @Test("the v1 engine can execute the built-in recipe")
    func engineCanExecuteBuiltIn() {
        #expect(CleanupFFmpegEngine().canExecute(recipe))
    }

    // MARK: - 5. Output-name collision uniquify

    @Test("no collision → <stem>_cleaned.mov beside the original")
    func outputNameNoCollision() {
        let url = CleanupJob.cleanedOutputURL(
            forSourcePath: "/Volumes/Tapes/1998/thanksgiving.mxf",
            fileExists: { _ in false })
        #expect(url.path == "/Volumes/Tapes/1998/thanksgiving_cleaned.mov")
    }

    @Test("collisions uniquify Finder-style: _cleaned 2, _cleaned 3, …")
    func outputNameCollisions() {
        let taken: Set<String> = [
            "/Volumes/Tapes/1998/thanksgiving_cleaned.mov",
            "/Volumes/Tapes/1998/thanksgiving_cleaned 2.mov"
        ]
        let url = CleanupJob.cleanedOutputURL(
            forSourcePath: "/Volumes/Tapes/1998/thanksgiving.mxf",
            fileExists: { taken.contains($0) })
        #expect(url.path == "/Volumes/Tapes/1998/thanksgiving_cleaned 3.mov")
    }

    // MARK: - 6. Provenance round-trip

    @Test("cleanupRecipeID/Version survive the DTO encode → record decode round-trip")
    func provenanceRoundTrip() throws {
        let sourceID = UUID()
        let rec = VideoRecord()
        rec.filename = "tape_cleaned.mov"
        rec.fullPath = "/tmp/tape_cleaned.mov"
        rec.derivedFrom = sourceID
        rec.cleanupRecipeID = "vhs-quick-clean"
        rec.cleanupRecipeVersion = 1

        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)

        #expect(decoded.derivedFrom == sourceID)
        #expect(decoded.cleanupRecipeID == "vhs-quick-clean")
        #expect(decoded.cleanupRecipeVersion == 1)
    }

    @Test("legacy record JSON (no cleanup keys) decodes with nil provenance")
    func provenanceLegacyDecode() throws {
        let legacy = """
        { "filename": "old.mov", "fullPath": "/tmp/old.mov" }
        """
        let decoded = try JSONDecoder().decode(VideoRecord.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.cleanupRecipeID == nil)
        #expect(decoded.cleanupRecipeVersion == nil)
    }

    @Test("records without cleanup provenance encode without the keys (byte-delta zero)")
    func provenanceAbsentKeysNotEncoded() throws {
        let rec = VideoRecord()
        rec.filename = "plain.mov"
        let data = try JSONEncoder().encode(VideoRecordDTO(rec))
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("cleanupRecipeID"))
        #expect(!text.contains("cleanupRecipeVersion"))
    }

    // MARK: - Clone parity for the new fields

    @Test("snapshotClone carries the cleanup provenance fields")
    func cloneCarriesProvenance() {
        let rec = VideoRecord()
        rec.cleanupRecipeID = "vhs-quick-clean"
        rec.cleanupRecipeVersion = 1
        let clone = rec.snapshotClone()
        #expect(clone.cleanupRecipeID == "vhs-quick-clean")
        #expect(clone.cleanupRecipeVersion == 1)
    }

    // MARK: - Scratch estimate sanity

    @Test("output-size estimate scales with duration and never under-floors")
    func scratchEstimateSanity() {
        let sdHour = CleanupJob.estimatedOutputBytes(durationSeconds: 3600,
                                                     resolution: "720x480")
        // SD ProRes LT hour ≈ 15-25 GB — sanity band, not an exact pin.
        #expect(sdHour > 10_000_000_000 && sdHour < 30_000_000_000)
        let tiny = CleanupJob.estimatedOutputBytes(durationSeconds: 10,
                                                   resolution: "160x120")
        #expect(tiny >= 40_000_000, "4 MB/s floor must apply")
        let junkResolution = CleanupJob.estimatedOutputBytes(durationSeconds: 60,
                                                             resolution: "n/a")
        #expect(junkResolution > 0, "unparseable resolution falls back to SD")
    }
}
