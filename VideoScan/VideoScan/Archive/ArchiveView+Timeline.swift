// ArchiveView+Timeline.swift
// Archive tab — Timeline view (docs/archive-view.md, first cut
// 2026-08-20). The archive is the app's vetted shelf: known dates, human
// names, verified copies — so its natural view is the story over time,
// not a file table. Layout (Rick 2026-10-06): a horizontal decade ribbon
// across the top (ArchiveDecadeRibbon.swift, Dock-style magnification),
// and below it ONE decade's page, year by year under pinned year headers
// (click a decade to turn the page). Files view (ArchiveView+Table) stays
// available via the toolbar switch.

import SwiftUI

// MARK: - Item projection (main actor → pure model)

extension ArchiveView {

    /// Photo extensions that can land in the archive as milestone markers.
    private static let photoExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "dng", "raw"]

    /// Project ONE archived asset into a timeline item. `rec` is the
    /// asset row from the archived snapshot; the master copy supplies the
    /// on-disk name and placement.
    @MainActor
    static func timelineItem(for rec: VideoRecord, model: VideoScanModel) -> ArchiveTimelineItem {
        let copy = model.isArchiveCopy(rec) ? rec : (model.masterArchiveCopy(of: rec) ?? rec)
        let rel = ArchiveCategorySnapshot.relativePath(copy.fullPath,
                                                      root: model.masterArchiveRootPath)
        let ext = (copy.filename as NSString).pathExtension.lowercased()
        let kind: ArchiveTimelineItem.Kind
        if photoExtensions.contains(ext) {
            kind = .photo
        } else if rec.streamType == .audioOnly {
            kind = .audio
        } else {
            kind = .video
        }
        let people = ArchivePeopleCell.text(for: rec)
        // Lineage for version grouping (codex #1644): a promotion link is
        // the archive copy of the SAME item (an orphan copy standing in for
        // its vanished source), not a version — never passed on.
        let lineage = rec.derivationKind == ArchivePromotion.derivationKind ? nil : rec.derivedFrom
        var item = ArchiveTimelineItem(id: rec.id,
                                   title: ArchiveTimelinePath.title(fromArchiveFilename: copy.filename),
                                   archiveFilename: copy.filename,
                                   relPath: rel,
                                   year: ArchiveTimelinePath.year(fromRelPath: rel),
                                   kind: kind,
                                   durationSeconds: rec.durationSeconds,
                                   peopleText: people == "—" ? "" : people,
                                   isVerified: copy.archiveFixity != nil)
        item.derivedFromID = lineage
        item.derivationKind = lineage == nil ? nil : rec.derivationKind
        return item
    }

    /// All archived assets as timeline items — memoized per records
    /// version (same discipline as the category snapshot: one compute per
    /// version, never O(records) in body).
    @MainActor
    func cachedTimelineItems() -> [ArchiveTimelineItem] {
        let key = RecordsVersion(count: model.records.count,
                                 revision: model.volumeAggregatesRevision)
        return timelineItemMemo.value(for: key) {
            // One card per item, its versions folded in as chips (Rick
            // 2026-09-22) — app-side only, nothing on disk moves.
            ArchiveItemVersions.group(snapshot.archived.map { Self.timelineItem(for: $0, model: model) })
        }
    }

    /// Timeline grouping + ribbon ticks, memoized per records version
    /// and search text: built once per data change, O(1) on every other
    /// render (CLAUDE.md: no O(records) work in view bodies).
    @MainActor
    func cachedTimeline() -> ArchiveTimelineSnapshot {
        let key = ArchiveTimelineKey(
            version: RecordsVersion(count: model.records.count,
                                    revision: model.volumeAggregatesRevision),
            query: searchText)
        return timelineMemo.value(for: key) {
            ArchiveTimelineSnapshot.build(items: cachedTimelineItems(), matching: searchText)
        }
    }

    /// The Timeline pane, fed from the memoized snapshot.
    @MainActor
    var timelinePane: some View {
        ArchiveTimelinePane(
            snapshot: cachedTimeline(),
            selectedIDs: selectedIDs,
            scrollTarget: timelineScrollTarget,
            contextMenu: { ids in AnyView(self.recordContextMenu(for: ids)) },
            openItems: { ids in
                MediaOpener.open(ids.compactMap { self.model.record(forID: $0) })
            })
    }
}

/// Memo key for the timeline grouping: the catalog's version plus the
/// search text that narrows it.
struct ArchiveTimelineKey: Equatable {
    let version: RecordsVersion
    let query: String
}

// MARK: - The pane

