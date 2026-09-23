import Foundation
import Darwin
import Testing
@testable import VideoScan

/// Opt-in, real preparation work. Run alone in Release on a routed test Mac.
/// Staging is an EXTERNAL input-prefetch experiment, not a shipped RAM feature.
/// Each input gets one production job so RAM residency is bounded to one file.
@Suite("Archive Angel — opt-in 100-file benchmark", .serialized)
struct ArchiveAngelBenchmarkTests {
    struct Input: Codable, Sendable {
        var path: String
        var sha256: String
        var durationSeconds: Double
        var videoCodec: String
        var audioCodec: String
        var streamType: String
    }

    struct Configuration: Codable, Sendable {
        var schemaVersion: Int
        var runID: String
        var mode: String
        var outputRoot: String
        var stagingRoot: String?
        var makeLossless: Bool
        var files: [Input]

        func validate() throws {
            guard schemaVersion == 1, files.count == 100,
                  Set(files.map(\.path)).count == 100,
                  ["direct", "ssd-staged", "ram-staged"].contains(mode),
                  !runID.isEmpty, runID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  outputRoot.hasPrefix("/"),
                  mode == "direct" || stagingRoot?.hasPrefix("/") == true,
                  files.allSatisfy({ $0.path.hasPrefix("/") && $0.sha256.count == 64 &&
                      $0.sha256.allSatisfy(\.isHexDigit) && $0.durationSeconds >= 8 &&
                      ["videoOnly", "videoAndAudio"].contains($0.streamType) }) else {
                throw BenchmarkError.invalidConfiguration
            }
        }
    }

    struct Result: Codable {
        var index: Int
        var path: String
        var success = false
        var failure: String?
        var copySeconds: Double = 0
        var prepareSeconds: Double = 0
        var endToEndSeconds: Double = 0
        var sourceUnchanged = false
        /// Process lifetime high-water mark, not whole-machine or ffmpeg RSS.
        var testHostPeakRSSBytes: Int64?
        var plan: ArchiveAngelPlan?
    }

    struct Report: Encodable {
        var schemaVersion = 1
        var runID: String
        var mode: String
        var requested = 100
        var results: [Result] = []
        var completed: Int { results.count }
        var passed: Int { results.filter(\.success).count }
        var failed: Int { completed - passed }
        var incomplete: Int { requested - completed }

