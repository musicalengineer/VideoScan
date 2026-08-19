import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized)
struct AdversarialCoreStressTests {
    private static let configDir = URL(fileURLWithPath: "/tmp/vs-codex-stress", isDirectory: true)

    private static var stressEnabled: Bool {
        if ProcessInfo.processInfo.environment["VIDEOSCAN_STRESS"] == "1" { return true }
        return FileManager.default.fileExists(atPath: configDir.appendingPathComponent("enabled").path)
    }

    private static var iterations: Int {
        let raw = configuredValue("iterations", env: "VIDEOSCAN_STRESS_ITERATIONS", default: "24")
        return max(Int(raw) ?? 24, 5)
    }

    private static var parallelism: Int {
        let raw = configuredValue("parallelism", env: "VIDEOSCAN_STRESS_PARALLELISM", default: "6")
        return max(Int(raw) ?? 6, 1)
    }

    private static var timeoutSeconds: Double {
        let raw = configuredValue("timeout", env: "VIDEOSCAN_STRESS_TIMEOUT", default: "90")
        return max(Double(raw) ?? 90, 5)
    }

    @Test func mixedCatalogProcessAndModelLoadWorkloadsReachTerminalState() async throws {
        guard Self.stressEnabled else { return }

        let iterations = Self.iterations
        let parallelism = Self.parallelism
        let telemetry = StressTelemetry()

        try await Self.withTimeout(seconds: Self.timeoutSeconds) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for worker in 0..<parallelism {
                    group.addTask {
                        for iteration in 0..<iterations {
                            switch (worker + iteration) % 5 {
                            case 0:
                                try Self.runDuplicateAnalysis(worker: worker, iteration: iteration)
                                await telemetry.recordDuplicatePass()
                            case 1:
                                try Self.runCorrelationAssignment(worker: worker, iteration: iteration)
                                await telemetry.recordCorrelationPass()
                            case 2:
                                try await Self.runSubprocessFlood(worker: worker, iteration: iteration)
                                await telemetry.recordProcessPass()
                            case 3:
                                try Self.runCatalogSnapshotRoundTrip(worker: worker, iteration: iteration)
                                await telemetry.recordSnapshotPass()
                            default:
                                try await Self.runArcFaceLoaderProbe()
                                await telemetry.recordModelProbePass()
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        let summary = await telemetry.summary
        #expect(summary.duplicates > 0, "Stress run never exercised duplicate analysis")
        #expect(summary.correlations > 0, "Stress run never exercised correlation assignment")
        #expect(summary.processes > 0, "Stress run never exercised subprocess pipe draining")
        #expect(summary.snapshots > 0, "Stress run never exercised catalog snapshot encoding")
        #expect(summary.modelProbes > 0, "Stress run never exercised ArcFace loader probing")
    }

    private static func runDuplicateAnalysis(worker: Int, iteration: Int) throws {
        let records = makeDuplicateStressRecords(worker: worker, iteration: iteration)
        let summary = DuplicateDetector.analyze(records: records)

        guard summary.groups == 16 else {
            throw StressFailure("duplicate groups expected 16, got \(summary.groups)")
        }
        guard summary.extraCopies == 16 else {
            throw StressFailure("duplicate extra copies expected 16, got \(summary.extraCopies)")
        }
        let grouped = records.filter { $0.duplicateGroupID != nil }
        guard grouped.count == 32 else {
            throw StressFailure("duplicate grouped records expected 32, got \(grouped.count)")
        }
    }

    private static func runCorrelationAssignment(worker: Int, iteration: Int) throws {
        let pairs = makeCorrelationStressRecords(worker: worker, iteration: iteration)
        let videos = pairs.filter { $0.streamType == .videoOnly }
        let audios = pairs.filter { $0.streamType == .audioOnly }
        let pools = CorrelationScorer.buildAudioPools(from: audios)
        var candidates: [CorrelationScorer.Candidate] = []

        for video in videos {
            let key = CorrelationScorer.filenameCorrelationKey(video.filename)
            for audio in CorrelationScorer.gatherCandidateAudios(
                for: video,
                vKey: key,
                allAudios: audios,
                byKey: pools.byKey,
                byDir: pools.byDir,
                durationTolerance: 0.25,
                timestampTolerance: 60
            ) {
                if let candidate = CorrelationScorer.scoreCorrelatePair(
                    video: video,
                    audio: audio,
                    vKey: key,
                    durationTolerance: 0.25,
                    timestampTolerance: 60
                ) {
                    candidates.append(candidate)
                }
            }
        }

        var matched = Set<UUID>()
        _ = CorrelationScorer.assignCandidates(candidates, matched: &matched)

        guard matched.count == 40 else {
            throw StressFailure("correlation matched IDs expected 40, got \(matched.count)")
        }
        guard videos.allSatisfy({ $0.pairedWith != nil && $0.pairGroupID != nil }) else {
            throw StressFailure("not every video reached paired terminal state")
        }
        guard audios.allSatisfy({ $0.pairedWith != nil && $0.pairGroupID != nil }) else {
            throw StressFailure("not every audio reached paired terminal state")
        }
    }

    private static func runSubprocessFlood(worker: Int, iteration: Int) async throws {
        let bytes = 64 * 1024
        let result = await ProcessRunner.runProcess(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "/bin/dd if=/dev/zero bs=1024 count=64 2>/dev/null | /usr/bin/tee /dev/stderr"
            ],
            stderrLimitBytes: bytes + 1024
        )

        guard result.exitCode == 0 else {
            throw StressFailure("process \(worker)-\(iteration) exited \(result.exitCode): \(result.stderr)")
        }
        guard result.stdout?.count == bytes else {
            throw StressFailure("process stdout expected \(bytes), got \(result.stdout?.count ?? 0)")
        }
        guard result.stderr.count >= bytes else {
            throw StressFailure("process stderr expected at least \(bytes), got \(result.stderr.count)")
        }
    }

    private static func runCatalogSnapshotRoundTrip(worker: Int, iteration: Int) throws {
        let records = makeCorrelationStressRecords(worker: worker, iteration: iteration)
        let snapshot = CatalogSnapshot(records: records, savedFromHost: "stress-\(worker)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try CatalogSnapshotDTO(snapshot).encoded(using: encoder)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CatalogSnapshot.self, from: data)

        guard decoded.records.count == records.count else {
            throw StressFailure("snapshot record count expected \(records.count), got \(decoded.records.count)")
        }
        guard decoded.savedFromHost == "stress-\(worker)" else {
            throw StressFailure("snapshot host tag did not round-trip")
        }
    }

    private static func runArcFaceLoaderProbe() async throws {
        let (first, firstError) = await ArcFaceModelLoader.shared.getModel()
        let (second, secondError) = await ArcFaceModelLoader.shared.getModel()

        if let first, let second {
            guard first !== second else {
                throw StressFailure("ArcFaceModelLoader returned the same MLModel instance twice")
            }
        } else if firstError == nil && secondError == nil {
            // Model absent on this machine is an acceptable terminal state.
            return
        }
    }

    private static func makeDuplicateStressRecords(worker: Int, iteration: Int) -> [VideoRecord] {
        var records: [VideoRecord] = []
        for group in 0..<16 {
            let base = "stress_dup_w\(worker)_i\(iteration)_g\(group)"
            records.append(makeDuplicateRecord(
                filename: "\(base).mov",
                streamType: .videoAndAudio,
                sizeBytes: Int64(10_000_000 + group),
                durationSeconds: 42.0 + Double(group),
                partialMD5: "hash-\(worker)-\(iteration)-\(group)",
                resolution: "1920x1080",
                videoCodec: "h264",
                audioCodec: "aac",
                timecode: "01:00:\(String(format: "%02d", group)):00"
            ))
            records.append(makeDuplicateRecord(
                filename: "\(base)_copy.mov",
                streamType: .videoAndAudio,
                sizeBytes: Int64(10_000_000 + group),
                durationSeconds: 42.0 + Double(group),
                partialMD5: "hash-\(worker)-\(iteration)-\(group)",
                resolution: "1920x1080",
                videoCodec: "h264",
                audioCodec: "aac",
                timecode: "01:00:\(String(format: "%02d", group)):00"
            ))
        }
        return records
    }

    private static func makeCorrelationStressRecords(worker: Int, iteration: Int) -> [VideoRecord] {
        var records: [VideoRecord] = []
        let baseDate = Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + worker * 10_000 + iteration * 100))
        for pair in 0..<20 {
            let clipID = String(format: "%06X", worker * 10_000 + iteration * 100 + pair)
            let directory = "/Volumes/Stress/Reel\(pair % 4)"
            let duration = 30.0 + Double(pair)

            let video = VideoRecord()
            video.filename = "00001.V\(clipID).mxf"
            video.directory = directory
            video.fullPath = "\(directory)/\(video.filename)"
            video.streamTypeRaw = StreamType.videoOnly.rawValue
            video.durationSeconds = duration
            video.dateCreatedRaw = baseDate.addingTimeInterval(Double(pair))
            video.timecode = "02:00:\(String(format: "%02d", pair)):00"
            video.tapeName = "TAPE-\(pair % 3)"
            records.append(video)

            let audio = VideoRecord()
            audio.filename = "00001.A\(clipID).mxf"
            audio.directory = directory
            audio.fullPath = "\(directory)/\(audio.filename)"
            audio.streamTypeRaw = StreamType.audioOnly.rawValue
            audio.durationSeconds = duration
            audio.dateCreatedRaw = baseDate.addingTimeInterval(Double(pair))
            audio.timecode = video.timecode
            audio.tapeName = video.tapeName
            records.append(audio)
        }
        return records
    }

    private static func withTimeout(seconds: Double, operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw StressFailure("stress test timed out after \(seconds)s")
            }

            try await group.next()
            group.cancelAll()
        }
    }

    private static func configuredValue(_ filename: String, env: String, default defaultValue: String) -> String {
        if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty {
            return value
        }
        let path = configDir.appendingPathComponent(filename).path
        if let value = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }
        return defaultValue
    }
}

private actor StressTelemetry {
    private var duplicatePasses = 0
    private var correlationPasses = 0
    private var processPasses = 0
    private var snapshotPasses = 0
    private var modelProbePasses = 0

    func recordDuplicatePass() { duplicatePasses += 1 }
    func recordCorrelationPass() { correlationPasses += 1 }
    func recordProcessPass() { processPasses += 1 }
    func recordSnapshotPass() { snapshotPasses += 1 }
    func recordModelProbePass() { modelProbePasses += 1 }

    var summary: (duplicates: Int, correlations: Int, processes: Int, snapshots: Int, modelProbes: Int) {
        (duplicatePasses, correlationPasses, processPasses, snapshotPasses, modelProbePasses)
    }
}

private struct StressFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
