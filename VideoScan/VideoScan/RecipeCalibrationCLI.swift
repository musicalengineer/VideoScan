import Foundation

// MARK: - RecipeCalibrationCLI (--recipe-calibrate)
//
// Headless adapter that runs NativeRecipeScorer over a labeled corpus
// (subfolders = labels; "Donna" = positive, everything else negative —
// same convention as tools/donna-recipe/recipe_smoke.py) and prints the
// numbers thresholds are read off of:
//
//   - per-clip scores under the configured gate
//   - Donna vs NotDonna distributions, separation, pairwise AUC
//   - a small-face-bar sweep re-scored from per-face (px, cosine)
//     samples — one decode pass serves the whole grid
//
// This exists because cosine thresholds are NOT portable across embedding
// spaces (see the calibration NOTE in RecipeScoring.swift): every time
// the backend or checkpoint changes, this run is how the native-space
// bars are re-derived. Invocation (same pattern as --person-eval):
//
//   VideoScan.app/Contents/MacOS/VideoScan --recipe-calibrate \
//       --gallery ~/dev/VideoScan/tests/fixtures/photos/Donna \
//       --corpus  ~/dev/VideoScan/tests/fixtures/videos/DonnaTestVideos \
//       [--engine adaface|arcface] [--fps 2] [--top-k 5]
//       [--record-px 25] [--vote-px 60] [--small-face-min-cos 0.55]
//
// Per-face samples stay in this process and die with it — nothing is
// persisted (POI cycle-2 rule).

enum RecipeCalibrationCLI {

    struct Options {
        var gallery = ""
        var corpus = ""
        var engine = RecipeEmbeddingBackend.adaface
        var params = RecipeParameters()
    }

    private static let videoSuffixes: Set<String> =
        ["mov", "mp4", "m4v", "avi", "mts", "m2ts", "mxf", "mkv"]

    /// Small-face bar grid for the sweep. Coarse on purpose — this picks
    /// a region, the G2 C2-style sweep does the fine calibration.
    private static let sweepBars: [Double] = stride(from: 0.0, through: 0.80, by: 0.05).map { $0 }

    static func run(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 2
        }

        var params = options.params
        params.collectFaceSamples = true
        let scorer = NativeRecipeScorer(backend: options.engine, params: params)

        print("=== native recipe calibration [\(options.engine.rawValue)] ===")
        print("gate: record≥\(params.recordPx)px vote≥\(params.votePx)px "
            + "smallFaceMinCos=\(fmt(params.smallFaceMinCos)) "
            + "top-\(params.topK) @ \(params.samplingFPS) fps")
        do {
            let eras = try await scorer.prepare(galleryRoot: URL(fileURLWithPath: options.gallery))
            print("era centroids: \(eras)")
        } catch {
            FileHandle.standardError.write(Data("setup failed: \(error.localizedDescription)\n".utf8))
            return 2
        }