struct ArchiveTimelinePane: View {
    /// Memoized by ArchiveView (cachedTimeline) — never built here.
    let snapshot: ArchiveTimelineSnapshot
    private var timeline: ArchiveTimeline { snapshot.timeline }
    /// The decade under the ribbon's lens. Nil until the user picks one.
    @State private var selectedDecade: Int?
    /// Items to highlight — a hand-off from the Catalog/Hallie selects
    /// the target here instead of dropping into the Files table
    /// (ArchiveHomeState rule 2).
    var selectedIDs: Set<UUID> = []
    /// Item to scroll into view once the pane is up. Owned by ArchiveView.
    var scrollTarget: UUID? = nil
    /// The enclosing ArchiveView's context menu + open handling.
    let contextMenu: (Set<UUID>) -> AnyView
    let openItems: ([UUID]) -> Void

    private static let undatedAnchor = ArchiveDecadeTick.undatedID

    /// Scroll targets in the stream live in their OWN id space. The rail's
    /// `ForEach(timeline.decades)` gives each rail row the decade's Int id,
    /// so `scrollTo(1990)` found the rail's own (already visible) row and
    /// nothing moved — only Undated, which is not in that ForEach, jumped
    /// (Rick 2026-09-23). A String "stream-1990" can't collide with it.
    static func anchorID(_ decade: Int) -> String { "stream-\(decade)" }
    /// A year's anchor — its own prefix, so 1990-the-year never collides
    /// with 1990-the-decade.
    static func yearAnchorID(_ year: Int) -> String { "year-\(year)" }

    /// The decade page on screen: the user's pick while it is still on the
    /// ribbon, else the oldest decade with media. O(decades).
    private var page: Int? { snapshot.page(selected: selectedDecade) }

