// PythonClipWorkerTests.swift — the Swift half of the model watchdog
// (PythonClipWorker.swift), against the REAL bench.py worker loop hosting a
// fake ClipService (tests/fixtures/background/fake_clip_service.py; no model).
//   LOGIC      load names the approach / revision / model from the worker;
//              a clip comes back as the worker's record; the worker's own
//              prints never reach the protocol; peak RSS is the worker's.
//   ISOLATION  a clip past its cap is killed (timeout), the next clip
//              respawns and reloads; a worker that dies mid-clip is `died`
//              with its last words, and the next clip respawns; an exception
//              is a `workerError`, the worker stays up; a load past its cap
//              is a timeout; a load reply with no valid approach id is refused;
//              a missing interpreter is refused in words.
//   SENSOR     rule 13: a `.remoteTextOnly` host is refused by PayloadGate
//              BEFORE any spawn (zero processes started).
// Python: the repo's venv when present, else Homebrew's, else /usr/bin/python3.

import Foundation
import Testing
@testable import VideoScanCore

enum ClipWorkerFixture {
    /// …/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/ModelLab/<this file> → six up is the repo.
    static var repo: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }

    static var python: URL {
        let candidates = [repo.appendingPathComponent("venv/bin/python3").path, "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return URL(fileURLWithPath: candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3")
    }

    static func factory(_ attribute: String = "make_service") -> String {
        "import:\(repo.appendingPathComponent("tests/fixtures/background").path):fake_clip_service:\(attribute)"
    }

    static let descriptor = SeatedApproach.eraA2

    static func configuration(_ attribute: String = "make_service", clipTimeout: Duration = .seconds(20),
                              loadTimeout: Duration = .seconds(30), log: URL? = nil, loadSeconds: Double = 0) -> PythonClipWorker.Configuration {
        var environment = ProcessInfo.processInfo.environment
        if let log { environment["FAKE_CLIP_LOG"] = log.path }
        if loadSeconds > 0 { environment["FAKE_LOAD_SECONDS"] = String(loadSeconds) }
        return PythonClipWorker.Configuration(python: python, script: repo.appendingPathComponent("tools/video-llm-bench/bench.py"),
                                              factory: factory(attribute), loadTimeout: loadTimeout, clipTimeout: clipTimeout,
                                              environment: environment)
    }

    static func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@Suite("PythonClipWorker", .serialized)
struct PythonClipWorkerTests {

