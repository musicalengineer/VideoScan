// CatalogShowingSummary.swift
// "Showing: Not Yet Archived · Connected drives" — the one-line
// answer to "why don't I see X?" (Rick 2026-08-22: "humans looking at
// lots of data need bright clear reminders, remember we're dealing with
// senior citizens, me included").
//
// WHY PILLS, NOT A SENTENCE. Every filter combination would otherwise
// need its own grammar. A pill is a fact, not a clause: each one is two or
// three plain words, and any combination of them reads fine side by side.
//
// ONE VOCABULARY (2026-11-17). A Show filter is called the same thing in
// the Show menu and in this box: `CatalogViewFilter.title`. Two sets of
// words for one switch made the box something to translate rather than read.
//
// EVERYTHING (2026-11-17, "final shape for now"). No filter ticked means
// every file is listed, and the box says "Everything" — unless Show Pairs
// Only narrows the list, in which case it says that instead (the box never
// calls a narrowed list "Everything"). Show ▸ Folders drops no file, so the
// box says "Everything · Folders". There is no media-kind word any more:
// Audio Only is one of the filters.
//
// THE BOX TELLS THE TRUTH (2026-11-17 audit). Every filter that is on is
// named — with or without a Master Archive. When the full line does not fit, the box draws a
// shorter line that COUNTS the filters ("+2 more", "3 filters on") instead
// of cutting them off the end; the tooltip always carries the full list.
// While a focus set overrides the filters the box says the focus, not the
// filters. The box is a readout: clicking it changes nothing.
//
// Pure `enum` + value type — headless-testable, no SwiftUI, no model.

import Foundation
import SwiftUI

// MARK: - Vocabulary

enum CatalogShowingSummary {

    /// One pill. `emphasis` picks the colour: the archive pill is the
    /// one that matters most, so it is the only one that goes green.
    struct Pill: Equatable, Identifiable {
        enum Emphasis: Equatable { case neutral, archiveToDo, archiveAll, volume, person }
        /// What a click on the pill does. Only the volume and person tokens
        /// are buttons; the box's own pills are a readout (`.none`).
        enum Action: Equatable { case none, clearVolumes, clearPerson }

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
        var viewFilters: Set<CatalogViewFilter> = []
        var showPairsOnly = false
        var showDisconnectedMedia = false
        /// Show ▸ Folders (the one folder view, 2026-11-17) — a view shape,
        /// not a filter; it gets its own pill, "Folders", so the folder rows
        /// explain themselves from the Showing box too.
        var footageFolders = false
        /// A Master Archive is designated. With one, and Not Yet Archived
        /// off, the box says "Including archived" (archived files ARE in
        /// the list then); Not Yet Archived, when on, is named either way.
        var hasMasterArchive = false
        /// Focus mode ("Show in Catalog", "A/V Pair focus") overrides every
        /// filter; the row says so instead of listing filters that are
        /// not in force.
        var focusLabel: String? = nil
        /// Volumes-pane selection, as the pane's own display labels
        /// (`VolumeReachability.displayLabel`), sorted. Empty = no volume
        /// filter = the whole catalog (the launch state; never persisted).
        var selectedVolumeLabels: [String] = []
        /// The Catalog's Person picker (2026-10-24): the chosen person's
        /// name; nil = Everyone. Session-only, like the volume selection.
        var selectedPersonName: String? = nil
    }

    // MARK: The volume pill (Rick 2026-10-24)
    //
    // A Volumes-pane selection narrows the table to those volumes. It is
    // session-only (launch = whole catalog), which is exactly why it is easy
    // to forget: Rick saw 3 of 17 folders under Folders Only with nothing on
    // the line saying why. So a selection is the FIRST pill, accent-coloured,
    // and clicking it is the way back to the whole catalog.

    /// What a blank label (a target whose name does not resolve) reads as —
    /// never an empty pill.
    static let unnamedVolume = "Selected volume"
    /// Two or more selected volumes.
    static let selectedVolumes = "Selected volumes"
    /// Longest label the pill draws before shortening in the middle (the
    /// tooltip always carries the full name).
    static let volumeLabelLimit = 28

