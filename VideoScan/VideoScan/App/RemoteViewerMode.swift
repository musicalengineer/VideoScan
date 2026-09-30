// RemoteViewerMode.swift
// Process-wide "am I a viewer?" answer for Phase 1 of remote use
// (docs/remote_use_design.md, Rick 2026-08-29: "when I am on the porch with
// the M5 I can just launch the app … and talk to Hallie and play videos").
//
// CatalogSync decides master-vs-viewer from the hostname. That decision
// used to reach only the catalog (CatalogStore.isReadOnly + the model's
// isReadOnly flag). A viewer also must not compile the family tree, write
// POI profiles, record CyberBrain notes, save pronunciations, or start
// media-file operations — and every one of those lives far from the
// catalog. Rather than thread a flag through a dozen initializers, the
// decision is published ONCE here and read where a write would happen.
//
// `ViewerModeCenter` ≈ a lock-protected global (C++: a static with a
// mutex around it). It is set exactly once at launch by VideoScanApp from
// CatalogSync.mode, and tests set it directly (and reset in `defer`).
// The default is `.master`, so a process that never calls `install` —
// the master, every CLI, every existing test — behaves exactly as before.
//
// `ViewerWriteGuard.refuse(_:)` is the one line a write path adds:
//
//     if ViewerWriteGuard.refuse("POIProfile.save") { return }
//
// It answers true (and logs) only on a viewer. The refusal log is
// captured in-process too, so the read-only enforcement sensor can assert
// "refused + log line" for every write path without parsing catalog.log.

import Foundation

/// Which side of the sync this process is. Mirrors CatalogSyncMode; kept
/// as its own type so VideoScanCore-adjacent code can read it without
/// importing the sync engine.
enum RemoteViewerRole: Equatable, Sendable {
    case master
    case viewer(masterHostname: String)

    var isViewer: Bool {
        if case .viewer = self { return true }
        return false
    }
}

/// The single source of truth for the role, plus the small facts the
/// viewer UI needs (the master's display name).
final class ViewerModeCenter: @unchecked Sendable {
    static let shared = ViewerModeCenter()

    private let lock = NSLock()
    private var role: RemoteViewerRole = .master
    private var refusalLog: [String] = []
    /// Where refusals are written besides the in-process capture.
    /// Production = catalog.log via appLog; tests may inject a sink.
    private var sink: (String) -> Void = { appLog.write($0) }

    /// Bounded capture so a long viewer session cannot grow this without
    /// limit (worst case: 256 short strings).
    static let refusalLogCapacity = 256

    init() {}

    /// Install the role. Called once at launch (VideoScanApp) and by tests.
    func install(_ role: RemoteViewerRole) {
        lock.withLock { self.role = role }
    }

    /// Reset to the master default and drop captured refusals (tests).
    func reset(sink: ((String) -> Void)? = nil) {
        lock.withLock {
            role = .master
            refusalLog.removeAll()
            self.sink = sink ?? { appLog.write($0) }
        }
    }

    var currentRole: RemoteViewerRole { lock.withLock { role } }
    var isViewer: Bool { currentRole.isViewer }

    /// "RicksM4" — the master's hostname without `.local`, for banners
    /// and the "on the master (RicksM4)" disabled-control hint. On the
    /// master itself this is the local machine's short name, but no UI
    /// shows it there.
    var masterDisplayName: String {
        switch currentRole {
        case .master:
            return Self.shortName(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        case .viewer(let hostname):
            return Self.shortName(hostname)
        }
    }

    static func shortName(_ hostname: String) -> String {
        var name = hostname
        if name.lowercased().hasSuffix(".local") { name = String(name.dropLast(".local".count)) }
        return name
    }

    /// The disabled-control hint every master-only affordance shows.
    var masterOnlyHint: String { "on the master (\(masterDisplayName))" }

    /// Every refusal this process has logged, oldest first (bounded).
    var refusals: [String] { lock.withLock { refusalLog } }

    fileprivate func recordRefusal(_ line: String) {
        let sink: (String) -> Void = lock.withLock {
            refusalLog.append(line)
            if refusalLog.count > Self.refusalLogCapacity {
                refusalLog.removeFirst(refusalLog.count - Self.refusalLogCapacity)
            }
            return self.sink
        }
        sink(line)
    }
}

/// The one-line guard write paths call. Returns true when the write must
/// NOT happen (viewer mode) — and logs why, naming the path, so the
/// enforcement sensor and catalog.log both see it.
enum ViewerWriteGuard {
    static let logPrefix = "[viewer] refused write:"

    /// `path` names the write ("CatalogStore.saveNow", "POIProfile.save").
    /// Cheap on the master: one lock take and a Bool compare.
    @discardableResult
    static func refuse(_ path: String, center: ViewerModeCenter = .shared) -> Bool {
        guard center.isViewer else { return false }
        center.recordRefusal("\(logPrefix) \(path) — \(center.masterOnlyHint)")
        return true
    }

    /// Typed error for throwing write paths so callers can show the hint.
    struct RefusedError: LocalizedError {
        let path: String
        let hint: String
        var errorDescription: String? { "\(path) is not available on a viewer — \(hint)" }
    }

    /// Throwing variant for `throws` write paths.
    static func check(_ path: String, center: ViewerModeCenter = .shared) throws {
        if refuse(path, center: center) {
            throw RefusedError(path: path, hint: center.masterOnlyHint)
        }
    }
}

/// Copy for the Family Tree tab's viewer-specific banner: a generation the
/// master compiled that this build cannot read. Pure so a test can pin
/// the exact wording without a view.
enum FamilyTreeViewerBanner {
    static func compiledElsewhereText(center: ViewerModeCenter = .shared) -> String {
        "Family tree compiled on \(center.masterDisplayName) — sync again once the master is up to date."
    }
}
