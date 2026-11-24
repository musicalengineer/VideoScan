import Foundation

/// The catalog.log line for a mount event, or nil when the mount is not a drive.
///
/// Mount notifications are system-wide. A drive a person attaches appears directly under
/// /Volumes; a disk image a tool or a test attaches at its own folder (`hdiutil attach
/// -mountpoint <folder>`) does not. Those got a "Volume mounted" line too, so every testbed run
/// filled catalog.log with `diskfull-mnt-…`, `mnt`, `VideoScanTests` (11/18–11/23). The mount
/// handler still refreshes reachability for every mount; only the line is limited.
enum VolumeMountLog {
    static func line(for url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents   // ".." resolved first
        guard parts.count == 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        return "Volume mounted: \(parts[2]) (not auto-added — use Add Scan Target to catalog)"
    }
}