    /// The labels with blanks named — a pill or tooltip never reads "".
    private static func named(_ labels: [String]) -> [String] {
        labels.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? unnamedVolume : $0 }
    }

    /// No selection → nil (no pill). One → its pane label. Two+ →
    /// "Selected volumes" (the names go in the tooltip).
    static func volumePill(labels: [String]) -> Pill? {
        let names = named(labels)
        guard let only = names.first else { return nil }
        return Pill(names.count == 1 ? only : selectedVolumes, .volume, action: .clearVolumes)
    }

    /// The pill's tooltip: which volumes, and what a click does.
    static func volumeHelp(labels: [String]) -> String {
        let which = labels.count == 1 && labels[0].trimmingCharacters(in: .whitespaces).isEmpty
            ? "one selected volume"
            : named(labels).joined(separator: ", ")
        return "Showing only \(which) — click to show the whole catalog"
    }

    /// The selection after a pill's click: `.clearVolumes` empties it, every
    /// other action leaves it alone. Generic over the ID so the test needs
    /// no scan targets (≈ a C++ function template over the key type).
    static func volumeSelection<ID: Hashable>(after action: Pill.Action, _ current: Set<ID>) -> Set<ID> {
        action == .clearVolumes ? [] : current
    }

    // MARK: The person pill (Rick 2026-10-24)
    //
    // The Person ▾ picker narrows the table to one person's videos. Same
    // reason as the volume pill: a narrowing nobody sees is a narrowing
    // somebody forgets. It follows the volume pill and clears to Everyone.

    /// No person → nil (no pill). Otherwise their name.
    static func personPill(name: String?) -> Pill? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return Pill(trimmed.isEmpty ? CatalogPerson.unnamed : trimmed, .person, action: .clearPerson)
    }

    /// The person pill's tooltip.
    static func personHelp(name: String) -> String {
        "Showing only videos of \(name) — click to show everyone"
    }

    /// The picker after a pill's click: `.clearPerson` is Everyone (nil);
    /// every other action leaves it alone.
    static func personSelection<P>(after action: Pill.Action, _ current: P?) -> P? {
        action == .clearPerson ? nil : current
    }

    /// The empty table's line when a person is chosen and nothing shows.
    static func personEmptyNote(name: String) -> String {
        "No videos of \(name) here — choose Everyone in the Person menu, or click the \(name) pill, "
            + "to see the whole catalog"
    }

    /// The "No matches" hint while a person is chosen: the search ran over
    /// their videos only.
    static func personSearchHint(name: String) -> String {
        "Only videos of \(name) were searched — choose Everyone in the Person menu to search the whole catalog."
    }

    /// "RicksBackups > Ric…Final Copy": a long label keeps its head and tail.
    static func shortVolumeLabel(_ s: String) -> String {
        guard s.count > volumeLabelLimit else { return s }
        let keep = volumeLabelLimit - 1
        let head = (keep + 1) / 2
        return String(s.prefix(head)) + "\u{2026}" + String(s.suffix(keep - head))
    }


    /// The words for one Show filter — the menu's own (`title`), so the
    /// menu and the box never disagree.
    static func words(for filter: CatalogViewFilter) -> String { filter.title }

    /// What the box says when no Show filter is on and nothing else narrows
    /// the list (DECISIONS 2026-11-17: "no filter ticked means everything is
    /// shown, and the Showing box says so").
    static let everything = "Everything"

    /// Is the list every file in scope? No Show filter, and not Show Pairs
    /// Only (the one view switch that drops rows; the folder view does not).
    static func listsEverything(_ s: State) -> Bool {
        s.viewFilters.isEmpty && !s.showPairsOnly
    }

    /// The pills, in reading order: selected volume(s) · the chosen person
    /// · then the box's pills. Focus mode overrides every filter, the volume
    /// and person ones included.
    static func pills(for s: State) -> [Pill] {
        guard s.focusLabel == nil else { return boxPills(for: s) }
        let tokens = [volumePill(labels: s.selectedVolumeLabels), personPill(name: s.selectedPersonName)]
        return tokens.compactMap { $0 } + boxPills(for: s)
    }

    /// What the box says when a Master Archive exists and Not Yet Archived
    /// is off — a state, not a filter. True by construction: with that
    /// filter off no step of the row pass drops an archived file.
    static let includingArchived = "Including archived"
    /// The one title of the clear action (the Show menu and the empty table).
    static let clearAllFiltersTitle = "Clear All Filters"

    /// One pill per Show filter that is on — ALL of them, whatever else is
    /// true — Not Yet Archived first (the eye knows that slot), the rest in
    /// menu order.
    static func filterPills(for filters: Set<CatalogViewFilter>) -> [Pill] {
        let ordered = CatalogViewFilter.ordered(filters)
        let archive = ordered.filter { $0 == .notYetArchived }
        let rest = ordered.filter { $0 != .notYetArchived }
        return archive.map { Pill($0.title, .archiveToDo) } + rest.map { Pill($0.title) }
    }

    /// The pills the highlighted box draws as text, in reading order: what
    /// · the filters that are on · pairs · folders · where. Order is fixed so the eye learns where each fact lives. The
    /// volume pill is not here: it is its own accent button in front of the box.
    static func boxPills(for s: State) -> [Pill] {
        if let focus = s.focusLabel {
            return [Pill(focus, .neutral)]
        }
        var out: [Pill] = []
        if listsEverything(s) { out.append(Pill(everything)) }
        let filters = filterPills(for: s.viewFilters)
        if s.hasMasterArchive, !s.viewFilters.contains(.notYetArchived) {
            out.append(Pill(includingArchived, .archiveAll))
        }
        out.append(contentsOf: filters)
        if s.showPairsOnly { out.append(Pill("Pairs only")) }
        if s.footageFolders { out.append(Pill(FootageFolderWords.showingPill)) }

        out.append(Pill(s.showDisconnectedMedia ? "All drives" : "Connected drives"))
        return out
    }

    /// The lines the box may draw, longest first; it draws the first that
    /// fits (ViewThatFits) and never truncates one. Every line either NAMES
    /// each filter that is on or says how many it is not naming:
    ///   1. the whole line:  "Not Yet Archived · Needs a Date · Connected drives"
    ///   2. one filter on: its name alone ("Needs a Date");
    ///      several: the first and a count ("Not Yet Archived +1 more")
    ///   3. several: the count alone ("2 filters on")
    /// No filter on: the whole line, then "Everything" when that is what is
    /// listed. The tooltip (`help`) always carries the full list.
    static func boxLines(for s: State) -> [String] {
        let full = boxPills(for: s).map(\.text).joined(separator: " · ")
        guard s.focusLabel == nil else { return [full] }
        let names = filterPills(for: s.viewFilters).map(\.text)
        var lines = [full]
        if let first = names.first {
            if names.count == 1 {
                lines.append(first)
            } else {
                lines.append(first + " +\(names.count - 1) more")
                lines.append("\(names.count) filters on")
            }
        } else if listsEverything(s) {
            lines.append(everything)
        }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// VoiceOver / log line: "Showing Not Yet Archived, Connected drives".
    static func sentence(for s: State) -> String {
        "Showing " + pills(for: s).map(\.text).joined(separator: ", ")
    }

    /// The box's tooltip: the whole truth, however short the drawn line is.
    static func help(for s: State) -> String {
        if let focus = s.focusLabel {
            return "\(focus): only these files are listed. The Show filters are not applied until you leave this view."
        }
        let on = filterPills(for: s.viewFilters).map(\.text)
        let filters = on.isEmpty ? "No Show filter is on." : "Show filters on: " + on.joined(separator: ", ") + "."
        return "Showing " + boxPills(for: s).map(\.text).joined(separator: ", ") + ".\n" + filters
            + "\nUse the Show menu to change what is listed."
    }

    /// The empty table's words when the Show filters alone left nothing.
    static func filteredEmptyNote(filters: Set<CatalogViewFilter>) -> String {
        let on = filterPills(for: filters).map(\.text)
        return on.count == 1
            ? "No files match the Show filter that is on: \(on[0])."
            : "No files match the Show filters that are on: " + on.joined(separator: ", ") + "."
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
    /// `sampled` of the `count` hidden hits are hidden only by a sampled
    /// `v1:` match (GH #327, Rick 2026-10-23): they are "possibly archived
    /// (sampled)", never "already in the Archive".
    static func archivedHitsMessage(count: Int, sampled: Int = 0) -> String {
        let sampled = min(max(0, sampled), count)
        let proven = count - sampled
        let maybe = "possibly archived (sampled) — not yet verified."
        guard sampled > 0 else {
            return proven == 1
                ? "1 match is already in the Archive."
                : "\(proven.formatted()) matches are already in the Archive."
        }
        guard proven > 0 else {
            return sampled == 1 ? "1 match is \(maybe)" : "\(sampled.formatted()) matches are \(maybe)"
        }
        let head = proven == 1 ? "1 match is already in the Archive" : "\(proven.formatted()) matches are already in the Archive"
        return head + "; \(sampled.formatted()) more \(sampled == 1 ? "is" : "are") \(maybe)"
    }
}

// MARK: - The box

/// One highlighted box beside the Show menu: "Not Yet Archived · Connected
/// drives", or "Everything · Connected drives" when no filter is on. Pure layout over a handful of Bools —
/// no records are touched here. A READOUT, not a control: it has no click.
/// The glyph says the one thing that matters most at a glance: green
/// checklist = the to-do view (Not Yet Archived on), blue box = archived
/// files are listed, none = no Master Archive yet or a focus set.
struct CatalogShowingBox: View {
    let state: CatalogShowingSummary.State

    // Senior-friendly: 14pt semibold, one size up from the toolbar chrome.
    static let font = Font.system(size: 14, weight: .semibold)
    private let toDoGreen = Color(red: 0.10, green: 0.62, blue: 0.30)
    private let allBlue = Color(red: 0.13, green: 0.45, blue: 0.85)

    /// The view's meaning as a glyph + its colour (2026-10-24, Rick: solid
    /// fills with white text were hard on the eyes) — the chip itself is
    /// neutral, so only the volume pill is tinted. nil = no Master Archive,
    /// or a focus set (the filters are not in force).
    private var mark: (symbol: String, color: Color)? {
        guard state.hasMasterArchive, state.focusLabel == nil else { return nil }
        return state.viewFilters.contains(.notYetArchived)
            ? ("checklist", toDoGreen) : ("archivebox.fill", allBlue)
    }

    var body: some View {
        // At most three short strings, built from a handful of values.
        let lines = CatalogShowingSummary.boxLines(for: state)
        HStack(spacing: 6) {
            if let mark {
                Image(systemName: mark.symbol)
                    .imageScale(.small)
                    .foregroundStyle(mark.color)
            }
            // The first line that fits is drawn whole; a line that does not
            // fit is never cut short — the next, shorter one counts the
            // filters it leaves out. (≈ picking the longest of N preformatted
            // strings that fits the column, instead of ellipsizing one.)
            ViewThatFits(in: .horizontal) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(Self.font)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.28), lineWidth: 1))
        .help(CatalogShowingSummary.help(for: state))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(CatalogShowingSummary.sentence(for: state))
        .accessibilityIdentifier("catalog.showingBox")
    }
}

