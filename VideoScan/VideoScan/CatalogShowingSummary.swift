// CatalogShowingSummary.swift
// "Showing: Videos · Not yet archived · Connected drives" — the one-line
// answer to "why don't I see X?" (Rick 2026-08-22: "humans looking at
// lots of data need bright clear reminders, remember we're dealing with
// senior citizens, me included").
//
// WHY PILLS, NOT A SENTENCE. Every filter combination would otherwise
// need its own grammar ("Showing Unpaired Not in Archive Repaired not
// waiting for Papal dispensation" — Rick's own parody). A pill is a
// fact, not a clause: each one is two or three plain words, and any
// combination of them reads fine side by side. The vocabulary below is
// the ONLY place the words live — the raw `CatalogViewFilter` names
// ("Untagged (junk candidate)") never reach the row.
//
// WHY POSITIVES. "Not yet archived" is the one sanctioned negative,
// because it is the name of the job (the catalog is the to-do list; the
// Archive tab is the done list). Everything else says what IS shown.
//
// The archive pill is the big switch Rick asked for: click it and the
// view flips between "Not yet archived" (default once a Master Archive
// exists) and "Including archived". Same for the drives pill.
//
// Pure `enum` + value type — headless-testable, no SwiftUI, no model.

import Foundation
import SwiftUI

// MARK: - Vocabulary

enum CatalogShowingSummary {

    /// One pill. `emphasis` picks the colour: the archive pill is the
    /// one that matters most, so it is the only one that goes green.
    struct Pill: Equatable, Identifiable {
        enum Emphasis: Equatable { case neutral, archiveToDo, archiveAll, reveal }
        enum Action: Equatable { case none, toggleArchived, toggleDrives }

        let text: String
        let emphasis: Emphasis
        let action: Action
        var id: String { text }

        init(_ text: String, _ emphasis: Emphasis = .neutral, action: Action = .none) {
            self.text = text
            self.emphasis = emphasis
            self.action = action
        }
    }

    /// Everything the row needs to know, as plain values (no bindings).
    struct State: Equatable {
        var kindFacet: CatalogKindFacet = .videoBearing
        var viewFilters: Set<CatalogViewFilter> = []
        var showPairsOnly = false
        var showDisconnectedMedia = false
        var showRemoved = false
        var showSetAside = false
        var showSuperseded = false
        /// A Master Archive is designated — without one "archived" is
        /// meaningless and the archive pill is omitted entirely.
        var hasMasterArchive = false
        /// Focus mode ("Show in Catalog", "A/V Pair focus") overrides every
        /// filter; the row says so instead of listing filters that are
        /// not in force.
        var focusLabel: String? = nil
    }

    /// Plain-words label for one additive filter. Every case is handled
    /// so a new filter cannot ship without its words (compiler-enforced).
    static func words(for filter: CatalogViewFilter) -> String {
        switch filter {
        case .videoAndAudioOnly:    return "With sound"
        case .unpairedOnly:         return "Missing their other half"
        case .ratedOnly:            return "Starred"
        case .hasFamily:            return "With family"
        case .workspaceOnly:        return "In the workspace"
        case .untaggedOnly:         return "Untagged"
        case .awaitingConfirmation: return "Repaired, waiting for your OK"
        case .notYetArchived:       return "Not yet archived"
        case .hasMasterCopy:        return "Already archived"
        }
    }

    /// Plain-words label for the media-kind facet.
    static func words(for facet: CatalogKindFacet) -> String {
        switch facet {
        case .videoBearing: return "Videos"
        case .audioOnly:    return "Audio only"
        case .everything:   return "All kinds"
        }
    }

    /// The pills, in reading order: what · archive state · extra filters
    /// · where · revealed hidden records. Order is fixed so the eye
    /// learns where each fact lives.
    static func pills(for s: State) -> [Pill] {
        if let focus = s.focusLabel {
            return [Pill(focus, .neutral)]
        }
        var out: [Pill] = []
        out.append(Pill(words(for: s.kindFacet)))

        if s.hasMasterArchive {
            if s.viewFilters.contains(.notYetArchived) {
                out.append(Pill("Not yet archived", .archiveToDo, action: .toggleArchived))
            } else if s.viewFilters.contains(.hasMasterCopy) {
                out.append(Pill("Already archived", .archiveAll))
            } else {
                out.append(Pill("Including archived", .archiveAll, action: .toggleArchived))
            }
        }

        // Remaining additive filters in declaration order — the archive
        // pair is already spoken for above.
        for f in CatalogViewFilter.allCases
        where s.viewFilters.contains(f) && f != .notYetArchived && f != .hasMasterCopy {
            out.append(Pill(words(for: f)))
        }
        if s.showPairsOnly { out.append(Pill("Pairs only")) }

        out.append(Pill(s.showDisconnectedMedia ? "All drives" : "Connected drives",
                        action: .toggleDrives))

        if s.showRemoved    { out.append(Pill("Plus removed files", .reveal)) }
        if s.showSetAside   { out.append(Pill("Plus set-aside files", .reveal)) }
        if s.showSuperseded { out.append(Pill("Plus replaced originals", .reveal)) }
        return out
    }

