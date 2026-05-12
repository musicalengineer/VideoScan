import Foundation
import Testing
@testable import VideoScan

@Suite("ArcFace Parallel Search Crash Reproducer")
struct ArcFaceParallelSearchReproducerTests {
    private static let markerPath = "/tmp/vs-codex-stress/arcface-parallel-repro-enabled"
    private static let configPath = "/tmp/vs-codex-stress/arcface-parallel-repro.conf"

    @Test("overlapping real ArcFace jobs reach terminal states")
    @MainActor
    func overlappingRealArcFaceJobsReachTerminalStates() async throws {
        guard Self.isEnabled else { return }

        let (probe, probeError) = await ArcFaceModelLoader.shared.getModel()
        guard probe != nil else {
            Issue.record("ArcFace model unavailable: \(probeError ?? "unknown")")
            return
        }

        let specs = try Self.resolveJobSpecs()
        let model = PersonFinderModel()
        model.settings.recognitionEngine = .arcface
        model.settings.concurrency = Self.intSetting("VIDEOSCAN_ARCFACE_REPRO_CONCURRENCY", defaultValue: 12)
        model.settings.frameStep = Self.intSetting("VIDEOSCAN_ARCFACE_REPRO_FRAME_STEP", defaultValue: 5)
        model.settings.minPresenceSecs = 0
        model.settings.previewRate = 25
        model.settings.arcfaceThreshold = 0.40137

        var jobs: [ScanJob] = []
        for spec in specs {
            let job = ScanJob(searchPath: spec.searchPath)
            job.assignedProfile = spec.profile
            job.assignedEngine = .arcface
            model.jobs.append(job)
            await model.loadFacesForJob(job)
            guard !job.assignedFaces.isEmpty else {
                throw ReproducerFailure("profile \(spec.profile.name) loaded no reference faces from \(spec.profile.referencePath)")
            }
            jobs.append(job)
        }

        for job in jobs {
            model.startJob(job)
            try await Task.sleep(for: .milliseconds(Self.intSetting("VIDEOSCAN_ARCFACE_REPRO_START_STAGGER_MS", defaultValue: 250)))
        }

        let deadline = Date().addingTimeInterval(Self.doubleSetting("VIDEOSCAN_ARCFACE_REPRO_TIMEOUT", defaultValue: 300))
        while Date() < deadline {
            if jobs.allSatisfy({ $0.status.isTerminal }) { break }
            try await Task.sleep(for: .milliseconds(500))
        }

        let unfinished = jobs.filter { !$0.status.isTerminal }
        if !unfinished.isEmpty {
            for job in unfinished { model.stopJob(job) }
            let summary = unfinished
                .map { "\($0.assignedProfile?.name ?? "(unknown)"):\($0.status.label) scanned \($0.videosScanned)/\($0.videosTotal)" }
                .joined(separator: ", ")
            throw ReproducerFailure("ArcFace parallel repro timed out with unfinished jobs: \(summary)")
        }

        let failures = jobs.filter {
            if case .failed = $0.status { return true }
            return $0.status == .cancelled
        }
        if !failures.isEmpty {
            let summary = failures
                .map { "\($0.assignedProfile?.name ?? "(unknown)"):\($0.status.label) scanned \($0.videosScanned)/\($0.videosTotal)" }
                .joined(separator: ", ")
            throw ReproducerFailure("ArcFace parallel repro ended with failed/cancelled jobs: \(summary)")
        }

        let scanned = jobs.map(\.videosScanned).reduce(0, +)
        #expect(scanned > 0, "ArcFace parallel repro completed without scanning any videos")
    }

    private static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["VIDEOSCAN_ARCFACE_PARALLEL_REPRO"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
            || FileManager.default.fileExists(atPath: configPath)
    }

    private static func resolveJobSpecs() throws -> [JobSpec] {
        if let raw = stringSetting("VIDEOSCAN_ARCFACE_REPRO_JOBS"),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let specs = try raw.split(separator: ";").map { try parseJobSpec(String($0)) }
            guard !specs.isEmpty else {
                throw ReproducerFailure("VIDEOSCAN_ARCFACE_REPRO_JOBS must define at least one job")
            }
            return specs
        }

        let profiles = POIProfile.listAll()
        let preferredNames = ["Donna", "Ma"]
        let searchPath = stringSetting("VIDEOSCAN_ARCFACE_REPRO_SEARCH_PATH") ?? "/Users/rickb/Movies"
        guard FileManager.default.fileExists(atPath: searchPath) else {
            throw ReproducerFailure("default search path does not exist: \(searchPath)")
        }

        let selected = preferredNames.compactMap { name in
            profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard selected.count >= 2 else {
            throw ReproducerFailure("expected POI profiles Donna and Ma in Application Support/VideoScan/POI")
        }

        return selected.map { profile in
            JobSpec(profile: stressProfile(from: profile), searchPath: searchPath)
        }
    }

    private static func parseJobSpec(_ raw: String) throws -> JobSpec {
        let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ReproducerFailure("job spec must be Name=/path, got \(raw)")
        }
        let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let path = NSString(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw ReproducerFailure("search path does not exist for \(name): \(path)")
        }
        guard let profile = POIProfile.listAll().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ReproducerFailure("POI profile not found: \(name)")
        }
        return JobSpec(profile: stressProfile(from: profile), searchPath: path)
    }

    private static func stressProfile(from profile: POIProfile) -> POIProfile {
        let runID = stringSetting("VIDEOSCAN_ARCFACE_REPRO_RUN_ID") ?? "manual"
        POIProfile(
            name: "\(profile.name)-arcface-repro-\(runID)-\(UUID().uuidString.prefix(8))",
            referencePath: profile.referencePath,
            rejectedFiles: profile.rejectedFiles,
            engine: RecognitionEngine.arcface.rawValue,
            visionThreshold: profile.visionThreshold,
            arcfaceThreshold: 0.40137,
            minFaceConfidence: profile.minFaceConfidence,
            largestFaceOnly: profile.largestFaceOnly,
            coverImageFilename: profile.coverImageFilename,
            notes: profile.notes,
            aliases: profile.aliases,
            coverCropOffsetX: profile.coverCropOffsetX,
            coverCropOffsetY: profile.coverCropOffsetY,
            coverCropScale: profile.coverCropScale,
            sortOrder: profile.sortOrder
        )
    }

    private static func stringSetting(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }
        return config[key]
    }

    private static func intSetting(_ key: String, defaultValue: Int) -> Int {
        Int(stringSetting(key) ?? "") ?? defaultValue
    }

    private static func doubleSetting(_ key: String, defaultValue: Double) -> Double {
        Double(stringSetting(key) ?? "") ?? defaultValue
    }

    private static var config: [String: String] {
        guard let contents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return [:]
        }
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .reduce(into: [:]) { result, line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }
    }

    private struct JobSpec {
        var profile: POIProfile
        var searchPath: String
    }

    private struct ReproducerFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
