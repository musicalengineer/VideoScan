// FamilyTreeWriteGate.swift
// The Family Tree's read-only state (DECISIONS 2026-11-01, Rick: "why can't
// the user see the FT view in read-only mode from the M4?").
//
// The compiled graph (App Support/family-tree/compiled/) is local and reading
// it is safe; only the asset store (photos, documents, bookmarks, identity
// rulings, person refresh) needs the designated Master Archive. So when the
// archive is offline or mounted with the wrong UUID, or this Mac is a
// CatalogSync viewer, the tab shows the graph with EVERY writer disabled and
// says so in one banner. Nothing is written anywhere in that state.
//
// Two inputs decide it, and both already exist — no new global state:
//   • `FamilyAssetStore.Access` (published by the catalog model through
//     FamilyAssetConfigurationCenter: `.unavailable` = designated archive
//     offline or wrong UUID);
//   • the CatalogSync role (ViewerModeCenter, installed once at launch from
//     `catalogSync.viewerRole` — the same detection every viewer guard uses).
//
// Access × role → mode:
//
//                    master                 viewer
//   .readWrite       full (today)           read-only (viewer)
//   .readOnly        full (today: the asset read-only (viewer)
//                    store refuses its own
//                    writes, as before)
//   .unavailable     read-only (archive)    read-only (viewer)
//
// "Refused" is no longer an access outcome. The only refusal left is a load
// outcome: in read-only mode there is no compiled graph this build can read
// (missing, corrupt, or another version's), so there is nothing to show.
//
// Every writer in FamilyTree/ checks the mode through `check` / `refuse`
// (the source sensor FamilyTreeReadOnlyWriteSiteSensorTests lists them).
// On a viewer the refusal is delegated to ViewerWriteGuard so the viewer's
// own refusal capture and wording are unchanged; with the archive absent
// the refusal is logged here, one line, and thrown as `Refused`.
//
// (For Rick: `enum … { case readOnly(Reason) }` ≈ a C++ std::variant with a
// payload; `static func` ≈ a free function in a namespace.)

import Foundation
import VideoScanCore

/// What the Family Tree tab may do right now.
enum FamilyTreeAccessMode: Equatable, Sendable {
    /// Behaviour exactly as before 2026-11-01.
    case full
    /// The compiled graph is shown; every writer is disabled.
    case readOnly(Reason)

    enum Reason: Equatable, Sendable {
        /// The designated Master Archive is offline or has the wrong UUID.
        case archiveUnavailable
        /// This Mac is a CatalogSync viewer.
        case viewer
    }

    var isReadOnly: Bool { self != .full }
    var allowsWrites: Bool { self == .full }

    /// The matrix in the header. Pure; the one place it is decided.
    static func resolve(access: FamilyAssetStore.Access, isViewer: Bool) -> FamilyTreeAccessMode {
        if isViewer { return .readOnly(.viewer) }
        if access == .unavailable { return .readOnly(.archiveUnavailable) }
        return .full
    }

    /// The process-wide answer, for writers that live outside the tree model
    /// (walk decorations, person refresh, pulls, research, pins). Read at
    /// each use, so an archive that comes back is honoured without a relaunch.
    static func current(configuration: FamilyAssetConfigurationCenter = .shared,
                        viewer: ViewerModeCenter = .shared) -> FamilyTreeAccessMode {
        resolve(access: configuration.snapshot().access, isViewer: viewer.isViewer)
    }
}

extension FamilyTreeAccessMode {
    /// The stricter of two answers: viewer › archive absent › full. A writer
    /// that has two sources of authority (its own cached access and the
    /// published one) obeys whichever says less.
    func strictest(_ other: FamilyTreeAccessMode) -> FamilyTreeAccessMode {
        if self == .readOnly(.viewer) || other == .readOnly(.viewer) { return .readOnly(.viewer) }
        if isReadOnly || other.isReadOnly { return .readOnly(.archiveUnavailable) }
        return .full
    }
}

/// A model's own source access, readable from any thread, so detached work
/// re-reads it at the moment it writes (codex #190 F2/F3). C++: a mutex-
/// guarded value.
final class FamilyTreeAccessLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var access: FamilyAssetStore.Access
    init(_ access: FamilyAssetStore.Access) { self.access = access }
    var value: FamilyAssetStore.Access { lock.withLock { access } }
    func set(_ next: FamilyAssetStore.Access) { lock.withLock { access = next } }
}

