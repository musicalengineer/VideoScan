// MachineEstimateFolders.swift
// Catalog ▸ Show ▸ Folders by Machine Estimate (Rick 2026-11-13): the folder
// table filled with the era job's guesses instead of Rick's own folders —
// "1980s (estimated)", "1991 (estimated)" — so he can see whether the
// machine's dating helps him group files. A VIEW only: nothing is stored,
// no folder is created, no date is written; switching it off puts his own
// folders back exactly as they were.
//
// One sentence: each catalog row whose content has a fused machine era
// (MachineEraStore's cache, the newest era per content) is filed under ONE
// synthetic folder chosen by Core's `MachineEraResolver.estimateFolder` —
// its year when the range is at most a year wide, else the decade of its
// midpoint — and those folders are handed to the same join
// (`FootageFolders.index`) as `Event`s, so copies and versions still fold
// under their recording. A row with no era stays a loose file.
//
// The folders are read-only: their ids are synthetic (derived from the
// year, stable across launches so an open triangle stays open) and no
// folder store knows them. The table's edit paths ask
// `FootageFolders.Index.estimated` and refuse (rename, kind, delete, drop,
// move, remove); Add to Folder ▸ still files a row in one of Rick's real
// folders, which is the point of looking.
//
// Cost: one pass over the rows with a hash probe each, off the main actor
// with the join. Memory: one content key per row that has an era.
//
// (For Rick: a pure function, rows + a map in, a vector of folder
// descriptors out — no state, like a free function in a C++ header.)

import Foundation
import SwiftUI
import VideoScanCore

enum MachineEstimateFolders {

    /// The UserDefaults key the option is remembered under.
    static let settingKey = "catalog.foldersByMachineEstimate"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: settingKey) }
    static func set(_ on: Bool, _ defaults: UserDefaults = .standard) { defaults.set(on, forKey: settingKey) }

    /// The folders for `rows`, oldest first. `eras` is keyed by the content's
    /// whole-file digest (lowercase hex), newest era first.
    static func events(rows: [FootageFolders.Row], eras: [String: [MachineEra]]) -> [FootageFolders.Event] {
        guard !eras.isEmpty else { return [] }
        var keys: [MachineEraResolver.EstimateFolder: Set<String>] = [:]
        for row in rows {
            guard let digest = FootageFolders.Row.wholeFileDigest(row.digest), let era = eras[digest]?.first else { continue }
            keys[MachineEraResolver.estimateFolder(era: era), default: []].insert(row.contentKey)
        }
        return keys.keys.sorted().map { folder in
            FootageFolders.Event(id: folderID(folder), title: folder.title, dateWords: MachineEstimateWords.folderDateWords,
                                 contentKeys: (keys[folder] ?? []).sorted(), kind: .other)
        }
    }

    /// A stable id per folder: the same year gives the same id on every
    /// launch. Its version and variant fields are zero, which `UUID()` (a
    /// version-4 UUID: version nibble 4, variant bits 10) can never produce,
    /// so an estimate folder's id can never equal one of Rick's (Codex #290).
    static func folderID(_ folder: MachineEraResolver.EstimateFolder) -> UUID {
        let tag: Int
        switch folder {
        case .year: tag = 1
        case .decade: tag = 2
        }
        let year = min(max(0, folder.firstYear), 99_999_999)
        let text = idPrefix + String(format: "%04d%08d", tag, year)
        return UUID(uuidString: text) ?? unknownFolderID
    }

    static let idPrefix = "E57A0000-0000-0000-0000-"
    /// What an unformattable year would get: still inside the namespace.
    static let unknownFolderID = UUID(uuid: (0xE5, 0x7A, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF))

    /// Is `id` an estimate folder's? Asked of the ROW's id by every folder
    /// edit path, so a synthetic row still on screen while the join swaps
    /// back to Rick's folders is refused too (Codex #290): the row's own id
    /// answers, never a flag that may have moved ahead of the display.
    static func isEstimateFolder(_ id: UUID) -> Bool {
        let b = id.uuid
        return b.0 == 0xE5 && b.1 == 0x7A && b.2 == 0 && b.3 == 0 && b.4 == 0 && b.5 == 0
            && b.6 == 0 && b.7 == 0 && b.8 == 0 && b.9 == 0
    }
}

/// The estimate view's words (UI words are Rick's to change; one place).
enum MachineEstimateWords {
    static let toggleTitle = "Folders by Machine Estimate"
    static let symbol = "calendar.badge.clock"
    static let help = "Group the files by the era the machine guessed from the pictures (1980s, 1990s, or a year it read on screen). A view only: nothing is filed, dated or changed, and your own folders come back when you switch it off."
    static let pill = "By machine estimate"
    static let folderDateWords = "machine estimate, not confirmed"
    static let legend = "Folders are the machine's guess of the era, from the pictures alone — not confirmed. A file with no guess stays outside, unless it was made from one inside."
    static let readOnlyMenuNote = "A machine estimate — not one of your folders"
    static let dropRefused = "a drop on a folder did nothing — this folder is a machine estimate, not one of your folders. Use Add to Folder to file it in one of yours."
}

/// Show ▸ Folders by Machine Estimate — its menu row. Turning it on turns
/// the folder view on; turning the folder view off turns it off (the parent).
struct MachineEstimateFoldersToggle: View {
    @ObservedObject var folders: FootageFoldersSnapshot
    @Binding var foldersOn: Bool
    let apply: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { foldersOn && folders.estimated },
                             set: { on in
                                 apply(on)
                                 if on { foldersOn = true }
                             })) {
            Label(MachineEstimateWords.toggleTitle, systemImage: MachineEstimateWords.symbol)
        }
        .help(MachineEstimateWords.help)
        .accessibilityIdentifier("catalog.show.foldersByMachineEstimate")
    }
}
