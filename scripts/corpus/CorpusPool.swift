// CorpusPool.swift — N corpus files in flight, each under its own deadline.
//
// NOT part of the Xcode project (see CorpusDriverSupport.swift for how these
// files reach a build). Foundation ONLY, so tests/test_corpus_run.py compiles
// it by itself in Swift 6 mode and pins its behaviour (SwiftPoolTests): the
// order at N = 1, never more than N in flight, every file exactly once, the
// deadline each file's own.
//
// Why (Rick, 2026-11-20: "2 hour testbeds in serial is not performant
// design"): the check lane spends nearly all of a file's ~2.5 s waiting on
// ffprobe/ffmpeg children, one file after another. `each` keeps `width` files
// in flight — the config's `jobs`, which scripts/corpus_run.py derives from
// the host (half its logical cores: the M4 8, the Ultra 15) — and N = 1 is the serial loop itself,
// not a group of one.
//
// The deadline: a file that overruns `seconds` from its own `arm` is written
// as `timeout` in the engine it was in, its `end` is written `cut`, and the
// test host exits itself (`halt`, `_exit(86)` in the driver). Several files
// overdue at one tick are all cut. The other files in flight are left as they
// are — begun, not ended — and the Python side runs every file a launch of
// N > 1 left unfinished again ALONE (`settle`, `alone`): only a launch of one
// file at a time convicts a file of a crash or a timeout.
//
// Memory: the pool holds at most `width` child tasks; the deadline one entry
// per file in flight (a SHA-256, an engine word, two dates). Each file's
// engines bound their own output (ProcessRunner caps a child's stdout at
// 1 MiB and stderr at 256 KiB), so N in flight is at worst N × ~2.5 MB.
// (For Rick: a TaskGroup ≈ a std::vector<std::future<void>> whose next
// std::async is started each time one future completes — a bounded worker
// pool without a queue object.)

import Foundation

enum CorpusPool {
    /// Calls `body` once for every item, at most `width` at a time, and returns when all have
    /// returned. `width` ≤ 1 is the plain loop: the items one after another, in order.
    static func each<Item: Sendable>(_ items: [Item], width: Int,
                                     _ body: @escaping @Sendable (Item) async -> Void) async {
        guard width > 1, items.count > 1 else {
            for item in items { await body(item) }
            return
        }
        await withTaskGroup(of: Void.self) { group in
            var next = items.makeIterator()
            for _ in 0..<width {
                guard let item = next.next() else { break }
                group.addTask { await body(item) }
            }
            // One finishes, the next starts: never more than `width` in flight, started in the given order.
            while await group.next() != nil {
                if let item = next.next() { group.addTask { await body(item) } }
            }
        }
    }
}

/// The per-file deadline, for every file in flight. Armed at `begin`, told which engine each
/// file is in; when a file overruns, it writes that file's `timeout` and `end cut` and halts.
final class CorpusDeadline: @unchecked Sendable {
    private struct Running {
        var engine: String
        let due: Date
        let started: Date
    }

    private let lock = NSLock()
    private var running: [String: Running] = [:]
    private let write: @Sendable ([String: Any]) -> Void
    private let halt: @Sendable () -> Void
    private let timer: DispatchSourceTimer

    /// `write` appends one progress line; `halt` ends the process (the driver: `_exit(86)`).
    init(write: @escaping @Sendable ([String: Any]) -> Void, halt: @escaping @Sendable () -> Void) {
        self.write = write
        self.halt = halt
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func arm(sha: String, seconds: Double) {
        let now = Date()
        lock.lock()
        running[sha] = Running(engine: "", due: now.addingTimeInterval(seconds), started: now)
        lock.unlock()
    }

    /// The file `sha` is now in `engine`.
    func entering(sha: String, _ engine: String) {
        lock.lock()
        running[sha]?.engine = engine
        lock.unlock()
    }

    /// Every file in flight is now in `engine` (the verbs lane: one step over its whole sample).
    func entering(_ engine: String) {
        lock.lock()
        for sha in running.keys { running[sha]?.engine = engine }
        lock.unlock()
    }

    func disarm(sha: String) {
        lock.lock()
        running[sha] = nil
        lock.unlock()
    }

    private func tick() {
        let now = Date()
        lock.lock()
        let overdue = running.filter { now > $0.value.due }.sorted { $0.key < $1.key }
        lock.unlock()
        guard !overdue.isEmpty else { return }
        for (sha, file) in overdue {
            if !file.engine.isEmpty {
                write(["ev": "engine", "sha": sha, "engine": file.engine, "outcome": "timeout",
                       "s": now.timeIntervalSince(file.started)])
            }
            write(["ev": "end", "sha": sha, "cut": true])
        }
        halt()
    }
}
