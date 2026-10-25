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
//  THE PAGE IS SHORT (Rick 2026-10-24, DECISIONS "People tab vs Catalog"):
//  at most PersonVideoPage.curatedCap rows — his picks first, in his order
//  (all of them), then the best of the rest (PersonVideos.ranked), one row
//  per piece of footage; hidden videos never. The full machine-assisted set
//  is the Catalog's Person ▾ filter, one click away ("See all … →").
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
    /// PROVEN archived (GH #327): the green "In the Archive" badge and the
    /// header's count read only this.
    let isArchived: Bool
    let volume: String
    /// Hidden from the to-do view only by a sampled `v1:` match — shown as
    /// "Possibly archived (sampled)", never counted (Rick 2026-10-23).
    var isPossiblyArchived: Bool = false
    /// The stored whole-file SHA-256 (nil: none yet) — the identity a
    /// "Remove from <name>'s Page" hide matches on (PersonPageHides).
    var digest: String? = nil

    /// The badge words for `isPossiblyArchived` (one place, pinned by test).
    static let possiblyArchivedWords = "Possibly archived (sampled)"

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

    /// Which tier a record puts this person in (strongest wins). A
    /// confirmed tag is Rick's word and always wins; otherwise a rejection
    /// ("<name> Isn't in This Video") vetoes the machine tiers, even when a
    /// stale face match is still on the record (2026-10-24).
    static func tier(of rec: VideoRecord, keys: Set<String>) -> PersonVideoTier? {
        if rec.confirmedByUserPeople.contains(where: { keys.contains($0.name.lowercased()) }) { return .tagged }
        if !rec.rejectedPeople.isEmpty, rec.rejectedPeople.contains(where: { keys.contains($0.lowercased()) }) {
            return nil
        }
        if rec.detectedPeople.contains(where: { keys.contains($0.lowercased()) }) { return .foundByFace }
        if rec.suspectedPeople.contains(where: { keys.contains($0.lowercased()) }) { return .maybe }
        return nil
    }

    /// The Catalog's Person picker association (2026-10-24): tagged or
    /// found by face — never a maybe, never a rejected one. The SAME tier
    /// rule as this page, so the two can never disagree. Pure; a row with
    /// no people pays three empty-array reads.
    static func associates(_ rec: VideoRecord, keys: Set<String>) -> Bool {
        if rec.confirmedByUserPeople.isEmpty && rec.detectedPeople.isEmpty { return false }
        switch tier(of: rec, keys: keys) {
        case .tagged?, .foundByFace?: return true
        case .maybe?, nil: return false
        }
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
            if foldsIntoArchiveCopy(rec, listed: paths, in: model) { continue }   // its archive copy carries the row
            out.append(row(rec, tier: tier, in: model, now: now))
        }
        return sorted(out)
    }

    /// True when `rec` is a source whose archived copy is also in this
    /// person's list, so the copy's row stands for both. PROVEN copies only
    /// (GH #327): folding into a sampled `v1:` match would hide a different
    /// video behind it.
    @MainActor
    static func foldsIntoArchiveCopy(_ rec: VideoRecord, listed paths: Set<String>, in model: VideoScanModel) -> Bool {
        guard !model.isArchiveCopy(rec), let copy = model.provenArchivedCopy(of: rec) else { return false }
        return paths.contains(copy.fullPath)
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
            isArchived: model.isProvenArchived(rec),
            volume: VolumeReachability.displayLabel(forPath: rec.fullPath),
            isPossiblyArchived: model.isPossiblyArchivedSampled(rec),
            digest: VideoScanModel.storedFullDigest(rec))
    }

    /// Everything a person's page shows, built once per reload: the picks
    /// and the tagged rows, one row per piece of footage
    /// (PersonVideoFamilies), the hidden ones apart (PersonPageHides); the
    /// curated list drawn from them; and the honest size of the Catalog's
    /// Person filter for the "See all … in the Catalog →" link.
    /// O(that person's videos), never O(catalog).
    @MainActor
    static func page(for profile: POIProfile, in model: VideoScanModel, now: Date = Date()) -> PersonVideoPage {
        let resolved = FeaturedVideos.resolve(profile, in: model)
        let hides = PersonPageHides.Lookup(profile.hiddenVideos)
        let allPicks = resolved.videos.map { row($0, tier: .tagged, in: model, now: now) }
        let pickRows = allPicks.filter { !hides.hides($0) }   // a hidden video never shows, pick or not
        let born = profile.birthdate.map { Calendar.current.component(.year, from: $0) }
        let all = rows(for: profile, in: model, now: now)
        let plausibleRows = all.filter { plausible($0, bornYear: born) }
        let pickIDs = Set(allPicks.map(\.id))
        var shown: [PersonVideoRow] = []
        var hidden = allPicks.filter { hides.hides($0) }
        for r in plausibleRows where !pickIDs.contains(r.id) {
            if hides.hides(r) { hidden.append(r) } else { shown.append(r) }
        }
        // One evidence pass over the page's records AND the Catalog filter's
        // (folded sources, rows dated before birth): proven groups either way.
        let associated = associatedRecords(for: profile, in: model)
        var seen = Set<UUID>()
        let evidenceRecs = ((pickRows + shown + hidden).compactMap { model.record(forID: $0.id) } + associated)
            .filter { seen.insert($0.id).inserted }
        let groups = PersonVideoFamilies.groups(PersonVideoFamilies.evidence(for: evidenceRecs, in: model))
        let withMaybes = PersonVideoFamilies.collapse(picks: pickRows, tagged: shown, groups: groups)
        let strong = PersonVideoFamilies.collapse(picks: pickRows, tagged: shown.filter { $0.tier != .maybe }, groups: groups)
        let hiddenGroups = PersonVideoFamilies.collapse(picks: [], tagged: hidden, groups: groups).tagged
        var page = PersonVideoPage(picks: withMaybes.picks, picksWithoutMaybes: strong.picks,
                                   missingPicks: resolved.missing, tagged: strong.tagged,
                                   taggedWithMaybes: withMaybes.tagged, hidden: hiddenGroups,
                                   hiddenBeforeBirth: all.count - plausibleRows.count)
        page.curated = curate(picks: strong.picks, tagged: strong.tagged)
        page.catalogFiles = associated.count
        page.catalogVideos = PersonVideoFamilies.footageCount(associated.map(\.id), groups: groups)
        return page
    }

    /// The records the Catalog's Person filter shows for this person (by
    /// default — live, not set aside): PersonVideos.associates over the
    /// person index's paths. O(that person's videos).
    @MainActor
    static func associatedRecords(for profile: POIProfile, in model: VideoScanModel) -> [VideoRecord] {
        let keys = tagKeys(for: profile)
        var out: [VideoRecord] = []
        for path in model.searchIndex.paths(forPersonNamesExactly: keys) {
            guard let rec = model.record(forPath: path), !rec.isPurged, !rec.isSetAside,
                  associates(rec, keys: keys) else { continue }
            out.append(rec)
        }
        return out
    }

    // MARK: The curated page (Rick 2026-10-24, DECISIONS "People tab vs Catalog")

    /// Best first: confirmed tags before face matches (the tier is the
    /// match's confidence — the catalog stores no per-file face score), the
    /// archived footage before the rest, then the longer, then by title.
    /// Pure.
    static func ranked(_ groups: [PersonVideoGroup]) -> [PersonVideoGroup] {
        // Keys computed once per group (≈ a C++ decorate-sort-undecorate).
        let keyed = groups.map { g in
            (group: g,
             tier: g.rows.map(\.tier).min() ?? .maybe,
             archived: g.rows.contains(where: \.isArchived),
             seconds: g.lead.durationSeconds)
        }
        return keyed.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.archived != b.archived { return a.archived }
            if a.seconds != b.seconds { return a.seconds > b.seconds }
            return a.group.lead.title.localizedCaseInsensitiveCompare(b.group.lead.title) == .orderedAscending
        }.map(\.group)
    }

    /// The page: every pick, in Rick's order (all of them, even past the
    /// cap — he chose them), then the best of the rest until `cap`. Pure.
    static func curate(picks: [PersonVideoGroup], tagged: [PersonVideoGroup],
                       cap: Int = PersonVideoPage.curatedCap) -> [PersonVideoGroup] {
        picks + ranked(tagged).prefix(max(0, cap - picks.count))
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

    /// The same for a page's groups, by their lead row (already sorted).
    static func byDecade(_ groups: [PersonVideoGroup]) -> [(decade: String, groups: [PersonVideoGroup])] {
        var out: [(decade: String, groups: [PersonVideoGroup])] = []
        for g in groups {
            if out.last?.decade == g.lead.decadeLabel {
                out[out.count - 1].groups.append(g)
            } else {
                out.append((g.lead.decadeLabel, [g]))
            }
        }
        return out
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

/// A person's page, as values (PersonVideos.page).
struct PersonVideoPage: Equatable, Sendable {
    /// Picks with every tagged version under them (maybes included).
    var picks: [PersonVideoGroup] = []
    /// The same, maybes left out of the versions.
    var picksWithoutMaybes: [PersonVideoGroup] = []
    var missingPicks = 0
    /// Tagged and found by face, one row per piece of footage.
    var tagged: [PersonVideoGroup] = []
    /// The same with the maybes.
    var taggedWithMaybes: [PersonVideoGroup] = []
    /// Hidden from this page ("N hidden — Show").
    var hidden: [PersonVideoGroup] = []
    var hiddenBeforeBirth = 0
    /// What the page SHOWS (2026-10-24): the picks, then the best of the
    /// rest up to `curatedCap` (PersonVideos.curate).
    var curated: [PersonVideoGroup] = []
    /// The honest size of the Catalog's Person filter for this person:
    /// every live record tagged or found by face (PersonVideos.associates),
    /// and the pieces of footage they make (same proven evidence).
    var catalogVideos = 0
    var catalogFiles = 0

    /// The most rows the page fills to (Rick may change it). Picks beyond
    /// it are all shown.
    static let curatedCap = 15

    static let empty = PersonVideoPage()

    /// "See all 12 videos · 31 files of Donna in the Catalog →".
    static func seeAllWords(videos: Int, files: Int, name: String) -> String {
        guard videos > 0 else { return "" }
        let what = videos == 1 ? "1 video" : "\(videos) videos"
        let filesPart = files != videos ? " \u{00B7} \(files) files" : ""
        return (videos == 1 ? "See " : "See all ") + what + filesPart + " of \(name) in the Catalog \u{2192}"
    }

    /// Rows only a maybe brought here.
    var maybeCount: Int { taggedWithMaybes.count - tagged.count }

    /// "12" or "12 videos · 31 files" — the header counts count rows (one
    /// per piece of footage); the files only when they differ.
    static func countWords(_ groups: [PersonVideoGroup]) -> String {
        let files = groups.reduce(0) { $0 + $1.fileCount }
        guard files != groups.count else { return "\(groups.count)" }
        return "\(groups.count) video\(groups.count == 1 ? "" : "s") · \(files) files"
    }
}

// MARK: - The section

struct PersonVideosSection: View {
    let profile: POIProfile
    /// A plain reference — NOT observed (the catalog model publishes many
    /// times a second during long jobs). Refresh is by person, on appear,
    /// when a pick or a hide changes, and by the ↻ button.
    let catalogModel: VideoScanModel
    let onShowInCatalog: (String) -> Void
    /// "See all … in the Catalog →": the parent goes through
    /// CatalogPersonLink (Person ▾ picker set, Folders Only off).
    let onShowAllInCatalog: () -> Void

    /// Built once per reload (PersonVideos.page) — the body only reads it.
    @State private var page = PersonVideoPage.empty
    @State private var loaded = false
    @State private var refreshTick = 0
    /// Groups whose "+N versions" is open.
    @State private var openVersions: Set<UUID> = []
    @State private var showHidden = false
    /// The row with the keyboard (↑↓ move it; Rick 2026-10-25).
    @State private var selectedRowID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !loaded {
                ProgressView().controlSize(.small).padding(16)
            } else {
                // A List with a selection, not a scroll stack (Rick 2026-10-25:
                // "all views that have lists should allow up/down arrow").
                // For Rick: List ≈ an NSTableView; the selection binding is
                // what makes ↑↓ work, and the window's click hook gives it
                // the keyboard on click. Non-row items opt out of selection.
                List(selection: $selectedRowID) {
                    // The page (Rick 2026-10-24): his picks first, then the
                    // best of the rest, at most PersonVideoPage.curatedCap.
                    if page.picksWithoutMaybes.isEmpty { pickHint.selectionDisabled() }
                    ForEach(page.curated) { group in groupView(group) }
                    if page.missingPicks > 0 {
                        Text("\(page.missingPicks) picked video\(page.missingPicks == 1 ? "" : "s") can't be found in the catalog right now.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .selectionDisabled()
                    }
                    seeAllInCatalog.selectionDisabled()
                    hiddenFooter.selectionDisabled()
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
        page = PersonVideos.page(for: current, in: catalogModel)
        loaded = true
        appLog.write("People: \(current.displayName)'s page — \(page.curated.count) shown "
            + "(\(page.picksWithoutMaybes.count) picked, cap \(PersonVideoPage.curatedCap)); "
            + "\(page.catalogVideos) videos / \(page.catalogFiles) files in the Catalog; "
            + "\(page.hiddenBeforeBirth) dated before birth, \(page.maybeCount) maybe, "
            + "\(page.hidden.count) hidden from the page")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Videos of \(profile.displayName)")
                .font(.system(size: 17, weight: .semibold))
            if loaded, !page.curated.isEmpty {
                Text(PersonVideoPage.countWords(page.curated))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                let archived = page.curated.filter(\.lead.isArchived).count
                if archived > 0 {
                    Label("\(archived) in the Archive", systemImage: "archivebox.fill")
                        .font(.system(size: 13)).foregroundStyle(.green)
                }
            }
            Spacer()
            Button { refreshTick += 1 } label: { Image(systemName: "arrow.clockwise") }
                .vsGlassButtonStyle()
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

    /// "See all 12 videos of Donna in the Catalog →" — the full machine-
    /// assisted set lives in the Catalog (DECISIONS 2026-10-24).
    @ViewBuilder private var seeAllInCatalog: some View {
        let words = PersonVideoPage.seeAllWords(videos: page.catalogVideos, files: page.catalogFiles,
                                                name: profile.displayName)
        if !words.isEmpty {
            Button(words) { onShowAllInCatalog() }
                .buttonStyle(.link)
                .font(.system(size: 13))
                .help("Open the Catalog showing every video tagged \(profile.displayName) or found by face")
                .accessibilityIdentifier("people.videos.seeAllInCatalog")
                .padding(.horizontal, 14).padding(.top, 10)
        }
    }

    /// "3 hidden — Show": the way back from "Remove from <name>'s Page".
    @ViewBuilder private var hiddenFooter: some View {
        if !page.hidden.isEmpty {
            HStack(spacing: 6) {
                Text("\(page.hidden.count) hidden from \(profile.displayName)\u{2019}s page")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(showHidden ? "Hide" : "Show") { showHidden.toggle() }
                    .buttonStyle(.link).font(.system(size: 12))
            }
            .padding(.horizontal, 14).padding(.top, 12)
            if showHidden {
                ForEach(page.hidden) { group in
                    rowView(group.lead, scope: group.rows, actions: [.putBackOnPage])
                        .opacity(0.7)
                }
            }
        }
    }

    /// One piece of footage: its lead row, then "+N versions" (closed by
    /// default). A right-click on the lead acts on every file of the
    /// footage; on a version, on that file alone.
    @ViewBuilder private func groupView(_ group: PersonVideoGroup) -> some View {
        rowView(group.lead, scope: group.rows, actions: [.removeFromPage, .notInVideo])
            .tag(group.lead.id)
        if !group.versions.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { openVersions.contains(group.id) },
                set: { if $0 { openVersions.insert(group.id) } else { openVersions.remove(group.id) } })) {
                ForEach(group.versions) { v in
                    rowView(v, scope: [v], actions: [.removeFromPage, .notInVideo]).tag(v.id)
                }
            } label: {
                Text(group.versionsWords)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .help(PersonVideoGroup.evidenceHelp)
            }
            .padding(.leading, 140).padding(.trailing, 14)
            .selectionDisabled()
        }
    }

    /// `scope`: the rows a right-click acts on (the whole footage on a
    /// lead, one file on a version).
    private func rowView(_ row: PersonVideoRow, scope: [PersonVideoRow],
                         actions: [PersonVideoRemovalAction]) -> some View {
        PersonVideoRowView(row: row, catalogModel: catalogModel, onShowInCatalog: onShowInCatalog,
                           removal: PersonVideoRowRemoval(
                               personName: profile.displayName,
                               actions: actions,
                               perform: { action in
                                   let recs = scope.compactMap { catalogModel.record(forID: $0.id) }
                                   PersonVideoRemoval.perform(action, recs: recs, profile: profile, model: catalogModel)
                                   refreshTick += 1
                               }))
    }
}

// MARK: - One row

/// What a person's page offers to take a row off it (PersonVideoRemoval).
struct PersonVideoRowRemoval {
    let personName: String
    let actions: [PersonVideoRemovalAction]
    /// The section resolves the row's records at the click.
    let perform: @MainActor (PersonVideoRemovalAction) -> Void
}

struct PersonVideoRowView: View {
    let row: PersonVideoRow
    let catalogModel: VideoScanModel
    let onShowInCatalog: (String) -> Void
    /// nil on pages that offer no removal (a family's page).
    var removal: PersonVideoRowRemoval? = nil

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
            } else if row.isPossiblyArchived {
                Label(PersonVideoRow.possiblyArchivedWords, systemImage: "archivebox")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Its sampled signature matches a file in the Archive — not yet verified by a full SHA-256.")
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
            if let removal {
                ForEach(removal.actions, id: \.self) { action in
                    Button(action.title(removal.personName)) { removal.perform(action) }
                        .help(action.help(removal.personName))
                }
                Divider()
            }
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

// MARK: - A family's page

/// "Videos of Rick & Donna Breen Family" — the videos picked for a family
/// group (FamilyGroup.swift), grouped by decade. Same rows, same
/// right-click menu as a person's page.
struct FamilyVideosSection: View {
    let familyUUID: UUID
    let catalogModel: VideoScanModel
    let onShowInCatalog: (String) -> Void

    @State private var family: FamilyGroup?
    @State private var rows: [PersonVideoRow] = []
    @State private var missing = 0
    @State private var refreshTick = 0
    /// The row with the keyboard (↑↓ move it; Rick 2026-10-25).
    @State private var selectedRowID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "person.3.fill").foregroundStyle(.tint)
                Text("Videos of \(family?.name ?? "this family")")
                    .font(.system(size: 17, weight: .semibold))
                if !rows.isEmpty {
                    Text("\(rows.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    let archived = rows.filter(\.isArchived).count
                    if archived > 0 {
                        Label("\(archived) in the Archive", systemImage: "archivebox.fill")
                            .font(.system(size: 13)).foregroundStyle(.green)
                    }
                }
                Spacer()
                Button { refreshTick += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .vsGlassButtonStyle()
                    .help("Look again")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            // Same list shape as a person's page (Rick 2026-10-25): ↑↓ move
            // the selection; headers and notes opt out of selection.
            List(selection: $selectedRowID) {
                if rows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No videos picked for \(family?.name ?? "this family") yet.")
                            .font(.system(size: 15))
                        Text("Right-click a video in the Catalog or the Archive ▸ Show in People tab ▸ \(family?.name ?? "the family").")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .selectionDisabled()
                } else {
                    ForEach(PersonVideos.byDecade(rows), id: \.decade) { group in
                        Text(group.decade)
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14).padding(.top, 6)
                            .selectionDisabled()
                        ForEach(group.rows) { row in
                            PersonVideoRowView(row: row, catalogModel: catalogModel,
                                               onShowInCatalog: onShowInCatalog)
                                .tag(row.id)
                        }
                    }
                }
                if missing > 0 {
                    Text("\(missing) picked video\(missing == 1 ? "" : "s") can't be found in the catalog right now.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .selectionDisabled()
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .task(id: "\(familyUUID)-\(refreshTick)") {
            family = FamilyGroupStore.load(familyUUID)
            let picks = FeaturedVideos.resolve(family?.featuredVideos ?? [], in: catalogModel)
            rows = PersonVideos.sorted(picks.videos.map { PersonVideos.row($0, tier: .tagged, in: catalogModel) })
            missing = picks.missing
            appLog.write("People: \(family?.name ?? "family")'s page — \(rows.count) picked")
        }
        .onReceive(NotificationCenter.default.publisher(for: FeaturedVideos.changed)) { note in
            if (note.object as? UUID) == familyUUID { refreshTick += 1 }
        }
    }
}
