// BackgroundQuitMarker.swift — "Quit VideoScan Background" (Rick 2026-11-08).
//
// The menu bar's Quit must keep the helper DOWN, but two things would start
// it again at once: launchd starts the helper on demand whenever anyone
// connects to its Mach service (the app's 10-minute status poll, the
// `--status` CLI), and RunAtLoad starts it at login. So Quit writes this
// marker before it exits 0, and the service checks it at start:
//
//   • a marker from THIS boot → the service logs one line and exits 0
//     (launchd leaves an exit 0 down: KeepAlive {SuccessfulExit false});
//   • a marker from an earlier boot → stale: removed, the service starts
//     (Quit lasts until the Mac restarts);
//   • VideoScan clears it when it launches, and when the checkbox is turned
//     on (opening VideoScan starts the helper again).
//
// A torn or unreadable marker reads as NO marker: the helper runs and the
// reason is returned to the caller to log. Quitting is a convenience, not a
// safety interlock; failing toward "running" keeps analysis visible in the
// menu bar rather than silently stopped.
//
// File: <stateRoot>/quit.json (beside holds.json). C++ reading: a pid-file
// style flag with the boot time inside it, so a reboot invalidates it.

import Foundation

public struct BackgroundQuitMarker: Codable, Equatable, Sendable {
    public var quitAt: Date
    /// `kern.boottime` seconds of the boot the Quit happened in.
    public var bootSeconds: Int64

    public init(quitAt: Date, bootSeconds: Int64) {
        self.quitAt = quitAt
        self.bootSeconds = bootSeconds
    }

    /// "20:41" today, "Nov 7, 20:41" otherwise — for the Settings line and logs.
    public func quitWords(now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(quitAt, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: quitAt)
    }
}

public final class BackgroundQuitStore: @unchecked Sendable {
    public let url: URL
    /// The current boot's identity; injectable for tests.
    private let bootSeconds: @Sendable () -> Int64?

    public init(url: URL, bootSeconds: @escaping @Sendable () -> Int64? = BackgroundQuitStore.currentBootSeconds) {
        self.url = url
        self.bootSeconds = bootSeconds
    }

    public static func beside(stateRoot: URL) -> BackgroundQuitStore {
        BackgroundQuitStore(url: stateRoot.appendingPathComponent("quit.json"))
    }

    /// The one marker both sides use: the helper (Quit, start) and VideoScan
    /// (status poll, launch clear). ~/Library/Application Support/VideoScan/background/quit.json
    /// — the helper's fixed state root (BackgroundService.stateRoot).
    public static func production() -> BackgroundQuitStore {
        beside(stateRoot: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VideoScan/background", isDirectory: true))
    }

    /// What `active()` found.
    public enum Reading: Equatable, Sendable {
        case none
        /// Quit in this boot: stay down.
        case active(BackgroundQuitMarker)
        /// Quit in an earlier boot: removed, run.
        case stale(BackgroundQuitMarker)
        /// The file exists but could not be read: run, and say why.
        case unreadable(String)
        /// The boot time could not be read: run (cannot tell this boot from another).
        case noBootTime
    }

    /// Writes the marker for this boot. Throws when the boot time or the file write fails.
    @discardableResult
    public func write(now: Date = Date()) throws -> BackgroundQuitMarker {
        guard let boot = bootSeconds() else { throw QuitMarkerError.noBootTime }
        // Whole seconds: ISO 8601 on disk has none, so the returned marker
        // equals the one read back.
        let marker = BackgroundQuitMarker(quitAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
                                          bootSeconds: boot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(marker).write(to: url, options: .atomic)
        return marker
    }

    /// Reads the marker; a stale one is removed here.
    public func read() -> Reading {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        let marker: BackgroundQuitMarker
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            marker = try dec.decode(BackgroundQuitMarker.self, from: Data(contentsOf: url))
        } catch {
            return .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let boot = bootSeconds() else { return .noBootTime }
        if marker.bootSeconds == boot { return .active(marker) }
        try? FileManager.default.removeItem(at: url)
        return .stale(marker)
    }

    /// The active marker, or nil (stale markers are removed as a side effect).
    public func active() -> BackgroundQuitMarker? {
        if case .active(let m) = read() { return m }
        return nil
    }

    /// Removes the marker (any boot, or torn); returns what was there when readable.
    @discardableResult
    public func clear() -> BackgroundQuitMarker? {
        let was: BackgroundQuitMarker?
        switch read() {
        case .active(let m), .stale(let m): was = m
        default: was = nil
        }
        try? FileManager.default.removeItem(at: url)
        return was
    }

    /// `sysctl kern.boottime` seconds; nil if the call fails.
    public static let currentBootSeconds: @Sendable () -> Int64? = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Int64(tv.tv_sec)
    }
}

public enum QuitMarkerError: Error, LocalizedError {
    case noBootTime
    public var errorDescription: String? { "the Mac's boot time could not be read (sysctl kern.boottime)" }
}
