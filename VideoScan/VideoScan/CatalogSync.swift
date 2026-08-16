// CatalogSync.swift
// Read-only catalog sync between Rick's Mac fleet.
//
// "master" is load-bearing terminology here — it matches the project's
// hardware-fleet vocabulary in MEMORY.md, the rsync man page, and the
// public conversation Rick and the agents have been having about this
// feature. Renaming it to "primary" or "leader" would make the code
// harder to map to the spec, not easier.
//
// One master (Mac Studio — where the LaCie 8TB media lives) and N
// viewer clients (MBPs, future hardware). Mode is decided by hostname.
// On the master, this file writes a manifest.sha256 next to catalog.json
// after every successful save so a viewer can verify nothing was
// corrupted in transit. On a viewer, it shells out to rsync over SSH
// to mirror the catalog/POI tree into a staging directory, recomputes
// the SHA-256 of each staged file, compares to the manifest, and only
// then atomically swaps the verified copy into place.
//
// Design notes / constraints:
//
//  - Strictly one-direction: master → viewer. No bidirectional sync,
//    no conflict resolution, no queued write-back. Viewer-side writes
//    are refused at CatalogStore (see CatalogStore.isReadOnly).
//
//  - rsync runs over SSH using whatever key Rick already has in place;
//    we don't deal with key setup. If ssh prompts, the sync fails fast
//    and the UI falls back to the last-good snapshot.
//
//  - The rsync runner is dependency-injected (`RsyncRunner` protocol)
//    so a unit test can substitute a stub without spawning real
//    subprocesses. The hostname source is also injected. The Application
//    Support root is injected. Anything that touches the real world
//    is behind a seam.
//
//  - Manifest format is the standard `shasum -a 256` line shape:
//      <64 hex chars><two spaces><relative path>
//    one entry per file, sorted by path. Easy to diff by eye and easy
//    to verify externally with `shasum -a 256 -c manifest.sha256`.
//
//  - Memory: streams files through CryptoKit's SHA256 in 1 MB chunks
//    rather than slurping. catalog.json grows with the library; 100k
//    records puts it around ~80 MB on Rick's machine today.
//    Worst-case footprint: ~1 MB hashing buffer per file + the rsync
//    subprocess's own pages, all transient.
//
//  - Atomic swap: rename(2) is atomic within a filesystem, so the
//    live catalog directory is replaced as a single op. We keep the
//    *previous* live dir as `.sync-previous/` for one generation in
//    case the new copy turns out to be wrong after the fact.

import Foundation
import Combine
import CryptoKit

// MARK: - Mode

/// What this process is allowed to do with the catalog.
///
/// `master` is the machine that owns the media and is the only one that
/// can mutate catalog.json. `viewer` is any other Mac in the fleet —
/// it can read but never write.
enum CatalogSyncMode: Equatable {
    case master
    case viewer
}

/// Persisted defaults key. Rick can set this in `defaults` without a
/// recompile if he ever renames a Mac:
///     defaults write Rick-Breen.VideoScan CatalogSyncMasterHostname RicksNewStudio.local
enum CatalogSyncDefaultsKey {
    static let masterHostname = "CatalogSyncMasterHostname"
}

/// Hard-coded default master. Matches the hostname of Rick's Mac Studio M4 Max
/// as documented in CLAUDE.md / MEMORY.md. The Plist override above wins.
let defaultMasterHostname = "RicksM4.local"

// MARK: - Dependency seams (so tests can stub the world)

/// Where the catalog and POI tree live. Default points at
/// ~/Library/Application Support/VideoScan/. Tests inject a tmp dir.
struct CatalogSyncPaths {
    /// The live directory the app reads/writes (catalog.json, POI/, ...).
    let liveDir: URL
    /// The directory rsync writes into before the swap.
    let stagingDir: URL
    /// Snapshot of the previous live dir, kept for one generation.
    let previousDir: URL
    /// Plaintext file holding the timestamp of the most recent successful sync.
    let lastSyncFile: URL

