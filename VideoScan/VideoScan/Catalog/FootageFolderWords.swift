// FootageFolderWords.swift
// Every word, glyph, colour and spacing the Footage folders view shows —
// in ONE place so Rick can iterate on the real app without touching the
// model or the table (docs/archive/design/footage_folders_2026_10_16.md §2: the
// UI is tried on the real catalog and tweaked by eye). Since 2026-10-17
// the view is a two-level Finder (FootageFolderLevel.swift): the words
// for the breadcrumb bar and the Back button live here too.
//
// Nothing here reads a record. (For Rick: a namespace of constants —
// a C++ `namespace` of `constexpr` values and a few tiny pure functions.)

import SwiftUI

enum FootageFolderWords {

    // MARK: The Show option

    /// Show ▸ "Folders" — the ONE folder view (DECISIONS 2026-11-17; it
    /// replaced Events & Copies as Folders, Folders Only and Folders by
    /// Machine Estimate). The Showing box says the same word.
    static let showOptionTitle = "Folders"
    static let showOptionHelpOn = "Showing every folder first — yours in colour, the machine's era guesses in grey — then every file in no folder. A folder's triangle shows its files; drag a file onto one of your folders (or right-click \u{25B8} Add to Folder) to file it. Click to go back to the plain list."
    static let showOptionHelpOff = "Click to see every folder — yours and the machine's era guesses in grey — above the files in no folder, so you can drag files into your folders."
    /// The pill in the Showing box while the view is on: the menu's word.
    static let showingPill = showOptionTitle

    // MARK: Glyphs (one per relation, as the design names them)

    static let madeFromGlyph = "\u{21B3}"      // ↳
    static let copyGlyph = "="
    static let clipGlyph = "\u{2282}"          // ⊂
    static let sameEventGlyph = "\u{2248}"     // ≈
    /// Filled, like the Finder's list view: an outline folder vanished on
    /// the dark theme (Rick 2026-10-19).
    static let folderSymbol = "folder.fill"
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

    /// "26-Nov-2009" for one day; "26-Nov-2009 – 28-Nov-2009" for a span
    /// (whichever order the two days come in) — the Catalog table's one
    /// date spelling (CatalogTableDate.swift).
    static func dateRange(_ a: Date, _ b: Date) -> String {
        CatalogTableDate.range(a, b)
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
        "\(title) — the triangle or \u{2192} shows it here (\u{2325}-click: every folder); double-click, Return or \u{2318}\u{2193} opens it."
    }
    static func copiesScopeTitle(_ filename: String) -> String { "Copies & related: \(filename)" }

    static let legend = "\(madeFromGlyph) made from it\u{2003}\(copyGlyph) copy\u{2003}\(clipGlyph) clip of it\u{2003}\(sameEventGlyph) same event\u{2003}grey folder: the machine's era guess, not confirmed"
    static let legendHelp = "How a row relates to the recording above it. A folder's triangle (or \u{2192} / \u{2190}) shows or hides its footage in place, \u{2325}-click for every folder; double-click a folder (or \u{2318}\u{2193}) to open it; \u{2318}\u{2191}, Back or Esc returns to the catalog.\n\n" + MachineEstimateWords.legend

    // MARK: Right-click

    static let showCopiesAndRelated = "Show Copies & Related\u{2026}"
    static let showInItsEvent = "Show in its event"
    static let openFolder = "Open Folder"
    static let renameFolder = "Rename\u{2026}"
    static let folderKindMenu = "Folder Kind"
    static let deleteFolder = "Delete Folder\u{2026}"
    static let addToFolder = "Add to Folder"
    static let moveToFolder = "Move to Folder"
    static func removeFromFolder(_ name: String) -> String { "Remove from \u{201C}\(name)\u{201D}" }
    static let noOtherFolders = "No other folders"
    static let addHelp = "The files join that folder and stay in every folder they are already in."
    static let moveHelp = "The files leave this folder and join that one (other folders keep them)."
    static let removeHelp = "The files leave this folder only — they stay on disk and in every other folder."

    // MARK: Rename and delete

    static let renameTitle = "Rename Folder"
    static let renameButton = "Rename"
    static func deleteTitle(_ name: String) -> String { "Delete the folder \u{201C}\(name)\u{201D}?" }
    static func deleteMessage(files: Int) -> String {
        "It holds \(files) file\(files == 1 ? "" : "s"). Only the folder goes: the files stay on disk, in the catalog and in every other folder, and the folder's history is kept."
    }
    static let deleteButton = "Delete Folder"

    // MARK: The folder inspector

    static let inspectorKind = "Kind"
    static let inspectorCreated = "Created"
    static let inspectorChanged = "Last changed"
    static let inspectorFiles = "Files"
    static let inspectorDuration = "Total duration"
    static let inspectorSize = "Total size"
    static let inspectorDates = "Dates"
    static let inspectorVolumes = "Volumes"
    static let inspectorOnline = "Online"
    static let inFolders = "In folders"

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
    /// The Finder's folder blue, a lighter blue than the accent so it
    /// reads on the dark theme (the accent blue sank into the row stripes).
    static let folderTint = Color(red: 0.36, green: 0.68, blue: 0.96)
    /// A person's folder (Rick 2026-10-19): green, as light as the blue.
    static let personFolderTint = Color(red: 0.40, green: 0.80, blue: 0.47)
    /// Any other folder: a neutral grey that still reads on the dark theme.
    static let otherFolderTint = Color(white: 0.62)

    /// The machine's era-guess folder (2026-11-17, "Rick's (blue) and the
    /// machine's (grey)"): a darker grey than Rick's "other" folders and its
    /// own symbol, so a guess is never mistaken for a folder he made.
    static let machineFolderTint = Color(white: 0.48)
    static let machineFolderSymbol = "questionmark.folder.fill"

    /// Event blue, person green, other grey — Rick's own folders; a folder
    /// the machine guessed is always the machine grey.
    static func folderTint(for kind: FolderKind, byMachine: Bool = false) -> Color {
        if byMachine { return machineFolderTint }
        switch kind {
        case .event: return folderTint
        case .person: return personFolderTint
        case .other: return otherFolderTint
        }
    }
    static let folderSymbolFont = Font.system(size: 17.3)
    static let folderTitleFont = Font.system(.body).weight(.semibold)
    static let relationFont = Font.system(size: 11)
    static let legendFont = Font.system(size: 11)
    static let glyphFont = Font.system(size: 12, design: .monospaced)
    /// Back and the path: big and bold enough to find on the dark theme (Rick 2026-10-19).
    static let crumbFont = Font.system(size: 14, weight: .bold)
    /// A copy, version or clip indents this much under its recording —
    /// one outline step, the same as the system's own child indent, so the
    /// triangle-and-indent hierarchy reads like the Finder's (2026-10-18;
    /// was 22). A ≈ row is a recording in its own right: no indent, the
    /// glyph is only its marker.
    static let memberIndent: CGFloat = 16
    static let glyphWidth: CGFloat = 12

    /// How far a member row's glyph sits in from its own outline level.
    static func indent(for relation: FootageFolders.Relation) -> CGFloat {
        if case .sameEvent = relation { return 0 }
        return relation.glyph == nil ? 0 : memberIndent
    }
}
