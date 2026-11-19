// CorpusDriverSupport.swift — the real-data corpus harness, in-app half.
//
// NOT part of the Xcode project. scripts/corpus_run.py lays the files of
// scripts/corpus/ over the M4's testbed worktree (VideoScanTests/
// CorpusHarnessOverlay/, untracked) for one run and moves them out again, so
// a ref that predates the harness can be run across the corpus. The engines
// therefore run in the app's own unit-test host — the gauntlet's headless
// driver — where `TestEnvironment.isTestHost` already makes the shared
// catalog store, catalog sync and the background service inert.
//
// Shape: `CorpusRun.open` proves the seal and reads the sealed catalog
// through Core's read-only door (`SQLiteCatalogReader`, sealed-snapshot
// open: no file is created beside it); each driver then walks the pending
// files and reports one JSON line per event to the run's progress file.
// The Python side folds those lines into the report.
//
// THE SEAL is CorpusSeal.swift (one pure function, Foundation only, pinned by
// behaviour); `CorpusRun.open` gathers the facts and asks it. It is checked
// here again because this is the process that touches the media (fail closed
// — any miss is `refused` and the test stops):
//   - the hostname is the M4's;
//   - the real home (account database, not $HOME) holds corpus/THIS_IS_TEST_DATA.txt;
//   - config, catalog, work and progress resolve under ~/corpus/{state,work};
//   - $HOME and Application Support resolve under ~/corpus/state, or (the
//     verbs lane) under the run's own work folder — the patched .xctestrun
//     took effect — and this IS a test host;
//   - the catalog names no Master Archive and every record is under
//     ~/corpus/media or the adopted external volume's corpus/media (a row
//     only: a file is given to an engine only while that volume is proven), or
//     (the verbs lane) under the run's folder of clones;
//   - the verbs lane's clone, archive and scratch folders are under the run's
//     work folder, which is under ~/corpus/work.
//
// Deadline: a file that overruns `deadlineSeconds` is recorded as `timeout`
// and the test host EXITS ITSELF (`_exit`); the Python side relaunches for
// the files left. No other process is ever signalled.
//
// Privacy: only enum case names, codec/container names and numbers are
// written. Never a filename, a path, an engine's sentence or stderr.
//
// Memory: the loaded records (~6,400 in v2, a few MB) and one small JSON line at a time.
// (For Rick: `final class … @unchecked Sendable` with an NSLock ≈ a C++
// class whose members are guarded by a std::mutex — the compiler is told
// "I lock it myself".)

import Foundation
import XCTest
import VideoScanCore
@testable import VideoScan

struct CorpusRefusal: Error {
    let word: String
}

enum CorpusWords {
    /// An enum value's case name without its payload: `.referenceMovie(paths…)` → "referenceMovie".
    static func caseName(_ value: Any) -> String {
        let text = String(describing: value)
        let head = text.split(separator: "(", maxSplits: 1).first.map(String.init) ?? text
        return word(head.split(separator: ".").last.map(String.init) ?? head)
    }

    /// A word is letters, digits and `_ , : + -` (a space becomes `_`: "Not run" → "Not_run").
    /// Anything else — a slash, a dot — is not a word and is written as `scrubbed`, whole;
    /// the Python side applies the same rule again.
    static func word(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_,:+-")
        let spaced = text.replacingOccurrences(of: " ", with: "_")
        guard !spaced.isEmpty else { return "none" }
        guard spaced.count <= 64, spaced.allSatisfy({ allowed.contains($0) }) else { return "scrubbed" }
        return spaced
    }
}

/// The run's progress file: one JSON object per line, flushed to disk per line
/// so a crash loses at most the line being written.
final class CorpusProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    /// Opened without following a link, and only a regular file with ONE name: a second name could be
    /// a corpus document's (Codex #331 F3: the pin, hard-linked as a progress file).
    init(path: String) throws {
        let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { throw CorpusRefusal(word: "progress_not_writable") }
        var info = stat()
        // ... and on the home volume: a run folder with a volume mounted over it is never written (Codex #333 F2).
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_dev == CorpusSeal.homeDevice(realHome: CorpusRun.realHome()) else {
            close(fd)
            throw CorpusRefusal(word: "progress_not_writable")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        lock.lock()
        defer { lock.unlock() }
        handle.write(data)
        handle.write(Data("\n".utf8))
        try? handle.synchronize()
    }
}

