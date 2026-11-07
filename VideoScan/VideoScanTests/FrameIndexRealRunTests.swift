// FrameIndexRealRunTests.swift — the HEADLESS driver for a real Index Frames
// run and the ten-query measurement (docs/design/file_dossier_view.md §II.7;
// the SigLIP 2 report). Not part of any lane: both tests are DISABLED unless
// a config file exists at
//   ~/Library/Application Support/VideoScan/observations/siglip2/realrun.json
// so CI, the sensor lane and the nightly skip them (counted as skipped).
//
// Why a test-hosted driver: the index must be built overnight while Rick's
// app is the catalog's one committer. This runs the SAME FrameIndexJob and
// engine as the window's Index Frames… (rule 4), over a sqlite `.backup`
// COPY of the catalog opened read-only (`openForReading`), and writes only
// the index folder. Pause / Stop are a control file beside the index
// (`control`: "pause" | "stop" | anything else = run), polled every second —
// the job's own pause() / cancel(), so a stop saves and a re-run resumes.
//
// realrun.json: {"catalog": "<backup.sqlite>", "folders": ["/Volumes/X", …],
//                "maxFiles": 300, "queriesOut": "<dir for the query report>"}
//
// Privacy: the query report names hits by path and time only; frames are
// written (for the LOCAL VLM judge) only to `queriesOut`, which must be
// outside the repository.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import VideoScanCore
@testable import VideoScan

private struct RealRunConfig: Decodable {
    let catalog: String
    let folders: [String]
    let maxFiles: Int?
    let queriesOut: String?

    static let url = FrameIndexStore.productionRoot.appendingPathComponent("realrun.json")
    static var present: Bool { FileManager.default.fileExists(atPath: url.path) }
    static func load() throws -> RealRunConfig { try JSONDecoder().decode(RealRunConfig.self, from: Data(contentsOf: url)) }
}

private enum RealRun {
    static func log(_ line: String) {
        let stamped = "[\(Date().formatted(date: .omitted, time: .standard))] \(line)\n"
        let url = FrameIndexStore.productionRoot.appendingPathComponent("realrun.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close() }
        else { try? Data(stamped.utf8).write(to: url) }
        print(stamped, terminator: "")
    }

    static func openCatalog(_ path: String) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "frame-index-realrun")
        let outcome = await repository.openForReading(at: URL(fileURLWithPath: path))
        guard case .readOnly = outcome else { throw Refusal("the catalog copy did not open read-only: \(outcome)") }
        return repository
    }

    static func rows(_ config: RealRunConfig, _ repository: GRDBCatalogRepository) async throws -> [CatalogRow.FrameIndexFile] {
        var all: [CatalogRow.FrameIndexFile] = []
        var seen = Set<String>()
        for folder in config.folders {
            let rows = try await repository.read { try $0.frameIndexFiles(.folder(folder)) }
            for r in rows where seen.insert(r.digest).inserted { all.append(r) }
        }
        return all
    }
}

@Suite("Frames — real run (headless driver; needs realrun.json)", .serialized, .enabled(if: RealRunConfig.present, "no realrun.json — not a lane test"))
@MainActor
struct FrameIndexRealRunTests {

