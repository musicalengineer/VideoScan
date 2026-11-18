// MachineEstimateFolders.swift
// The machine's grey folders in Catalog ▸ Show ▸ Folders (Rick 2026-11-13,
// the era guesses as folders; 2026-11-17, "one folder view showing every
// folder, Rick's (blue) and the machine's (grey), with the media files beside
// them"). "1980s (estimated)", "1991 (estimated)" — so he can see whether the
// machine's dating helps him group files. A VIEW only: nothing is stored, no
// folder is created, no date is written.
//
// One sentence: each catalog row whose content has a fused machine era
// (MachineEraStore's cache, the newest era per content) and that Rick has NOT
// filed in one of his own folders is filed under ONE synthetic folder chosen by
// Core's `MachineEraResolver.estimateFolder` — its year when the range is at
// most a year wide, else the decade of its midpoint — and those folders are
// handed to the same join (`FootageFolders.index`) beside Rick's, marked
// `byMachine`, so copies and versions still fold under their recording and a
// family that touches one of Rick's folders goes there, never grey
// (`FootageFolders.split`). A row with neither stays a loose file.
//
// THE HELD ROW, for grey folders (2026-11-17). A re-run of the era job can
// re-file a content into another grey folder. A row Rick has SELECTED does not
// move under him: its grey folder is held (`held`, record id → folder) until
// the selection moves off it — the same rule `CatalogRows` keeps for a row a
// Show filter stops matching. FootageFoldersSnapshot takes and releases holds.
//
// The folders are read-only: their ids are synthetic (derived from the year,
// stable across launches so an open triangle stays open) and no folder store
// knows them. The table's edit paths ask the row's id
// (`isEstimateFolder`) and refuse (rename, kind, delete, drop, move, remove);
// a drag OUT of one is an add to Rick's folder, never a move; Add to Folder ▸
// files a row in one of Rick's real folders, which is the point of looking.
//
// Cost: one pass over the rows with a hash probe each, off the main actor
// with the join (a second pass only when a hold exists). Memory: one content
// key per row that has an era.
//
// (For Rick: pure functions, rows + a map in, a vector of folder descriptors
// out — no state, like free functions in a C++ header.)

import Foundation
import SwiftUI
import VideoScanCore

enum MachineEstimateFolders {

    typealias EstimateFolder = MachineEraResolver.EstimateFolder

    /// The grey folders for `rows`, oldest first. `eras` is keyed by the
    /// content's whole-file digest (lowercase hex), newest era first.
    /// `excluding`: the content keys in Rick's own folders — never grey.
    /// `held`: rows Rick has selected → the grey folder they were in; such a
    /// row's content stays there whatever its era says now.
    static func events(rows: [FootageFolders.Row], eras: [String: [MachineEra]], excluding ownKeys: Set<String> = [],
                       held: [UUID: EstimateFolder] = [:]) -> [FootageFolders.Event] {
        guard !eras.isEmpty || !held.isEmpty else { return [] }
        var pinned: [String: EstimateFolder] = [:]
        if !held.isEmpty {
            for row in rows { if let f = held[row.id] { pinned[row.contentKey] = f } }
        }
        var keys: [EstimateFolder: Set<String>] = [:]
        for row in rows where !ownKeys.contains(row.contentKey) {
            guard let folder = pinned[row.contentKey] ?? estimate(row, eras: eras) else { continue }
            keys[folder, default: []].insert(row.contentKey)
        }
        return keys.keys.sorted().map { folder in
            FootageFolders.Event(id: folderID(folder), title: folder.title, dateWords: MachineEstimateWords.folderDateWords,
                                 contentKeys: (keys[folder] ?? []).sorted(), kind: .other, byMachine: true)
        }
    }

    /// The grey folder the row's newest era files it under; nil without one
    /// (or for a sampled `v1:` hash, which never names a content).
    static func estimate(_ row: FootageFolders.Row, eras: [String: [MachineEra]]) -> EstimateFolder? {
        guard let digest = FootageFolders.Row.wholeFileDigest(row.digest), let era = eras[digest]?.first else { return nil }
        return MachineEraResolver.estimateFolder(era: era)
    }

