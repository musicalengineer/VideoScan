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

// MARK: - The row

/// Full-width line under the toolbar: "Showing" then the pills. Sits
/// OUTSIDE the toolbar's fixed-inset layout so its variable width never
/// slides the search capsule. Pure layout over a handful of Bools — no
/// records are touched here.
struct CatalogShowingRow: View {
    let state: CatalogShowingSummary.State
    let onToggleArchived: () -> Void
    let onToggleDrives: () -> Void

    // Senior-friendly type: 14pt, one size up from the table chrome.
    private static let labelFont = Font.system(size: 14, weight: .semibold)
    private static let pillFont = Font.system(size: 14, weight: .medium)
    private let toDoGreen = Color(red: 0.10, green: 0.62, blue: 0.30)
    private let allBlue = Color(red: 0.13, green: 0.45, blue: 0.85)

    var body: some View {
        let pills = CatalogShowingSummary.pills(for: state)
        HStack(spacing: 8) {
            Text("Showing")
                .font(Self.labelFont)
                .foregroundColor(.secondary)
            ForEach(pills) { pill in
                pillView(pill)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.underPageBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(CatalogShowingSummary.sentence(for: state))
        .accessibilityIdentifier("catalog.showingRow")
    }

    @ViewBuilder
    private func pillView(_ pill: CatalogShowingSummary.Pill) -> some View {
        switch pill.action {
        case .none:
            pillLabel(pill)
        case .toggleArchived:
            Button(action: onToggleArchived) { pillLabel(pill) }
                .buttonStyle(.plain)
                .help(state.viewFilters.contains(.notYetArchived)
                      ? "Files already in the Master Archive are hidden — this is your to-do list. Click to include them."
                      : "Archived files are shown too. Click to hide them and see only what still needs archiving.")
                .accessibilityIdentifier("catalog.showingRow.archived")
        case .toggleDrives:
            Button(action: onToggleDrives) { pillLabel(pill) }
                .buttonStyle(.plain)
                .help(state.showDisconnectedMedia
                      ? "Files on disconnected drives are listed too. Click to show only drives that are plugged in."
                      : "Only drives that are plugged in right now. Click to also list files on disconnected drives.")
                .accessibilityIdentifier("catalog.showingRow.drives")
        }
    }

    private func pillLabel(_ pill: CatalogShowingSummary.Pill) -> some View {
        let (fg, bg): (Color, Color) = {
            switch pill.emphasis {
            case .archiveToDo: return (.white, toDoGreen)
            case .archiveAll:  return (.white, allBlue)
            case .reveal:      return (.orange, Color.orange.opacity(0.14))
            case .neutral:     return (.primary, Color.secondary.opacity(0.14))
            }
        }()
        return HStack(spacing: 4) {
            Text(pill.text)
            if pill.action != .none {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(0.8)
            }
        }
        .font(Self.pillFont)
        .foregroundColor(fg)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule().fill(bg))
        .contentShape(Capsule())
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
