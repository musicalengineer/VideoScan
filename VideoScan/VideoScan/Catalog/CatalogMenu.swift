// CatalogMenu.swift — the Catalog menu as ONE value (Rick 2026-11-01,
// DECISIONS "The Catalog menu is three groups and Catalog Status answers
// three questions"):
//
//   Catalog Status — <Database|Files> needs attention… / — Green…
//   Validate Catalog…
//   Update Catalog…
//   Tidy Catalog… (N)                 hidden when N = 0
//   ─────────────
//   Delete Selected Files…   ⌘⌫       the file verb (to the Finder Trash)
//   ─────────────
//   Content Analysis…                 the content verb (the analyzers live there)
//
// Shape: `CatalogMenuLayout.entries(tidyTotal:)` is the item list and order
// as a pure value (CatalogMenuTests pins it); `CatalogMenuContent` renders
// exactly that list, so the menu cannot drift from the value. Every verb
// keeps its ONE engine (rule 4): each case below calls the function the
// old item called; only the entry points moved (CatalogMenuSensorTests
// asserts the call targets).
//
// The "what and how long" rule (same ruling): every item with an ellipsis
// opens a sheet whose first lines say what it touches, what it never
// touches and its time class; the item's help text repeats the first line.
// The words live here once (`CatalogActionBrief`), so the help and the
// sheet cannot disagree.
//
// State: `CatalogMenuStore` — a feature store (rule 12, #337), owned by the
// App, holding which sheet the menu asked the main window to show. Nothing
// here extends VideoScanModel.
//
// (For Rick: an `enum` with associated values ≈ a tagged union; the layout
// function ≈ a constexpr table builder; `@ObservedObject` ≈ a subscription
// to one object's change signal.)

import Combine
import SwiftUI
import VideoScanCore

// MARK: - The item list (pure)

/// One row of the Catalog menu.
enum CatalogMenuEntry: Equatable, Sendable {
    case catalogStatus
    case validateCatalog
    case updateCatalog
    /// `total` = the sum of the Tidy sheet's live counts (> 0, or the row is not there).
    case tidyCatalog(total: Int)
    case divider
    case deleteSelectedFiles
    case contentAnalysis
}

enum CatalogMenuLayout {

    static let validateTitle = "Validate Catalog…"
    static let updateTitle = "Update Catalog…"
    static let deleteTitle = "Delete Selected Files…"
    static let contentAnalysisTitle = "Content Analysis…"
    static let tidyTitlePrefix = "Tidy Catalog…"

    /// The three groups, in order: catalog verbs · the file verb · the content verb.
    static func entries(tidyTotal: Int) -> [CatalogMenuEntry] {
        var out: [CatalogMenuEntry] = [.catalogStatus, .validateCatalog, .updateCatalog]
        if tidyTotal > 0 { out.append(.tidyCatalog(total: tidyTotal)) }
        out += [.divider, .deleteSelectedFiles, .divider, .contentAnalysis]
        return out
    }

    /// "Tidy Catalog… (3)"
    static func tidyTitle(_ total: Int) -> String { "\(tidyTitlePrefix) (\(total.formatted()))" }

    /// The titles as the menu shows them ("—" for a divider) — the value a
    /// person reads, for tests and the log.
    static func titles(_ entries: [CatalogMenuEntry], statusTitle: String) -> [String] {
        entries.map { entry in
            switch entry {
            case .catalogStatus: return statusTitle
            case .validateCatalog: return validateTitle
            case .updateCatalog: return updateTitle
            case .tidyCatalog(let n): return tidyTitle(n)
            case .divider: return "—"
            case .deleteSelectedFiles: return deleteTitle
            case .contentAnalysis: return contentAnalysisTitle
            }
        }
    }
}

// MARK: - What and how long (pure)

/// How long an action takes, in the three words the ruling allows.
enum CatalogTimeClass: String, Sendable, Equatable {
    case instant
    case minutes
    /// Hours, and safe to stop: running it again continues where it stopped.
    case hoursResumable

    var words: String {
        switch self {
        case .instant: return "Instant."
        case .minutes: return "Minutes."
        case .hoursResumable: return "Hours — resumable: stop any time; running it again continues where it stopped."
        }
    }
}

/// The first lines of every ellipsis item's sheet: what it touches, what
/// it never touches, how long. `help` (the menu tooltip) is the first line.
struct CatalogActionBrief: Sendable, Equatable {
    var touches: String
    var neverTouches: String
    var time: CatalogTimeClass

    var help: String { touches }
    var lines: [String] { [touches, neverTouches, time.words] }

    static let catalogStatus = CatalogActionBrief(
        touches: "Shows whether the catalog database, your files and their analysis are current — read from the catalog file, its last check and the drives' last check, now.",
        neverTouches: "Changes nothing: no file and no catalog row is written.",
        time: .instant)

    static let validateCatalog = CatalogActionBrief(
        touches: "Checks that every catalog entry on a connected drive still points at its file (one stat per file), marks a file that is gone Missing and one that is back live, then checks the catalog against itself and writes a dated report beside it.",
        neverTouches: "Never opens, moves, renames or deletes a file; drives that are not connected are left alone.",
        time: .minutes)

    static let updateCatalog = CatalogActionBrief(
        touches: "Rescans the drives you pick, confirms every file is where the catalog says, relinks the ones that moved and marks the ones that are gone Missing — with a preview before anything changes.",
        neverTouches: "Never moves, renames or deletes a file; drives you do not pick are left alone; tags, people, notes and dates stay with each file.",
        time: .minutes)

