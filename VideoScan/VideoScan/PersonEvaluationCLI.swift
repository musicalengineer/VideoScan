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
            if options.engine == .arcface { settings.arcfaceThreshold = value }
            else { settings.threshold = value }
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

        @Sendable func dlib() async -> pfVideoResult? {
            await pfProcessVideoWithDlib(
                filePath: options.video, settings: configuredSettings, index: 1, total: 1,
                pauseGate: pauseGate, logFn: log, progressFn: noopString, distFn: recordDistance
            )
        }

        let result: pfVideoResult?
        if options.facePresenceOnly {
            // An empty reference-print array deliberately makes every observed
            // face an unmatched face while preserving the production decoder,
            // sampling, orientation, detector, watchdog, and face counter.
            result = await vision()
        } else { switch options.engine {
        case .vision: result = await vision()
        case .arcface: result = await arcface()
        case .dlib: result = await dlib()
        case .hybrid:
            let first = await vision()
            result = (first?.segments.isEmpty == false) ? first : await dlib()
        } }
        guard let result else { throw CLIError("recognition engine returned no result") }

        // POI cycle 03: the video-level presence decision. Raw hit counting
        // upstream is untouched; only the confirmed/none classification of
        // the already-computed total differs between modes.
        let rule = options.presenceRule

        return Output(
            schemaVersion: 2, person: options.facePresenceOnly ? "" : options.person,
            engine: options.facePresenceOnly ? "FacePresence/Vision" : options.engine.displayName,
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
                guard let engine = RecognitionEngine.allCases.first(where: {
                    $0.displayName.lowercased() == raw || $0.title.lowercased() == raw
                }) else { throw CLIError("unknown engine: \(raw)") }
                options.engine = engine
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