    /// VoiceOver / log line: "Showing Videos, Not yet archived, Connected drives".
    static func sentence(for s: State) -> String {
        "Showing " + pills(for: s).map(\.text).joined(separator: ", ")
    }

    // MARK: Persistence of the filter set

    /// `Set<CatalogViewFilter>` ⇄ one UserDefaults string. Raw values are
    /// the menu labels, which contain commas-free text today but spaces
    /// and parentheses — so the separator is a character no label will
    /// ever use. Unknown tokens (a filter renamed or removed in a later
    /// build) are dropped, never crash.
    static let separator = "|"

    static func encode(_ filters: Set<CatalogViewFilter>) -> String {
        CatalogViewFilter.allCases.filter { filters.contains($0) }
            .map(\.rawValue).joined(separator: separator)
    }

    static func decode(_ raw: String) -> Set<CatalogViewFilter> {
        Set(raw.split(separator: Character(separator))
                .compactMap { CatalogViewFilter(rawValue: String($0)) })
    }

    // MARK: Archived search hits

    /// Split a search's survivors into the rows the to-do view keeps and
    /// the rows it hides because they are already archived. Pure: the
    /// archive predicate is injected (the model's memoized index in
    /// production, a closure in tests). Only called while the
    /// Not-yet-archived filter is on — otherwise nothing is hidden.
    static func splitArchivedHits(
        _ hits: [VideoRecord],
        isArchived: (VideoRecord) -> Bool
    ) -> (shown: [VideoRecord], archived: [VideoRecord]) {
        var shown: [VideoRecord] = []
        var archived: [VideoRecord] = []
        shown.reserveCapacity(hits.count)
        for r in hits {
            if isArchived(r) { archived.append(r) } else { shown.append(r) }
        }
        return (shown, archived)
    }

    /// The banner's words. One sentence, count first, no jargon.
    static func archivedHitsMessage(count: Int) -> String {
        count == 1
            ? "1 match is already in the Archive."
            : "\(count.formatted()) matches are already in the Archive."
    }
}

// MARK: - The box

/// One highlighted box beside the Show menu: "Showing: Videos · Not yet
/// archived · Connected drives". Pure layout over a handful of Bools —
/// no records are touched here. Colour says the one thing that matters
/// most at a glance: green = to-do view (archived hidden), blue =
/// archived included, neutral = no Master Archive yet.
struct CatalogShowingBox: View {
    let state: CatalogShowingSummary.State

    // Senior-friendly: 14pt semibold, one size up from the toolbar chrome.
    private static let font = Font.system(size: 14, weight: .semibold)
    private let toDoGreen = Color(red: 0.10, green: 0.62, blue: 0.30)
    private let allBlue = Color(red: 0.13, green: 0.45, blue: 0.85)

    private var fill: Color {
        guard state.hasMasterArchive else { return Color.secondary.opacity(0.18) }
        return state.viewFilters.contains(.notYetArchived) ? toDoGreen : allBlue
    }
    private var foreground: Color { state.hasMasterArchive ? .white : .primary }

    var body: some View {
        let pills = CatalogShowingSummary.pills(for: state)
        HStack(spacing: 6) {
            Text(pills.map(\.text).joined(separator: " · "))
                .font(Self.font)
                .foregroundColor(foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .help(state.hasMasterArchive
              ? (state.viewFilters.contains(.notYetArchived)
                 ? "Files already in the Master Archive are hidden — this is your to-do list. Click to include them."
                 : "Archived files are shown too. Click to hide them and see only what still needs archiving.")
              : "What the table is filtered to. Use the Show menu to change it.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CatalogShowingSummary.sentence(for: state))
        .accessibilityIdentifier("catalog.showingBox")
    }
}

// MARK: - Archived-hits banner (CatalogContent)

extension CatalogContent {
    /// Shown only while a search is active, the to-do filter is on, and
    /// at least one hit was hidden for being archived. Same register as
    /// the undo banners above the table. "Show in Archive" carries the
    /// query across so EVERY hit is listed there, with the first one
    /// highlighted.
    @ViewBuilder
    var archivedHitsBanner: some View {
        if !archivedSearchHitIDs.isEmpty, !searchText.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.green)
                Text(CatalogShowingSummary.archivedHitsMessage(count: archivedSearchHitIDs.count))
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                Button("Show in Archive") {
                    guard let first = archivedSearchHitIDs.first,
                          let rec = model.record(forID: first) else { return }
                    model.pendingArchiveSearch = archivedSearchHitIDs.count > 1 ? searchText : nil
                    onShowInArchive?(rec)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("catalog.archivedHits.showInArchive")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.08))
            .accessibilityIdentifier("catalog.archivedHitsBanner")
        }
    }
}