    static func standard() -> CatalogSyncPaths {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        let root = appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        return CatalogSyncPaths(
            liveDir: root,
            stagingDir: root.appendingPathComponent(".sync-staging", isDirectory: true),
            previousDir: root.appendingPathComponent(".sync-previous", isDirectory: true),
            lastSyncFile: root.appendingPathComponent("last_sync.txt")
        )
    }
}

/// Source of the local hostname. Tests inject a fixed string.
protocol HostnameSource: Sendable {
    func currentHostname() -> String
}

/// Production hostname source — same lookup the rest of the codebase
/// already uses (see CatalogStore.CatalogHost).
struct SystemHostnameSource: HostnameSource {
    func currentHostname() -> String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

/// Outcome of a single rsync invocation. Tests return a synthetic one;
/// production fills it from ProcessRunner.Result.
struct RsyncOutcome: Sendable {
    let succeeded: Bool
    let exitCode: Int32
    let stderr: String
}

/// Wraps the rsync subprocess. `// `protocol` ≈ a pure-virtual C++ base class
/// with no data — a contract the implementation has to satisfy.
protocol RsyncRunner: Sendable {
    /// Run rsync with the given args. `destDir` is created (incl. parents)
    /// before launch so rsync's --delete behavior is well-defined.
    func run(args: [String], destDir: URL) async -> RsyncOutcome
}

/// Production rsync runner — shells out to /usr/bin/rsync via ProcessRunner.
struct SystemRsyncRunner: RsyncRunner {
    /// Default macOS rsync. Apple ships rsync 2.6.9 here, which is ancient
    /// but supports the flags we use. Homebrew rsync 3.x at
    /// /opt/homebrew/bin/rsync also works; we prefer system to avoid pulling
    /// in a Homebrew dependency for the sync feature.
    static let defaultRsyncPath = "/usr/bin/rsync"

    let rsyncPath: String

    init(rsyncPath: String = SystemRsyncRunner.defaultRsyncPath) {
        self.rsyncPath = rsyncPath
    }

    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        try? FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true)
        let result = await ProcessRunner.runProcess(
            executable: rsyncPath,
            arguments: args
        )
        return RsyncOutcome(
            succeeded: result.exitCode == 0,
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }
}

// MARK: - Engine

/// State of the most recent sync attempt, observable from SwiftUI for the banner.
struct CatalogSyncState: Equatable {
    enum Phase: Equatable {
        case idle                   // never tried this session
        case syncing                // in flight right now
        case synced(at: Date)       // succeeded — live dir == master
        case failed(reason: String) // could not sync; live dir is last-good snapshot
    }

    var phase: Phase = .idle
    /// Timestamp of the most recent successful sync that this app saw at any
    /// point — survives an offline launch because it's persisted to last_sync.txt.
    /// nil if there's never been a successful sync (first run on a brand-new viewer).
    var lastSuccessfulSync: Date?

    var isSynced: Bool {
        if case .synced = phase { return true }
        return false
    }
}

/// Top-level sync engine. Owns mode detection, manifest write/verify,
/// rsync invocation, and the observable state for the banner.
///
/// `// `@MainActor` ≈ "every method runs on the UI thread". Cheap here —
/// the heavy lifting (rsync, hashing) is awaited off-actor via async I/O.
@MainActor
final class CatalogSync: ObservableObject {

    // MARK: Configuration (injected for tests)

    private let paths: CatalogSyncPaths
    private let hostnameSource: HostnameSource
    private let rsyncRunner: RsyncRunner
    private let masterHostname: String
    private let log: (String) -> Void

    /// True when this Mac is the catalog master (full read/write).
    let mode: CatalogSyncMode

    /// SSH user@host for the master. Rick has SSH keys set up across the
    /// fleet already; we read the username from `NSUserName()` since his
    /// account is `rickb` on every Mac.
    private let remoteUser: String

