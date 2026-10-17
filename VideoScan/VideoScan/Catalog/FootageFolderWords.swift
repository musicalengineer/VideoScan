// FootageFolderWords.swift
// Every word, glyph, colour and spacing the Footage folders view shows —
// in ONE place so Rick can iterate on the real app without touching the
// model or the table (docs/design/footage_folders_2026_10_16.md §2: the
// UI is tried on the real catalog and tweaked by eye). Since 2026-10-17
// the view is a two-level Finder (FootageFolderLevel.swift): the words
// for the breadcrumb bar and the Back button live here too.
//
// Nothing here reads a record. (For Rick: a namespace of constants —
// a C++ `namespace` of `constexpr` values and a few tiny pure functions.)

import SwiftUI

enum FootageFolderWords {

    // MARK: The Show option

    /// Show ▸ "Events & Copies as Folders".
    static let showOptionTitle = "Events & Copies as Folders"
    static let showOptionHelpOn = "Confirmed events are folders, like the Finder: double-click one to see its footage with the copies and versions under each recording. Click to go back to the plain list."
    static let showOptionHelpOff = "Click to see each confirmed event as a folder (Finder-style); double-click a folder to see its footage with the copies and versions under each recording."
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
    static let backSymbol = "chevron.left"

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

    /// "12 items · 3 copies" — the Finder's word for a folder's contents.
    static func itemsAndCopies(items: Int, copies: Int) -> String {
        var s = "\(items) item\(items == 1 ? "" : "s")"
        if copies > 0 { s += "\(separator)\(copies) cop\(copies == 1 ? "y" : "ies")" }
        return s
    }

    /// "3 archived" / "" when none.
    static func archived(_ count: Int) -> String {
        count > 0 ? "\(count) archived" : ""
    }

    /// "Nov 26, 2009" for one day; "Nov 26, 2009 – Nov 28, 2009" for a
    /// span (whichever order the two days come in).
    static func dateRange(_ a: Date, _ b: Date) -> String {
        let from = FootageFolders.dateFormatter.string(from: min(a, b))
        let to = FootageFolders.dateFormatter.string(from: max(a, b))
        return from == to ? from : "\(from) \u{2013} \(to)"
    }

    // MARK: The breadcrumb bar, the Back button and the legend

    /// The root of every path: "Catalog".
    static let crumbRoot = "Catalog"
    static let crumbSeparator = " \u{25B8} "   // ▸
    /// "Catalog ▸ Marks Birthday 1984"; "Catalog" at the top.
    static func crumbPath(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return crumbRoot }
        return "\(crumbRoot)\(crumbSeparator)\(title)"
    }
    static let crumbAll = "\u{2039} All"      // ‹ All
    /// "‹ All · Thanksgiving 2009" — the Back button's spoken label.
    static func crumb(_ title: String) -> String { "\(crumbAll)\(separator)\(title)" }
    static let backTitle = "Back"
    static let backHelp = "Back to the whole catalog (\u{2318}\u{2191}, \u{2190} or Esc — the Finder's Enclosing Folder)."
    static let backHelpAtTop = "You are at the top of the catalog."
    static func folderRowHelp(_ title: String) -> String {
        "\(title) — double-click, Return, \u{2318}\u{2193} or \u{2192} to open it."
    }
    static func copiesScopeTitle(_ filename: String) -> String { "Copies & related: \(filename)" }

    static let legend = "\(madeFromGlyph) made from it\u{2003}\(copyGlyph) copy\u{2003}\(clipGlyph) clip of it\u{2003}\(sameEventGlyph) same event"
    static let legendHelp = "How a row relates to the recording above it. Double-click a folder (or \u{2318}\u{2193}) to open it; \u{2318}\u{2191}, Back or Esc returns to the catalog."

    // MARK: Right-click

    static let showCopiesAndRelated = "Show Copies & Related\u{2026}"
    static let showInItsEvent = "Show in its event"
    static let openFolder = "Open Folder"

    // MARK: A derivative landed — the one console line

    static func landed(_ name: String, source: String) -> String {
        "Catalog: \(name) is in the catalog (made from \(source))"
    }
    static func landedSelected(_ name: String, source: String) -> String {
        "\(landed(name, source: source)) — selected."
    }
    static func landedInFolder(_ name: String, source: String, folder: String) -> String {
        "\(landed(name, source: source)) — it lands in \(folder); selected there."
    }
    static func landedHiddenByFilter(_ name: String, source: String) -> String {
        "\(landed(name, source: source)) — hidden by the current filter or search, so it is not selected."
    }
    static func landedOutsideScope(_ name: String, source: String, scope: String, place: String?) -> String {
        let placeWords = place.map { "it is in \($0)" } ?? "it is in no event"
        return "\(landed(name, source: source)) — the list is narrowed to \(scope); \(placeWords), so it is not selected."
    }

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
    static let crumbFont = Font.system(size: 12, weight: .medium)
    /// Rows with a relation glyph indent this much under their recording.
    static let memberIndent: CGFloat = 22
    static let glyphWidth: CGFloat = 12
}
