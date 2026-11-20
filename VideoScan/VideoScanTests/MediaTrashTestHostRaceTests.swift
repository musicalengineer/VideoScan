// MediaTrashTestHostRaceTests.swift
// Rule 7 regression (2026-11-20, found while proving MFO verbs run in
// parallel): under a test host `MediaTrash.move` sends every file to ONE
// per-process scratch Trash, choosing a free name with "exists? → move" —
// two steps. Two jobs (or two tests, which Swift Testing runs in parallel)
// trashing files with the same name at the same moment both see the name
// free; the second move then fails ("file exists") or replaces the first
// file's bytes. Either way a parallel test reads a wrong outcome — and the
// suites that trash were `.serialized` partly to dodge it.
//
// Isolation dimension: synthetic files in a per-test temp folder, the
// test-host Trash only (never Rick's), names unique to this run.
// (For Rick: DispatchQueue.concurrentPerform ≈ a C++ parallel_for over N
// threads; the race is a classic check-then-act TOCTOU.)

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

@Suite("MediaTrash — the test-host Trash under concurrent moves")
struct MediaTrashTestHostRaceTests {

    @Test("RED 2026-11-20: 32 same-named files trashed at once all land, each under its own name, bytes intact")
    func concurrentSameNameMovesAllLand() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("test_trashrace_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let name = "test_trashrace_\(UUID().uuidString.prefix(8)).mov"
        let n = 32
        var sources: [URL] = []
        var digests: [String] = []
        for i in 0..<n {
            let dir = root.appendingPathComponent("v\(i)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(name)
            let bytes = Data("clip \(i) ".utf8) + Data(repeating: UInt8(i), count: 4_096)
            try bytes.write(to: url)
            sources.append(url)
            digests.append(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }

        // ≈ C++: a mutex-guarded vector of results, filled from N threads.
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var landed: [String?]
            var errors: [String] = []
            init(_ n: Int) { landed = Array(repeating: nil, count: n) }
        }
        let results = Results(n)
        let srcs = sources
        DispatchQueue.concurrentPerform(iterations: n) { i in
            do {
                let dest = try MediaTrash.move(srcs[i])
                results.lock.withLock { results.landed[i] = dest.path }
            } catch {
                results.lock.withLock { results.errors.append("\(i): \(error.localizedDescription)") }
            }
        }
        let landed = results.landed, errors = results.errors
        defer { for p in landed.compactMap({ $0 }) { try? fm.removeItem(atPath: p) } }

        #expect(errors.isEmpty, "moves failed: \(errors.prefix(3))")
        let paths = landed.compactMap { $0 }
        #expect(paths.count == n)
        #expect(Set(paths).count == paths.count, "two moves landed on the same name — one replaced the other")
        for (i, p) in landed.enumerated() {
            guard let p else { continue }
            let data = (try? Data(contentsOf: URL(fileURLWithPath: p))) ?? Data()
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == digests[i], "file \(i) at \(p) holds another file's bytes")
            #expect(!fm.fileExists(atPath: sources[i].path), "the source left its folder")
        }
    }
}
