import Foundation
import Testing
@testable import VideoScan

/// Opt-in decoder lifecycle/throughput stress for the native recipe scorer.
/// Enable with VIDEOSCAN_NATIVE_RECIPE_STRESS=1 or the marker file below.
/// The default 100 scans are synthetic-fixture repetitions, not 100 distinct
/// family videos; this catches reader leaks, intermittent decode failures,
/// and gross throughput regressions without putting private media in Git.
@Suite(.serialized, .timeLimit(.minutes(6)))
struct NativeRecipeMediaStressTests {
    private static let marker = "/tmp/vs-codex-stress/native-recipe-stress-enabled"
    private static let configPath = "/tmp/vs-codex-stress/native-recipe-stress.conf"

    @Test("native recipe decoder survives 100 mixed-container scans")
    func mixedContainerStress() async throws {
        guard Self.isEnabled else { return }
        let names = [
            "test_video_audio.mp4",
            "test_video_audio.mov",
            "test_video_audio.mkv",
            "test_ffv1_pcm_4s.mkv",
            "test_video_audio.mxf",
            "test_video_only.mxf",
        ]
        let count = max(Int(Self.setting("VIDEOSCAN_NATIVE_RECIPE_STRESS_COUNT")
                            ?? "") ?? 100, 1)
        let root = URL(fileURLWithPath: testFixturesDir(), isDirectory: true)
        let scorer = NativeRecipeScorer(
            testEmbedder: { _, _ in [1, 0] },
            centroids: [RecipeEraCentroid(era: "synthetic", centroid: [1, 0])]
        )

        let start = Date()
        var totalFrames = 0
        var totalBytes: Int64 = 0
        for index in 0..<count {
            let name = names[index % names.count]
            let url = root.appendingPathComponent(name)
            print("[native-recipe-stress] starting scan \(index + 1)/\(count): \(name)")
            let result = await scorer.score(clip: url)
            guard result.error == nil, result.frameCount > 0 else {
                let detail = result.error ?? "zero frames"
                throw NativeRecipeStressFailure(
                    "scan \(index + 1)/\(count) \(name): \(detail)")
            }
            totalFrames += result.frameCount
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            totalBytes += Int64(values.fileSize ?? 0)
        }
        let elapsed = max(Date().timeIntervalSince(start), 0.001)
        let filesPerSecond = Double(count) / elapsed
        let megabytesPerSecond = (Double(totalBytes) / 1_000_000) / elapsed
        let framesPerSecond = Double(totalFrames) / elapsed
        print(String(format:
            "[native-recipe-stress] scans=%d frames=%d bytes=%lld elapsed=%.3fs files/s=%.2f MB/s=%.2f sampled-frames/s=%.2f",
            count, totalFrames, totalBytes, elapsed, filesPerSecond,
            megabytesPerSecond, framesPerSecond))
        #expect(totalFrames >= count)

        let budget = max(Double(Self.setting(
            "VIDEOSCAN_NATIVE_RECIPE_STRESS_BUDGET_SECONDS") ?? "") ?? 300, 1)
        #expect(elapsed <= budget,
                "native recipe stress took \(elapsed)s; budget is \(budget)s")
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["VIDEOSCAN_NATIVE_RECIPE_STRESS"] == "1"
            || FileManager.default.fileExists(atPath: marker)
            || FileManager.default.fileExists(atPath: configPath)
    }

    private static func setting(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key] { return value }
        guard let text = try? String(contentsOfFile: configPath,
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

private struct NativeRecipeStressFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
