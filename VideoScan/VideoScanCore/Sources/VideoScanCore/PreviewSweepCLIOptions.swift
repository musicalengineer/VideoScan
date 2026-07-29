// PreviewSweepCLIOptions.swift (VideoScanCore)
// Argument parsing + small policy helpers for the out-of-process preview
// helper (2026-07-28, Stage 1). Kept in Core (not the executable target) so
// the arg grammar, the single-instance lock, and the catalog-freshness
// decision are all unit-testable without launching a process.

import Foundation
import Darwin

// MARK: - Parsed options

public struct PreviewSweepCLIOptions: Equatable {

    public enum Mode: Equatable {
        /// One planning+sweep pass, then exit (`--once`).
        case once
        /// Keep running: sweep, sleep, re-check the catalog, repeat (default).
        case watch
    }

    /// Path to the persisted catalog.json (READ-ONLY — the catalog is
    /// single-writer, owned by the app).
    public var catalogURL: URL
    public var mode: Mode
    /// Plan only, rip nothing (`--dry-run`).
    public var dryRun: Bool
    /// Sweep workers ACROSS volumes (per-volume is always serialized to 1).
    public var workerCount: Int
    /// Seconds to sleep between passes in `.watch` mode.
    public var intervalSeconds: Double
    /// Cache directory override (`--cache-dir`). nil ⇒ the app's real
    /// preview-cache under Application Support. Overriding is for testing /
    /// by-hand proofs so a run never has to touch the real cache.
    public var cacheDirOverride: URL?

    public init(catalogURL: URL,
                mode: Mode = .watch,
                dryRun: Bool = false,
                workerCount: Int = 2,
                intervalSeconds: Double = 30,
                cacheDirOverride: URL? = nil) {
        self.catalogURL = catalogURL
        self.mode = mode
        self.dryRun = dryRun
        self.workerCount = workerCount
        self.intervalSeconds = intervalSeconds
        self.cacheDirOverride = cacheDirOverride
    }

    // MARK: Defaults

    /// The real production catalog:
    /// ~/Library/Application Support/VideoScan/catalog.json
    public static func defaultCatalogURL(
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("catalog.json")
    }

    // MARK: Parsing

    public enum ParseError: Error, Equatable {
        case unknownFlag(String)
        case missingValue(forFlag: String)
        case badNumber(forFlag: String, value: String)
        /// `--help`/`-h` requested — the caller prints usage and exits 0.
        case helpRequested
    }

    /// Parse argv (WITHOUT the program name). Unknown flags are an error
    /// (fail loud, don't silently ignore a typo'd `--catlog`).
    public static func parse(_ args: [String],
                             defaultCatalog: URL) -> Result<PreviewSweepCLIOptions, ParseError> {
        var opts = PreviewSweepCLIOptions(catalogURL: defaultCatalog)
        var i = 0
        func nextValue(for flag: String) -> String? {
            guard i + 1 < args.count else { return nil }
            i += 1
            return args[i]
        }
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--once":
                opts.mode = .once
            case "--watch":
                opts.mode = .watch
            case "--dry-run":
                opts.dryRun = true
            case "--help", "-h":
                return .failure(.helpRequested)
            case "--catalog":
                guard let v = nextValue(for: arg) else { return .failure(.missingValue(forFlag: arg)) }
                opts.catalogURL = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            case "--cache-dir":
                guard let v = nextValue(for: arg) else { return .failure(.missingValue(forFlag: arg)) }
                opts.cacheDirOverride = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
            case "--workers":
                guard let v = nextValue(for: arg) else { return .failure(.missingValue(forFlag: arg)) }
                guard let n = Int(v), n >= 1 else { return .failure(.badNumber(forFlag: arg, value: v)) }
                opts.workerCount = n
            case "--interval":
                guard let v = nextValue(for: arg) else { return .failure(.missingValue(forFlag: arg)) }
                guard let s = Double(v), s >= 0, s.isFinite else { return .failure(.badNumber(forFlag: arg, value: v)) }
                opts.intervalSeconds = s
            default:
                return .failure(.unknownFlag(arg))
            }
            i += 1
        }
        return .success(opts)
    }

    public static let usage = """
    videoscan-preview-sweep — out-of-process preview (filmstrip/still) prewarmer

    USAGE:
      videoscan-preview-sweep [--once | --watch] [--dry-run]
                              [--catalog <path>] [--workers <n>] [--interval <seconds>]

    OPTIONS:
      --once            Run a single plan+sweep pass, then exit.
      --watch           Keep running: sweep, sleep, re-check the catalog, repeat. (default)
      --dry-run         Plan only — report what would be ripped, rip nothing.
      --catalog <path>  catalog.json to read (READ-ONLY). Default:
                        ~/Library/Application Support/VideoScan/catalog.json
      --cache-dir <p>   Preview-cache directory to write. Default:
                        ~/Library/Application Support/VideoScan/preview-cache
      --workers <n>     Sweep workers across volumes (per-volume is always 1). Default: 2.
      --interval <s>    Seconds to sleep between passes in --watch mode. Default: 30.
      -h, --help        Show this help.

    The app owns catalog.json and metadata_cache.sqlite; this helper never writes them.
    Only ONE instance runs at a time (single-instance lock). Cache writes are guarded by
    an advisory file lock so the app and this helper never corrupt a payload.
    """
}

