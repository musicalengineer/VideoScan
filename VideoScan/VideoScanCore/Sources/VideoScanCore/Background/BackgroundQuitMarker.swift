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
// A torn or unreadable marker (also: a symlink, a directory, over 4 KB —
// Codex sweep 11/09) reads as NO marker: the helper runs and the
// reason is returned to the caller to log. Quitting is a convenience, not a
// safety interlock; failing toward "running" keeps analysis visible in the
// menu bar rather than silently stopped.
//
// File: <stateRoot>/quit.json (beside holds.json). C++ reading: a pid-file
// style flag with the boot session id (kern.bootsessionuuid; the boot time
// for markers written before 11/09) inside it, so a reboot invalidates it.

import Foundation

public struct BackgroundQuitMarker: Codable, Equatable, Sendable {
    public var quitAt: Date
    /// `kern.boottime` seconds of the boot the Quit happened in.
    public var bootSeconds: Int64
    /// `kern.bootsessionuuid` of the boot the Quit happened in (nil in markers
    /// written before 2026-11-09).
    public var bootSession: String?

    public init(quitAt: Date, bootSeconds: Int64, bootSession: String? = nil) {
        self.quitAt = quitAt
        self.bootSeconds = bootSeconds
        self.bootSession = bootSession
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
    private let bootSession: @Sendable () -> String?

    public init(url: URL, bootSeconds: @escaping @Sendable () -> Int64? = BackgroundQuitStore.currentBootSeconds,
                bootSession: @escaping @Sendable () -> String? = BackgroundQuitStore.currentBootSession) {
        self.url = url
        self.bootSeconds = bootSeconds
        self.bootSession = bootSession
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
                                          bootSeconds: boot, bootSession: bootSession())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(marker).write(to: url, options: .atomic)
        return marker
    }

    /// A marker is ~100 bytes; anything larger is not one (Codex sweep 11/09 F6).
    static let maxBytes = 4_096

    /// The marker's bytes: a regular file opened with O_NOFOLLOW (a symlink is
    /// refused, never followed), at most `maxBytes`. nil + why otherwise;
    /// (nil, nil) when there is no file. Memory: ≤ 4 KB.
    private func readBytes() -> (Data?, String?) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return (nil, nil) }
            return (nil, "\(url.lastPathComponent): \(errno == ELOOP ? "a symbolic link, not the marker" : String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return (nil, "\(url.lastPathComponent): not a regular file") }
        guard st.st_size <= Int64(Self.maxBytes) else { return (nil, "\(url.lastPathComponent): \(st.st_size) bytes — not a quit marker") }
        var buffer = [UInt8](repeating: 0, count: Self.maxBytes + 1)
        var total = 0
        while total < buffer.count {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if n < 0 { if errno == EINTR { continue }; return (nil, "\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            total += n
        }
        guard total <= Self.maxBytes else { return (nil, "\(url.lastPathComponent): grew past \(Self.maxBytes) bytes — not a quit marker") }
        return (Data(buffer.prefix(total)), nil)
    }

    /// Same boot? The boot session id when both sides have one (kern.boottime
    /// moves when the clock is corrected — Codex sweep 11/09 F5); else the
    /// boot seconds (markers written before the session id).
    private func sameBoot(_ marker: BackgroundQuitMarker, boot: Int64) -> Bool {
        if let theirs = marker.bootSession, let ours = bootSession() { return theirs == ours }
        return marker.bootSeconds == boot
    }

    /// Reads the marker; a stale one is removed here.
    public func read() -> Reading {
        let (bytes, problem) = readBytes()
        if let problem { return .unreadable(problem) }
        guard let bytes else { return .none }
        let marker: BackgroundQuitMarker
        do {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            marker = try dec.decode(BackgroundQuitMarker.self, from: bytes)
        } catch {
            return .unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let boot = bootSeconds() else { return .noBootTime }
        if sameBoot(marker, boot: boot) { return .active(marker) }
        _ = removeMarkerFile()
        return .stale(marker)
    }

    /// unlink(2) — one regular file, never a directory tree (Codex sweep 11/09
    /// F2: `removeItem` removed a directory named quit.json recursively).
    /// nil when gone, else why it is still there.
    private func removeMarkerFile() -> String? {
        var st = stat()
        if lstat(url.path, &st) != 0 { return errno == ENOENT ? nil : String(cString: strerror(errno)) }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFLNK else { return "\(url.lastPathComponent) is not a file — left in place" }
        if unlink(url.path) == 0 || errno == ENOENT { return nil }
        return String(cString: strerror(errno))
    }

    /// The active marker, or nil (stale markers are removed as a side effect).
    public func active() -> BackgroundQuitMarker? {
        if case .active(let m) = read() { return m }
        return nil
    }

    /// What `clear()` did.
    public enum ClearOutcome: Equatable, Sendable {
        /// No marker was there.
        case nothing
        /// Removed; the marker when it was readable.
        case cleared(BackgroundQuitMarker?)
        /// Still there (or not a marker file): why — the helper stays down.
        case failed(String)

        public var marker: BackgroundQuitMarker? { if case .cleared(let m) = self { return m }; return nil }
    }

    /// Removes the marker (any boot, or torn).
    @discardableResult
    public func clear() -> ClearOutcome {
        let was: BackgroundQuitMarker?
        switch read() {
        case .none: return .nothing
        case .stale(let m): return .cleared(m)     // read() already removed it
        case .active(let m): was = m
        case .unreadable, .noBootTime: was = nil
        }
        // A removal that failed is said, never reported as cleared (F3).
        if let why = removeMarkerFile() { return .failed(why) }
        return .cleared(was)
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

extension BackgroundQuitStore {
    /// `sysctl kern.bootsessionuuid` — the boot's identity (unlike
    /// `kern.boottime`, which the kernel moves when the clock is corrected);
    /// nil if the call fails.
    public static let currentBootSession: @Sendable () -> String? = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}

public enum QuitMarkerError: Error, LocalizedError {
    case noBootTime
    public var errorDescription: String? { "the Mac's boot time could not be read (sysctl kern.boottime)" }
}