        // (label, clipName, result)
        var results: [(label: String, name: String, verdict: RecipeClipScore)] = []
        let corpusURL = URL(fileURLWithPath: options.corpus)
        let fm = FileManager.default
        guard let labelDirs = try? fm.contentsOfDirectory(
            at: corpusURL, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else {
            FileHandle.standardError.write(Data("cannot enumerate corpus: \(options.corpus)\n".utf8))
            return 2
        }

        let started = CFAbsoluteTimeGetCurrent()
        for labelDir in labelDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? labelDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let label = labelDir.lastPathComponent
            guard let clips = try? fm.contentsOfDirectory(
                at: labelDir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for clip in clips.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where videoSuffixes.contains(clip.pathExtension.lowercased()) {
                let clipStart = CFAbsoluteTimeGetCurrent()
                let verdict = await scorer.score(clip: clip)
                let secs = CFAbsoluteTimeGetCurrent() - clipStart
                results.append((label, clip.lastPathComponent, verdict))
                if let err = verdict.error {
                    print("  \(label)/\(clip.lastPathComponent): ERR \(err)")
                } else {
                    print("  \(label)/\(clip.lastPathComponent): \(fmt(verdict.score ?? 0)) "
                        + "(\(verdict.frameCount) frames, \(verdict.gatedFaceCount) gated faces) "
                        + "[\(String(format: "%.1f", secs))s]")
                }
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let scored = results.filter { $0.verdict.error == nil }
        print("\n=== \(results.count) clips in \(Int(elapsed))s "
            + "(\(String(format: "%.1f", elapsed / Double(max(results.count, 1))))s/clip)")

        summarize(scored: scored, configured: params)
        return 0
    }

    // MARK: Reporting

    private static func summarize(
        scored: [(label: String, name: String, verdict: RecipeClipScore)],
        configured: RecipeParameters
    ) {
        func isPositive(_ label: String) -> Bool { label.lowercased() == "donna" }
        let donna = scored.filter { isPositive($0.label) }.compactMap { $0.verdict.score }
        let other = scored.filter { !isPositive($0.label) }.compactMap { $0.verdict.score }
        guard !donna.isEmpty, !other.isEmpty else {
            print("not enough labeled clips for a summary "
                + "(\(donna.count) positive / \(other.count) negative)")
            return
        }

        print("\nconfigured gate:")
        printDistributions(donna: donna, other: other)

        // Sweep the small-face bar from the collected per-face samples —
        // no re-decode. Errored clips are already excluded.
        print("\nsmall-face bar sweep (re-scored from per-face samples):")
        print("  bar    AUC    worst-Donna  best-NotDonna")
        var best: (bar: Double, auc: Double, margin: Double)?
        for bar in sweepBars {
            var params = configured
            params.smallFaceMinCos = bar
            var pos: [Double] = []
            var neg: [Double] = []
            for row in scored {
                guard let samples = row.verdict.faceSamples else { continue }
                let score = RecipeMath.clipScore(fromSamples: samples, params: params).score
                if isPositive(row.label) { pos.append(score) } else { neg.append(score) }
            }
            guard let auc = RecipeMath.pairwiseAUC(positives: pos, negatives: neg),
                  let worstPos = pos.min(), let bestNeg = neg.max() else { continue }
            let margin = worstPos - bestNeg
            print("  \(fmt(bar))  \(String(format: "%.3f", auc))  \(fmt(worstPos))        \(fmt(bestNeg))")
            if let current = best {
                if auc > current.auc || (auc == current.auc && margin > current.margin) {
                    best = (bar, auc, margin)
                }
            } else {
                best = (bar, auc, margin)
            }
        }

        if let best {
            var params = configured
            params.smallFaceMinCos = best.bar
            var pos: [Double] = []
            var neg: [Double] = []
            for row in scored {
                guard let samples = row.verdict.faceSamples else { continue }
                let score = RecipeMath.clipScore(fromSamples: samples, params: params).score
                if isPositive(row.label) { pos.append(score) } else { neg.append(score) }
            }
            print("\nsorted scores at bar \(fmt(best.bar)) (best sweep point):")
            print("  Donna:    " + pos.sorted().map(fmt).joined(separator: " "))
            print("  NotDonna: " + neg.sorted(by: >).map(fmt).joined(separator: " "))
        }
    }

    private static func printDistributions(donna: [Double], other: [Double]) {
        let ds = donna.sorted(), os = other.sorted()
        guard let dMin = ds.first, let dMax = ds.last,
              let oMin = os.first, let oMax = os.last else { return }
        print("Donna scores:    min \(fmt(dMin))  median \(fmt(ds[ds.count / 2]))  max \(fmt(dMax))")
        print("NotDonna scores: min \(fmt(oMin))  median \(fmt(os[os.count / 2]))  max \(fmt(oMax))")
        let auc = RecipeMath.pairwiseAUC(positives: donna, negatives: other) ?? 0
        print("separation: worst-Donna \(fmt(dMin)) vs best-NotDonna \(fmt(oMax))"
            + "  |  AUC \(String(format: "%.3f", auc))")
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    // MARK: Parsing

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else { throw CLIError("missing value after \(flag)") }
            index += 1
            return arguments[index]
        }
        func doubleValue(after flag: String) throws -> Double {
            guard let number = Double(try value(after: flag)) else {
                throw CLIError("invalid number for \(flag)")
            }
            return number
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--recipe-calibrate": break
            case "--gallery": options.gallery = try value(after: argument)
            case "--corpus": options.corpus = try value(after: argument)
            case "--engine":
                let raw = try value(after: argument).lowercased()
                guard let engine = RecipeEmbeddingBackend(rawValue: raw) else {
                    throw CLIError("unknown engine: \(raw) (adaface|arcface)")
                }
                options.engine = engine
            case "--sex-gate": options.params.sexGateEnabled = true
            case "--sex-gate-min-age":
                options.params.sexGateMinAge = Int(try value(after: argument)) ?? 18
            case "--sex-gate-male-margin":
                options.params.sexGateMaleVetoMargin = Float(try value(after: argument)) ?? 1.0
            case "--fps": options.params.samplingFPS = try doubleValue(after: argument)
            case "--top-k":
                guard let k = Int(try value(after: argument)), k > 0 else {
                    throw CLIError("invalid --top-k")
                }
                options.params.topK = k
            case "--record-px":
                guard let px = Int(try value(after: argument)), px > 0 else {
                    throw CLIError("invalid --record-px")
                }
                options.params.recordPx = px
            case "--vote-px":
                guard let px = Int(try value(after: argument)), px > 0 else {
                    throw CLIError("invalid --vote-px")
                }
                options.params.votePx = px
            case "--small-face-min-cos":
                options.params.smallFaceMinCos = try doubleValue(after: argument)
            default:
                throw CLIError("unknown argument: \(argument)")
            }
            index += 1
        }
        guard !options.gallery.isEmpty else { throw CLIError("--gallery is required") }
        guard !options.corpus.isEmpty else { throw CLIError("--corpus is required") }
        guard options.params.samplingFPS > 0 else { throw CLIError("--fps must be > 0") }
        return options
    }

    private struct CLIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
