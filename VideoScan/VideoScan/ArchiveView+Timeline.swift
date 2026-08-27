// ArchiveView+Timeline.swift
// Archive tab — Timeline view (docs/archive-view.md, first cut
// 2026-08-20). The archive is the app's vetted shelf: known dates, human
// names, verified copies — so its natural view is the story over time,
// not a file table. Layout: a vertical decade rail on the left (oldest at
// the top, reading down — Rick), the year-by-year stream on the right.
// Files view (ArchiveView+Table) stays available via the toolbar switch.

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
        return ArchiveTimelineItem(id: rec.id,
                                   title: ArchiveTimelinePath.title(fromArchiveFilename: copy.filename),
                                   archiveFilename: copy.filename,
                                   relPath: rel,
                                   year: ArchiveTimelinePath.year(fromRelPath: rel),
                                   kind: kind,
                                   durationSeconds: rec.durationSeconds,
                                   peopleText: people == "—" ? "" : people,
                                   isVerified: copy.archiveFixity != nil)
    }

    /// All archived assets as timeline items — memoized per records
    /// version (same discipline as the category snapshot: one compute per
    /// version, never O(records) in body).
    @MainActor
    func cachedTimelineItems() -> [ArchiveTimelineItem] {
        let key = RecordsVersion(count: model.records.count,
                                 revision: model.volumeAggregatesRevision)
        return timelineItemMemo.value(for: key) {
            snapshot.archived.map { Self.timelineItem(for: $0, model: model) }
        }
    }

    /// The Timeline pane, fed from memoized items narrowed by the search
    /// field. Search runs over archived items only — cheap per keystroke.
    @MainActor
    var timelinePane: some View {
        ArchiveTimelinePane(
            timeline: ArchiveTimeline.build(items: cachedTimelineItems(),
                                            matching: searchText),
            selectedIDs: selectedIDs,
            scrollTarget: timelineScrollTarget,
            contextMenu: { ids in AnyView(self.recordContextMenu(for: ids)) },
            openItems: { ids in
                MediaOpener.open(ids.compactMap { self.model.record(forID: $0) })
            })
    }
}

// MARK: - The pane

struct ArchiveTimelinePane: View {
    /// Built by ArchiveView per render from memoized parts; cheap
    /// (archived count, not catalog count).
    let timeline: ArchiveTimeline
    /// Rail selection → scroll anchor. Nil until the user clicks.
    @State private var focusedDecade: Int?
    /// Items to highlight — a hand-off from the Catalog/Hallie selects
    /// the target here instead of dropping into the Files table
    /// (ArchiveHomeState rule 2).
    var selectedIDs: Set<UUID> = []
    /// Item to scroll into view once the pane is up. Owned by ArchiveView.
    var scrollTarget: UUID? = nil
    /// The enclosing ArchiveView's context menu + open handling.
    let contextMenu: (Set<UUID>) -> AnyView
    let openItems: ([UUID]) -> Void

    private static let undatedAnchor = -1

    var body: some View {
        if timeline.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    decadeRail(proxy: proxy)
                        .frame(width: 128)
                    Divider()
                    stream
                }
                .onAppear { scrollToTarget(proxy) }
                .onChange(of: scrollTarget) { scrollToTarget(proxy) }
            }
        }
    }

    /// Bring the hand-off target into view. The cards carry `.id(item.id)`
    /// inside the LazyVStack; SwiftUI resolves the scroll from the
    /// identifier even for cards not yet materialised.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget, timeline.contains(target) else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(target, anchor: .center) }
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
            Text("Right-click a file in the Catalog and choose Archive Helper — every promoted file takes its place on this timeline.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Decade rail (vertical, oldest at top)

    private func decadeRail(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DECADES")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(timeline.decades) { decade in
                        railRow(decade, proxy: proxy)
                    }
                    if !timeline.undated.isEmpty {
                        Divider().padding(.vertical, 4)
                        railButton(label: "Undated",
                                   count: timeline.undated.count,
                                   anchor: Self.undatedAnchor,
                                   dimmed: false,
                                   help: "Archived without a resolvable year — set a date in the Inspector, re-promote files them in place.",
                                   proxy: proxy)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func railRow(_ decade: ArchiveTimelineDecade, proxy: ScrollViewProxy) -> some View {
        railButton(label: decade.label,
                   count: decade.count,
                   anchor: decade.id,
                   dimmed: decade.isGap,
                   help: decade.isGap
                       ? "No media yet from the \(decade.label) — tapes in the attic?"
                       : "\(decade.count) archived from \(decade.rangeLabel)",
                   proxy: proxy)
    }

    private func railButton(label: String, count: Int, anchor: Int,
                            dimmed: Bool, help: String,
                            proxy: ScrollViewProxy) -> some View {
        Button {
            focusedDecade = anchor
            withAnimation { proxy.scrollTo(anchor, anchor: .top) }
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 15, weight: dimmed ? .regular : .semibold))
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                Spacer()
                Text(dimmed ? "—" : "\(count)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(focusedDecade == anchor
                        ? Color.accentColor.opacity(0.12)
                        : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: The stream

    private var stream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(timeline.decades) { decade in
                    if decade.isGap {
                        gapBand(decade)
                            .id(decade.id)
                    } else {
                        Section {
                            ForEach(decade.years) { year in
                                yearBlock(year)
                            }
                        } header: {
                            decadeHeader(decade)
                                .id(decade.id)
                        }
                    }
                }
                if !timeline.undated.isEmpty {
                    Section {
                        ForEach(timeline.undated) { item in
                            itemCard(item)
                        }
                    } header: {
                        undatedHeader
                            .id(Self.undatedAnchor)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }

    private func decadeHeader(_ decade: ArchiveTimelineDecade) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(decade.label)
                .font(.system(size: 26, weight: .bold))
            Text("\(decade.count) archived")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(String(year.year))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            ForEach(year.items) { item in
                itemCard(item)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    // MARK: Item card

    /// One media card. The WHOLE card is click-to-play (Rick, RD round 1:
    /// "people will see a timeline item and want to click it") — the
    /// vetted shelf's payoff is playing the memory, so a card click never
    /// means "select". The play glyph is the affordance; right-click
    /// keeps the full archive menu (journey, details, reveal).
    private func itemCard(_ item: ArchiveTimelineItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)
        return Button {
            openItems([item.id])
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
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
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .help(playHelp(for: item.kind))
                if item.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .help("Byte-verified in the Master Archive")
                }
            }
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
        }
        .buttonStyle(.plain)
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

    private func icon(for kind: ArchiveTimelineItem.Kind) -> String {
        switch kind {
        case .video: return "film"
        case .audio: return "waveform"
        case .photo: return "photo"
        }
    }
}
