import Foundation
import Darwin

/// Narrow headless adapter for the external accuracy evaluator. It invokes the
/// production per-video recognition functions directly: no SwiftUI scene, no
/// catalog mutation, no clips, and no result-cache shortcut.
enum PersonEvaluationCLI {
    private actor BestDistanceAccumulator {
        private var best: Float?
        func record(_ value: Float) {
            if let current = best {
                if value < current { best = value }
            } else {
                best = value
            }
        }
        func value() -> Float? { best }
    }

    /// Internal (not private) so the unit tests can pin the parse/validation
    /// truth table without spawning a process.
    struct Options {
        var engine = RecognitionEngine.vision
        var person = ""
        var references = ""
        var video = ""
        var threshold: Float?
        var frameStep: Int?
        var minFaceConfidence: Float?
        var largestFaceOnly = false
        var facePresenceOnly = false
        // ISOLATED legacy-dlib replay arm (codex post-merge #3). dlib was
        // removed from RecognitionEngine (#144) but historical eval
        // manifests still say `--engine dlib`; this CLI-only token keeps
        // them replayable against the kept-deprecated
        // scripts/face_recognize.py. Deliberately NOT a RecognitionEngine
        // case — Search can never see it, and the dlib-cannot-reappear
        // registry sensor stays intact.
        var legacyDlib = false
        var pythonPath: String?          // --python-path (default: ToolLocator)
        var recognitionScript: String?   // --recognition-script (default: repo script)
        // POI cycle 03 — minimum-hit confirmation floor (eval-only A/B
        // surface). nil = flag not given. Parse validation guarantees the
        // pair is coherent: `minHits` is set iff `aggregationMode` is
        // `.minimumHits` (no inert flags, no silent defaults).
        var aggregationMode: EvalPresenceRule.Mode?
        var minHits: Int?

        /// The single rule this run both EXECUTES and EMITS — one source, so
        /// the reported configuration is always the effective one (cycle 2's
        /// provenance lesson). Default (no flags) is the legacy any-hit arm.
        var presenceRule: EvalPresenceRule {
            if aggregationMode == .minimumHits, let floor = minHits {
                return .minimumHits(floor: floor)
            }
            return .legacy
        }
    }

    struct SegmentOutput: Codable {
        let start: Double
        let end: Double
        let bestDistance: Float
        let averageDistance: Float
    }

    /// Machine-readable result for one video. schemaVersion 2 (POI cycle 03)
    /// is a purely ADDITIVE change over 1: `hits`, `segments`,
    /// `facesDetected`, `bestDistance` keep their raw pipeline semantics.
    /// New fields:
    ///   - `aggregation` — the exact EvalPresenceRule used (the evaluator's
    ///     config-hash surface; byte-stable under this encoder's sortedKeys).
    ///   - `presence`    — video-level decision: "confirmed" or "none". The
    ///     grader counts ONLY the exact spelling "confirmed" as a positive.
    ///     Default/legacy runs: confirmed ⇔ hits > 0 (any-hit, unchanged
    ///     semantics). minimum-hits runs: confirmed ⇔ hits ≥ minHits.
    struct Output: Codable {
        let schemaVersion: Int
        let person: String
        let engine: String
        let video: String
        let facesDetected: Int
        let hits: Int
        let bestDistance: Float?
        let segments: [SegmentOutput]
        let elapsedSeconds: Double
        let peakRSSMB: Double
        let error: String?
        let aggregation: EvalPresenceRule
        let presence: String
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        // Attribute error outputs to the rule that was actually requested
        // whenever parsing got far enough to know it; before that, the only
        // truthful answer is the default (legacy).
        var attributedRule = EvalPresenceRule.legacy
        do {
            let options = try parse(arguments)
            attributedRule = options.presenceRule
            let started = CFAbsoluteTimeGetCurrent()
            let output = try await evaluate(options, started: started)
            try emit(output)
            return output.error == nil ? 0 : 1
        } catch {
            let output = Output(
                schemaVersion: 2, person: "", engine: "", video: "",
                facesDetected: 0, hits: 0, bestDistance: nil, segments: [],
                elapsedSeconds: 0, peakRSSMB: peakRSSMB(),
                error: error.localizedDescription,
                aggregation: attributedRule, presence: EvalPresenceRule.noneSpelling
            )
            try? emit(output)
            return 2
        }
    }

