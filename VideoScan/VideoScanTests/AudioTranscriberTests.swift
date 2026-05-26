import Foundation
import Testing
@testable import VideoScan

// MARK: - AudioTranscriber Phase-1 tests
//
// Exercises the engine wiring + schema round-trip + writeback + search
// integration for the audio-transcription feature.
//
// Tier:
//   * Always-on: Python subprocess stub-fail smoke, MLX Whisper stub
//     fires .notImplemented (mlx-swift-examples 2.29.1 has no Whisper
//     module), Codable round-trip both populated and legacy-empty,
//     applyAudioTranscript correctness, search predicate hits the
//     transcript text.
//   * Opt-in via VS_RUN_WHISPER=1: real end-to-end transcription
//     through scripts/whisper_transcribe.py running in venv-mlx.
//     Skipped if venv-mlx, the script, or the fixture aren't on disk.
//
// Cost discipline for the gated test mirrors VS_RUN_VLM:
//   * ~244 MB HuggingFace download on first run (cached under
//     ~/.cache/huggingface afterwards)
//   * ~10-30s cold model load even when weights are cached
//   * ~5-30s transcription per clip
// Standard `xcodebuild test` sweeps MUST not pay that cost — same
// reasoning as the captioning suite.

@Suite("Audio Transcriber — Phase 1 engine + schema + writeback + search")
struct AudioTranscriberTests {

    // MARK: - Always-on: MLX Whisper stub

    /// mlx-swift-examples 2.29.1 ships no Swift Whisper module, so
    /// `MLXWhisperTranscriber` is a structural stub today. The test
    /// records that contract — the moment a real Swift Whisper module
    /// lands and the .notImplemented assertion stops holding, this
    /// test fails and forces us to wire the body. That's the intended
    /// trip-wire.
    @Test("MLX Whisper stub throws .notImplemented (no Swift module today)")
    func mlxWhisperStubReturnsNotImplemented() async throws {
        let runner = MLXWhisperTranscriber()
        #expect(runner.modelID == "whisper-medium-mlx-q4")

        do {
            _ = try await runner.transcribe(videoPath: "/dev/null/nonexistent.mp4")
            Issue.record("MLXWhisperTranscriber should have thrown .notImplemented")
        } catch let err as AudioTranscriberError {
            switch err {
            case .notImplemented(let engine):
                #expect(engine == "MLXWhisper")
            default:
                Issue.record("Expected .notImplemented, got: \(err)")
            }
        }
    }

    // MARK: - Always-on: Python subprocess stub-fail smoke

    /// With a bogus python path the runner should surface
    /// .subprocessLaunchFailed rather than crash. Smoke test for the
    /// fail-fast wiring without paying any actual ML cost.
    @Test("Python subprocess fails fast with missing interpreter")
    func pythonStubFailsLaunchOnMissingInterpreter() async throws {
        let runner = PythonSubprocessAudioTranscriber(
            pythonPath: "/dev/null/no-python",
            scriptPath: "/dev/null/no-script.py"
        )
        #expect(runner.modelID == "python-whisper-medium-mlx-q4")

        // Need a path that's NOT pre-empted by the audio-track gate.
        // Point at a file that does exist + is an audio asset OR
        // accept that the gate fires first (.audioUnreadable). We
        // actually want the launch-failure path, so we point at an
        // existing test fixture so the audio gate passes — then the
        // bogus interpreter triggers the real wiring failure.
        let fixturesDir = testFixturesDir()
        let videoPath = fixturesDir + "/test_face_3s.mp4"
        guard FileManager.default.fileExists(atPath: videoPath) else {
            // Fixture missing means we can't reach the launch path;
            // accept whichever audio-unreadable variant fires.
            do {
                _ = try await runner.transcribe(videoPath: "/dev/null/nope.mp4")
                Issue.record("expected an AudioTranscriberError")
            } catch is AudioTranscriberError {
                return
            }
            return
        }

        do {
            _ = try await runner.transcribe(videoPath: videoPath)
            Issue.record("Expected the runner to fail launch")
        } catch let err as AudioTranscriberError {
            switch err {
            case .subprocessLaunchFailed:
                break // expected
            default:
                Issue.record("Expected .subprocessLaunchFailed, got: \(err)")
            }
        }
    }

