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

    /// Interlaced NTSC-style source (ffprobe field_order "tt") with
    /// allowlisted (copyable) PCM audio.
    private var interlacedSource: CleanupSource {
        CleanupSource(path: "/tmp/tape.mov",
                      durationSeconds: 63.5,
                      fieldOrder: "tt",
                      hasAudio: true,
                      audioCodec: "pcm_s16le")
    }

    private var progressiveSource: CleanupSource {
        CleanupSource(path: "/tmp/clip.mp4",
                      durationSeconds: 10,
                      fieldOrder: "progressive",
                      hasAudio: true,
                      audioCodec: "aac")
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

    // MARK: - M4: audio copy allowlist (default-deny)

    @Test("audio copy allowlist: pcm_* + playback-safe codecs copy; everything else (incl. unknown) re-encodes",
          arguments: [
            ("pcm_s16le", true), ("pcm_s24be", true), ("PCM_F32LE", true),
            ("aac", true), ("alac", true), ("mp3", true), ("mp2", true),
            ("ac3", true), ("eac3", true), ("adpcm_ima_qt", true),
            ("vorbis", false), ("opus", false), ("cook", false),
            ("qdm2", false), ("qdmc", false), ("mace3", false),
            ("", false), ("unknowncodec", false)
          ])
    func audioCopyAllowlist(codec: String, expectCopy: Bool) {
        #expect(CleanupFFmpegEngine.audioCopyAllowed(codec: codec) == expectCopy,
                "audioCopyAllowed(\(codec)) should be \(expectCopy)")
    }

    @Test("non-allowlisted audio (vorbis/qdm2/unknown) builds -c:a pcm_s16le -ar 48000, never copy",
          arguments: ["vorbis", "qdm2", ""])
    func ffmpegArgsModernizeAudio(codec: String) {
        var source = interlacedSource
        source.audioCodec = codec
        let args = CleanupFFmpegEngine.ffmpegArgs(recipe: recipe,
                                                  source: source,
                                                  input: "/tmp/in.mov",
                                                  output: "/tmp/out_cleaned.mov")
        #expect(adjacent(args, "-c:a", "pcm_s16le"),
                "codec \(codec) must re-encode to pcm_s16le; got \(args)")
        #expect(adjacent(args, "-ar", "48000"))
        #expect(!adjacent(args, "-c:a", "copy"))
    }

    @Test("allowlisted audio (alac) still stream-copies")
    func ffmpegArgsCopyAllowlisted() {
        var source = interlacedSource
        source.audioCodec = "alac"
        let args = CleanupFFmpegEngine.ffmpegArgs(recipe: recipe,
                                                  source: source,
                                                  input: "/tmp/in.mov",
                                                  output: "/tmp/out_cleaned.mov")
        #expect(adjacent(args, "-c:a", "copy"))
        #expect(!args.contains("-ar"))
    }

    @Test("MANDATORY M4 integration: vorbis-audio fixture renders with pcm_s16le audio and probes clean",
          .timeLimit(.minutes(2)))
    func vorbisAudioModernizedEndToEnd() async throws {
        try #require(CleanupTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("vorbis")
        defer { try? FileManager.default.removeItem(at: dir) }

        // vorbis must live in mkv — it can't mux into .mov/.mp4, which is
        // exactly why the allowlist exists. Homebrew ffmpeg ships without
        // libvorbis, so this uses the native (experimental, stereo-only)
        // vorbis encoder via a custom invocation.
        let src = dir.appendingPathComponent("test_vorbis.mkv").path
        try CleanupTestMedia.runFFmpeg([
            "-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000",
            "-c:v", "libx264",
            "-ac", "2", "-c:a", "vorbis", "-strict", "experimental"
        ], output: src)
        let srcProbe = try CleanupTestMedia.probe(src)
        #expect(srcProbe.audio?.codec_name == "vorbis",
                "fixture precondition: expected vorbis audio")

        let source = CleanupSource(path: src,
                                   durationSeconds: srcProbe.durationSeconds,
                                   fieldOrder: srcProbe.video?.field_order ?? "unknown",
                                   hasAudio: true,
                                   audioCodec: srcProbe.audio?.codec_name ?? "")
        let scratch = dir.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch,
                                                withIntermediateDirectories: true)
        let rendered = try await CleanupFFmpegEngine().render(
            recipe: recipe,
            source: source,
            scratchDirectory: scratch,
            progress: { _ in })

        // probe() throwing == unreadable output, so a clean probe IS the
        // "file plays" check; the codec pins the modernize branch.
        let out = try CleanupTestMedia.probe(rendered.path)
        #expect(out.audio?.codec_name == "pcm_s16le",
                "vorbis must be modernized to pcm_s16le; got \(out.audio?.codec_name ?? "nil")")
        #expect(out.video?.codec_name == "prores")
        #expect(abs(out.durationSeconds - srcProbe.durationSeconds) <= 0.5)
    }

    // MARK: - m3: sheet and job share one planned destination

    @Test("CleanupRequest computes the destination once; the job adopts it verbatim")
    @MainActor
    func requestAndJobShareDestination() {
        let record = VideoRecord()
        record.filename = "tape.mov"
        record.fullPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_cleanup_m3_\(UUID().uuidString.prefix(8))/tape.mov").path
        record.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let request = CleanupRequest(record: record,
                                     recipe: CleanupRecipeRegistry.vhsQuickClean)
        let job = CleanupJob(record: record,
                             recipe: request.recipe,
                             model: VideoScanModel(),
                             plannedOutput: request.destinationURL)
        #expect(job.outputURL == request.destinationURL,
                "the sheet must never promise a name the job doesn't plan to use")
    }

    // MARK: - B1: chunked publish copy

    @Test("chunkedCopy is byte-faithful with monotonic progress ending at 1.0")
    func chunkedCopyRoundTrip() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("chunkcopy")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 20 MB (3 chunks at the 8 MB default) of non-trivial bytes.
        var megabyte = Data(capacity: 1 << 20)
        for i in 0..<(1 << 20) { megabyte.append(UInt8((i &* 31) % 251)) }
        var payload = Data(capacity: 20 << 20)
        for _ in 0..<20 { payload.append(megabyte) }
        let src = dir.appendingPathComponent("src.bin")
        let dst = dir.appendingPathComponent("dst.bin")
        try payload.write(to: src)

        let beats = CleanupObservationBox([Double]())
        try await CleanupJob.chunkedCopy(from: src.path, to: dst.path) { fraction in
            beats.mutate { $0.append(fraction) }
        }

        let copied = try Data(contentsOf: dst)
        #expect(copied == payload, "chunked copy must be byte-faithful")
        let seen = beats.value
        #expect(seen == seen.sorted(), "progress must be monotonic; got \(seen)")
        #expect(seen.last == 1.0, "progress must end at 1.0; got \(seen)")
        #expect(seen.count >= 2, "a 20 MB copy at 8 MB chunks must beat more than once")
    }
}