    static let tidyCatalog = CatalogActionBrief(
        touches: "Lists the one-off hygiene actions the catalog still needs, each with its count; each runs only when you press its Run.",
        neverTouches: "Never touches a file on disk — only catalog rows change, and each action makes its own safety copy or asks first.",
        time: .instant)

    static let deleteSelectedFiles = CatalogActionBrief(
        touches: "Moves the highlighted files to the Finder Trash; you can put them back until you empty it.",
        neverTouches: "Never touches Master Archive files, files on drives that are not connected, or half of a recovered audio/video pair unless every half is selected.",
        time: .instant)

    static let contentAnalysis = CatalogActionBrief(
        touches: "Opens the analyzers (embedded dates, full hashes, sound fingerprints, captions, …): each reads your files and keeps what it learns as catalog metadata, only when you press Run or it runs in the background.",
        neverTouches: "Never moves, renames or deletes a file, and never writes beside your files.",
        time: .hoursResumable)

    static func brief(for entry: CatalogMenuEntry) -> CatalogActionBrief? {
        switch entry {
        case .catalogStatus: return catalogStatus
        case .validateCatalog: return validateCatalog
        case .updateCatalog: return updateCatalog
        case .tidyCatalog: return tidyCatalog
        case .deleteSelectedFiles: return deleteSelectedFiles
        case .contentAnalysis: return contentAnalysis
        case .divider: return nil
        }
    }
}

/// The brief as the first lines of a sheet or window — what · never · how long.
struct CatalogActionBriefHeader: View {
    let brief: CatalogActionBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(brief.touches, systemImage: "hand.point.right")
            Label(brief.neverTouches, systemImage: "lock.shield")
            Label(brief.time.words, systemImage: "clock")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("catalog.actionBrief")
    }
}

// MARK: - The feature store

/// Which sheet the Catalog menu asked the main window to show. Owned by the
/// App (`@StateObject`), hosted on the main window by `CatalogMenuSheetHost`.
@MainActor
final class CatalogMenuStore: ObservableObject {
    enum Sheet: String, Identifiable, Sendable {
        case validateCatalog
        case tidyCatalog
        var id: String { rawValue }
    }

    @Published var sheet: Sheet?

    func present(_ sheet: Sheet) { self.sheet = sheet }
}

// MARK: - The one engine per verb

/// The calls the menu, the sheets and the Catalog Status window make — each
/// the SAME function the retired item called (rule 4).
@MainActor
enum CatalogMenuActions {
    /// Validate Catalog as the MFO job it is (the MFO window comes forward).
    static func startValidate(model: VideoScanModel, center: MediaFileOperationsCenter) {
        _ = center.startedByUser { $0.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker) }
    }
}

// MARK: - The menu (renders the value)

struct CatalogMenuContent: View {
    let model: VideoScanModel
    @ObservedObject var store: CatalogMenuStore
    /// The coverage pass's snapshot — the Tidy total rides it (O(1) read).
    @ObservedObject var coverage: AnalyzeCoverageSnapshot
    let isReadOnly: Bool

    /// The Tidy sheet's live total (0 = the row is not shown).
    private var tidyTotal: Int { coverage.report.tidy.menuTotal }

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(CatalogMenuLayout.entries(tidyTotal: tidyTotal).enumerated()), id: \.offset) { _, entry in
            item(entry)
        }
    }

    @ViewBuilder
    private func item(_ entry: CatalogMenuEntry) -> some View {
        switch entry {
        case .catalogStatus:
            CatalogStatusMenuItem(freshness: model.catalogFreshness)
        case .validateCatalog:
            ValidateCatalogMenuItem(store: store, isReadOnly: isReadOnly)
        case .updateCatalog:
            // Update Catalog (2026-08-17): rescan + relink after files were
            // moved or renamed outside the app; preview, then Apply.
            Button(CatalogMenuLayout.updateTitle) { model.openUpdateCatalog() }
                .disabled(isReadOnly)
                .help(CatalogActionBrief.updateCatalog.help)
                .accessibilityIdentifier("catalog.menu.updateCatalog")
        case .tidyCatalog(let total):
            Button(CatalogMenuLayout.tidyTitle(total)) { store.present(.tidyCatalog) }
                .disabled(isReadOnly)
                .help(CatalogActionBrief.tidyCatalog.help)
                .accessibilityIdentifier("catalog.menu.tidyCatalog")
        case .divider:
            Divider()
        case .deleteSelectedFiles:
            // ⌘⌫ as a real key equivalent (2026-09-20) — CatalogTrashCommand.swift.
            CatalogTrashMenuItem()
        case .contentAnalysis:
            // ⇧⌘O is declared once, on the Window menu item; not here.
            Button(CatalogMenuLayout.contentAnalysisTitle) {
                AnalyzeWindowOpener.open(using: openWindow, source: "catalog-menu")
            }
            .help(CatalogActionBrief.contentAnalysis.help)
            .accessibilityIdentifier("catalog.menu.contentAnalysis")
        }
    }
}

// MARK: - The sheets, hosted on the main window

struct CatalogMenuSheetHost: ViewModifier {
    @ObservedObject var store: CatalogMenuStore
    let model: VideoScanModel
    let center: MediaFileOperationsCenter

    func body(content: Content) -> some View {
        content.sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .validateCatalog:
                ValidateCatalogSheet(model: model, center: center)
            case .tidyCatalog:
                CatalogTidySheet(model: model, center: center)
            }
        }
    }
}
