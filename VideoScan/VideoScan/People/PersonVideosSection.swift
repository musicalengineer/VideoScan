//
//  PersonVideosSection.swift
//  VideoScan
//
//  "VIDEOS OF DONNA" — the People tab's primary view (Rick 2026-10-04,
//  GH #272, UI-first trial). Click a person and see the videos we already
//  know they are in — catalog and Master Archive together, each marked
//  archived or not — instead of starting a live drive search. Family
//  members can stay in this tab, browse here, and ask Hallie. Detail
//  (columns, metadata, editing) stays in Catalog and Archive.
//
//  Tiers come straight from the catalog's three people lists:
//    Tagged        — confirmedByUserPeople (a person said so)
//    Found by face — detectedPeople (the matcher, strong tier)
//    Maybe         — suspectedPeople (guesses; hidden unless asked for)
//
//  MAIN THREAD IS PRECIOUS: the person → paths answer comes from the
//  catalog search index's person bucket (O(names), microseconds), and rows
//  are built only for THOSE records — never a pass over the catalog.
//  Thumbnails come only from frames already cached (memory, or the
//  overnight preview cache on disk), looked up off the main actor per
//  visible row; this panel never decodes video or wakes a sleeping drive
//  for a picture.
//
//  (For Rick: `LazyVStack` ≈ a list that only builds the rows on screen;
//  `.task(id:)` ≈ start this async work when the view appears and restart
//  it whenever `id` changes, cancelling the old run.)
//

import AppKit
import SwiftUI
import VideoScanCore

// MARK: - Rows (pure data)

enum PersonVideoTier: Int, Comparable, Sendable {
    case tagged, foundByFace, maybe

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .tagged: return "Tagged"
        case .foundByFace: return "Found by face"
        case .maybe: return "Maybe"
        }
    }

    var color: Color {
        switch self {
        case .tagged: return .green
        case .foundByFace: return .blue
        case .maybe: return .orange
        }
    }
}

struct PersonVideoRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let path: String
    let title: String
    let year: Int?
    let durationSeconds: Double
    let tier: PersonVideoTier
    let isArchived: Bool
    let volume: String

    var decadeLabel: String {
        guard let year else { return "Date unknown" }
        return "\(year / 10 * 10)s"
    }

    var subtitle: String {
        var parts: [String] = []
        if let year { parts.append(String(year)) }
        if durationSeconds >= 60 {
            parts.append("\(Int(durationSeconds / 60)) min")
        } else if durationSeconds > 0 {
            parts.append("\(Int(durationSeconds)) s")
        }
        if !volume.isEmpty { parts.append(volume) }
        return parts.joined(separator: " · ")
    }
}

enum PersonVideos {

    /// The lowercased names a person is tagged under: short name, every
    /// alias, and the display name (aliases are the join key — see the
    /// People↔CyberBrain alias note).
    static func tagKeys(for profile: POIProfile) -> Set<String> {
        let all = [profile.name, profile.displayName] + profile.aliases
        return Set(all.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                      .filter { !$0.isEmpty })
    }

    /// Which tier a record puts this person in (strongest wins).
    static func tier(of rec: VideoRecord, keys: Set<String>) -> PersonVideoTier? {
        if rec.confirmedByUserPeople.contains(where: { keys.contains($0.name.lowercased()) }) { return .tagged }
        if rec.detectedPeople.contains(where: { keys.contains($0.lowercased()) }) { return .foundByFace }
        if rec.suspectedPeople.contains(where: { keys.contains($0.lowercased()) }) { return .maybe }
        return nil
    }

    /// Rows for one person. O(that person's videos), never O(catalog).
    /// A source whose Master Archive copy is also in the list is folded
    /// into the copy (one row per video, marked archived).
    @MainActor
    static func rows(for profile: POIProfile, in model: VideoScanModel, now: Date = Date()) -> [PersonVideoRow] {
        let keys = tagKeys(for: profile)
        let paths = model.searchIndex.paths(forPersonNamesExactly: keys)
        var out: [PersonVideoRow] = []
        out.reserveCapacity(paths.count)
        for path in paths {
            guard let rec = model.record(forPath: path), !rec.isPurged, !rec.isSetAside,
                  let tier = tier(of: rec, keys: keys) else { continue }
            if !model.isArchiveCopy(rec), let copy = model.archivedCopy(of: rec), paths.contains(copy.fullPath) {
                continue   // its archive copy carries the row
            }
            out.append(row(rec, tier: tier, in: model, now: now))
        }
        return sorted(out)
    }