    /// Auto-refresh polling task for viewer mode. nil when not running.
    /// See `startViewerAutoRefresh()` for the design rationale.
    private var autoRefreshTask: Task<Void, Never>?

    // MARK: Observable state

    @Published private(set) var state = CatalogSyncState()

    // MARK: Init

    /// Production initializer — uses the system everything.
    ///
    /// Inert under a test host: the app target IS the test host, so
    /// `xcodebuild test` runs this startup path for real. Without the
    /// gate a test run writes the master manifest — and on a viewer-mode
    /// machine syncFromMaster() would pull the master catalog over local
    /// data. Narrow gate: ONLY production() is affected; tests that
    /// construct CatalogSync directly with mocks exercise the real logic
    /// (same pattern as CatalogStore.shared).
    static func production() -> CatalogSync {
        let masterHost = UserDefaults.standard.string(
            forKey: CatalogSyncDefaultsKey.masterHostname
        ) ?? defaultMasterHostname

        return CatalogSync(
            paths: CatalogSyncPaths.standard(),
            hostnameSource: SystemHostnameSource(),
            rsyncRunner: SystemRsyncRunner(),
            masterHostname: masterHost,
            remoteUser: NSUserName(),
            isInert: TestEnvironment.isTestHost,
            log: { line in
                NSLog("VideoScan: %@", line)
                appLog.write(line)
            }
        )
    }

    /// When true, all mutating entry points (manifest write, sync pull,
    /// viewer auto-refresh) are no-ops. Set by production() in test hosts.
    let isInert: Bool

    init(
        paths: CatalogSyncPaths,
        hostnameSource: HostnameSource,
        rsyncRunner: RsyncRunner,
        masterHostname: String,
        remoteUser: String,
        isInert: Bool = false,
        log: @escaping (String) -> Void
    ) {
        self.paths = paths
        self.hostnameSource = hostnameSource
        self.rsyncRunner = rsyncRunner
        self.masterHostname = masterHostname
        self.remoteUser = remoteUser
        self.isInert = isInert
        self.log = log
        if isInert {
            log("CatalogSync: inert — test host detected; sync disabled")
        }

        // Hostname-based mode detection. Both the canonical "<name>.local"
        // form and the bare "<name>" form match — `localizedName` returns
        // the bare form, while ProcessInfo.hostName usually has .local
        // appended. Compare case-insensitively to handle Mac/macOS UI
        // capitalization quirks.
        let local = hostnameSource.currentHostname()
        let isMaster = Self.hostnameMatches(local: local, master: masterHostname)
        self.mode = isMaster ? .master : .viewer

        // Hydrate last-successful-sync from disk so the banner can show
        // "snapshot from 3 hr ago" even on a launch that hasn't tried to
        // sync yet.
        self.state.lastSuccessfulSync = Self.readLastSyncTimestamp(at: paths.lastSyncFile)

        log("CatalogSync: mode=\(isMaster ? "master" : "viewer") host=\(local) master=\(masterHostname)")
    }

    /// Hostname compare that ignores `.local` suffix and is case-insensitive.
    /// Exposed for tests.
    static func hostnameMatches(local: String, master: String) -> Bool {
        func normalize(_ s: String) -> String {
            var n = s.lowercased()
            if n.hasSuffix(".local") { n = String(n.dropLast(".local".count)) }
            return n
        }
        return normalize(local) == normalize(master)
    }

    var isReadOnly: Bool { mode == .viewer }

    // MARK: - Manifest (master side)

    /// Files that participate in the manifest, relative to liveDir.
    /// Anything not in this allow-list is invisible to the viewer.
    nonisolated private static let manifestRoots = ["catalog.json", "catalog.json.prev", "POI"]