    /// A stable id per folder: the same year gives the same id on every
    /// launch. Its version and variant fields are zero, which `UUID()` (a
    /// version-4 UUID: version nibble 4, variant bits 10) can never produce,
    /// so an estimate folder's id can never equal one of Rick's (Codex #290).
    static func folderID(_ folder: EstimateFolder) -> UUID {
        let tag: Int
        switch folder {
        case .year: tag = 1
        case .decade: tag = 2
        }
        let year = min(max(0, folder.firstYear), 99_999_999)
        let text = idPrefix + String(format: "%04d%08d", tag, year)
        return UUID(uuidString: text) ?? unknownFolderID
    }

    /// `folderID`'s inverse: the year or decade an estimate folder's id
    /// names; nil for one of Rick's ids and for `unknownFolderID`. (A year
    /// below 0 was clamped to 0 by `folderID` and reads back as 0.)
    static func estimateFolder(fromID id: UUID) -> EstimateFolder? {
        guard isEstimateFolder(id) else { return nil }
        let tail = id.uuidString.suffix(12)
        guard let tag = Int(tail.prefix(4)), let year = Int(tail.suffix(8)) else { return nil }
        switch tag {
        case 1: return .year(year)
        case 2: return .decade(year)
        default: return nil
        }
    }

    static let idPrefix = "E57A0000-0000-0000-0000-"
    /// What an unformattable year would get: still inside the namespace.
    static let unknownFolderID = UUID(uuid: (0xE5, 0x7A, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF))

    /// Is `id` an estimate folder's? Asked of the ROW's id by every folder
    /// edit path, so a synthetic row still on screen while the join swaps
    /// is refused too (Codex #290): the row's own id answers, never a flag
    /// that may have moved ahead of the display.
    static func isEstimateFolder(_ id: UUID) -> Bool {
        let b = id.uuid
        return b.0 == 0xE5 && b.1 == 0x7A && b.2 == 0 && b.3 == 0 && b.4 == 0 && b.5 == 0
            && b.6 == 0 && b.7 == 0 && b.8 == 0 && b.9 == 0
    }
}

extension FootageFolders {

    /// Every folder the one view shows, for ONE join: Rick's own, then the
    /// machine's grey ones for every content he has not filed. Pure; run off
    /// the main actor by the model's refresh.
    static func oneViewEvents(rows: [Row], own: [Event], eras: [String: [MachineEra]],
                              held: [UUID: MachineEstimateFolders.EstimateFolder]) -> [Event] {
        let ownKeys = Set(own.lazy.flatMap(\.contentKeys))
        return own + MachineEstimateFolders.events(rows: rows, eras: eras, excluding: ownKeys, held: held)
    }

    /// The held rows whose grey folder differs from where the estimate would
    /// put them now — the only releases worth a re-join. Empty (and no pass)
    /// when nothing is held. A row Rick has filed since is not counted: it is
    /// in his folder either way.
    static func divergedHolds(rows: [Row], own: [Event], eras: [String: [MachineEra]],
                              held: [UUID: MachineEstimateFolders.EstimateFolder]) -> Set<UUID> {
        guard !held.isEmpty else { return [] }
        let ownKeys = Set(own.lazy.flatMap(\.contentKeys))
        var out: Set<UUID> = []
        for row in rows {
            guard let pinned = held[row.id], !ownKeys.contains(row.contentKey) else { continue }
            if MachineEstimateFolders.estimate(row, eras: eras) != pinned { out.insert(row.id) }
        }
        return out
    }
}

/// The grey folders' words (UI words are Rick's to change; one place).
enum MachineEstimateWords {
    static let symbol = "calendar.badge.clock"
    static let folderDateWords = "machine estimate, not confirmed"
    static let legend = "Grey folders are the machine's guess of the era, from the pictures alone — not confirmed. A file with no guess stays outside, unless it was made from one inside; a file you have put in one of your folders is never in a grey one."
    static let readOnlyMenuNote = "A machine estimate — not one of your folders"
    static let dropRefused = "a drop on a folder did nothing — this folder is a machine estimate, not one of your folders. Use Add to Folder to file it in one of yours."
}