// MARK: - Full-job remediation integration (B1/M1/M2/M3/m2)

// .serialized: full CleanupJob runs spawn real ffprobe children through
// probeFile; serial keeps subprocess load deterministic.
@Suite(.serialized) @MainActor
struct CleanupPublishRemediationTests {

    /// M3: a file that appears at the planned destination AFTER job init
    /// (mid-render TOCTOU) is never clobbered — the publish re-uniquifies
    /// to `_cleaned 2` and the pre-existing file survives byte-identical.
    @Test("publish re-uniquifies on a mid-render collision and never clobbers the existing file")
    func publishReUniquifiesAndNeverClobbers() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("reuniquify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let generated = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_reuniq")
        let ownedSrc = dir.appendingPathComponent("test_reuniq_src.mp4").path
        try FileManager.default.moveItem(atPath: generated, toPath: ownedSrc)

        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        model.records = [source]

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: StubCleanupEngine())
        // The collision appears AFTER init chose the name (the TOCTOU
        // window QA flagged): plant a sentinel at the planned destination.
        let planned = job.outputURL
        let sentinel = Data("precious pre-existing file — must survive".utf8)
        try sentinel.write(to: planned)

        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        // Non-clobber: the sentinel is untouched.
        #expect(try Data(contentsOf: planned) == sentinel,
                "publish DESTROYED a pre-existing file at the planned name")
        // Re-uniquify: the output landed at the bumped name.
        let expectedBump = planned.deletingLastPathComponent()
            .appendingPathComponent(planned.deletingPathExtension()
                .lastPathComponent + " 2.mov")
        #expect(job.publishedURL == expectedBump,
                "expected \(expectedBump.lastPathComponent); got \(job.publishedURL?.lastPathComponent ?? "nil")")
        #expect(FileManager.default.fileExists(atPath: expectedBump.path))
        // The catalog record points at the ACTUAL destination.
        #expect(model.records.last?.fullPath == expectedBump.path)
    }

    /// M1 + M2 + m2: catalog registration makes the record searchable
    /// immediately, fires the catalog-mutated notification (debounced
    /// persistence), records the audio disposition in the journey, and
    /// late progress beats can't drag a finished bar backwards.
    @Test("catalog registration: search index, mutation notification, audio journey note, late-beat guard")
    func catalogRegistrationSideEffects() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("catalogfx")
        defer { try? FileManager.default.removeItem(at: dir) }
        let generated = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_catfx")
        let ownedSrc = dir.appendingPathComponent("test_catfx_src.mp4").path
        try FileManager.default.moveItem(atPath: generated, toPath: ownedSrc)

        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")   // audioCodec default "aac" → copy path
        model.records = [source]

        // M2: observe the mutation ping (the model's debounced-save hook).
        let sawMutation = CleanupObservationBox(false)
        let observer = NotificationCenter.default.addObserver(
            forName: .videoScanCatalogMutated, object: nil, queue: nil
        ) { _ in
            sawMutation.mutate { $0 = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: StubCleanupEngine())
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        let published = try #require(job.publishedURL)
        let newRec = try #require(model.records.last)
        #expect(newRec.fullPath == published.path)

        // M1: searchable without a relaunch.
        #expect(model.searchIndex.hasHaystack(for: published.path),
                "cleaned output must be in the search index immediately")
        // M2: persistence hook fired.
        #expect(sawMutation.value,
                ".videoScanCatalogMutated must fire after cataloging (debounced save)")
        // M4 journey note: aac is allowlisted → copied.
        #expect(newRec.notes.contains("audio copied unchanged"),
                "journey must record the audio disposition; notes: \(newRec.notes)")
        #expect(source.notes.contains("audio copied unchanged"))

        // m2: a straggler beat after finish() must not move the bar.
        #expect(job.fraction == 1.0)
        job.applyProgressFraction(0.25)
        #expect(job.fraction == 1.0,
                "late progress beat dragged a finished bar to \(job.fraction)")
    }

    /// m1: the scan walker never admits an in-flight `.vs-partial.` file.
    @Test("scan walker skips .vs-partial files")
    func walkerSkipsPartials() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("walker")
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("tape.mov")
        let partial = dir.appendingPathComponent("tape_cleaned.vs-partial.mov")
        try Data("real".utf8).write(to: real)
        try Data("half-copied".utf8).write(to: partial)

        let found = await FilesystemWalker.walkDirectory(
            root: dir.path,
            videoExtensions: ["mov"],
            skipDirs: [],
            skipBundleExtensions: [],
            skipSmallFiles: false)
        #expect(found.map(\.lastPathComponent) == ["tape.mov"],
                "walker must skip the .vs-partial transient; found \(found.map(\.lastPathComponent))")
    }
}