    @Test(.timeLimit(.minutes(600)))
    func indexTheConfiguredSlice() async throws {
        let config = try RealRunConfig.load()
        let repository = try await RealRun.openCatalog(config.catalog)
        let all = try await RealRun.rows(config, repository)
        let embedder = SigLIPEmbedder.shared
        let existing = FrameIndexStore.load(root: FrameIndexStore.productionRoot, model: embedder.modelID).index
        let seed = FrameIndexBuilder(model: embedder.modelID, dims: embedder.dims, seed: existing)
        // The slice: not yet done, with a picture, at most maxFiles.
        let todo = Array(all.filter { $0.hasVideo && !$0.removed && !seed.isDone($0.digest) }.prefix(config.maxFiles ?? .max))
        RealRun.log("real run: \(all.count) contents in \(config.folders.joined(separator: ", ")); \(todo.count) to index this run; index holds \(existing?.count ?? 0) frames")
        let job = FrameIndexJob(scope: .files(todo.map(\.fileID)), loadFiles: { _ in todo }, embedder: embedder)
        job.note = { line in RealRun.log(line); appLog.write("[frame index] " + line) }
        job.progressLogSeconds = 60
        let started = Date()
        job.start()
        let control = FrameIndexStore.productionRoot.appendingPathComponent("control")
        while job.state.isActive {
            let word = (try? String(contentsOf: control, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if word == "stop", job.state == .running { RealRun.log("control: stop"); job.cancel() }
            else if word == "pause", !job.isPaused, job.state == .running { RealRun.log("control: pause"); job.pause() }
            else if word != "pause", word != "stop", job.isPaused { RealRun.log("control: resume"); job.resume() }
            try? await Task.sleep(for: .seconds(1))
        }
        await job.task?.value
        let took = Date().timeIntervalSince(started)
        RealRun.log("OUTCOME \(job.state) — \(job.indexed) files, \(job.framesAdded) frames in \(Int(took)) s = \(String(format: "%.1f", Double(job.framesAdded) / max(1, took))) frames/s; "
                    + "model load \(String(format: "%.1f", await embedder.loadSeconds ?? 0)) s; RSS \(Self.residentMB()) MB")
        #expect(job.state != .running)
    }

    @Test(.timeLimit(.minutes(30)))
    func runTheTenQueries() async throws {
        let config = try RealRunConfig.load()
        guard let outDir = config.queriesOut.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let repository = try await RealRun.openCatalog(config.catalog)
        let rows = try await repository.read { try $0.frameIndexFiles(.everything) }
        let files = Dictionary(rows.map { ($0.digest, $0) }, uniquingKeysWith: { a, _ in a })
        let t0 = Date()
        let index = try #require(FrameIndexStore.load(root: FrameIndexStore.productionRoot, model: SigLIPConfig.modelID).index)
        let loadIndex = Date().timeIntervalSince(t0)
        let embedder = SigLIPEmbedder.shared
        let wasWarm = await embedder.isLoaded
        let queries = ["a birthday cake with candles", "kids opening presents", "the beach", "snow", "a dog", "a Christmas tree",
                       "people at a dinner table", "a boat", "fireworks", "a baby"]
        var report: [[String: Any]] = []
        var first = true
        for q in queries {
            let s = Date()
            let v = try await embedder.embed(text: q)
            let embedS = Date().timeIntervalSince(s)
            let s2 = Date()
            let hits = FrameSearch.topK(query: v, in: index, k: 5, allowed: Set(files.keys), perContent: 2)
            let searchS = Date().timeIntervalSince(s2)
            var hitRows: [[String: Any]] = []
            for (rank, h) in hits.enumerated() {
                let f = files[h.entry.digest]
                var row: [String: Any] = ["rank": rank + 1, "path": f?.path ?? "?", "seconds": h.entry.seconds, "score": Double(h.score), "digest": h.entry.digest]
                if let path = f?.path, let image = await FrameThumbnails.shared.image(path: path, seconds: h.entry.seconds) {
                    let name = "q\(report.count + 1)-r\(rank + 1).jpg"
                    if Self.writeJPEG(image, to: outDir.appendingPathComponent(name)) { row["frame"] = name }
                }
                hitRows.append(row)
            }
            report.append(["query": q, "embedSeconds": embedS, "searchSeconds": searchS, "cold": first && !wasWarm, "hits": hitRows])
            first = false
        }
        // Warm latency: ten more embeds of the same queries.
        var warm: [Double] = []
        for q in queries { let s = Date(); _ = try await embedder.embed(text: q); warm.append(Date().timeIntervalSince(s)) }
        let summary: [String: Any] = ["frames": index.count, "contents": index.indexedDigests.count, "failures": index.failures.count,
                                      "indexLoadSeconds": loadIndex, "modelLoadSeconds": await embedder.loadSeconds ?? 0,
                                      "warmEmbedSecondsMedian": warm.sorted()[warm.count / 2], "warmEmbedSecondsMax": warm.max() ?? 0,
                                      "rssMB": Self.residentMB(), "queries": report]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outDir.appendingPathComponent("queries.json"))
        RealRun.log("queries: \(queries.count) run over \(index.count) frames; warm median \(String(format: "%.3f", warm.sorted()[warm.count / 2])) s")
    }

    static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
    }
}