    @Test func loadNamesWhatRanAndAClipComesBackAsTheWorkersRecord() async throws {
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(), descriptor: ClipWorkerFixture.descriptor)
        let info = try await worker.load()
        #expect(info.approachID.rawValue == "qwen3-vl-8b-4bit/era-v1/window-60s")
        #expect(info.revision == 3)
        #expect(info.model == "mlx-community/Qwen3-VL-8B-Instruct-4bit")
        #expect(info.signer == "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3")
        let data = try await worker.analyzeClip(path: "/synthetic/stamp.mov", durationS: 120)
        let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((record["window_results"] as? [Any])?.count == 3)
        #expect(((record["summary"] as? [String: Any])?["fused_years"] as? [Int]) == [1991, 1991])
        let rss = await worker.peakRSSBytes()
        #expect((rss ?? 0) > 1_000_000, "the worker's own peak (a Python process is MBs): \(rss ?? 0)")
        #expect(await worker.spawns == 1)
        await worker.close()
        #expect(await worker.workerPID == nil)
    }

    @Test func aClipPastItsCapIsKilledAndTheNextClipRespawnsAndReloads() async throws {
        let log = ClipWorkerFixture.temporaryFile("fake-clip-log")
        defer { try? FileManager.default.removeItem(at: log) }
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(clipTimeout: .seconds(2), log: log),
                                      descriptor: ClipWorkerFixture.descriptor)
        try await worker.load()
        let firstPID = try #require(await worker.workerPID)
        await #expect(throws: PythonClipWorkerError.timeout(method: "analyze_clip", seconds: 2)) {
            _ = try await worker.analyzeClip(path: "/synthetic/hang.mov", durationS: 60)
        }
        #expect(kill(firstPID, 0) != 0, "the hung worker is gone")
        _ = try await worker.analyzeClip(path: "/synthetic/ok.mov", durationS: 60)
        #expect(await worker.spawns == 2)
        #expect(await worker.timeouts == 1)
        #expect(ClipWorkerFixture.lines(log).filter { $0 == "load" }.count == 2, "reloaded after the kill")
        await worker.close()
    }

    @Test func aWorkerThatDiesMidClipIsDiedWithItsLastWordsAndTheNextClipRespawns() async throws {
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(), descriptor: ClipWorkerFixture.descriptor)
        do {
            _ = try await worker.analyzeClip(path: "/synthetic/die.mov", durationS: 60)
            Issue.record("a dying worker answered")
        } catch let error as PythonClipWorkerError {
            guard case .died(let method, let tail) = error else { Issue.record("expected died, got \(error)"); return }
            #expect(method == "analyze_clip")
            #expect(tail.contains("dying on purpose"), "\(tail)")
        }
        _ = try await worker.analyzeClip(path: "/synthetic/ok.mov", durationS: 60)
        #expect(await worker.spawns == 2)
        await worker.close()
    }

    @Test func anExceptionIsAWorkerErrorAndTheWorkerStaysUp() async throws {
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(), descriptor: ClipWorkerFixture.descriptor)
        await #expect(throws: PythonClipWorkerError.workerError(type: "RuntimeError", message: "deliberate")) {
            _ = try await worker.analyzeClip(path: "/synthetic/boom.mov", durationS: 60)
        }
        _ = try await worker.analyzeClip(path: "/synthetic/ok.mov", durationS: 60)
        #expect(await worker.spawns == 1)
        await worker.close()
    }

    @Test func aLoadPastItsCapIsATimeout() async throws {
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(loadTimeout: .seconds(2), loadSeconds: 30),
                                      descriptor: ClipWorkerFixture.descriptor)
        await #expect(throws: PythonClipWorkerError.timeout(method: "load", seconds: 2)) { try await worker.load() }
        #expect(await worker.workerPID == nil)
    }

    @Test func aLoadReplyWithoutAValidApproachIdIsRefused() async throws {
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration("make_wrong_id_service"), descriptor: ClipWorkerFixture.descriptor)
        do {
            try await worker.load()
            Issue.record("a load reply without an approach id was accepted")
        } catch let error as PythonClipWorkerError {
            guard case .protocolError(let words) = error else { Issue.record("\(error)"); return }
            #expect(words.contains("approach_id"))
        }
        await worker.close()
    }

    @Test func aMissingInterpreterIsRefusedInWords() {
        #expect(throws: PythonClipWorkerError.notFound("the Python interpreter is not at /nonexistent/venv-mlx/bin/python3")) {
            _ = try PythonClipWorker.Configuration.repo(URL(fileURLWithPath: "/nonexistent"), factory: "x")
        }
    }

    @Test func aRemoteHostIsRefusedByThePayloadGateBeforeAnySpawn() async throws {
        let remote = ApproachDescriptor(id: SeatedApproach.eraA2ID, revision: 3, host: .remoteTextOnly, accepts: [.pixels],
                                        emits: [.era], resources: ResourceProfile(peakRAMGB: 8), promptHash: "sha256:x")
        let worker = PythonClipWorker(configuration: ClipWorkerFixture.configuration(), descriptor: remote)
        do {
            try await worker.load()
            Issue.record("a remote host was loaded")
        } catch let error as PythonClipWorkerError {
            guard case .payloadRefused(let words) = error else { Issue.record("\(error)"); return }
            #expect(words.contains("rule 13"))
        }
        #expect(await worker.spawns == 0, "nothing was started")
        #expect(await worker.workerPID == nil)
    }
}

/// The worker child's QoS (Rick 2026-11-04): utility — interactive apps win
/// the CPU and the performance cores stay reachable — never background (on
/// Apple silicon steered to the efficiency cores).
@Suite("PythonClipWorker — the child runs at utility QoS")
struct PythonClipWorkerQoSTests {
    static func configuration() -> PythonClipWorker.Configuration {
        PythonClipWorker.Configuration(python: URL(fileURLWithPath: "/usr/bin/python3"), script: URL(fileURLWithPath: "/dev/null"),
                                       factory: "unused")
    }

    @Test("LOGIC: the worker's Process is set to .utility before it runs")
    func processIsUtility() {
        #expect(PythonClipWorker.makeProcess(Self.configuration()).qualityOfService == .utility)
    }

    @Test("TRUTH: a child started the worker's way reports QOS_CLASS_UTILITY (0x11) from qos_class_self()",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func childReportsUtility() throws {
        let process = PythonClipWorker.makeProcess(Self.configuration())
        // Same Process, same QoS; only the words it runs change: ask the kernel what the child got.
        process.arguments = ["-I", "-c", "import ctypes; print(ctypes.CDLL(None).qos_class_self())"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let text = (String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "17", "QOS_CLASS_UTILITY is 0x11 = 17; the child said \(text) (33 = user-interactive, 9 = background)")
    }
}