// MARK: - Catalog freshness (watch mode)

/// Tracks catalog.json's modification time between passes so `--watch` only
/// re-reads the snapshot when the app actually rewrote it. Simple by design
/// for Stage 1: mtime is the freshness signal (the app rewrites the whole
/// file atomically). Missing/unstattable file ⇒ nil mtime ⇒ treated as
/// "changed" so the next pass still attempts a read (it will just plan
/// nothing if the file is absent).
public struct CatalogFreshness {
    private var lastMTime: TimeInterval?

    public init() {}

    /// Returns true (and records the new mtime) when the catalog looks
    /// changed since the last check — i.e. the caller should re-read it.
    public mutating func hasChanged(catalogURL: URL,
                                    fileManager: FileManager = .default) -> Bool {
        let mtime = (try? fileManager.attributesOfItem(atPath: catalogURL.path))?[.modificationDate] as? Date
        let now = mtime?.timeIntervalSince1970
        defer { lastMTime = now }
        // First check (lastMTime nil) always "changed"; nil now (missing
        // file) also counts as changed so a later reappearance is caught.
        guard let last = lastMTime, let now else { return true }
        return now != last
    }
}

// MARK: - Single-instance lock

/// A pidfile guarded by an advisory exclusive flock so two helper processes
/// never run at once (Stage-1 requirement). The lock is held for the
/// lifetime of the process (the fd stays open); the OS releases it if the
/// process dies. `acquire` returns nil when another live instance holds it.
///
/// For Rick: flock(fd, LOCK_EX | LOCK_NB) — a non-blocking exclusive file
/// lock. EWOULDBLOCK means someone else holds it, so we bow out.
public final class SingleInstanceLock: @unchecked Sendable {
    private let fd: Int32
    private let url: URL

    private init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    /// Try to become the sole instance. Returns the held lock on success,
    /// nil if another instance already holds it (or the lockfile can't be
    /// opened). Writes our pid into the file for humans (`cat` the lockfile).
    public static func acquire(at url: URL) -> SingleInstanceLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // Best-effort: stamp our pid (truncate first so a shorter pid can't
        // leave stale trailing bytes).
        ftruncate(fd, 0)
        let pidLine = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        return SingleInstanceLock(fd: fd, url: url)
    }

    /// Release the lock and remove the pidfile. Idempotent-ish (the fd is
    /// closed once; a second call is harmless).
    public func release() {
        flock(fd, LOCK_UN)
        close(fd)
        try? FileManager.default.removeItem(at: url)
    }

    /// Default lock location:
    /// ~/Library/Application Support/VideoScan/.previewsweepd.lock
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent(".previewsweepd.lock")
    }
}