    @MainActor
    private static func evaluate(_ options: Options, started: CFAbsoluteTime) async throws -> Output {
        guard FileManager.default.fileExists(atPath: options.video) else {
            throw CLIError("video does not exist: \(options.video)")
        }
        guard options.facePresenceOnly || FileManager.default.fileExists(atPath: options.references) else {
            throw CLIError("reference path does not exist: \(options.references)")
        }

        var settings = PersonFinderSettings()
        settings.personName = options.person
        settings.referencePath = options.references
        settings.recognitionEngine = options.engine
        if let value = options.threshold {
            switch options.engine {
            case .arcface: settings.arcfaceThreshold = value
            case .adaface: settings.adafaceThreshold = value
            default:       settings.threshold = value
            }
        }
        if let value = options.frameStep { settings.frameStep = value }
        if let value = options.minFaceConfidence { settings.minFaceConfidence = value }
        settings.largestFaceOnly = options.largestFaceOnly
        settings.concurrency = 1
        settings.previewRate = Int.max
        // Freeze the configured value before capturing it in @Sendable engine
        // closures. The mutable setup variable never crosses concurrency.
        let configuredSettings = settings

        let faces: [ReferenceFace]
        if options.facePresenceOnly {
            faces = []
        } else {
            let loaded = await Task.detached(priority: .userInitiated) {
                pfLoadReferencePhotos(from: options.references, largestFaceOnly: options.largestFaceOnly)
            }.value
            guard !loaded.0.isEmpty else {
                let detail = loaded.2 ?? loaded.1.map { "\($0.filename): \($0.reason)" }.joined(separator: "; ")
                throw CLIError("no usable reference faces: \(detail)")
            }
            faces = loaded.0
        }

        let log: @Sendable (String) async -> Void = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        let noopString: @Sendable (String) async -> Void = { _ in }
        let distanceAccumulator = BestDistanceAccumulator()
        let recordDistance: @Sendable (Float) async -> Void = { value in
            await distanceAccumulator.record(value)
        }
        let pauseGate = PauseGate()

        @Sendable func vision() async -> pfVideoResult? {
            await pfProcessVideo(
                filePath: options.video, prints: faces.map(\.featurePrint), settings: configuredSettings,
                index: 1, total: 1, pauseGate: pauseGate, logFn: log,
                progressFn: noopString, frameFn: { _, _, _ in },
                distFn: recordDistance, distFnFinal: recordDistance,
                visionStatsFn: { _, _ in }, previewRateFn: { Int.max }
            )
        }

        @Sendable func arcface() async -> pfVideoResult? {
            let (model, modelError) = await ArcFaceModelLoader.shared.getModel()
            guard let model else { await log("ArcFace model load failed: \(modelError ?? "unknown")"); return nil }
            let (embeddings, embeddingError) = arcfaceLoadReferenceEmbeddings(
                from: options.references, largestFaceOnly: options.largestFaceOnly,
                useLandmarkAlignment: configuredSettings.arcfaceLandmarkAlignment, model: model
            )
            guard embeddingError == nil, !embeddings.isEmpty else {
                await log("ArcFace reference embedding failed: \(embeddingError ?? "no embeddings")")
                return nil
            }
            return await pfProcessVideoWithArcFace(
                filePath: options.video, referenceEmbeddings: embeddings, settings: configuredSettings,
                model: model, index: 1, total: 1, pauseGate: pauseGate,
                logFn: log, progressFn: noopString, frameFn: { _, _, _ in },
                distFn: recordDistance, distFnFinal: recordDistance,
                visionStatsFn: { _, _ in }, previewRateFn: { Int.max }
            )
        }

        @Sendable func adaface() async -> pfVideoResult? {
            let (model, modelError) = await AdaFaceModelLoader.shared.getModel()
            guard let model else { await log("AdaFace model load failed: \(modelError ?? "unknown")"); return nil }
            let (embeddings, embeddingError) = arcfaceLoadReferenceEmbeddings(
                from: options.references, largestFaceOnly: options.largestFaceOnly,
                useLandmarkAlignment: configuredSettings.arcfaceLandmarkAlignment, model: model,
                useSharedPool: false
            )
            guard embeddingError == nil, !embeddings.isEmpty else {
                await log("AdaFace reference embedding failed: \(embeddingError ?? "no embeddings")")
                return nil
            }
            return await pfProcessVideoWithArcFace(
                filePath: options.video, referenceEmbeddings: embeddings, settings: configuredSettings,
                model: model, index: 1, total: 1, pauseGate: pauseGate,
                logFn: log, progressFn: noopString, frameFn: { _, _, _ in },
                distFn: recordDistance, distFnFinal: recordDistance,
                visionStatsFn: { _, _ in }, previewRateFn: { Int.max },
                engineTag: "AdaFace",
                cosineThresholdOverride: configuredSettings.adafaceThreshold,
                useSharedPool: false
            )
        }

        let result: pfVideoResult?
        if options.facePresenceOnly {
            // An empty reference-print array deliberately makes every observed
            // face an unmatched face while preserving the production decoder,
            // sampling, orientation, detector, watchdog, and face counter.
            result = await vision()
        } else if options.legacyDlib {
            // Isolated legacy replay — never dispatched from Search.
            result = await Self.legacyDlibProcessVideo(
                options: options, settings: configuredSettings, logFn: log
            )
        } else { switch options.engine {
        case .vision: result = await vision()
        case .arcface: result = await arcface()
        case .adaface: result = await adaface()
        case .hybrid:
            let first = await vision()
            result = (first?.segments.isEmpty == false) ? first : await adaface()
        } }
        guard let result else { throw CLIError("recognition engine returned no result") }

        // POI cycle 03: the video-level presence decision. Raw hit counting
        // upstream is untouched; only the confirmed/none classification of
        // the already-computed total differs between modes.
        let rule = options.presenceRule

        // Legacy replays report "dlib" — the exact token historical outputs
        // carried, so old and new runs diff cleanly.
        let engineLabel = options.facePresenceOnly ? "FacePresence/Vision"
            : (options.legacyDlib ? "dlib" : options.engine.displayName)
        return Output(
            schemaVersion: 2, person: options.facePresenceOnly ? "" : options.person,
            engine: engineLabel,
            video: options.video, facesDetected: result.facesDetected, hits: result.totalHits,
            bestDistance: await distanceAccumulator.value() ?? result.segments.map(\.bestDistance).min(),
            segments: result.segments.map {
                SegmentOutput(start: $0.startSecs, end: $0.endSecs,
                              bestDistance: $0.bestDistance, averageDistance: $0.avgDistance)
            },
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - started,
            peakRSSMB: peakRSSMB(), error: nil,
            aggregation: rule,
            presence: rule.presence(hits: result.totalHits)
        )
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else { throw CLIError("missing value after \(flag)") }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--person-eval": break
            case "--engine":
                let raw = try value(after: argument).lowercased()
                if raw == "dlib" {
                    // Legacy replay token — see Options.legacyDlib. Matches
                    // what pre-#144 manifests emitted (displayName "dlib").
                    options.legacyDlib = true
                } else if let engine = RecognitionEngine.allCases.first(where: {
                    $0.displayName.lowercased() == raw || $0.title.lowercased() == raw
                }) {
                    options.engine = engine
                } else {
                    throw CLIError("unknown engine: \(raw)")
                }
            case "--python-path": options.pythonPath = try value(after: argument)
            case "--recognition-script": options.recognitionScript = try value(after: argument)
            case "--person": options.person = try value(after: argument)
            case "--references": options.references = try value(after: argument)
            case "--video": options.video = try value(after: argument)
            case "--threshold":
                guard let number = Float(try value(after: argument)) else { throw CLIError("invalid threshold") }
                options.threshold = number
            case "--frame-step":
                guard let number = Int(try value(after: argument)), number > 0 else { throw CLIError("invalid frame step") }
                options.frameStep = number
            case "--min-face-confidence":
                guard let number = Float(try value(after: argument)) else { throw CLIError("invalid face confidence") }
                options.minFaceConfidence = number
            case "--largest-face-only": options.largestFaceOnly = true
            case "--face-presence-only": options.facePresenceOnly = true
            // POI cycle 03 — aggregation A/B surface. Strict by design:
            // duplicates, unknown modes, non-positive/non-integer floors,
            // and inert flag combinations are all hard errors, so the run
            // either executes exactly the requested rule or refuses.
            case "--aggregation":
                guard options.aggregationMode == nil else { throw CLIError("duplicate --aggregation") }
                let raw = try value(after: argument).lowercased()
                switch raw {
                case "minimum-hits", "minimumhits": options.aggregationMode = .minimumHits
                case "legacy", "legacy-any-hit", "legacyanyhit": options.aggregationMode = .legacyAnyHit
                default: throw CLIError("unknown aggregation mode: \(raw)")
                }
            case "--min-hits":
                guard options.minHits == nil else { throw CLIError("duplicate --min-hits") }
                let raw = try value(after: argument)
                // Int() rejects floats, NaN, hex, empty, and overflow — every
                // malformed spelling fails here rather than defaulting.
                guard let number = Int(raw), number > 0 else {
                    throw CLIError("invalid --min-hits: \(raw) (must be a positive integer)")
                }
                options.minHits = number
            default: throw CLIError("unknown argument: \(argument)")
            }
            index += 1
        }
        guard options.facePresenceOnly || !options.person.isEmpty else { throw CLIError("--person is required") }
        guard options.facePresenceOnly || !options.references.isEmpty else { throw CLIError("--references is required") }
        guard !options.video.isEmpty else { throw CLIError("--video is required") }
        // POI cycle 03 flag coherence (order-independent, checked post-parse):
        // the emitted config must always be the effective config, so a flag
        // that could not influence this run is an error, not a no-op.
        switch options.aggregationMode {
        case .minimumHits:
            guard options.minHits != nil else {
                throw CLIError("--aggregation minimum-hits requires --min-hits (no silent default)")
            }
            guard !options.facePresenceOnly else {
                throw CLIError("--aggregation minimum-hits conflicts with --face-presence-only (a presence-only run has no reference hits to count)")
            }
        case .legacyAnyHit, nil:
            guard options.minHits == nil else {
                throw CLIError("--min-hits requires --aggregation minimum-hits")
            }
        }
        return options
    }

    private static func emit(_ output: Output) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(output)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func peakRSSMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / (1024 * 1024)
    }

    private struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - Isolated legacy-dlib replay arm (codex post-merge #3, #144)
//
// dlib's Search seat was replaced by AdaFace, but historical eval manifests
// (tools/person-eval/label_queue_to_manifest.py output) still say
// `--engine dlib`. This arm keeps those replays working by shelling out to
// the kept-deprecated scripts/face_recognize.py — a trimmed adaptation of
// the removed pfProcessVideoWithDlib (git 39d9997). CONTAINMENT RULES:
//  - not a RecognitionEngine case (the registry sensor proves Search can
//    never show or dispatch it)
//  - reachable ONLY through the CLI `--engine dlib` token
//  - no PauseGate/MemoryPressureMonitor coupling — evals run one video per
//    process; the RSS budget is a fixed env hint to the script

extension PersonEvaluationCLI {

    private struct LegacyDlibSegmentJSON: Codable {
        let start: Double
        let end: Double
        let bestDist: Float
        let avgDist: Float
        let hitCount: Int
        enum CodingKeys: String, CodingKey {
            case start, end
            case bestDist = "best_dist"
            case avgDist  = "avg_dist"
            case hitCount = "hit_count"
        }
    }

    private struct LegacyDlibResultJSON: Codable {
        let video: String
        let duration: Double
        let fps: Double
        let error: String?
        let facesDetected: Int
        let hits: Int
        let bestDist: Float?
        let segments: [LegacyDlibSegmentJSON]
        enum CodingKeys: String, CodingKey {
            case video, duration, fps, error, segments, hits
            case facesDetected = "faces_detected"
            case bestDist      = "best_dist"
        }
    }

    /// Default script location when --recognition-script isn't given:
    /// prefer the working copy's script (repo-relative), fall back to the
    /// canonical checkout. Internal for the parse/validation tests.
    static func legacyDlibDefaultScript() -> String {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/scripts/face_recognize.py",
            NSHomeDirectory() + "/dev/VideoScan/scripts/face_recognize.py"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[1]
    }

    static func legacyDlibProcessVideo(
        options: Options,
        settings: PersonFinderSettings,
        logFn: @escaping @Sendable (String) async -> Void
    ) async -> pfVideoResult? {
        let python = options.pythonPath ?? ToolLocator.pythonPath
        let script = options.recognitionScript ?? legacyDlibDefaultScript()
        let filename = (options.video as NSString).lastPathComponent

        await logFn("legacy-dlib: python=\(python)")
        await logFn("legacy-dlib: script=\(script)")
        guard FileManager.default.isExecutableFile(atPath: python) else {
            await logFn("legacy-dlib: Python executable not found or not executable — pass --python-path")
            return nil
        }
        guard FileManager.default.fileExists(atPath: script) else {
            await logFn("legacy-dlib: recognition script not found — pass --recognition-script")
            return nil
        }

        let stdout = await ProcessRunner.runStreaming(
            executable: python,
            arguments: [
                script,
                "--ref-path", settings.referencePath,
                "--video", options.video,
                "--threshold", String(format: "%.4f", settings.threshold),
                "--frame-step", String(settings.frameStep),
                "--min-conf", String(format: "%.4f", settings.minFaceConfidence),
                "--pad", String(format: "%.2f", settings.pad),
                "--min-duration", String(format: "%.2f", settings.minDuration)
            ],
            environment: [
                // Fixed budget: single-video eval process, no monitor coupling.
                "FACE_RECOG_MAX_RSS_MB": "2048"
            ],
            stderrLine: { line in Task { await logFn("  " + line) } }
        )

        guard let jsonStr = stdout else {
            await logFn("legacy-dlib: failed to launch Python process")
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(
            LegacyDlibResultJSON.self, from: Data(jsonStr.utf8)) else {
            let snippet = String(jsonStr.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            await logFn("legacy-dlib: invalid JSON from script: \(snippet)")
            return nil
        }
        if let err = parsed.error {
            await logFn("legacy-dlib: script error: \(err)")
            return pfVideoResult(filename: filename, filePath: options.video,
                                 durationSeconds: parsed.duration, fps: parsed.fps,
                                 totalHits: 0, segments: [],
                                 facesDetected: parsed.facesDetected)
        }
        let segs = parsed.segments.map {
            pfSegment(startSecs: $0.start, endSecs: $0.end,
                      bestDistance: $0.bestDist, avgDistance: $0.avgDist)
        }
        return pfVideoResult(filename: filename, filePath: options.video,
                             durationSeconds: parsed.duration, fps: parsed.fps,
                             totalHits: parsed.hits, segments: segs,
                             facesDetected: parsed.facesDetected)
    }
}
