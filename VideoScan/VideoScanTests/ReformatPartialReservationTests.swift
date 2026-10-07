import Testing
import Foundation
@testable import VideoScan

// MARK: - ReformatPartialReservationTests (N1014-F1, 2026-10-07)
//
// Reformat's partial used to be `<stem>.vs.hevc.<YYYYMMDD-HHMMSS>.vs-partial.mp4`
// — built from the source STEM and a one-second timestamp, never reserved,
// and cleared with an unconditional `removeItem` before every encode. Two
// batch jobs on `a.avi` and `a.mov` (same folder, same second) therefore
// shared ONE partial path: job B's start unlinked the file job A's ffmpeg
// was writing, and either job's cleanup could delete the other's work.
//
// The contract pinned here: each run reserves its own `<…>.<8 hex>.vs-partial.mp4`
// (O_EXCL, registered live — DerivativeOutputPublish.reservePartial, the
// publisher Transcode/Combine use) and removes only that file through
// PartialFileNaming.remove.
//
// Fixtures: two tiny `test_` placeholder sources (the fake ffmpeg never
// reads them) and a pass-through fake ffmpeg that only intercepts this
// suite's names. VS_FFMPEG_PATH is process-global, so the suite is
// serialized and every other call goes to the real ffmpeg.

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct ReformatPartialReservationTests {

    static let stem = "test_rfres_tape"

    /// Fake ffmpeg: for this suite's sources it logs the output path it was
    /// given, writes the INPUT path into it (so the file says whose it is),
    /// then waits for `<input>.go` and exits 1 (a failed encode → the job
    /// cleans up its partial). Everything else runs the real ffmpeg.
    static func fakeFFmpeg(in dir: URL, log: URL, real: String) throws -> URL {
        let url = dir.appendingPathComponent("ffmpeg")
        let script = """
        #!/bin/sh
        case "$*" in *\(stem)*) ;; *) exec "\(real)" "$@" ;; esac
        for out; do :; done
        in=""; prev=""
        for a; do [ "$prev" = "-i" ] && in="$a"; prev="$a"; done
        printf '%s' "$in" > "$out"
        echo "$out" >> "\(log.path)"
        n=0
        while [ ! -f "$in.go" ] && [ $n -lt 600 ]; do sleep 0.05; n=$((n+1)); done
        echo "test_rfres: released" >&2
        exit 1
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func record(_ path: URL) -> VideoRecord {
        let r = VideoRecord()
        r.filename = path.lastPathComponent
        r.fullPath = path.path
        r.directory = path.deletingLastPathComponent().path
        r.ext = path.pathExtension.lowercased()
        r.durationSeconds = 10
        return r
    }

    static func loggedPaths(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Poll (yielding the main actor) until `count` partial paths are logged.
    static func waitForLog(_ log: URL, count: Int) async throws -> [String] {
        for _ in 0..<400 {
            let lines = loggedPaths(log)
            if lines.count >= count { return lines }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("fake ffmpeg logged \(loggedPaths(log).count) of \(count) runs")
        return loggedPaths(log)
    }

    /// Two jobs whose sources share a stem, built in the same second, so
    /// their OUTPUT names are identical — the batch shape from the review.
    static func sameSecondJobs(_ a: VideoRecord, _ b: VideoRecord,
                               model: VideoScanModel) throws -> (ReformatJob, ReformatJob) {
        for _ in 0..<5 {
            let jobA = ReformatJob(record: a, model: model, orchestrator: nil)
            let jobB = ReformatJob(record: b, model: model, orchestrator: nil)
            if jobA.outputURL == jobB.outputURL { return (jobA, jobB) }
        }
        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey:
            "could not build two jobs in the same second"])
    }

    @Test("two same-stem Reformat jobs never share a partial; one job's cleanup never removes the other's file")
    func sameStemJobsNeverShareOrDeleteAPartial() async throws {
        let real = ToolLocator.ffmpegPath
        try #require(FileManager.default.isExecutableFile(atPath: real), "ffmpeg is a required dependency")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_rfres_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let log = tools.appendingPathComponent("partials.log")
        let fake = try Self.fakeFFmpeg(in: tools, log: log, real: real)

        let srcA = dir.appendingPathComponent("\(Self.stem).avi")
        let srcB = dir.appendingPathComponent("\(Self.stem).mov")
        try Data("test_ placeholder A".utf8).write(to: srcA)
        try Data("test_ placeholder B".utf8).write(to: srcB)
        let recA = Self.record(srcA)
        let recB = Self.record(srcB)
        let model = VideoScanModel()
        model.records = [recA, recB]

        setenv(ToolLocator.ffmpegEnvVar, fake.path, 1)
        defer { unsetenv(ToolLocator.ffmpegEnvVar) }

        let (jobA, jobB) = try Self.sameSecondJobs(recA, recB, model: model)
        // Release both fakes whatever happens, so no test run leaves them waiting.
        defer {
            FileManager.default.createFile(atPath: srcA.path + ".go", contents: nil)
            FileManager.default.createFile(atPath: srcB.path + ".go", contents: nil)
        }

        jobA.start()
        let afterA = try await Self.waitForLog(log, count: 1)
        jobB.start()
        let afterB = try await Self.waitForLog(log, count: 2)
        try #require(afterA.count >= 1 && afterB.count >= 2)
        let partialA = afterB[0]
        let partialB = afterB[1]

        #expect(partialA != partialB, "both jobs were handed the same partial: \(partialA)")
        #expect(PartialFileNaming.isPartialName((partialA as NSString).lastPathComponent),
                "Reformat's partial must be a reserved `<…>.<8 hex>.vs-partial.<ext>` name: \(partialA)")

        // B fails and cleans up. A is still encoding: its file must survive.
        FileManager.default.createFile(atPath: srcB.path + ".go", contents: nil)
        await jobB.task?.value
        #expect(FileManager.default.fileExists(atPath: partialA),
                "job B's cleanup removed job A's in-flight partial")
        #expect((try? String(contentsOfFile: partialA, encoding: .utf8)) == srcA.path,
                "job A's partial now holds another job's bytes")

        FileManager.default.createFile(atPath: srcA.path + ".go", contents: nil)
        await jobA.task?.value
        if case .failed = jobA.state {} else { Issue.record("job A: \(jobA.state)") }
        if case .failed = jobB.state {} else { Issue.record("job B: \(jobB.state)") }

        let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.contains("vs-partial") }
        #expect(left.isEmpty, "each job removes its own partial: \(left)")
        #expect(!PartialFileNaming.isLive(URL(fileURLWithPath: partialA)), "A's reservation released")
        #expect(!PartialFileNaming.isLive(URL(fileURLWithPath: partialB)), "B's reservation released")
        #expect(!FileManager.default.fileExists(atPath: jobA.outputURL.path), "a failed encode publishes nothing")
    }

    /// Sensor: Reformat goes through the shared partial publishers and has
    /// no unguarded removal of a computed partial name left anywhere.
    @Test("sensor: ReformatJob reserves and removes partials only through the shared publishers")
    func reformatUsesSharedPartialPublishers() throws {
        let text = try SourceTree.appSource(named: "ReformatJob.swift")
        #expect(text.contains("DerivativeOutputPublish.reservePartial(for: outputURL)"))
        #expect(text.contains("PartialFileNaming.remove("))
        #expect(text.contains("DerivativeOutputPublish.keepUnpublished("),
                "a finished encode that cannot be published is kept, not left at a sweepable name")
        #expect(!text.contains("removeItem(atPath: partialPath)"),
                "an unconditional removeItem on a partial path can delete another job's file")
        #expect(!text.contains("Self.partialURL(for: outputURL)"),
                "the fixed, shared partial name must not be used by Reformat itself")
    }
}