/// The per-file deadline. Armed at `begin`, told which engine is running; when the
/// file overruns, it writes the `timeout` and exits this process.
final class CorpusDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (sha: String, engine: String, due: Date, started: Date)?
    private let progress: CorpusProgress
    private let timer: DispatchSourceTimer

    init(progress: CorpusProgress) {
        self.progress = progress
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func arm(sha: String, seconds: Double) {
        lock.lock()
        current = (sha, "", Date().addingTimeInterval(seconds), Date())
        lock.unlock()
    }

    func entering(_ engine: String) {
        lock.lock()
        current?.engine = engine
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    private func tick() {
        lock.lock()
        let now = current
        lock.unlock()
        guard let now, Date() > now.due else { return }
        if !now.engine.isEmpty {
            progress.write(["ev": "engine", "sha": now.sha, "engine": now.engine, "outcome": "timeout",
                            "s": Date().timeIntervalSince(now.started)])
        }
        progress.write(["ev": "end", "sha": now.sha, "cut": true])
        _exit(86)
    }
}

final class CorpusRun: @unchecked Sendable {
    let config: CorpusConfig
    let progress: CorpusProgress
    let deadline: CorpusDeadline
    /// The external root as the seal found it when the run opened: `mayOpen` lets a file on it through
    /// only while this same volume is proven again.
    let external: CorpusExternal

    private init(config: CorpusConfig, progress: CorpusProgress, external: CorpusExternal) {
        self.config = config
        self.progress = progress
        self.deadline = CorpusDeadline(progress: progress)
        self.external = external
    }

    static func realHome() -> String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "/nonexistent" }
        return String(cString: dir)
    }

    static func resolved(_ path: String) -> String { CorpusSeal.resolved(path) }

    static func isUnder(_ path: String, _ root: String) -> Bool { CorpusSeal.isUnder(path, root) }

    static func hostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(bytes: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    /// Reads the config the Python side wrote and proves the seal (`CorpusSeal.refusal`: one
    /// pure function, pinned by behaviour in tests/test_corpus_run.py). `lane` is the driver's
    /// own lane: a config for another lane is refused. A refusal is written to the run's
    /// progress file only when that file is itself proven to be inside the corpus work folder.
    static func open(lane: String) throws -> CorpusRun {
        guard let configPath = ProcessInfo.processInfo.environment["VS_CORPUS_CONFIG"], !configPath.isEmpty else {
            throw XCTSkip("the corpus harness did not launch this test (no VS_CORPUS_CONFIG)")
        }
        // The gate first: on the wrong Mac, without the marker, or with a config outside
        // ~/corpus/work, nothing is read — not even the config (Codex #313 F6).
        let loaded = CorpusSeal.loadConfig(hostname: hostname(), realHome: realHome(), configPath: configPath,
                                           read: { FileManager.default.contents(atPath: $0) })
        if let word = loaded.refusal { throw CorpusRefusal(word: word) }
        let config = loaded.config
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/"
        let input = CorpusSealInput(hostname: hostname(), realHome: realHome(), configPath: configPath, lane: lane, config: config,
                                    homeDirectory: NSHomeDirectory(), applicationSupport: appSupport,
                                    isTestHost: TestEnvironment.isTestHost)
        if let word = CorpusSeal.refusal(input) {
            // Say why in the progress file — but only when that file is proven to be this run's own.
            if let config, CorpusSeal.progressIsProven(config, realHome: realHome()),
               let progress = try? CorpusProgress(path: config.progress) {
                progress.write(["ev": "refused", "why": word])
            }
            throw CorpusRefusal(word: word)
        }
        guard let config else { throw CorpusRefusal(word: "config_outside_the_corpus") }
        return CorpusRun(config: config, progress: try CorpusProgress(path: config.progress),
                         external: CorpusSeal.external(realHome: realHome()))
    }

    /// The sealed catalog through Core's read-only door for a non-writer. Refuses
    /// a catalog that names a Master Archive or a record outside the corpus.
    func loadCatalog() async throws -> SQLiteCatalogReader.Loaded {
        let url = URL(fileURLWithPath: config.catalog)
        switch await SQLiteCatalogReader.load(.syncedCopy(url, master: "the corpus")) {
        case .failure:
            progress.write(["ev": "refused", "why": "catalog_would_not_open"])
            throw CorpusRefusal(word: "catalog_would_not_open")
        case .success(let loaded):
            // The verbs lane's catalog names its clones; the others' name ~/corpus/media and the adopted volume's copies.
            let roots = config.volRoot.map { [$0] } ?? [config.mediaRoot] + (external.mount.map { [$0 + "/corpus/media"] } ?? [])
            guard loaded.masterArchiveJSON == nil else {
                progress.write(["ev": "refused", "why": "catalog_names_a_master_archive"])
                throw CorpusRefusal(word: "catalog_names_a_master_archive")
            }
            guard loaded.records.allSatisfy({ record in roots.contains { CorpusRun.isUnder(record.fullPath, $0) } }) else {
                progress.write(["ev": "refused", "why": "a_record_is_outside_the_corpus"])
                throw CorpusRefusal(word: "a_record_is_outside_the_corpus")
            }
            progress.write(["ev": "hello", "lane": config.lane, "homeSealed": true, "testHost": true,
                            "archiveDesignation": false, "records": loaded.records.count,
                            "unreadable": loaded.unreadable])
            return loaded
        }
    }

    func begin(_ item: CorpusConfig.Item) {
        progress.write(["ev": "begin", "sha": item.sha])
        deadline.arm(sha: item.sha, seconds: config.deadlineSeconds)
    }

    func end(_ item: CorpusConfig.Item) {
        deadline.disarm()
        progress.write(["ev": "end", "sha": item.sha])
    }

    func facts(_ item: CorpusConfig.Item, _ values: [String: Any]) {
        var event = values
        event["ev"] = "facts"
        event["sha"] = item.sha
        progress.write(event)
    }

    /// Runs one engine step under the deadline and records its outcome word — or, for a file on the
    /// external volume that is no longer proven, records `external_volume_not_proven` and runs nothing.
    func engine(_ item: CorpusConfig.Item, _ name: String,
                _ body: () async throws -> (outcome: String, kinds: [String])) async {
        // The external volume is proven again now: a file on it is never opened on a proof made earlier.
        guard CorpusSeal.mayOpen(item.path, realHome: CorpusRun.realHome(), atOpen: external) else {
            progress.write(["ev": "engine", "sha": item.sha, "engine": name, "outcome": "external_volume_not_proven",
                            "kinds": [String](), "s": 0])
            return
        }
        deadline.entering(name)
        let started = Date()
        var outcome = "error:unknown", kinds: [String] = []
        do {
            (outcome, kinds) = try await body()
        } catch {
            outcome = "error:" + CorpusWords.caseName(error)
        }
        progress.write(["ev": "engine", "sha": item.sha, "engine": name, "outcome": CorpusWords.word(outcome),
                        "kinds": kinds.map(CorpusWords.word), "s": Date().timeIntervalSince(started)])
    }

    func done() {
        progress.write(["ev": "done"])
    }
}