/// "May the Family Tree write NOW?" — the published archive authority
/// (FamilyAssetConfigurationCenter), the CatalogSync role (ViewerModeCenter)
/// and, for a tree model, its own configured access; the strictest wins.
/// Evaluated at each call: a value to hand to detached work, never a
/// snapshot of the answer.
struct FamilyTreeWriteAuthority: Sendable {
    var latch: FamilyTreeAccessLatch?
    var configuration: FamilyAssetConfigurationCenter = .shared
    var viewer: ViewerModeCenter = .shared

    var mode: FamilyTreeAccessMode {
        let published = FamilyTreeAccessMode.current(configuration: configuration, viewer: viewer)
        guard let latch else { return published }
        return FamilyTreeAccessMode.resolve(access: latch.value, isViewer: viewer.isViewer).strictest(published)
    }

    func check(_ writer: FamilyTreeWriter, path: String,
               log: (String) -> Void = { appLog.write($0) }) throws {
        try FamilyTreeWriteGate.check(writer, path: path, mode: mode, viewerCenter: viewer, log: log)
    }

    /// The process-wide authority (no model): published configuration + role.
    static var process: FamilyTreeWriteAuthority { FamilyTreeWriteAuthority(latch: nil) }

    /// This authority as a Core `WritePermit`: asked — and logging its own
    /// refusal — at each nested write.
    func permit(_ writer: FamilyTreeWriter, path: String,
                log: @escaping @Sendable (String) -> Void = { appLog.write($0) }) -> WritePermit {
        let authority = self
        return WritePermit { what in
            !FamilyTreeWriteGate.refuse(writer, path: "\(path) [\(what)]", mode: authority.mode,
                                        viewerCenter: authority.viewer, log: log)
        }
    }

    /// THE Family Tree write primitive (codex #193). Asks the live authority
    /// NOW — call it after every lock and await, wrapping the bytes — and
    /// binds it as `WritePermit.current`, so a Core writer inside `body` that
    /// waits for its own lock (CyberBrain, the compiled store, the overlay)
    /// asks again after that wait, before its first byte. Every write in
    /// FamilyTree/ is lexically inside one of these (the sensor proves it).
    func withWrite<T>(_ writer: FamilyTreeWriter, path: String,
                      log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
                      _ body: () throws -> T) throws -> T {
        // The check NOW, in the gate's own words and error types; then the
        // same authority bound for every nested write.
        try FamilyTreeWriteGate.check(writer, path: path, mode: mode, viewerCenter: viewer, log: log)
        return try WritePermit.$current.withValue(permit(writer, path: path, log: log)) { try body() }
    }

    /// For a READ that may write as a side effect (a load that can promote a
    /// compile or retire an overlay): no check now — the nested writes ask
    /// at their own moment, through the bound permit.
    func whileReading<T>(_ writer: FamilyTreeWriter, path: String,
                         log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
                         _ body: () throws -> T) rethrows -> T {
        try WritePermit.$current.withValue(permit(writer, path: path, log: log), operation: body)
    }
}

extension FamilyTreeAccessMode {
    /// A mode supplier as a primitive authority (coordinators that carry a
    /// `writeMode` closure): same `withWrite`, same binding.
    static func withWrite<T>(_ writer: FamilyTreeWriter, path: String,
                             mode: @escaping @Sendable () -> FamilyTreeAccessMode,
                             log: @escaping @Sendable (String) -> Void = { appLog.write($0) },
                             _ body: () throws -> T) throws -> T {
        try FamilyTreeWriteGate.check(writer, path: path, mode: mode(), log: log)
        return try WritePermit.$current.withValue(permit(writer, path: path, mode: mode, log: log)) { try body() }
    }

    /// A mode supplier as a Core permit (asked at each nested write).
    static func permit(_ writer: FamilyTreeWriter, path: String,
                       mode: @escaping @Sendable () -> FamilyTreeAccessMode,
                       log: @escaping @Sendable (String) -> Void = { appLog.write($0) }) -> WritePermit {
        WritePermit { what in
            !FamilyTreeWriteGate.refuse(writer, path: "\(path) [\(what)]", mode: mode(), log: log)
        }
    }
}