    /// One row for `rec` (the shared date + archive rules).
    @MainActor
    static func row(_ rec: VideoRecord, tier: PersonVideoTier, in model: VideoScanModel,
                    now: Date = Date()) -> PersonVideoRow {
        let date = RecordDateResolver.resolve(
            userDate: rec.userDate, userDateConfidence: rec.userDateConfidence,
            embeddedCreationDate: rec.embeddedCreationDate,
            originMake: rec.originMake, originModel: rec.originModel, originEncoder: rec.originEncoder,
            inferredRecordDate: rec.inferredRecordDate, inferredDateConfidence: rec.inferredDateConfidence,
            inferredDateRange: rec.inferredDateRange,
            filename: rec.filename.isEmpty ? nil : rec.filename, now: now)
        return PersonVideoRow(
            id: rec.id, path: rec.fullPath,
            title: (rec.filename as NSString).deletingPathExtension,
            year: date.year, durationSeconds: rec.durationSeconds, tier: tier,
            isArchived: model.isArchived(rec),
            volume: VolumeReachability.displayLabel(forPath: rec.fullPath))
    }

    /// Rick 2026-10-04: "Donna wasn't alive in 1947." A row dated before
    /// the person's birth year cannot be them. Undated rows, and people
    /// with no birthdate, pass.
    static func plausible(_ row: PersonVideoRow, bornYear: Int?) -> Bool {
        guard let bornYear, let year = row.year else { return true }
        return year >= bornYear
    }

