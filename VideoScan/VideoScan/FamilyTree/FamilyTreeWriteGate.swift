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
