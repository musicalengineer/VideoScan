// ModelLabStoreTests.swift — the lab notebook sidecar `model-lab.sqlite`
// (video_llm_lab §3.4; sidecar rules in provenance_retroactive §sidecars).
// Dimensions:
//   LOGIC     — beginRun / putOutputs / forEachOutput round trip; keyset
//               paging sees every row once in rowid order; segments and
//               vectors round trip; the schema version; append-only
//               triggers refuse DELETE and UPDATE on every table; the
//               passive checkpoint is harmless.
//   ISOLATION — a newer schema is refused in words (read-write and
//               read-only); a poisoned file is refused; a corrupt raw_json
//               row never crashes a summary pass; preflight refuses a run
//               whose weights are missing BEFORE any row is written; the
//               read-only door restores a missing -wal and never writes; the
//               default directory on a test host is the sandbox.
//   SCALE     — see ModelLabScaleTests (1.6 M rows paged while a writer runs).

import Foundation
import SQLite3
import Testing
@testable import VideoScanCore

func modelLabScratch(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_modellab_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

enum ModelLabStoreFixtures {
    static let approach = ModelLabFixtures.descriptor(revision: 2)
    static let host = ModelLabStore.HostFacts(availableRAMGB: 64, weightsPresent: true)

    static func run(_ id: String = "run-1") -> ModelLabStore.RunStart {
        .init(runID: id, approach: approach, modelDigest: "sha256:model", gitSHA: "406d6c20", samplerID: "window-60s-1fps",
              startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func output(_ run: String, n: Int, valid: Bool = true, family: FieldFamily = .era) -> ModelLabStore.OutputRow {
        let json = valid
            ? #"{"family":"era","window":[\#(n * 60),\#(n * 60 + 60)],"yearRange":[1991,1995],"rationale":"r\#(n)","cues":[],"selfConfidence":0.5}"#
            : #"{"family":"era","window":[\#(n * 60),\#(n * 60 + 60)],"yearRange":[19910,1995]}"#
        return .init(runID: run, contentDigest: "sha256:\(String(format: "%016x", n / 10))", sizeBytes: Int64(1_000 + n),
                     windowStartS: Double(n * 60), windowEndS: Double(n * 60 + 60), family: family,
                     rawJSON: Data(json.utf8), schemaValid: valid, elapsedS: 1.5)
    }
}

@Suite("ModelLab — sidecar store (logic)")
struct ModelLabStoreLogicTests {

    @Test("beginRun writes the run record; outputs round trip in rowid order; counts agree")
    func roundTrip() throws {
        let dir = try modelLabScratch("rt"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        #expect(store.fileURL.lastPathComponent == "model-lab.sqlite")
        try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        let back = try #require(try store.run("run-1"))
        #expect(back.approachID == ModelLabStoreFixtures.approach.id && back.revision == 2 && back.promptHash == "sha256:0123")
        #expect(back.host == "mlxSwift" && back.modelDigest == "sha256:model" && back.gitSHA == "406d6c20" && back.samplerID == "window-60s-1fps")
        #expect(abs(back.startedAt.timeIntervalSince1970 - 1_800_000_000) < 0.001)
        #expect(try store.runCount() == 1)
        try store.putOutputs((0..<7).map { ModelLabStoreFixtures.output("run-1", n: $0, valid: $0 != 3) })
        #expect(try store.outputCount(runID: "run-1") == 7)
        var seen: [(Int64, ModelLabStore.OutputRow)] = []
        try store.forEachOutput(runID: "run-1", pageSize: 3) { rowid, row in seen.append((rowid, row)); return true }
        #expect(seen.count == 7)
        #expect(seen.map(\.0) == seen.map(\.0).sorted(), "rowid order")
        #expect(seen.map { $0.1.windowStartS } == [0, 60, 120, 180, 240, 300, 360])
        #expect(seen[3].1.schemaValid == false && seen[3].1.rawJSON == ModelLabStoreFixtures.output("run-1", n: 3, valid: false).rawJSON)
        #expect(seen[0].1.contentDigest == "sha256:0000000000000000" && seen[0].1.sizeBytes == 1_000 && seen[0].1.elapsedS == 1.5)
        var stopped = 0
        try store.forEachOutput(runID: "run-1", pageSize: 256) { _, _ in stopped += 1; return stopped < 2 }
        #expect(stopped == 2, "body returning false stops the walk")
        #expect(try store.outputCount(runID: "run-none") == 0)
        try store.putOutputs([])
        #expect(try store.outputCount(runID: "run-1") == 7, "an empty batch is a no-op")
    }

    @Test("a second run's outputs are not seen when paging the first; a batch is one transaction")
    func runsAreSeparate() throws {
        let dir = try modelLabScratch("sep"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run("a"), host: ModelLabStoreFixtures.host)
        try store.beginRun(ModelLabStoreFixtures.run("b"), host: ModelLabStoreFixtures.host)
        try store.putOutputs((0..<4).map { ModelLabStoreFixtures.output("a", n: $0) } + (0..<2).map { ModelLabStoreFixtures.output("b", n: $0) })
        var a = 0, b = 0
        try store.forEachOutput(runID: "a") { _, _ in a += 1; return true }
        try store.forEachOutput(runID: "b") { _, _ in b += 1; return true }
        #expect(a == 4 && b == 2)
        // A row for an unknown run is refused by the foreign key, and the whole batch rolls back.
        #expect(throws: ModelLabStore.Failure.self) {
            try store.putOutputs([ModelLabStoreFixtures.output("a", n: 9), ModelLabStoreFixtures.output("ghost", n: 1)])
        }
        #expect(try store.outputCount(runID: "a") == 4)
    }

    @Test("a duplicate run_id is refused; the first record stands")
    func duplicateRun() throws {
        let dir = try modelLabScratch("dup"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        #expect(throws: ModelLabStore.Failure.self) {
            try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        }
        #expect(try store.runCount() == 1)
    }

    @Test("segments (timed transcript) and vectors round trip by digest")
    func segmentsAndVectors() throws {
        let dir = try modelLabScratch("segvec"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.putSegments([
            .init(contentDigest: "sha256:s", engine: "whisper-medium-mlx@1", startS: 0, endS: 2.5, text: "look over here"),
            .init(contentDigest: "sha256:s", engine: "whisper-medium-mlx@1", startS: 2.5, endS: 4, text: "happy birthday"),
            .init(contentDigest: "sha256:other", engine: "whisper-medium-mlx@1", startS: 0, endS: 1, text: "x"),
        ])
        let segments = try store.segments(for: "sha256:s")
        #expect(segments.map(\.text) == ["look over here", "happy birthday"])
        #expect(segments.map(\.startS) == [0, 2.5])
        let blob = Data((0..<16).map { UInt8($0) })
        try store.putVectors([.init(contentDigest: "sha256:v", model: "siglip2-so400m", windowStartS: 0, windowEndS: 60, dims: 4, blob: blob)])
        let vectors = try store.vectors(for: "sha256:v")
        #expect(vectors.count == 1 && vectors.first?.dims == 4 && vectors.first?.blob == blob && vectors.first?.model == "siglip2-so400m")
        #expect(try store.vectors(for: "sha256:none").isEmpty)
    }

    @Test("append-only: DELETE and UPDATE are refused by trigger on runs, outputs, segments and vectors")
    func appendOnlyTriggers() throws {
        let dir = try modelLabScratch("trig"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        try store.putOutputs([ModelLabStoreFixtures.output("run-1", n: 0)])
        try store.putSegments([.init(contentDigest: "d", engine: "e", startS: 0, endS: 1, text: "t")])
        try store.putVectors([.init(contentDigest: "d", model: "m", windowStartS: 0, windowEndS: 1, dims: 1, blob: Data([1]))])
        for sql in ["DELETE FROM runs", "DELETE FROM outputs", "DELETE FROM segments", "DELETE FROM vectors",
                    "UPDATE runs SET git_sha = 'x'", "UPDATE outputs SET schema_valid = 0", "UPDATE segments SET text = 'y'", "UPDATE vectors SET dims = 2"] {
            let message = ModelLabStoreTestHook.exec(sql, in: dir)
            #expect(message?.contains("append-only") == true, "\(sql) → \(message ?? "ran")")
        }
        #expect(try store.runCount() == 1 && (try store.outputCount(runID: "run-1")) == 1)
        #expect(try store.segments(for: "d").count == 1 && (try store.vectors(for: "d")).count == 1)
    }

    @Test("schema version is written on first open, read back after reopen, rows survive; passive checkpoint is harmless")
    func schemaAndReopen() throws {
        let dir = try modelLabScratch("schema"); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try ModelLabStore(directory: dir)
            #expect(try store.schemaVersionOnDisk() == ModelLabStore.schemaVersion)
            try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
            try store.putOutputs([ModelLabStoreFixtures.output("run-1", n: 0)])
            try store.checkpointPassive()
        }
        let again = try ModelLabStore(directory: dir)
        #expect(try again.schemaVersionOnDisk() == ModelLabStore.schemaVersion)
        #expect(try again.runCount() == 1 && (try again.outputCount(runID: "run-1")) == 1)
    }

    @Test("summarize: counts rows, the stored schema_valid flag, and a replay decode per family")
    func summary() throws {
        let dir = try modelLabScratch("sum"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        try store.putOutputs((0..<10).map { ModelLabStoreFixtures.output("run-1", n: $0, valid: $0 % 3 != 0) })
        let s = try store.summarize(runID: "run-1")
        #expect(s.rows == 10 && s.schemaValid == 6 && s.schemaInvalid == 4)
        #expect(s.replayDecoded == 6 && s.replayUndecodable == 4)
        #expect(s.byFamily == [.era: 10])
        #expect(try store.summarize(runID: "none").rows == 0)
    }
}

@Suite("ModelLab — sidecar isolation: newer schema, poison, corrupt rows, preflight, read-only door")
struct ModelLabStoreIsolationTests {

    @Test("a sidecar written by a newer VideoScan is refused in words, read-write and read-only")
    func newerSchemaRefused() throws {
        let dir = try modelLabScratch("newer"); defer { try? FileManager.default.removeItem(at: dir) }
        do { _ = try ModelLabStore(directory: dir) }
        #expect(ModelLabStoreTestHook.exec("UPDATE schema SET version = 99", in: dir) == nil)
        let expected = ModelLabStore.Failure.schemaNewer(found: 99, supported: ModelLabStore.schemaVersion)
        #expect(throws: expected) { try ModelLabStore(directory: dir) }
        #expect(throws: expected) { try ModelLabStore(readingOnly: dir) }
        #expect(expected.description.contains("newer VideoScan") && expected.description.contains("99"))
    }

    @Test("a poisoned file (garbage bytes) is refused by name and left exactly as found")
    func poisonedFileRefused() throws {
        let dir = try modelLabScratch("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(ModelLabStore.fileName)
        let garbage = Data("not a database; a note from the lab".utf8)
        try garbage.write(to: file)
        #expect(throws: ModelLabStore.Failure.notADatabase(path: file.path)) { try ModelLabStore(directory: dir) }
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test("a corrupt raw_json row (invalid UTF-8 blob, truncated JSON, empty) never crashes a summary pass or a page walk")
    func corruptRawJSONTolerated() throws {
        let dir = try modelLabScratch("corrupt"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
        try store.putOutputs([ModelLabStoreFixtures.output("run-1", n: 0)])
        #expect(ModelLabStoreTestHook.exec("""
            INSERT INTO outputs (run_id, content_digest, size_bytes, window_start_s, window_end_s, family, raw_json, schema_valid, elapsed_s)
            VALUES ('run-1', 'sha256:c', 1, 0, 60, 'era', X'FFFE7B', 1, 1),
                   ('run-1', 'sha256:c', 1, 60, 120, 'era', '{"family":"era","window":[60,', 1, 1),
                   ('run-1', 'sha256:c', 1, 120, 180, 'era', '', 1, 1),
                   ('run-1', 'sha256:c', 1, 180, 240, 'notAFamily', '{}', 1, 1)
            """, in: dir) == nil)
        let s = try store.summarize(runID: "run-1")
        #expect(s.rows == 5 && s.replayDecoded == 1 && s.replayUndecodable == 4)
        #expect(s.unknownFamilyRows == 1)
        var walked = 0
        try store.forEachOutput(runID: "run-1") { _, _ in walked += 1; return true }
        #expect(walked == 5)
    }

    @Test("preflight: missing weights, too little RAM, a disabled approach and the remote slot are typed refusals; beginRun writes nothing")
    func preflightRefusals() throws {
        let dir = try modelLabScratch("pre"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ModelLabStore(directory: dir)
        let approach = ModelLabStoreFixtures.approach
        #expect(ModelLabStore.preflight(approach, host: .init(availableRAMGB: 64, weightsPresent: true)) == nil)
        #expect(ModelLabStore.preflight(approach, host: .init(availableRAMGB: 64, weightsPresent: false))
                == .weightsMissing(approach: approach.id, location: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"))
        #expect(ModelLabStore.preflight(approach, host: .init(availableRAMGB: 4, weightsPresent: true))
                == .insufficientRAM(approach: approach.id, neededGB: 6, availableGB: 4))
        let disabled = ModelLabFixtures.descriptor(enabled: false)
        #expect(ModelLabStore.preflight(disabled, host: ModelLabStoreFixtures.host) == .approachDisabled(approach: disabled.id))
        let remote = ModelLabFixtures.descriptor(host: .remoteTextOnly, accepts: [.derivedText], enabled: true)
        #expect(ModelLabStore.preflight(remote, host: ModelLabStoreFixtures.host) == .remoteHostNotEnabled(approach: remote.id),
                "Phase 0: the cloud slot is refused at START even if someone flips `enabled`")

        let run = ModelLabStoreFixtures.run("missing-weights")
        #expect(throws: ModelLabStore.Failure.refused(.weightsMissing(approach: approach.id, location: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"))) {
            try store.beginRun(run, host: .init(availableRAMGB: 64, weightsPresent: false))
        }
        #expect(try store.runCount() == 0, "refused at START: no row")
        #expect(try store.run("missing-weights") == nil)
        let words = ModelLabStore.Refusal.weightsMissing(approach: approach.id, location: "x").description
        #expect(words.contains("weights") && words.contains(approach.id.rawValue))
    }

    @Test("read-only door: reads rows, cannot write, restores a missing -wal (create-only), refuses a missing file")
    func readOnlyDoor() throws {
        let dir = try modelLabScratch("ro"); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = try ModelLabStore(directory: dir)
            try store.beginRun(ModelLabStoreFixtures.run(), host: ModelLabStoreFixtures.host)
            try store.putOutputs([ModelLabStoreFixtures.output("run-1", n: 0)])
        }
        let wal = dir.appendingPathComponent(ModelLabStore.fileName + "-wal")
        try? FileManager.default.removeItem(at: wal)   // what a sqlite3 shell's close leaves behind
        let reader = try ModelLabStore(readingOnly: dir)
        #expect(reader.isReadOnly)
        #expect(FileManager.default.fileExists(atPath: wal.path), "DECISIONS 2026-10-26 (#386): the empty -wal is restored")
        #expect(try reader.outputCount(runID: "run-1") == 1)
        #expect(throws: ModelLabStore.Failure.self) {
            try reader.putOutputs([ModelLabStoreFixtures.output("run-1", n: 1)])
        }
        #expect(throws: ModelLabStore.Failure.self) {
            try reader.beginRun(ModelLabStoreFixtures.run("ro"), host: ModelLabStoreFixtures.host)
        }
        let empty = try modelLabScratch("ro-empty"); defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ModelLabStore.Failure.self) { try ModelLabStore(readingOnly: empty) }
    }

    @Test("on a test host the default directory is the per-process sandbox, never ~/Library/Application Support")
    func defaultDirectoryIsSandboxed() {
        let dir = ModelLabStore.defaultDirectory.path
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/nowhere"
        #expect(!dir.hasPrefix(real), Comment(rawValue: dir))
        #expect(dir.contains("VideoScan-test-appsupport-"), Comment(rawValue: dir))
    }
}

// MARK: - Test-side SQLite poke (what another program, or a future build, would have written)

enum ModelLabStoreTestHook {
    /// Runs `sql` on its own connection. Returns nil on success, SQLite's
    /// message on failure (so a trigger's words can be asserted).
    static func exec(_ sql: String, in directory: URL) -> String? {
        var db: OpaquePointer?
        let path = directory.appendingPathComponent(ModelLabStore.fileName).path
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else { return "open failed" }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        return rc == SQLITE_OK ? nil : (message.map { String(cString: $0) } ?? "error \(rc)")
    }
}
