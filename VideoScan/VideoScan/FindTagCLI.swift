// FindTagCLI.swift — the detached find-and-tag daemon (--find-tag).
//
// Headless Find & Tag over the persisted catalog, modeled on the
// preview-sweep helper's Stage 2 (2026-08-06). Spawned detached by the
// app (posix_spawn + SETSID via PosixSpawnHelperLauncher) or run by
// hand; it OUTLIVES app quit, which is the point — an 11-hour overnight
// scan must survive rapid-dev rebuild/relaunch cycles.
//
// Data-flow contract (the difference from the preview helper, whose
// product is cache files): this daemon NEVER writes catalog.json. It
// reads the catalog (READ-ONLY, single-writer is the app), scores each
// video-bearing record with the SAME NativeRecipeScorer configuration
// the in-app job uses, and appends verdicts to a per-run journal
// (FindTagJournal.swift — the codex-pinned wire contract). The app
// ingests journals and applies tags via applyRecipeVerdict, deriving
// tiers from the recipeID's thresholds AT APPLY TIME.
//
// Wedge policy: per-clip watchdog on progress-beat age (same 300 s
// staleness bar as the in-app StallMonitor). A wedged clip's score task
// is ABANDONED and the loop continues — and unlike the in-app race that
// caused the 2026-08-06 misattribution, each clip's continuation and
// once-flag are LOCAL to the clip, so a late completion can only be
// discarded, never delivered to another clip. A run of consecutive
// wedges (volume died) fails the run rather than burning 300 s per file
// to the end of the catalog.
//
// Invocation:
//   VideoScan.app/Contents/MacOS/VideoScan --find-tag \
//       [--person Donna] [--catalog <path>] [--gallery <dir>]
//       [--journal-dir <dir>] [--path-prefix <prefix>] [--limit N]
//       [--no-resume] [--stall-seconds 300]

import AppKit
import Foundation
import VideoScanCore

enum FindTagCLI {

    struct Options {
        var person = "Donna"
        var catalogURL = PreviewSweepCLIOptions.defaultCatalogURL()
        var galleryPath = FindPersonJob.galleryPath
        var journalDir = FindTagPaths.journalDirectoryURL()
        /// Only records whose fullPath starts with this (spot-test aid).
        var pathPrefix: String?
        /// Scan at most N files (spot-test aid).
        var limit: Int?
        /// Reuse success verdicts from prior journals (same person +
        /// recipeID) by content fingerprint. Errors are always retried.
        var resume = true
        /// Seconds without a scorer progress beat before a clip is
        /// declared wedged and abandoned (in-app StallMonitor parity).
        var stallSeconds: Double = 300
    }

    static let recipeID = "recipe-v1-native"
    /// Consecutive wedge/error cap: distinguishes "this file is bad"
    /// (skip and continue) from "the volume/system died" (fail the run
    /// instead of burning stallSeconds on every remaining file).
    static let consecutiveWedgeCap = 5

    // MARK: - Tiny lock-boxes (ProcessRunner.DeadlineFlag convention)

    /// Set-once stop flag written by signal handlers, read by the loop.
    final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        func raise() { lock.lock(); stopped = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }

    /// Last progress-beat timestamp for the CURRENT clip. Reset at each
    /// clip start so a pre-first-frame hang (open wedge) is also caught.
    final class BeatBox: @unchecked Sendable {
        private let lock = NSLock()
        private var last = CFAbsoluteTimeGetCurrent()
        func note() { lock.lock(); last = CFAbsoluteTimeGetCurrent(); lock.unlock() }
        func reset() { note() }
        var age: Double {
            lock.lock()
            defer { lock.unlock() }
            return CFAbsoluteTimeGetCurrent() - last
        }
    }