    /// Wire the runner up with a real python interpreter but a bogus
    /// script path, to prove the script-existence guard fires before
    /// we try to launch.
    @Test("Python subprocess fails fast with missing script")
    func pythonStubFailsLaunchOnMissingScript() async throws {
        let runner = PythonSubprocessAudioTranscriber(
            pythonPath: "/usr/bin/python3",
            scriptPath: "/dev/null/no-script.py"
        )

        let fixturesDir = testFixturesDir()
        let videoPath = fixturesDir + "/test_face_3s.mp4"
        guard FileManager.default.fileExists(atPath: videoPath) else { return }

        do {
            _ = try await runner.transcribe(videoPath: videoPath)
            Issue.record("Expected runner to fail")
        } catch let err as AudioTranscriberError {
            switch err {
            case .subprocessLaunchFailed(let reason):
                #expect(reason.contains("Script missing"))
            default:
                Issue.record("Expected .subprocessLaunchFailed, got: \(err)")
            }
        }
    }

    /// Files that don't exist on disk should surface
    /// `.audioUnreadable` before any subprocess work. Cheapest possible
    /// failure path.
    @Test("Audio gate rejects nonexistent file")
    func audioGateRejectsMissingFile() async throws {
        do {
            _ = try await audioTrackIsPresent(at: "/dev/null/definitely-not-here.mp4")
            Issue.record("audioTrackIsPresent should throw for a missing path")
        } catch let err as AudioTranscriberError {
            switch err {
            case .audioUnreadable(let path):
                #expect(path.hasSuffix("definitely-not-here.mp4"))
            default:
                Issue.record("Expected .audioUnreadable, got: \(err)")
            }
        }
    }

    // MARK: - Always-on: PATH augmentation (ffmpeg lookup)

