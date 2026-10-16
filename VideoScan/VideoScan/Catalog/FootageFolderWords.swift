// FootageFolderWords.swift
// Every word, glyph, colour and spacing the Footage folders view shows —
// in ONE place so Rick can iterate on the real app without touching the
// model or the table (docs/design/footage_folders_2026_10_16.md §2: the
// UI is tried on the real catalog and tweaked by eye).
//
// Nothing here reads a record. (For Rick: a namespace of constants —
// a C++ `namespace` of `constexpr` values and a few tiny pure functions.)

import SwiftUI

enum FootageFolderWords {

    // MARK: The Show option

    /// Show ▸ "Events & Copies as Folders".
    static let showOptionTitle = "Events & Copies as Folders"
    static let showOptionHelpOn = "Confirmed events are folders and a file's copies and versions sit under it. Click to go back to the plain list."
    static let showOptionHelpOff = "Click to see each confirmed event as a folder, with a file's copies and versions under it (Finder-style)."
    /// The pill in the Showing box while the option is on.
    static let showingPill = "As folders"
    /// The UserDefaults key the option is remembered under.
    static let settingKey = "catalog.footageFolders"

    // MARK: Glyphs (one per relation, as the design names them)

    static let madeFromGlyph = "\u{21B3}"      // ↳
    static let copyGlyph = "="
    static let clipGlyph = "\u{2282}"          // ⊂
    static let sameEventGlyph = "\u{2248}"     // ≈
    static let folderSymbol = "folder"
    static let folderOpenSymbol = "folder.fill"
    static let chevronClosed = "chevron.right"
    static let chevronOpen = "chevron.down"

    // MARK: Relation words (after the name, muted)

    static let madeFromWords = "made from it"
    static let copyWords = "copy"
    static let copyByteForByte = "byte for byte"
    static let copySameGroup = "same duplicate group"
    static let clipWords = "clip of it"
    static let sameEventWords = "same event · different footage"
    static let separator = " · "

    /// "made from it · FFV1 preservation master" — the derivation kind in
    /// family words; an unknown kind reads as a plain version.
    static func madeFrom(kind: String?, codec: String) -> String {
        var parts = [madeFromWords]
        if let k = kind, let words = derivationKindWords[k] { parts.append(words) }
        else if !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: separator)
    }

    /// Derivation kinds → family words. A kind missing here reads as its
    /// codec (`madeFrom(kind:codec:)`), never as a raw key.
    static let derivationKindWords: [String: String] = [
        "transcode": "transcode",
        "preservation": "preservation master",
        "editing": "editing copy",
        "archival": "archival copy",
        "reformat": "reformatted",
        "trim": "trimmed",
        "balanceAudio": "balanced sound",
        "rebuildAudio": "repaired sound",
        "externalRepair": "repaired",
        "cleanup": "cleaned up",
        "promote": "archive copy",
    ]

    /// "copy · byte for byte, SanDiskWorkspace"
    static func copy(byteForByte: Bool, volume: String) -> String {
        let how = byteForByte ? copyByteForByte : copySameGroup
        return volume.isEmpty ? "\(copyWords)\(separator)\(how)" : "\(copyWords)\(separator)\(how), \(volume)"
    }

    // MARK: The folder row's summary columns

    /// "5 files · 2 copies"
    static func filesAndCopies(files: Int, copies: Int) -> String {
        var s = "\(files) file\(files == 1 ? "" : "s")"
        if copies > 0 { s += "\(separator)\(copies) cop\(copies == 1 ? "y" : "ies")" }
        return s
    }

    /// "3 archived" / "" when none.
    static func archived(_ count: Int) -> String {
        count > 0 ? "\(count) archived" : ""
    }

    // MARK: The breadcrumb and the legend

    static let crumbAll = "\u{2039} All"      // ‹ All
    static func crumb(_ title: String) -> String { "\(crumbAll)\(separator)\(title)" }
    static let crumbHelp = "Back to the whole list (or press Esc)."
    static func folderRowHelp(_ title: String) -> String {
        "\(title) — double-click to see only this event; → and ← open and close it."
    }
    static func copiesScopeTitle(_ filename: String) -> String { "Copies & related: \(filename)" }

    static let legend = "\(madeFromGlyph) made from it\u{2003}\(copyGlyph) copy\u{2003}\(clipGlyph) clip of it\u{2003}\(sameEventGlyph) same event"
    static let legendHelp = "How a row relates to the recording above it. →/← open and close a folder; double-click a folder to see only that event; Esc comes back."

    // MARK: Right-click

    static let showCopiesAndRelated = "Show Copies & Related\u{2026}"
    static let showInItsEvent = "Show in its event"
    static let openFolder = "Open Folder"
    static let closeFolder = "Close Folder"
    static let showOnlyThisEvent = "Show Only This Event"

    // MARK: Colours and spacing

    /// Copies read in grey; relation words are muted sans.
    static let copyColor = Color.secondary
    static let relationColor = Color.secondary
    static let summaryColor = Color.secondary
    static let folderTint = Color.accentColor
    static let relationFont = Font.system(size: 11)
    static let summaryFont = Font.system(size: 11, design: .monospaced)
    static let legendFont = Font.system(size: 11)
    static let glyphFont = Font.system(size: 12, design: .monospaced)
    /// Member rows indent this much in the name cell (one level only).
    static let memberIndent: CGFloat = 22
    static let chevronWidth: CGFloat = 14
}