    /// One-shot claim: exactly one of {score-completion, watchdog} may
    /// resume the clip's continuation. Local per clip — cross-clip
    /// misattribution is impossible by construction.
    final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        /// True exactly once, for the first caller.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
        var isClaimed: Bool { lock.lock(); defer { lock.unlock() }; return claimed }
    }

    /// Current scan position for the heartbeat task.
    final class PositionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var index = 0
        private var path = ""
        func set(index: Int, path: String) {
            lock.lock(); self.index = index; self.path = path; lock.unlock()
        }
        var snapshot: (index: Int, path: String) {
            lock.lock()
            defer { lock.unlock() }
            return (index, path)
        }
    }

    // MARK: - Entry

    // swiftlint:disable:next function_body_length
    static func run(arguments: [String]) async -> Int32 {
        let options: Options
        do {
            options = try parse(arguments)
        } catch {
            err("error: \(error.localizedDescription)")
            return 2
        }

        // Single instance — same flock+identity protocol as the preview
        // helper, own pidfile. The app's running-probe reads this too.
        guard let instanceLock = SingleInstanceLock.acquire(
            at: FindTagPaths.pidfileURL()) else {
            err("findtagd: another find-tag daemon is already running — exiting")
            return 3
        }
        defer { instanceLock.release() }

        // Clean-stop signals. SIG_IGN + DispatchSource is the standard
        // arrangement: the source fires on the signal, the loop drains
        // at the next clip boundary and journals runEnd(terminated).
        let stop = StopFlag()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        termSource.setEventHandler { stop.raise() }
        intSource.setEventHandler { stop.raise() }
        termSource.resume()
        intSource.resume()

        // Work plan from the persisted catalog (READ-ONLY).
        guard let records = FileBackedCatalogSource.loadRecords(from: options.catalogURL) else {
            err("findtagd: cannot read catalog at \(options.catalogURL.path)")
            return 2
        }
        var skippedHuman = 0
        var plan = records.filter { rec in
            guard rec.streamType == .videoOnly || rec.streamType == .videoAndAudio else {
                return false
            }
            if let prefix = options.pathPrefix, !rec.fullPath.hasPrefix(prefix) {
                return false
            }
            // Human-settled records are never machine-scanned: a human
            // tag or rejection outranks any score (applyRecipeVerdict
            // would refuse anyway — skipping here saves the decode).
            if isHumanSettled(rec, person: options.person) {
                skippedHuman += 1
                return false
            }
            return true
        }
        if let limit = options.limit { plan = Array(plan.prefix(limit)) }

        // Resume index from prior journals (success verdicts only).
        var reusable: [String: FindTagVerdict] = [:]
        if options.resume {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: options.journalDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" } ?? []
            reusable = FindTagJournalReader.reusableVerdicts(
                fromJournalFiles: files, person: options.person, recipeID: recipeID)
        }

        // Journal for THIS run.
        let runId = UUID().uuidString
        let startedAt = Date()
        let journalURL = options.journalDir.appendingPathComponent(
            FindTagPaths.journalFilename(runId: runId, at: startedAt))
        let journal: FindTagJournalWriter
        do {
            journal = try FindTagJournalWriter(fileURL: journalURL)
            try journal.append(.runStart(FindTagRunStart(
                runId: runId, at: startedAt, person: options.person,
                recipeID: recipeID, engine: "arcface",
                catalogPath: options.catalogURL.path, planned: plan.count)))
        } catch {
            err("findtagd: cannot open journal — \(error.localizedDescription)")
            return 2
        }
        defer { journal.close() }

        out("findtagd: run \(runId.prefix(8)) person=\(options.person) "
            + "planned=\(plan.count) (skipped \(skippedHuman) human-settled) "
            + "resume-index=\(reusable.count) journal=\(journalURL.lastPathComponent)")

        // Scorer — EXACT in-app configuration (FindPersonJob parity):
        // arcface backend, sex gate ON, no pause gate (nothing to pause
        // for headless).
        let beats = BeatBox()
        var params = RecipeParameters()
        params.sexGateEnabled = true
        let scorer = NativeRecipeScorer(
            backend: .arcface, params: params,
            onProgress: { _ in beats.note() })
        do {
            _ = try await scorer.prepare(
                galleryRoot: URL(fileURLWithPath: options.galleryPath))
        } catch {
            err("findtagd: recipe setup failed — \(error.localizedDescription)")
            try? journal.append(.runEnd(FindTagRunEnd(
                at: Date(), status: .failed, scored: 0, errors: 0,
                reused: 0, skippedHuman: skippedHuman)))
            return 2
        }

        // Heartbeat task: position + liveness every 30 s (not fsync'd).
        let position = PositionBox()
        let planned = plan.count
        let heartbeatTask = Task {
            while true {
                // A cancelled sleep must NOT write one last heartbeat on
                // the way out (it would land after runEnd — torn framing
                // seen in the first smoke run's journal).
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                let snap = position.snapshot
                guard snap.index > 0 else { continue }
                try? journal.append(.heartbeat(FindTagHeartbeat(
                    at: Date(), index: snap.index, planned: planned,
                    currentPath: snap.path)), sync: false)
            }
        }
        defer { heartbeatTask.cancel() }

        // MARK: Scan loop

        var scored = 0, errors = 0, reused = 0
        var consecutiveWedges = 0
        var inRunVerdicts: [String: (witness: String, verdict: RecipeClipScore)] = [:]

        for (index, rec) in plan.enumerated() {
            if stop.isRaised { break }
            let clipName = (rec.fullPath as NSString).lastPathComponent
            position.set(index: index + 1, path: rec.fullPath)
            let fingerprint = FindPersonJob.fingerprintKey(for: rec)
            let clipStart = CFAbsoluteTimeGetCurrent()
            var verdict: RecipeClipScore
            var reusedFrom: String?

            if !FileManager.default.fileExists(atPath: rec.fullPath) {
                verdict = RecipeClipScore(error: "missing file")
            } else if let fp = fingerprint, let prior = inRunVerdicts[fp] {
                verdict = prior.verdict
                reusedFrom = prior.witness
            } else if let fp = fingerprint, options.resume, let prior = reusable[fp] {
                verdict = RecipeClipScore(score: prior.score,
                                          frameCount: prior.frames,
                                          gatedFaceCount: prior.gatedFaces,
                                          error: nil,
                                          decodeTransport: prior.transport)
                reusedFrom = "journal:" + (prior.path as NSString).lastPathComponent
            } else {
                out("findtagd: scanning \(index + 1)/\(planned): \(clipName)")
                beats.reset()
                let raced = await scoreWithWatchdog(
                    scorer: scorer, clip: URL(fileURLWithPath: rec.fullPath),
                    beats: beats, stallSeconds: options.stallSeconds)
                verdict = raced ?? RecipeClipScore(
                    error: "wedged — no progress for \(Int(options.stallSeconds))s, decode abandoned")
            }

            let seconds = reusedFrom == nil
                ? CFAbsoluteTimeGetCurrent() - clipStart : 0
            if let fp = fingerprint, reusedFrom == nil, verdict.error == nil {
                inRunVerdicts[fp] = (witness: clipName, verdict: verdict)
            }

            do {
                try journal.append(.verdict(FindTagVerdict(
                    seq: index + 1, at: Date(), recordID: rec.id.uuidString,
                    path: rec.fullPath, fingerprint: fingerprint,
                    score: verdict.score, error: verdict.error,
                    frames: verdict.frameCount, gatedFaces: verdict.gatedFaceCount,
                    transport: verdict.decodeTransport,
                    seconds: (seconds * 10).rounded() / 10,
                    reusedFrom: reusedFrom)))
            } catch {
                err("findtagd: journal write failed — \(error.localizedDescription); stopping")
                break
            }

            if let reusedFrom {
                reused += 1
                out("findtagd: duplicate \(index + 1)/\(planned): \(clipName) = \(reusedFrom) — verdict reused")
            } else if let error = verdict.error {
                errors += 1
                out("findtagd: \(index + 1)/\(planned): \(clipName) ERR \(error)")
            } else {
                scored += 1
                let score = verdict.score.map { String(format: "%.3f", $0) } ?? "—"
                out("findtagd: \(index + 1)/\(planned): \(clipName) \(score) "
                    + "(\(verdict.frameCount) frames, \(verdict.gatedFaceCount) faces) "
                    + "[\(String(format: "%.1f", seconds))s"
                    + (verdict.decodeTransport.map { ", \($0)" } ?? "") + "]")
            }

            // Systemic-failure brake: N consecutive wedges = the volume
            // or system died, not N coincidentally bad files.
            if verdict.error?.hasPrefix("wedged") == true {
                consecutiveWedges += 1
                if consecutiveWedges >= consecutiveWedgeCap {
                    err("findtagd: \(consecutiveWedges) consecutive wedges — failing run")
                    heartbeatTask.cancel()
                    try? journal.append(.runEnd(FindTagRunEnd(
                        at: Date(), status: .failed, scored: scored,
                        errors: errors, reused: reused, skippedHuman: skippedHuman)))
                    return 1
                }
            } else if verdict.error == nil {
                consecutiveWedges = 0
            }
        }

        let status: FindTagRunEnd.Status = stop.isRaised ? .terminated : .completed
        heartbeatTask.cancel()
        try? journal.append(.runEnd(FindTagRunEnd(
            at: Date(), status: status, scored: scored, errors: errors,
            reused: reused, skippedHuman: skippedHuman)))
        out("findtagd: \(status.rawValue) — scored \(scored), errors \(errors), "
            + "reused \(reused), skipped \(skippedHuman) human-settled")
        return 0
    }

    // MARK: - Watchdog race (per-clip, self-contained)

    /// Score with a progress-staleness watchdog. Returns nil when the
    /// clip wedged (no beat for `stallSeconds`); the abandoned task's
    /// eventual completion hits an already-claimed OnceFlag and is
    /// dropped. Both the continuation and the flag are locals of THIS
    /// call — no daemon state a late completion could misdeliver into.
    static func scoreWithWatchdog(scorer: NativeRecipeScorer,
                                  clip: URL,
                                  beats: BeatBox,
                                  stallSeconds: Double) async -> RecipeClipScore? {
        let scoreTask = Task { await scorer.score(clip: clip) }
        let once = OnceFlag()
        return await withCheckedContinuation { cont in
            Task {
                let verdict = await scoreTask.value
                if once.claim() { cont.resume(returning: verdict) }
            }
            Task {
                while !once.isClaimed {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if once.isClaimed { return }
                    if beats.age > stallSeconds {
                        if once.claim() { cont.resume(returning: nil) }
                        return
                    }
                }
            }
        }
    }

    // MARK: - Filters

    /// A human already decided about this person on this record —
    /// confirmed or rejected — so the machine never rescans it.
    static func isHumanSettled(_ rec: VideoRecord, person: String) -> Bool {
        func same(_ other: String) -> Bool {
            other.compare(person, options: .caseInsensitive) == .orderedSame
        }
        return rec.rejectedPeople.contains(where: same)
            || rec.confirmedByUserPeople.contains(where: { same($0.name) })
    }

    // MARK: - Argument parsing

    enum ParseError: LocalizedError {
        case unknownFlag(String)
        case missingValue(String)
        case badNumber(String, String)
        var errorDescription: String? {
            switch self {
            case .unknownFlag(let f): return "unknown flag \(f)"
            case .missingValue(let f): return "missing value for \(f)"
            case .badNumber(let f, let v): return "bad number for \(f): \(v)"
            }
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        var opts = Options()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw ParseError.missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--find-tag": break
            case "--no-resume": opts.resume = false
            case "--person": opts.person = try value(arg)
            case "--catalog":
                opts.catalogURL = URL(fileURLWithPath:
                    (try value(arg) as NSString).expandingTildeInPath)
            case "--gallery":
                opts.galleryPath = (try value(arg) as NSString).expandingTildeInPath
            case "--journal-dir":
                opts.journalDir = URL(fileURLWithPath:
                    (try value(arg) as NSString).expandingTildeInPath, isDirectory: true)
            case "--path-prefix": opts.pathPrefix = try value(arg)
            case "--limit":
                let v = try value(arg)
                guard let n = Int(v), n >= 1 else { throw ParseError.badNumber(arg, v) }
                opts.limit = n
            case "--stall-seconds":
                let v = try value(arg)
                guard let s = Double(v), s >= 10, s.isFinite else {
                    throw ParseError.badNumber(arg, v)
                }
                opts.stallSeconds = s
            default: throw ParseError.unknownFlag(arg)
            }
            i += 1
        }
        return opts
    }

    // MARK: - Output (timestamped stdout/stderr; the spawn redirects
    // both to ~/Library/Logs/VideoScan/findtagd.log)

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    private static func out(_ line: String) {
        print("[\(timeFormatter.string(from: Date()))] \(line)")
        fflush(stdout)
    }

    private static func err(_ line: String) {
        FileHandle.standardError.write(
            Data("[\(timeFormatter.string(from: Date()))] \(line)\n".utf8))
    }
}
