import Foundation
import Testing
@testable import VideoScan

@Suite(.serialized)
struct FixtureMediaStressTests {
    private static let configDir = URL(fileURLWithPath: "/tmp/vs-codex-stress", isDirectory: true)
    private static let markerPath = "/tmp/vs-codex-stress/fixture-media-stress-enabled"
    private static let configPath = "/tmp/vs-codex-stress/fixture-media-stress.conf"

    @Test("fixture media searches scale through concurrent people and engines")
    @MainActor
    func fixtureMediaSearchesScaleThroughConcurrentPeopleAndEngines() async throws {
        guard Self.isEnabled else { return }

        let fixtures = try Self.fixtureVideos()
        let stageRoot = try Self.stageFixtureVideos(fixtures)
        defer { try? FileManager.default.removeItem(at: stageRoot) }

        let profiles = try Self.resolveProfiles()
        let engines = try Self.resolveEngines()
        let maxSearches = Self.intSetting("VIDEOSCAN_FIXTURE_STRESS_MAX_SEARCHES", defaultValue: 6)
        let timeoutSeconds = Self.doubleSetting("VIDEOSCAN_FIXTURE_STRESS_TIMEOUT", defaultValue: 180)
        let concurrency = Self.intSetting("VIDEOSCAN_FIXTURE_STRESS_CONCURRENCY", defaultValue: 12)
        let frameStep = Self.intSetting("VIDEOSCAN_FIXTURE_STRESS_FRAME_STEP", defaultValue: 5)
        let staggerMS = Self.intSetting("VIDEOSCAN_FIXTURE_STRESS_START_STAGGER_MS", defaultValue: 25)

        for searchCount in 1...maxSearches {
            let model = PersonFinderModel()
            model.settings.concurrency = concurrency
            model.settings.frameStep = frameStep
            model.settings.minPresenceSecs = 0
            model.settings.previewRate = 25

            var jobs: [ScanJob] = []
            for index in 0..<searchCount {
                let profile = profiles[index % profiles.count]
                let engine = engines[index % engines.count]
                let job = ScanJob(searchPath: stageRoot.path)
                job.assignedProfile = Self.stressProfile(from: profile, index: index)
                job.assignedEngine = engine
                model.jobs.append(job)

                // Every remaining engine consumes loaded reference faces
                // (the dlib subprocess seat that read photos itself was
                // removed in #144).
                await model.loadFacesForJob(job)
                guard !job.assignedFaces.isEmpty else {
                    throw StressFailure("profile \(profile.name) loaded no reference faces from \(profile.referencePath)")
                }
                jobs.append(job)
            }

            print(Self.stageHeader(searchCount: searchCount, jobs: jobs, stageRoot: stageRoot.path))

            for job in jobs {
                model.startJob(job)
                try await Task.sleep(for: .milliseconds(staggerMS))
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline {
                if jobs.allSatisfy({ $0.status.isTerminal }) { break }
                try await Task.sleep(for: .seconds(2))
                print(Self.progressSummary(searchCount: searchCount, jobs: jobs))
            }

            let unfinished = jobs.filter { !$0.status.isTerminal }
            if !unfinished.isEmpty {
                for job in unfinished { model.stopJob(job) }
                throw StressFailure("fixture stress stage \(searchCount) timed out: \(Self.progressSummary(searchCount: searchCount, jobs: unfinished))")
            }

            let failures = jobs.filter {
                if case .failed = $0.status { return true }
                return $0.status == .cancelled
            }
            if !failures.isEmpty {
                throw StressFailure("fixture stress stage \(searchCount) failed: \(Self.progressSummary(searchCount: searchCount, jobs: failures))")
            }

            let scanned = jobs.map(\.videosScanned).reduce(0, +)
            #expect(scanned > 0, "fixture stress stage \(searchCount) completed without scanning videos")
        }
    }

    private static var isEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["VIDEOSCAN_FIXTURE_STRESS"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
            || FileManager.default.fileExists(atPath: configPath)
    }

    private static func fixtureVideos() throws -> [URL] {
        let configured = stringSetting("VIDEOSCAN_FIXTURE_STRESS_FIXTURE_DIR")
            ?? testFixturesDir()
        let fixtureDir = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        let extensions = Set(["mov", "mp4", "m4v", "mkv", "mxf"])
        let videos = try FileManager.default.contentsOfDirectory(
            at: fixtureDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { extensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !videos.isEmpty else {
            throw StressFailure("no fixture videos found in \(fixtureDir.path)")
        }
        return videos
    }

    private static func stageFixtureVideos(_ fixtures: [URL]) throws -> URL {
        let runID = stringSetting("VIDEOSCAN_FIXTURE_STRESS_RUN_ID") ?? UUID().uuidString
        let base = stringSetting("VIDEOSCAN_FIXTURE_STRESS_STAGE_BASE") ?? NSTemporaryDirectory()
        let stageRoot = URL(fileURLWithPath: NSString(string: base).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("videoscan-fixture-stress-\(runID)", isDirectory: true)
        let duplicates = Self.intSetting("VIDEOSCAN_FIXTURE_STRESS_DUPLICATES", defaultValue: 12)
        let mode = stringSetting("VIDEOSCAN_FIXTURE_STRESS_STAGE_MODE") ?? "link"

        let fm = FileManager.default
        try? fm.removeItem(at: stageRoot)
        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)

        for copyIndex in 0..<duplicates {
            for source in fixtures {
                let destination = stageRoot.appendingPathComponent(
                    "\(copyIndex)-\(source.deletingPathExtension().lastPathComponent).\(source.pathExtension)"
                )
                if mode == "copy" {
                    try fm.copyItem(at: source, to: destination)
                } else {
                    do {
                        try fm.linkItem(at: source, to: destination)
                    } catch {
                        try fm.copyItem(at: source, to: destination)
                    }
                }
            }
        }

        return stageRoot
    }

    private static func resolveProfiles() throws -> [POIProfile] {
        let requested = (stringSetting("VIDEOSCAN_FIXTURE_STRESS_PEOPLE") ?? "Donna,Ma")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let all = POIProfile.listAll()
        let profiles = requested.compactMap { name in
            all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard profiles.count == requested.count, !profiles.isEmpty else {
            throw StressFailure("fixture stress expected POI profiles \(requested.joined(separator: ", "))")
        }
        return profiles
    }

    private static func resolveEngines() throws -> [RecognitionEngine] {
        let names = (stringSetting("VIDEOSCAN_FIXTURE_STRESS_ENGINES") ?? "vision,arcface")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let engines = names.compactMap { name -> RecognitionEngine? in
            switch name {
            case "vision": return .vision
            case "arcface": return .arcface
            case "adaface": return .adaface
            case "hybrid": return .hybrid
            default: return nil
            }
        }
        guard engines.count == names.count, !engines.isEmpty else {
            throw StressFailure("fixture stress engines must be vision, arcface, adaface, or hybrid")
        }
        return engines
    }

    private static func stressProfile(from profile: POIProfile, index: Int) -> POIProfile {
        let runID = stringSetting("VIDEOSCAN_FIXTURE_STRESS_RUN_ID") ?? "manual"
        return POIProfile(
            name: "\(profile.name)-fixture-stress-\(runID)-\(index)-\(UUID().uuidString.prefix(6))",
            referencePath: profile.referencePath,
            rejectedFiles: profile.rejectedFiles,
            engine: profile.engine,
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

    @MainActor
    private static func stageHeader(searchCount: Int, jobs: [ScanJob], stageRoot: String) -> String {
        let jobSummary = jobs.map {
            "\($0.assignedProfile?.name ?? "(unknown)")/\($0.assignedEngine?.shortLabel ?? "?")"
        }.joined(separator: ", ")
        return "[fixture-stress] stage \(searchCount): \(jobSummary) on \(stageRoot)"
    }

    @MainActor
    private static func progressSummary(searchCount: Int, jobs: [ScanJob]) -> String {
        let summary = jobs.map {
            "\($0.assignedProfile?.name ?? "(unknown)")/\($0.assignedEngine?.shortLabel ?? "?"):\($0.status.label) \($0.videosScanned)/\($0.videosTotal)"
        }.joined(separator: ", ")
        return "[fixture-stress] stage \(searchCount): \(summary)"
    }

    private static func stringSetting(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key] {
            return value
        }
        return config[key]
    }

    private static func intSetting(_ key: String, defaultValue: Int) -> Int {
        max(Int(stringSetting(key) ?? "") ?? defaultValue, 1)
    }

    private static func doubleSetting(_ key: String, defaultValue: Double) -> Double {
        max(Double(stringSetting(key) ?? "") ?? defaultValue, 1)
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

    private struct StressFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