// MARK: - The filter tokens (volume, person)

/// One tinted token in front of the Showing box: glyph · words · clear
/// glyph. The whole token is the button; a click clears that one narrowing.
/// A tinted token — accent wash + outline, primary text — reads in light
/// and dark mode (Finder's search scope). The ONE token style: the volume
/// and person pills are this view with their own words. Pure layout.
struct CatalogFilterToken: View {
    let symbol: String
    let text: String
    let help: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let identifier: String
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "xmark.circle.fill")
                    .imageScale(.medium)
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }
            .font(CatalogShowingBox.font)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // The accent wash ties it to the selected rows / chosen menu line.
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.65), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

/// The Volumes-pane selection's token; empty draws nothing. A click empties
/// the selection (back to the whole catalog).
struct CatalogVolumePill: View {
    /// The Volumes-pane selection's labels; empty draws nothing.
    let labels: [String]
    let onClear: () -> Void

    var body: some View {
        if let pill = CatalogShowingSummary.volumePill(labels: labels) {
            CatalogFilterToken(symbol: "externaldrive.fill",
                               text: CatalogShowingSummary.shortVolumeLabel(pill.text),
                               help: CatalogShowingSummary.volumeHelp(labels: labels),
                               accessibilityLabel: "Volume filter: \(pill.text)",
                               accessibilityHint: "Clears the volume filter and shows the whole catalog",
                               identifier: "catalog.showingVolumePill",
                               onClear: onClear)
        }
    }
}

/// The Person picker's token (2026-10-24); nil draws nothing. A click
/// clears to Everyone.
struct CatalogPersonPill: View {
    let name: String?
    let onClear: () -> Void

    var body: some View {
        if let pill = CatalogShowingSummary.personPill(name: name) {
            CatalogFilterToken(symbol: "person.crop.circle",
                               text: CatalogShowingSummary.shortVolumeLabel(pill.text),
                               help: CatalogShowingSummary.personHelp(name: pill.text),
                               accessibilityLabel: "Person filter: \(pill.text)",
                               accessibilityHint: "Clears the person filter and shows everyone",
                               identifier: "catalog.showingPersonPill",
                               onClear: onClear)
        }
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
            // Green seal only when at least one hidden hit is PROVEN archived.
            let allSampled = archivedSearchSampledHitCount >= archivedSearchHitIDs.count
            HStack(spacing: 10) {
                Image(systemName: allSampled ? "archivebox" : "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(allSampled ? .secondary : .green)
                Text(CatalogShowingSummary.archivedHitsMessage(count: archivedSearchHitIDs.count,
                                                               sampled: archivedSearchSampledHitCount))
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
