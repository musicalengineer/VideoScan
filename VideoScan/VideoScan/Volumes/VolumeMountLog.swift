import Foundation

/// The catalog.log line for a mount event.
enum VolumeMountLog {
    static func line(for url: URL) -> String? {
        "Volume mounted: \(url.lastPathComponent) (not auto-added — use Add Scan Target to catalog)"
    }
}