/// One case per write the Family Tree can make. The view disables the
/// matching control from `FamilyTreeLiveModel.isEnabled(_:)`; the write path
/// itself refuses through `FamilyTreeWriteGate` (model level, not view level).
enum FamilyTreeWriter: String, CaseIterable, Sendable {
    // The raw value is the words a refusal uses ("Bookmarking is
    // unavailable until …").
    case photo = "Choosing photos"                          // choose / crop / record a photo
    case document = "Adding or removing documents"          // add, remove, file a found record
    case bookmark = "Bookmarking"
    case identityRuling = "Hiding or showing records"       // Hide / Unhide a duplicate
    case identityPin = "Linking People profiles to the tree"
    case personRefresh = "Refresh from FamilySearch"        // launch / apply / undo
    case familySearchPull = "Get Family Tree"               // download / install / merge
    case recompile = "Recompiling the tree"
    case note = "Writing notes"                             // CyberBrain notes, corrections, testimony
    case pronunciation = "Saving pronunciations"            // "Said as" (CyberBrain)
    case research = "Saving research"                       // Research Person… dossier cache
    case walkDecorations = "Saving the tree walk"           // decorations.json
    case personOfTheDay = "Remembering the Person of the Day"
    case couplePortrait = "Changing the portrait"
    case crest = "Adding crests"
    case revealFolder = "Creating the GEDCOM folder"        // "Reveal folder"

    var noun: String { rawValue }
}

enum FamilyTreeWriteGate {
    /// The banner, verbatim from the ruling. Shown while the state holds.
    static let bannerText = "Photos and documents are unavailable until the Master Archive is connected"

    /// Every archive-absent refusal line starts with this (test sensor).
    static let logPrefix = "[family-tree] refused write (read-only):"

    struct Refused: LocalizedError, Equatable {
        let writer: FamilyTreeWriter
        let path: String
        var errorDescription: String? {
            "\(writer.noun) is unavailable until the Master Archive is connected."
        }
    }

    /// Throws when `mode` is read-only. On a viewer the refusal (log line,
    /// error type, wording) is ViewerWriteGuard's, unchanged; with the
    /// archive absent it is one line through `log` and a `Refused`.
    static func check(_ writer: FamilyTreeWriter, path: String,
                      mode: FamilyTreeAccessMode,
                      viewerCenter: ViewerModeCenter = .shared,
                      log: (String) -> Void = { appLog.write($0) }) throws {
        switch mode {
        case .full:
            return
        case .readOnly(.viewer):
            try ViewerWriteGuard.check(path, center: viewerCenter)
            // The mode said viewer but this center does not (a caller passed
            // a mode computed elsewhere): still refuse, never write.
            log("\(logPrefix) \(path) — viewer mode")
            throw Refused(writer: writer, path: path)
        case .readOnly(.archiveUnavailable):
            log("\(logPrefix) \(path) — the Master Archive is not connected")
            throw Refused(writer: writer, path: path)
        }
    }

    /// Non-throwing form: true = refused (and logged), touch nothing.
    @discardableResult
    static func refuse(_ writer: FamilyTreeWriter, path: String,
                       mode: FamilyTreeAccessMode,
                       viewerCenter: ViewerModeCenter = .shared,
                       log: (String) -> Void = { appLog.write($0) }) -> Bool {
        do {
            try check(writer, path: path, mode: mode, viewerCenter: viewerCenter, log: log)
            return false
        } catch {
            return true
        }
    }

    /// The words for a refusal in `mode` (what a sheet or inspector line says).
    static func refusalText(_ writer: FamilyTreeWriter, mode: FamilyTreeAccessMode,
                            viewerCenter: ViewerModeCenter = .shared) -> String? {
        switch mode {
        case .full: return nil
        case .readOnly(.viewer): return "\(writer.noun) happens \(viewerCenter.masterOnlyHint)."
        case .readOnly(.archiveUnavailable): return Refused(writer: writer, path: "").errorDescription
        }
    }
}