    /// White-box test: the subprocess environment must put
    /// `/opt/homebrew/bin` (and the Intel `/usr/local/bin` fallback)
    /// ahead of whatever the parent process inherited. mlx-whisper
    /// shells out to `ffmpeg` internally; without this prefix the
    /// child Python fails with `[Errno 2] No such file or directory:
    /// 'ffmpeg'` whenever the app is launched from Xcode or Finder.
    /// If we ever regress the ordering, ffmpeg lookup might pick up
    /// a stale build from a non-Homebrew location.
    @Test("Subprocess PATH puts /opt/homebrew/bin first")
    func subprocessEnvironmentIncludesHomebrewPaths() {
        // Case 1: typical inherited PATH from a Finder/Xcode launch
        // (no Homebrew prefix present).
        let inherited = "/usr/bin:/bin:/usr/sbin:/sbin"
        let augmented = augmentedPathWithHomebrew(inheriting: inherited)
        let parts = augmented.split(separator: ":").map(String.init)
        #expect(parts.first == "/opt/homebrew/bin",
                "Apple Silicon Homebrew prefix must come first; got: \(augmented)")
        #expect(parts.dropFirst().first == "/usr/local/bin",
                "Intel Homebrew fallback must be second; got: \(augmented)")
        #expect(augmented.contains("/usr/bin"),
                "Inherited PATH entries must be preserved: \(augmented)")
        // Ordering: Homebrew entries must precede the inherited /usr/bin.
        let homebrewIdx = parts.firstIndex(of: "/opt/homebrew/bin")
        let usrBinIdx = parts.firstIndex(of: "/usr/bin")
        if let h = homebrewIdx, let u = usrBinIdx {
            #expect(h < u, "Homebrew must precede /usr/bin in PATH")
        } else {
            Issue.record("Missing expected entry — homebrew=\(String(describing: homebrewIdx)) usr/bin=\(String(describing: usrBinIdx))")
        }

        // Case 2: nil inherited PATH (process launched with no PATH env
        // at all — pathological but possible). We must still emit a
        // usable PATH with no trailing colon.
        let fromNil = augmentedPathWithHomebrew(inheriting: nil)
        #expect(fromNil.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"),
                "nil inherited PATH should fall back to POSIX defaults; got: \(fromNil)")
        #expect(!fromNil.hasSuffix(":"),
                "Augmented PATH must not have a trailing colon (implicit cwd): \(fromNil)")

        // Case 3: empty-string inherited PATH — same fallback as nil.
        let fromEmpty = augmentedPathWithHomebrew(inheriting: "")
        #expect(fromEmpty.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"),
                "Empty inherited PATH should also fall back; got: \(fromEmpty)")
        #expect(!fromEmpty.hasSuffix(":"))
    }

    // MARK: - Always-on: Codable round-trip

    /// Records with all three audio-transcript fields populated should
    /// round-trip through JSON unchanged.
    @Test("Codable round-trip preserves audioTranscript fields")
    func codableRoundTripPopulated() throws {
        let rec = VideoRecord()
        rec.filename = "voiceover_2003.mxf"
        rec.fullPath = "/Volumes/Archive/voiceover_2003.mxf"
        rec.audioTranscript = "playing guitar in the kitchen"
        rec.audioTranscriptModel = "python-whisper-medium-mlx-q4"
        let when = Date(timeIntervalSince1970: 1_715_000_000)
        rec.audioTranscriptDate = when

        let enc = JSONEncoder()
        let data = try enc.encode(rec)

        let dec = JSONDecoder()
        let round = try dec.decode(VideoRecord.self, from: data)

        #expect(round.audioTranscript == "playing guitar in the kitchen")
        #expect(round.audioTranscriptModel == "python-whisper-medium-mlx-q4")
        // Date round-trip via JSONEncoder default strategy uses
        // double seconds since reference date — equality should hold
        // to better than millisecond precision for our values.
        if let d = round.audioTranscriptDate {
            #expect(abs(d.timeIntervalSince(when)) < 0.001,
                    "Date drift: round=\(d), orig=\(when)")
        } else {
            Issue.record("audioTranscriptDate decoded as nil")
        }
    }

    /// Legacy records (no audio-transcript keys in the JSON) should
    /// come back with all three fields nil — additive-optional
    /// migration contract.
    @Test("Codable decodes legacy (no audio fields) as all-nil")
    func codableRoundTripLegacy() throws {
        let rec = VideoRecord()
        rec.filename = "legacy.mxf"
        rec.fullPath = "/Volumes/Legacy/legacy.mxf"
        // explicitly leave all three audio* fields at default nil
        #expect(rec.audioTranscript == nil)

        let enc = JSONEncoder()
        let data = try enc.encode(rec)

        // Sanity: the encoded JSON should NOT mention the audio
        // transcript keys at all (encodeIfPresent skips them).
        if let s = String(data: data, encoding: .utf8) {
            #expect(!s.contains("audioTranscript"),
                    "Empty audio fields should be omitted from JSON; got: \(s.prefix(200))")
        }

        let dec = JSONDecoder()
        let round = try dec.decode(VideoRecord.self, from: data)
        #expect(round.audioTranscript == nil)
        #expect(round.audioTranscriptModel == nil)
        #expect(round.audioTranscriptDate == nil)
    }

    /// Empty-but-present transcript (e.g. "ran Whisper, found no
    /// speech") should encode as an empty-string value, not be
    /// elided. This is how the catalog distinguishes "never
    /// transcribed" from "transcribed → silent".
    @Test("Codable preserves empty-string transcript as evidence of a no-speech run")
    func codableRoundTripEmptyTranscript() throws {
        let rec = VideoRecord()
        rec.fullPath = "/x/y/quiet.mxf"
        rec.audioTranscript = ""   // explicit empty == ran, found no speech
        rec.audioTranscriptModel = "python-whisper-medium-mlx-q4"
        rec.audioTranscriptDate = Date()

        let data = try JSONEncoder().encode(rec)
        let round = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(round.audioTranscript == "")
        #expect(round.audioTranscriptModel == "python-whisper-medium-mlx-q4")
        #expect(round.audioTranscriptDate != nil)
    }

    // MARK: - Always-on: writeback correctness

    /// Direct record variant — populates all three fields and bumps
    /// the model's published change signal. Exercises the contract
    /// the orchestration layer will rely on.
    @MainActor
    @Test("applyAudioTranscript(_:modelID:to:) writes all three fields")
    func applyDirectMutatesRecord() {
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.filename = "clip.mxf"
        rec.fullPath = "/x/y/clip.mxf"
        model.records.append(rec)

        let before = Date()
        model.applyAudioTranscript("hello world",
                                   modelID: "python-whisper-medium-mlx-q4",
                                   to: rec)
        let after = Date()

        #expect(rec.audioTranscript == "hello world")
        #expect(rec.audioTranscriptModel == "python-whisper-medium-mlx-q4")
        if let d = rec.audioTranscriptDate {
            #expect(d >= before && d <= after,
                    "Date stamp out of bounds: \(d) not in [\(before), \(after)]")
        } else {
            Issue.record("audioTranscriptDate not set")
        }
    }

    /// Path-keyed variant returns true on success, false on miss.
    @MainActor
    @Test("applyAudioTranscript(_:to:model:) returns true on match, false on miss")
    func applyByPathLookup() {
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.fullPath = "/x/y/match.mxf"
        model.records.append(rec)

        let matched = model.applyAudioTranscript(
            "matched body", to: "/x/y/match.mxf",
            model: "python-whisper-medium-mlx-q4"
        )
        #expect(matched == true)
        #expect(rec.audioTranscript == "matched body")

        let miss = model.applyAudioTranscript(
            "should be skipped", to: "/x/y/not-in-catalog.mxf",
            model: "python-whisper-medium-mlx-q4"
        )
        #expect(miss == false)
    }

    /// Bulk variant counts matches and ignores unknown paths.
    @MainActor
    @Test("applyAudioTranscripts(_:model:) handles bulk + skips unknowns")
    func applyBulkBatch() {
        let model = VideoScanModel()
        let a = VideoRecord(); a.fullPath = "/x/a.mxf"; model.records.append(a)
        let b = VideoRecord(); b.fullPath = "/x/b.mxf"; model.records.append(b)

        let updated = model.applyAudioTranscripts(
            [
                "/x/a.mxf": "alpha audio",
                "/x/b.mxf": "",                // valid: ran, no speech
                "/x/missing.mxf": "ignored"     // not in catalog
            ],
            model: "python-whisper-medium-mlx-q4"
        )

        #expect(updated == 2)
        #expect(a.audioTranscript == "alpha audio")
        #expect(b.audioTranscript == "")
        #expect(b.audioTranscriptModel == "python-whisper-medium-mlx-q4")
    }

    /// Empty model id is a programming error — guard rejects it so a
    /// caller can't accidentally clear the provenance.
    @MainActor
    @Test("Empty model id is rejected by writeback")
    func emptyModelIDRejected() {
        let model = VideoScanModel()
        let rec = VideoRecord(); rec.fullPath = "/x/y.mxf"; model.records.append(rec)

        // Direct variant: silent no-op on empty model id.
        model.applyAudioTranscript("text", modelID: "", to: rec)
        #expect(rec.audioTranscript == nil)
        #expect(rec.audioTranscriptModel == nil)

        // Path variant: returns false.
        let r1 = model.applyAudioTranscript("text", to: "/x/y.mxf", model: "")
        #expect(r1 == false)

        // Bulk variant: returns 0.
        let r2 = model.applyAudioTranscripts(["/x/y.mxf": "text"], model: "")
        #expect(r2 == 0)
    }

    // MARK: - Always-on: search integration

    /// Universal-search predicate should pick up a substring inside
    /// audioTranscript exactly the way it picks up sceneCaptions text.
    @Test("Universal search matches inside audioTranscript text")
    func searchMatchesTranscriptSubstring() {
        let rec = VideoRecord()
        rec.filename = "interview.mxf"
        rec.fullPath = "/Volumes/Archive/interview.mxf"
        rec.audioTranscript = "playing guitar in the kitchen"

        // Exact phrase match
        #expect(pfRecordMatchesQuery(rec, query: "guitar") == true,
                "should hit on 'guitar'")
        // Case-insensitive
        #expect(pfRecordMatchesQuery(rec, query: "GUITAR") == true,
                "should hit case-insensitively")
        // Multi-token AND — both inside transcript
        #expect(pfRecordMatchesQuery(rec, query: "guitar kitchen") == true,
                "multi-token AND across transcript words should hit")
        // Negative
        #expect(pfRecordMatchesQuery(rec, query: "harpsichord") == false,
                "non-matching token should miss")
    }

    /// Cross-source composition: a person tag + a transcript token
    /// should hit via AND semantics, matching the docs/scene_captions_plan.md
    /// "Donna playing guitar" example shape.
    @Test("Search composes person tag AND transcript token")
    func searchComposesPeopleAndTranscript() {
        let rec = VideoRecord()
        rec.fullPath = "/x/y.mxf"
        rec.detectedPeople = ["Donna"]
        rec.audioTranscript = "playing guitar in the kitchen"

        #expect(pfRecordMatchesQuery(rec, query: "donna guitar") == true,
                "person tag + transcript word AND should hit")
        #expect(pfRecordMatchesQuery(rec, query: "donna harpsichord") == false,
                "person tag alone is not enough if other token misses")
    }

    /// Records with nil transcript should be unaffected by the new
    /// predicate clause — regression check that we didn't accidentally
    /// throw on a nil unwrap.
    @Test("Nil transcript does not crash the search predicate")
    func searchTolerantOfNilTranscript() {
        let rec = VideoRecord()
        rec.fullPath = "/x/y.mxf"
        rec.filename = "named.mp4"
        // audioTranscript stays nil
        #expect(pfRecordMatchesQuery(rec, query: "named") == true)
        #expect(pfRecordMatchesQuery(rec, query: "guitar") == false)
    }

    // MARK: - VS_RUN_WHISPER=1 gated: real Whisper transcription

    /// End-to-end Whisper transcription through the Python subprocess
    /// runner. Skipped unless VS_RUN_WHISPER=1 (or the Swift Testing
    /// xcodebuild equivalent, TEST_RUNNER_VS_RUN_WHISPER=1). Also
    /// skipped automatically if venv-mlx or the script aren't present —
    /// keeps the gated test green on machines where the user hasn't
    /// staged the MLX Python env yet.
    @Test(
        "Python+mlx-whisper end-to-end (VS_RUN_WHISPER=1)",
        .disabled(
            if: ProcessInfo.processInfo.environment["VS_RUN_WHISPER"] != "1",
            "Whisper end-to-end — set VS_RUN_WHISPER=1 (or TEST_RUNNER_VS_RUN_WHISPER=1 for xcodebuild) to enable. First run downloads ~244 MB."
        ),
        .timeLimit(.minutes(10))
    )
    func transcribesFixtureEndToEnd() async throws {
        // Resolve repo paths from the test file's #filePath — same
        // shape testFixturesDir() uses, walks up three levels.
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here
            .deletingLastPathComponent()   // VideoScanTests/
            .deletingLastPathComponent()   // VideoScan/
            .deletingLastPathComponent()   // project root
        let venvPython = repoRoot.appendingPathComponent("venv-mlx/bin/python").path
        let script = repoRoot.appendingPathComponent("scripts/whisper_transcribe.py").path
        let fixturesDir = testFixturesDir()
        let videoPath = fixturesDir + "/test_face_3s.mp4"

        // Pre-flight: skip cleanly when the local environment isn't
        // staged. This is NOT a failure — it just means the developer
        // hasn't set up venv-mlx yet, and forcing that as a hard
        // requirement would block the gated suite for everyone who
        // hasn't installed the MLX Python stack.
        guard FileManager.default.fileExists(atPath: venvPython) else {
            print("[VS_RUN_WHISPER] venv-mlx python not found at \(venvPython) — skipping")
            return
        }
        guard FileManager.default.fileExists(atPath: script) else {
            print("[VS_RUN_WHISPER] script not found at \(script) — skipping")
            return
        }
        guard FileManager.default.fileExists(atPath: videoPath) else {
            print("[VS_RUN_WHISPER] fixture not found at \(videoPath) — skipping")
            return
        }

        let runner = PythonSubprocessAudioTranscriber(
            pythonPath: venvPython,
            scriptPath: script
        )
        let text = try await runner.transcribe(videoPath: videoPath)

        // Real ground truth: we asserted on shape ("non-empty +
        // contains a recognizable English word"). The Whisper text
        // for test_face_3s.mp4 has historically included recognizable
        // English; if the fixture's audio is too quiet for medium-q4,
        // surface that as a test failure with the actual transcript
        // so Rick can swap to a louder fixture.
        #expect(!text.isEmpty, "Whisper returned empty transcript for fixture")
        print("[VS_RUN_WHISPER] transcript: \(text)")

        // Heuristic check for "recognizable English" — at least one
        // ASCII letter character pair (a real word). This is a very
        // weak assertion on purpose: Whisper may transcribe variant
        // wording, and we want the test to be a regression alarm,
        // not a fragile string match.
        let lowered = text.lowercased()
        let hasLetters = lowered.contains(where: { $0.isLetter })
        #expect(hasLetters, "Whisper output had no recognizable letters: \(text)")
    }
}