        enum CodingKeys: String, CodingKey {
            case schemaVersion, runID, mode, requested, results, completed, passed, failed, incomplete
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schemaVersion, forKey: .schemaVersion)
            try c.encode(runID, forKey: .runID)
            try c.encode(mode, forKey: .mode)
            try c.encode(requested, forKey: .requested)
            try c.encode(results, forKey: .results)
            try c.encode(completed, forKey: .completed)
            try c.encode(passed, forKey: .passed)
            try c.encode(failed, forKey: .failed)
            try c.encode(incomplete, forKey: .incomplete)
        }
    }

    enum BenchmarkError: Error { case invalidConfiguration, occupiedDestination, inputChanged, preparationFailed }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func digest(_ path: String) async throws -> String {
        try await Task.detached {
            try CatalogStore.sha256HexStreaming(fileURL: URL(fileURLWithPath: path))
        }.value
    }

    @Test("100 real production preparations; no original-only false green",
          .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_ANGEL_BENCHMARK_MANIFEST"] != nil))
    @MainActor
    func preparePinnedCorpus() async throws {
        let manifest = try #require(ProcessInfo.processInfo.environment["VIDEOSCAN_ANGEL_BENCHMARK_MANIFEST"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
        try config.validate()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: config.outputRoot).appendingPathComponent("test_angel_" + config.runID)
        guard !fm.fileExists(atPath: root.path) else { throw BenchmarkError.occupiedDestination }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = config.stagingRoot.map { URL(fileURLWithPath: $0).appendingPathComponent("test_angel_" + config.runID) }
        if let staging, config.mode != "direct" {
            guard !fm.fileExists(atPath: staging.path) else { throw BenchmarkError.occupiedDestination }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        let reportURL = root.appendingPathComponent("summary.json")
        var report = Report(runID: config.runID, mode: config.mode)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)

        for (index, input) in config.files.enumerated() {
            var result = Result(index: index, path: input.path)
            do {
                // The harness pins SHA before the run. Do not pre-read here:
                // that would warm the direct input and bias the comparison.
                // OS cache residency remains uncontrolled, not "cold disk".
                let beforeAttributes = try fm.attributesOfItem(atPath: input.path)
                let entryRoot = root.appendingPathComponent(String(format: "%03d", index))
                let sandbox = MasterArchiveTestSupport.Sandbox(root: entryRoot,
                    sources: entryRoot.appendingPathComponent("Sources"), archiveVolume: entryRoot.appendingPathComponent("Archive"))
                try fm.createDirectory(at: sandbox.archiveVolume, withIntermediateDirectories: true)
                let model = MasterArchiveTestSupport.makeModel(sandbox)
                model.scanTargets = []
                model.previewSweep.stop()
                model.archiveAngel.sweep.stop()
                // Assign only the isolated designation; initializeMasterArchive
                // also persists scan-target preferences, unwanted in a benchmark.
                model.masterArchive = MasterArchiveDesignation(targetPath: sandbox.archiveVolume.path,
                    rootPath: sandbox.archiveRoot.path, volumeUUID: nil)
                let center = MediaFileOperationsCenter()
                let clock = ContinuousClock()
                let started = clock.now
                var preparedPath = input.path
                var stagedURL: URL?
                if config.mode != "direct", let staging {
                    let destination = staging.appendingPathComponent("\(index)_" + URL(fileURLWithPath: input.path).lastPathComponent)
                    let copyStarted = clock.now
                    try await Task.detached {
                        try FileManager.default.copyItem(at: URL(fileURLWithPath: input.path), to: destination)
                    }.value
                    result.copySeconds = Self.seconds(clock.now - copyStarted)
                    stagedURL = destination
                    preparedPath = destination.path
                }
                let record = MasterArchiveTestSupport.makeRecord(path: preparedPath,
                    streamType: input.streamType == "videoOnly" ? .videoOnly : .videoAndAudio, starRating: 2)
                record.durationSeconds = input.durationSeconds
                record.videoCodec = input.videoCodec
                record.audioCodec = input.audioCodec
                record.isPlayable = "Yes"
                model.records = [record]
                let buffer = entryRoot.appendingPathComponent("Buffer")
                try fm.createDirectory(at: buffer, withIntermediateDirectories: true)
                let job = ArchiveAngelJob(model: model, center: center, count: 1,
                    makeLossless: config.makeLossless, bufferRoot: buffer)
                let prepareStarted = clock.now
                job.start()
                await job.task?.value
                result.prepareSeconds = Self.seconds(clock.now - prepareStarted)
                result.endToEndSeconds = Self.seconds(clock.now - started)
                result.plan = job.plan
                let after = try await Self.digest(input.path)
                let afterAttributes = try fm.attributesOfItem(atPath: input.path)
                result.sourceUnchanged = input.sha256.lowercased() == after.lowercased() &&
                    (beforeAttributes[.modificationDate] as? Date) == (afterAttributes[.modificationDate] as? Date)
                guard result.sourceUnchanged else { throw BenchmarkError.inputChanged }
                guard job.plan.entries.count == 1, let entry = job.plan.entries.first,
                      entry.status == .ready, entry.step(.accessCopy).state == .done,
                      !entry.steps.contains(where: { $0.state == .failed || $0.state == .pending }),
                      !entry.isOriginalOnly else { throw BenchmarkError.preparationFailed }
                for output in entry.companionsMade {
                    let relative = try #require(output.outputRelPath)
                    let url = URL(fileURLWithPath: job.plan.batchDir).appendingPathComponent(relative)
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    guard ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0 else { throw BenchmarkError.preparationFailed }
                }
                // Only our exact per-entry copy is removed; failed copies and
                // all durable plans/companions remain available for diagnosis.
                if let stagedURL { try fm.removeItem(at: stagedURL) }
                result.success = true
            } catch {
                result.failure = String(describing: error)
            }
            var usage = rusage()
            if getrusage(RUSAGE_SELF, &usage) == 0 {
                result.testHostPeakRSSBytes = Int64(usage.ru_maxrss)
            }
            report.results.append(result)
            try encoder.encode(report).write(to: reportURL, options: .atomic)
            #expect(result.success, "Archive Angel benchmark input \(index): \(result.failure ?? "unknown")")
            // Stop staged runs on failure rather than accumulate RAM inputs.
            if !result.success && config.mode != "direct" { break }
        }
        #expect(report.completed == 100)
        #expect(report.passed == 100)
        #expect(report.incomplete == 0)
    }

    @Test("incomplete and failed benchmark runs cannot report 100 passes")
    func reportAccounting() throws {
        var report = Report(runID: "accounting", mode: "direct")
        report.results = [Result(index: 0, path: "test_a", success: true), Result(index: 1, path: "test_b")]
        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["passed"] as? Int == 1)
        #expect(json["failed"] as? Int == 1)
        #expect(json["incomplete"] as? Int == 98)
    }

    @Test("benchmark refuses undersized, duplicate, or unpinned corpora")
    func configurationGuards() throws {
        let inputs = (0..<100).map { index in
            Input(path: "/tmp/test_\(index).mov", sha256: String(repeating: "a", count: 64),
                  durationSeconds: 10, videoCodec: "h264", audioCodec: "aac", streamType: "videoAndAudio")
        }
        var config = Configuration(schemaVersion: 1, runID: "guard-test", mode: "direct",
            outputRoot: "/tmp/test_output", makeLossless: false, files: inputs)
        try config.validate()
        config.files.removeLast()
        #expect(throws: BenchmarkError.self) { try config.validate() }
        config.files = inputs
        config.files[99] = inputs[0]
        #expect(throws: BenchmarkError.self) { try config.validate() }
        config.files = inputs
        config.files[0].sha256 = "not-pinned"
        #expect(throws: BenchmarkError.self) { try config.validate() }
        config.files = inputs
        config.mode = "ram-staged"
        #expect(throws: BenchmarkError.self) { try config.validate() }
    }
}