    /// Write `manifest.sha256` in liveDir covering catalog.json, .prev, and
    /// everything under POI/. No-op on a viewer (defense in depth — the
    /// viewer's CatalogStore is read-only, but if the delegate hook is ever
    /// wired up by mistake this still won't clobber the master's manifest).
    ///
    /// Best-effort: a write failure is logged but doesn't propagate. The
    /// viewer will simply see a stale or missing manifest and refuse to swap.
    func writeManifestIfMaster() {
        if isInert { return }
        guard mode == .master else { return }
        do {
            let count = try Self.computeAndWriteManifest(liveDir: paths.liveDir)
            log("CatalogSync: wrote manifest.sha256 (\(count) files)")
        } catch {
            log("CatalogSync: failed to write manifest.sha256: \(error.localizedDescription)")
        }
    }

    // MARK: Off-main, coalesced manifest refresh (#161 beachball fix)

    /// True while a background manifest computation is running.
    private var manifestRefreshRunning = false
    /// Set when a refresh was requested while one was already running; the
    /// running one re-arms itself on completion so the manifest always
    /// ends up describing the LATEST catalog.json.
    private var manifestRefreshDirty = false
    /// Number of background computations actually started. Test sensor for
    /// coalescing (N rapid requests → far fewer than N computations).
    private(set) var manifestRefreshCount = 0
    /// The in-flight refresh, so tests (and quit-time code) can await it.
    private(set) var manifestRefreshTask: Task<Void, Never>?

    /// Refresh `manifest.sha256` WITHOUT blocking the main actor.
    ///
    /// Why this exists: the store's observer callback used to call
    /// `writeManifestIfMaster()` synchronously after every successful save.
    /// That re-hashed catalog.json + catalog.json.prev + POI/ — hundreds of
    /// megabytes at the pre-reduction size — on the main thread, and was
    /// codex's #1-ranked contributor to the Catalog beachballs (#161).
    /// Hashing now runs on a detached utility task; requests that arrive
    /// while one is in flight coalesce into a single follow-up run.
    ///
    /// Same guards as the synchronous variant: no-op on a viewer, no-op on
    /// an inert (test-host) instance.
    func scheduleManifestRefresh() {
        if isInert { return }
        guard mode == .master else { return }
        if manifestRefreshRunning {
            manifestRefreshDirty = true
            return
        }
        manifestRefreshRunning = true
        manifestRefreshCount += 1
        let liveDir = paths.liveDir
        manifestRefreshTask = Task { [weak self] in
            // Task.detached: explicitly OFF the main actor. (A plain
            // nonisolated async call would inherit the caller's actor —
            // see the "approachable concurrency" trap notes.)
            let outcome: Result<Int, Error> = await Task.detached(priority: .utility) {
                Result { try Self.computeAndWriteManifest(liveDir: liveDir) }
            }.value
            guard let self else { return }
            self.manifestRefreshDidFinish(outcome)
        }
    }

    /// Await any in-flight manifest refresh (and the follow-up it may
    /// re-arm). Used by tests; harmless to call when idle.
    func flushManifestRefresh() async {
        // Each completion clears manifestRefreshTask (or replaces it with
        // the re-armed follow-up), so looping until nil drains the chain.
        while let task = manifestRefreshTask {
            await task.value
        }
    }

    private func manifestRefreshDidFinish(_ outcome: Result<Int, Error>) {
        switch outcome {
        case .success(let count):
            log("CatalogSync: wrote manifest.sha256 (\(count) files, background)")
        case .failure(let error):
            log("CatalogSync: failed to write manifest.sha256: \(error.localizedDescription)")
        }
        manifestRefreshRunning = false
        manifestRefreshTask = nil
        if manifestRefreshDirty {
            manifestRefreshDirty = false
            scheduleManifestRefresh()
        }
    }

    /// Compute + atomically write manifest.sha256 under `liveDir`. Returns
    /// the number of files covered. Pure filesystem work, safe off-main.
    nonisolated static func computeAndWriteManifest(liveDir: URL) throws -> Int {
        let lines = try computeManifestLines(rootDir: liveDir)
        let text = lines.joined(separator: "\n") + "\n"
        let manifestURL = liveDir.appendingPathComponent("manifest.sha256")
        try text.write(to: manifestURL, atomically: true, encoding: .utf8)
        return lines.count
    }