    /// Oldest first; undated last; then title.
    static func sorted(_ rows: [PersonVideoRow]) -> [PersonVideoRow] {
        rows.sorted { a, b in
            switch (a.year, b.year) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Consecutive rows grouped by decade label (rows already sorted).
    static func byDecade(_ rows: [PersonVideoRow]) -> [(decade: String, rows: [PersonVideoRow])] {
        var out: [(decade: String, rows: [PersonVideoRow])] = []
        for row in rows {
            if out.last?.decade == row.decadeLabel {
                out[out.count - 1].rows.append(row)
            } else {
                out.append((row.decadeLabel, [row]))
            }
        }
        return out
    }
}

// MARK: - The section

struct PersonVideosSection: View {
    let profile: POIProfile
    /// A plain reference — NOT observed (the catalog model publishes many
    /// times a second during long jobs). Refresh is by person, on appear,
    /// when a pick changes, and by the ↻ button.
    let catalogModel: VideoScanModel
    let onShowInCatalog: (String) -> Void

    /// Hand-picked (primary).
    @State private var featured: [PersonVideoRow] = []
    @State private var missingPicks = 0
    /// Automatic, from tags (secondary, folded away).
    @State private var tagged: [PersonVideoRow] = []
    @State private var hiddenBeforeBirth = 0
    @State private var loaded = false
    @State private var refreshTick = 0
    @AppStorage("people.videos.showMaybes") private var showMaybes = false
    @AppStorage("people.videos.showTagged") private var showTagged = false

    private var maybeCount: Int { tagged.filter { $0.tier == .maybe }.count }
    private var taggedShown: [PersonVideoRow] {
        let featuredIDs = Set(featured.map(\.id))
        return tagged.filter { !featuredIDs.contains($0.id) && (showMaybes || $0.tier != .maybe) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !loaded {
                ProgressView().controlSize(.small).padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if featured.isEmpty {
                            pickHint
                        } else {
                            ForEach(featured) { row in rowView(row) }
                        }
                        if missingPicks > 0 {
                            Text("\(missingPicks) picked video\(missingPicks == 1 ? "" : "s") can't be found in the catalog right now.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                        }
                        taggedDisclosure
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .task(id: "\(profile.uuid)-\(refreshTick)") { reload() }
        .onReceive(NotificationCenter.default.publisher(for: FeaturedVideos.changed)) { note in
            if (note.object as? UUID) == profile.uuid { refreshTick += 1 }
        }
    }

    private func reload() {
        loaded = false
        // Fresh from disk: a pick made in the Catalog saved profile.json,
        // and the People tab's copy of the profile may predate it.
        let current = POIProfile.listAll().first { $0.uuid == profile.uuid } ?? profile
        let picks = FeaturedVideos.resolve(current, in: catalogModel)
        featured = picks.videos.map { PersonVideos.row($0, tier: .tagged, in: catalogModel) }
        missingPicks = picks.missing
        let born = current.birthdate.map { Calendar.current.component(.year, from: $0) }
        let all = PersonVideos.rows(for: current, in: catalogModel)
        tagged = all.filter { PersonVideos.plausible($0, bornYear: born) }
        hiddenBeforeBirth = all.count - tagged.count
        loaded = true
        appLog.write("People: \(current.displayName)'s page — \(featured.count) picked, "
            + "\(tagged.count) tagged (\(hiddenBeforeBirth) dated before birth hidden, \(maybeCount) maybe)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Videos of \(profile.displayName)")
                .font(.system(size: 17, weight: .semibold))
            if loaded, !featured.isEmpty {
                Text("\(featured.count)")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                let archived = featured.filter(\.isArchived).count
                if archived > 0 {
                    Label("\(archived) in the Archive", systemImage: "archivebox.fill")
                        .font(.system(size: 13)).foregroundStyle(.green)
                }
            }
            Spacer()
            Button { refreshTick += 1 } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.glass)
                .help("Look again")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var pickHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No videos picked for \(profile.displayName) yet.")
                .font(.system(size: 15))
            Text("Right-click a video in the Catalog or the Archive ▸ Show in People tab ▸ \(profile.displayName).")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// The automatic list, folded away: it is evidence, not the page.
    @ViewBuilder private var taggedDisclosure: some View {
        let rows = taggedShown
        if !rows.isEmpty || maybeCount > 0 {
            DisclosureGroup(isExpanded: $showTagged) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        if maybeCount > 0 {
                            Toggle("Include \(maybeCount) maybe\(maybeCount == 1 ? "" : "s")", isOn: $showMaybes)
                                .toggleStyle(.checkbox)
                        }
                        if hiddenBeforeBirth > 0 {
                            Text("\(hiddenBeforeBirth) dated before \(profile.displayName) was born — not shown")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    ForEach(PersonVideos.byDecade(rows), id: \.decade) { group in
                        Text(group.decade)
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.top, 6)
                        ForEach(group.rows) { row in rowView(row) }
                    }
                }
            } label: {
                Text("More videos tagged \(profile.displayName) (\(rows.count))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    private func rowView(_ row: PersonVideoRow) -> some View {
        PersonVideoRowView(row: row, catalogModel: catalogModel, onShowInCatalog: onShowInCatalog)
    }
}

// MARK: - One row

private struct PersonVideoRowView: View {
    let row: PersonVideoRow
    let catalogModel: VideoScanModel
    let onShowInCatalog: (String) -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").font(.system(size: 20)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Text(row.subtitle)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if row.isArchived {
                Label("In the Archive", systemImage: "archivebox.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
            Text(row.tier.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(row.tier.color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(row.tier.color.opacity(0.12)))
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(hovering ? Color.accentColor.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
        .contextMenu {
            Button("Play") { play() }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(row.path, inFileViewerRootedAtPath: "")
            }
            Button("Show in Catalog") { onShowInCatalog(row.title) }
            Divider()
            ShowInPeopleTabMenu(records: catalogModel.record(forPath: row.path).map { [$0] } ?? [])
        }
        .help("Double-click to play")
        .task(id: row.path) { await loadCachedThumbnail() }
    }

    private func play() {
        // Same smart open as the Archive table: QuickTime when the codecs
        // allow, else VLC.
        if let rec = catalogModel.record(forPath: row.path) {
            MediaOpener.open([rec])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: row.path))
        }
        appLog.write("People: play \(row.title)")
    }

    /// Cached frames only: memory first, then the on-disk preview cache
    /// (a stat + JPEG decode, off the main actor). Never decodes video.
    private func loadCachedThumbnail() async {
        if let cached = catalogModel.thumbnailCache.object(forKey: row.path as NSString) {
            thumbnail = cached
            return
        }
        let path = row.path
        let disk = catalogModel.previewDiskCache
        let image: CGImage? = await Task.detached(priority: .utility) {
            guard let sig = PreviewDiskCache.fileSignature(atPath: path) else { return nil }
            return disk.lookup(path: path, mtime: sig.mtime, size: sig.size)
        }.value
        if let image, !Task.isCancelled { thumbnail = NSImage(cgImage: image, size: .zero) }
    }
}