    var body: some View {
        if timeline.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ArchiveDecadeRibbon(ticks: snapshot.ticks,
                                        selectedID: page,
                                        onSelect: { pickDecade($0, proxy: proxy) },
                                        onPickYear: { pickYear($0, proxy: proxy) })
                    Divider()
                    stream
                }
                .onAppear { scrollToTarget(proxy) }
                .onChange(of: scrollTarget) { scrollToTarget(proxy) }
            }
        }
    }

    /// Bring the hand-off target into view: turn to its decade's page,
    /// then scroll to its card. The cards carry `.id(item.id)` inside the
    /// LazyVStack; SwiftUI resolves the scroll from the identifier even
    /// for cards not yet materialised.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget, let card = timeline.cardID(for: target) else { return }
        if let targetPage = snapshot.page(containing: target) { selectedDecade = targetPage }
        // (For Rick: `DispatchQueue.main.async` ≈ posting to the UI thread's
        // queue — runs after this update, once the new page is built.)
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(card, anchor: .center) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 43))
                .foregroundColor(.secondary)
            Text("The story starts with the first promote")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Right-click a file in the Catalog and choose Archive Angel ▸ Prepare with Archive Angel — every promoted file takes its place on this timeline.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Decade ribbon → stream

    /// A ribbon pick: that decade's page, scrolled to its top. The scroll
    /// waits one turn of the run loop so it lands on the NEW page.
    private func pickDecade(_ anchor: Int, proxy: ScrollViewProxy) {
        selectedDecade = anchor
        DispatchQueue.main.async {
            proxy.scrollTo(Self.anchorID(anchor), anchor: .top)
        }
    }

    /// A year clicked in the ribbon's dwell-zoom row: its decade's page,
    /// scrolled to that year.
    private func pickYear(_ year: Int, proxy: ScrollViewProxy) {
        selectedDecade = (year / 10) * 10
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(Self.yearAnchorID(year), anchor: .top) }
        }
    }

    // MARK: The stream — one decade's page

    /// One decade at a time (Rick 2026-10-06), grouped by year under
    /// pinned year headers. Builds only the page's cards, lazily.
    private var stream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if page == Self.undatedAnchor {
                    undatedPage
                } else if let decade = timeline.decades.first(where: { $0.start == page }) {
                    decadePage(decade)
                }
            }
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func decadePage(_ decade: ArchiveTimelineDecade) -> some View {
        if decade.isGap {
            gapBand(decade)
                .id(Self.anchorID(decade.id))
        } else {
            // Scroll targets are zero-height ROWS, not the pinned headers:
            // a lazy stack does not reliably resolve scrollTo on a pinned
            // section header that has not been built yet (Rick 2026-09-23).
            Color.clear
                .frame(height: 0)
                .id(Self.anchorID(decade.id))
            decadeTitle(decade)
            ForEach(decade.years) { year in
                Color.clear
                    .frame(height: 0)
                    .id(Self.yearAnchorID(year.year))
                Section {
                    yearBlock(year)
                } header: {
                    yearHeader(year)
                }
            }
        }
    }

    @ViewBuilder
    private var undatedPage: some View {
        Color.clear
            .frame(height: 0)
            .id(Self.anchorID(Self.undatedAnchor))
        Section {
            cardGrid(timeline.undated)
                .padding(.horizontal, 18)
                .padding(.top, 6)
        } header: {
            undatedHeader
        }
    }

    /// The page's title — scrolls away; the year headers pin.
    private func decadeTitle(_ decade: ArchiveTimelineDecade) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(decade.label)
                .font(.system(size: 28, weight: .bold))
            Text("\(decade.count) archived · \(decade.rangeLabel)")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Pinned while its year's cards scroll under it. Solid backing.
    private func yearHeader(_ year: ArchiveTimelineYear) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(year.year))
                .font(.system(size: 20, weight: .semibold))
            Text(year.items.count == 1 ? "1 archived" : "\(year.items.count) archived")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .accessibilityIdentifier("archive.timeline.yearHeader.\(year.year)")
    }

    /// An empty decade is drawn, not skipped — the gap is the coaxing
    /// surface (docs/archive-view.md).
    private func gapBand(_ decade: ArchiveTimelineDecade) -> some View {
        HStack(spacing: 8) {
            Text(decade.label)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("nothing archived yet — tapes in the attic?")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var undatedHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Undated")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.orange)
            Text("set a date in the Inspector to file these in their year")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func yearBlock(_ year: ArchiveTimelineYear) -> some View {
        cardGrid(year.items)
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 12)
    }

    /// A year's cards as a grid that fills the pane's width — one column
    /// in a narrow window, two or three in a wide one (Rick 2026-09-22:
    /// "a lot of space in black… use that extra horizontal space").
    /// `.adaptive(minimum:)` ≈ "as many ≥ 340 pt columns as fit, then
    /// stretch them evenly". LazyVGrid builds only visible cards.
    private func cardGrid(_ items: [ArchiveTimelineItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 10, alignment: .top)],
                  alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                itemCard(item)
            }
        }
    }

    // MARK: Item card

    /// One media card. The WHOLE card is click-to-play (Rick, RD round 1:
    /// "people will see a timeline item and want to click it") — the
    /// vetted shelf's payoff is playing the memory, so a card click never
    /// means "select". The play glyph is the affordance; right-click
    /// keeps the full archive menu (journey, details, reveal).
    private func itemCard(_ item: ArchiveTimelineItem) -> some View {
        let isSelected = selectedIDs.contains(item.id) || item.versions.contains { selectedIDs.contains($0.id) }
        // A tap gesture, not a Button, so the version chips inside can be
        // real buttons of their own (a Button inside a Button's label is
        // unreliable on macOS).
        return VStack(alignment: .leading, spacing: 8) {
            // Play leads (the card's action), then the title with its seal
            // right beside it — no glyphs stranded at the far edge of a
            // wide pane.
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: playGlyph(for: item.kind))
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                    .help(playHelp(for: item.kind))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 16, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if item.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.green)
                                .help("Byte-verified in the Master Archive")
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: item.kind))
                            .foregroundStyle(.secondary)
                        if !item.peopleText.isEmpty {
                            Text(item.peopleText)
                                .foregroundStyle(.blue)
                                .lineLimit(1)
                        }
                        let dur = item.friendlyDuration
                        if !dur.isEmpty {
                            Text(dur)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 13))
                }
                Spacer(minLength: 0)
            }
            if !item.versions.isEmpty {
                versionChips(item)
                    .padding(.leading, 42)   // under the title, not the play glyph
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color(NSColor.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected
                              ? Color.accentColor.opacity(0.6)
                              : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { openItems([item.id]) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openItems([item.id]) }
        .id(item.id)
        .help(item.relPath)
        .contextMenu { contextMenu([item.id]) }
    }

    private func playHelp(for kind: ArchiveTimelineItem.Kind) -> String {
        switch kind {
        case .video: return "Play this video"
        case .audio: return "Play this recording"
        case .photo: return "Open this photo"
        }
    }

    /// "original · access · editable · preservation · restored" — each
    /// chip plays (opens) that version. The card's own file is marked.
    private func versionChips(_ item: ArchiveTimelineItem) -> some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(item.versions) { v in
                Button {
                    openItems([v.id])
                } label: {
                    Text(v.label)
                        .font(.system(size: 12, weight: v.id == item.id ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(v.id == item.id
                                                   ? Color.accentColor.opacity(0.22)
                                                   : Color.secondary.opacity(0.14)))
                        .foregroundStyle(v.id == item.id ? Color.accentColor : Color.primary)
                }
                .buttonStyle(.plain)
                .help("\(v.role.help)\n\(v.archiveFilename)")
                .contextMenu { contextMenu([v.id]) }
            }
        }
    }

    private func playGlyph(for kind: ArchiveTimelineItem.Kind) -> String {
        kind == .photo ? "eye.circle.fill" : "play.circle.fill"
    }

    private func icon(for kind: ArchiveTimelineItem.Kind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .photo: return "photo"
        }
    }
}