    /// Compute the manifest lines (sorted) for everything under `rootDir`
    /// that lives within `manifestRoots`. Pure function — no I/O on the
    /// app-support tree other than reads.
    nonisolated static func computeManifestLines(rootDir: URL) throws -> [String] {
        let fm = FileManager.default
        var entries: [(relPath: String, hash: String)] = []

        for top in manifestRoots {
            let url = rootDir.appendingPathComponent(top)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // Recursively walk top. enumerator() handles symlinks safely
                // (doesn't follow by default).
                guard let walker = fm.enumerator(at: url,
                                                 includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
                for case let fileURL as URL in walker {
                    let vals = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard vals.isRegularFile == true else { continue }
                    let rel = relativePath(of: fileURL, under: rootDir)
                    let hash = try sha256Hex(of: fileURL)
                    entries.append((rel, hash))
                }
            } else {
                let rel = relativePath(of: url, under: rootDir)
                let hash = try sha256Hex(of: url)
                entries.append((rel, hash))
            }
        }

        entries.sort { $0.relPath < $1.relPath }
        return entries.map { "\($0.hash)  \($0.relPath)" }
    }

    /// Relative path from `root` to `url`, using `/` separators.
    nonisolated static func relativePath(of url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        if urlPath.hasPrefix(rootPath + "/") {
            return String(urlPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }

    /// Streaming SHA-256 hex digest of a file. Reads in 1 MB chunks so a
    /// huge catalog.json doesn't balloon the process RSS.
    /// Worst-case memory: ~1 MB (chunk size).
    nonisolated static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk: Data
            if #available(macOS 13.0, *) {
                chunk = try handle.read(upToCount: chunkSize) ?? Data()
            } else {
                chunk = handle.readData(ofLength: chunkSize)
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Sync (viewer side)

    /// rsync arguments built from the include/exclude rules in the brief.
    /// Source ends in `/` so rsync mirrors the *contents* of the master's
    /// VideoScan dir, not the dir itself.
    ///
    /// Path-escape gotcha: Apple ships `openrsync` (protocol 29) on newer
    /// macOS rather than GNU rsync. openrsync's remote-path parser
    /// space-splits the source argument the way the remote shell would,
    /// so a literal space in "Application Support" gets treated as two
    /// separate source paths and both fail with "No such file or
    /// directory" — manifesting in the UI as "master offline." The fix
    /// is to backslash-escape spaces in the remote root so the parser
    /// (and the remote shell) preserve them as one path.
    /// Verified 2026-06-05 by Rick + Claude: with `Application\ Support`
    /// the rsync from M5 to M4.local succeeds; without it the empty-
    /// file-list error fires before catalog transfer can start.
    func rsyncArguments(stagingDir: URL) -> [String] {
        let remoteRoot = "/Users/\(remoteUser)/Library/Application Support/VideoScan/"
        // Escape spaces so openrsync + the remote shell both see a
        // single source path, not two split at the space.
        let escapedRoot = remoteRoot.replacingOccurrences(of: " ", with: "\\ ")
        let source = "\(remoteUser)@\(masterHostname):\(escapedRoot)"
        return [
            "-a",                                       // archive — preserve times/perms
            "--delete",                                  // mirror semantics
            // SSH options: BatchMode=yes so we never block on a password prompt;
            // tight timeouts so an offline master fails fast rather than hanging
            // the launch sync.
            "-e", "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new",
            "--include=catalog.json",
            "--include=catalog.json.prev",
            "--include=manifest.sha256",
            "--include=POI/",
            "--include=POI/**",
            "--exclude=*",
            source,
            stagingDir.path + "/"
        ]
    }

    // MARK: - Viewer auto-refresh
    //
    // The launch-time `syncFromMaster()` only fires once. Without this
    // helper, a viewer left running for hours sees nothing new — its
    // catalog stays frozen even as the master + dossier workers add
    // hundreds of records. This task fires a fresh `syncFromMaster()`
    // every `intervalSeconds` so M1/M5 viewers stay current.
    //
    // No-op on master mode — the master IS the writer, has nothing to
    // pull from. Idempotent — repeated calls don't stack tasks. Stop
    // with `stopViewerAutoRefresh()` (typically not needed; the task
    // dies with the CatalogSync instance when the app quits).

    /// Start the viewer-side periodic refresh. On master, no-op.
    /// Default interval is 90s — fast enough that the chip/dial tick
    /// up noticeably, slow enough that we don't thrash SSH+rsync.
    @MainActor
    func startViewerAutoRefresh(intervalSeconds: Double = 90) {
        if isInert { return }
        guard mode == .viewer else { return }
        guard autoRefreshTask == nil else { return }
        log("CatalogSync: starting viewer auto-refresh (\(Int(intervalSeconds))s interval)")
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(intervalSeconds))
                guard !Task.isCancelled else { break }
                await self?.syncFromMaster()
            }
        }
    }

    /// Cancel the auto-refresh loop. Idempotent.
    @MainActor
    func stopViewerAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Top-level entry point for a viewer. Idempotent — calling twice while
    /// one is already in flight collapses to the first attempt.
    ///
    /// On the master, this is a no-op.
    func syncFromMaster() async {
        if isInert { return }
        guard mode == .viewer else { return }
        if case .syncing = state.phase {
            log("CatalogSync: sync already in flight; ignoring duplicate request")
            return
        }
        state.phase = .syncing
        log("CatalogSync: starting rsync from \(masterHostname)")

        // 1. rsync into staging.
        let args = rsyncArguments(stagingDir: paths.stagingDir)
        let outcome = await rsyncRunner.run(args: args, destDir: paths.stagingDir)
        if !outcome.succeeded {
            let reason = "rsync exit \(outcome.exitCode): \(outcome.stderr.prefix(200))"
            log("CatalogSync: \(reason)")
            state.phase = .failed(reason: reason)
            return
        }

        // 2. Verify manifest in the staging dir. If the master never wrote
        //    one (e.g. running an old build), refuse the swap — better to
        //    keep the user on their last-good snapshot than copy in
        //    something unverifiable.
        do {
            try verifyManifest(in: paths.stagingDir)
        } catch {
            let reason = "manifest verify failed: \(error.localizedDescription)"
            log("CatalogSync: \(reason)")
            state.phase = .failed(reason: reason)
            return
        }

        // 3. Atomic swap — rotate live → previous, move staging → live.
        do {
            try atomicSwap()
        } catch {
            let reason = "swap failed: \(error.localizedDescription)"
            log("CatalogSync: \(reason)")
            state.phase = .failed(reason: reason)
            return
        }

        let now = Date()
        state.phase = .synced(at: now)
        state.lastSuccessfulSync = now
        Self.writeLastSyncTimestamp(now, to: paths.lastSyncFile)
        log("CatalogSync: sync complete at \(now)")
    }

    // MARK: - Verify

    enum ManifestVerifyError: LocalizedError, Equatable {
        case missingManifest
        case malformedManifest(String)
        case missingFile(String)
        case hashMismatch(String)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .missingManifest:        return "manifest.sha256 not present"
            case .malformedManifest(let s): return "malformed manifest line: \(s)"
            case .missingFile(let p):     return "file in manifest not in staging: \(p)"
            case .hashMismatch(let p):    return "sha256 mismatch: \(p)"
            case .ioError(let s):         return s
            }
        }
    }

    /// Recompute SHA-256 of each file listed in `<dir>/manifest.sha256` and
    /// compare. Throws on the first discrepancy. Exposed for tests.
    func verifyManifest(in dir: URL) throws {
        let manifestURL = dir.appendingPathComponent("manifest.sha256")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ManifestVerifyError.missingManifest
        }
        let text: String
        do {
            text = try String(contentsOf: manifestURL, encoding: .utf8)
        } catch {
            throw ManifestVerifyError.ioError(error.localizedDescription)
        }
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            // Format: "<64 hex>  <relpath>"
            guard let sep = line.range(of: "  ") else {
                throw ManifestVerifyError.malformedManifest(line)
            }
            let expectedHash = String(line[..<sep.lowerBound])
            let relPath = String(line[sep.upperBound...])
            let fileURL = dir.appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ManifestVerifyError.missingFile(relPath)
            }
            let actualHash: String
            do {
                actualHash = try Self.sha256Hex(of: fileURL)
            } catch {
                throw ManifestVerifyError.ioError("hash \(relPath): \(error.localizedDescription)")
            }
            if actualHash != expectedHash {
                throw ManifestVerifyError.hashMismatch(relPath)
            }
        }
    }

    // MARK: - Atomic swap

    /// Replace the live catalog/POI tree with the staged copy.
    ///
    /// We can't `mv staging live` directly because live also contains
    /// per-machine state we deliberately exclude from sync (sqlite caches,
    /// scan_jobs/, last_sync.txt, .sync-staging itself). So instead:
    ///
    ///   1. For each top-level entry the manifest covers, move the live
    ///      copy into .sync-previous/.
    ///   2. Move the staged copy into liveDir.
    ///   3. Drop the staging dir on the floor.
    ///
    /// Each individual move uses FileManager.replaceItem (which is
    /// rename(2)-backed on the same filesystem), so file-level swaps are
    /// atomic. The directory-level operation isn't a single atomic point —
    /// a power-loss mid-swap leaves a half-rotated state — but the next
    /// successful sync will re-mirror from the master, and the viewer is
    /// read-only so there's nothing user-typed to lose.
    func atomicSwap() throws {
        let fm = FileManager.default

        // Reset .sync-previous each time — we only keep one generation back.
        if fm.fileExists(atPath: paths.previousDir.path) {
            try fm.removeItem(at: paths.previousDir)
        }
        try fm.createDirectory(at: paths.previousDir, withIntermediateDirectories: true)

        for entry in Self.manifestRoots + ["manifest.sha256"] {
            let liveItem = paths.liveDir.appendingPathComponent(entry)
            let stagedItem = paths.stagingDir.appendingPathComponent(entry)
            let prevItem = paths.previousDir.appendingPathComponent(entry)

            // 1. Stash the old live copy if present.
            if fm.fileExists(atPath: liveItem.path) {
                try fm.moveItem(at: liveItem, to: prevItem)
            }
            // 2. Move the new copy into place if rsync produced one.
            if fm.fileExists(atPath: stagedItem.path) {
                try fm.moveItem(at: stagedItem, to: liveItem)
            }
        }

        // 3. Drop the now-empty staging dir.
        try? fm.removeItem(at: paths.stagingDir)
    }

    // MARK: - last_sync.txt persistence

    /// ISO-8601 string. Plain text so a user can `cat` it.
    private static func readLastSyncTimestamp(at url: URL) -> Date? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: trimmed)
    }

    private static func writeLastSyncTimestamp(_ date: Date, to url: URL) {
        let fmt = ISO8601DateFormatter()
        let s = fmt.string(from: date) + "\n"
        try? s.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - CatalogStoreObserver bridge

/// On the master, every catalog write triggers a manifest refresh so the
/// next viewer sync verifies cleanly. On a viewer, this is a no-op (the
/// data layer also refuses the write, so we'd never get here anyway).
extension CatalogSync: CatalogStoreObserver {
    func catalogStoreDidWrite(_ store: CatalogStore) {
        // Off-main + coalesced — never hash the catalog on the UI thread
        // in response to a save (#161).
        scheduleManifestRefresh()
    }
}

