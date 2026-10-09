//
//  FeaturedVideos.swift
//  VideoScan
//
//  HAND-PICKED PEOPLE-TAB VIDEOS (Rick 2026-10-04, GH #272): "this is the
//  introductory People tab which will have a few videos per person, maybe
//  10, that are definitely that person." The automatic tag tiers put Donna
//  in a 1947 film, so the People tab leads with videos a person PICKED:
//  right-click a video (Catalog, Archive, or the People panel) ▸ Show in
//  People tab ▸ Donna.
//
//  STORAGE: the person's profile.json (`POIProfile.featuredVideos`) — the
//  People tab is the source of truth for the inner circle. Each pick keeps
//  the record id, its path, its filename and its content hash, so it is
//  found again after a rename, a move or a promote into the Master Archive
//  (the archive copy carries the same content hash). Every write reloads
//  the profile from disk first, so a pick never overwrites an edit made
//  elsewhere, and posts `FeaturedVideos.changed` so the People panel
//  refreshes.
//

import SwiftUI
import VideoScanCore

/// One hand-picked video on a person's People-tab page.
struct FeaturedVideo: Codable, Equatable, Hashable, Sendable {
    var recordID: UUID
    var path: String
    var filename: String
    var contentHash: String?
    var addedAt: Date
}

enum FeaturedVideos {

    /// Decode a stored pick list ROW BY ROW (codex 2026-10-04 P1): a row this
    /// build can't read — or a value that isn't a list at all — is kept
    /// verbatim in `quarantined` and written back, never dropped, so one bad
    /// row can't make the next save erase every pick.
    static func decodeRows(_ raw: JSONValue?) -> (readable: [FeaturedVideo], quarantined: [JSONValue]) {
        guard let raw else { return ([], []) }
        guard case .array(let rows) = raw else { return ([], [raw]) }
        var readable: [FeaturedVideo] = []
        var quarantined: [JSONValue] = []
        for row in rows {
            if let data = try? JSONEncoder().encode(row),
               let pick = try? JSONDecoder().decode(FeaturedVideo.self, from: data) {
                readable.append(pick)
            } else {
                quarantined.append(row)
            }
        }
        return (readable, quarantined)
    }

    /// Posted after a pick is added or removed (object: the profile uuid).
    static let changed = Notification.Name("VideoScan.featuredVideosChanged")

    /// Does `pick` refer to `rec`? Id, then path, then content hash.
    static func matches(_ pick: FeaturedVideo, _ rec: VideoRecord) -> Bool {
        if pick.recordID == rec.id || pick.path == rec.fullPath { return true }
        if let hash = pick.contentHash, !hash.isEmpty, hash == rec.contentHash { return true }
        return false
    }

    static func isFeatured(_ rec: VideoRecord, in profile: POIProfile) -> Bool {
        isFeatured(rec, in: profile.featuredVideos)
    }

    static func isFeatured(_ rec: VideoRecord, in picks: [FeaturedVideo]) -> Bool {
        picks.contains { matches($0, rec) }
    }

    /// Add or remove `recs` in a pick list; returns how many changed.
    static func apply(_ recs: [VideoRecord], on: Bool, to picks: inout [FeaturedVideo]) -> Int {
        var count = 0
        for rec in recs {
            let present = isFeatured(rec, in: picks)
            if on, !present {
                picks.append(FeaturedVideo(
                    recordID: rec.id, path: rec.fullPath, filename: rec.filename,
                    contentHash: rec.contentHash.isEmpty ? nil : rec.contentHash, addedAt: Date()))
                count += 1
            } else if !on, present {
                picks.removeAll { matches($0, rec) }
                count += 1
            }
        }
        return count
    }

    /// The same for a FAMILY's page (FamilyGroup.swift).
    @MainActor @discardableResult
    static func set(_ recs: [VideoRecord], on: Bool, forFamily familyUUID: UUID) -> Bool {
        guard var family = FamilyGroupStore.load(familyUUID) else {
            appLog.write("People tab: could not find that family — nothing changed")
            return false
        }
        let count = apply(recs, on: on, to: &family.featuredVideos)
        guard count > 0 else { return true }
        do {
            try FamilyGroupStore.save(family)
        } catch {
            appLog.write("People tab: could not save \(family.name)'s page — \(error.localizedDescription)")
            return false
        }
        appLog.write("People tab: \(on ? "added" : "removed") \(count) video(s) "
            + "\(on ? "to" : "from") \(family.name)'s page (\(family.featuredVideos.count) now)")
        NotificationCenter.default.post(name: Self.changed, object: familyUUID)
        return true
    }

    /// Add (`on`) or remove the records from the person's page. Reloads
    /// the profile from disk, mutates, saves; false (and a log line) when
    /// the profile is gone or the save failed.
    @MainActor @discardableResult
    static func set(_ recs: [VideoRecord], on: Bool, for profileUUID: UUID) -> Bool {
        guard var profile = POIProfile.listAll().first(where: { $0.uuid == profileUUID }) else {
            appLog.write("People tab: could not find that person's profile — nothing changed")
            return false
        }
        let count = apply(recs, on: on, to: &profile.featuredVideos)
        guard count > 0 else { return true }
        do {
            try profile.save(writingFeaturedVideos: true)
        } catch {
            appLog.write("People tab: could not save \(profile.displayName)'s page — \(error.localizedDescription)")
            return false
        }
        appLog.write("People tab: \(on ? "added" : "removed") \(count) video(s) "
            + "\(on ? "to" : "from") \(profile.displayName)'s page (\(profile.featuredVideos.count) now)")
        NotificationCenter.default.post(name: Self.changed, object: profileUUID)
        return true
    }

    /// The records behind a person's picks, in pick order. A pick whose
    /// video has a Master Archive copy shows the archive copy. Picks that
    /// can no longer be found are skipped (and counted).
    @MainActor
    static func resolve(_ profile: POIProfile, in model: VideoScanModel) -> (videos: [VideoRecord], missing: Int) {
        resolve(profile.featuredVideos, in: model)
    }

    @MainActor
    static func resolve(_ picks: [FeaturedVideo], in model: VideoScanModel) -> (videos: [VideoRecord], missing: Int) {
        var out: [VideoRecord] = []
        var seen: Set<UUID> = []
        var missing = 0
        for pick in picks {
            var rec = model.record(forID: pick.recordID) ?? model.record(forPath: pick.path)
            if rec == nil, let hash = pick.contentHash, !hash.isEmpty {
                // Rare fallback (renamed AND re-scanned): ≤ ~10 picks a person.
                rec = model.records.first { $0.contentHash == hash && !$0.isPurged }
            }
            guard var found = rec, !found.isPurged else { missing += 1; continue }
            if !model.isArchiveCopy(found), let copy = model.archivedCopy(of: found) { found = copy }
            if seen.insert(found.id).inserted { out.append(found) }
        }
        return (out, missing)
    }
}

/// "Show in People tab ▸ Donna / Dan / …" — one submenu for every
/// right-click menu that offers it (Catalog, Archive, People panel).
struct ShowInPeopleTabMenu: View {
    let records: [VideoRecord]

    var body: some View {
        Menu("Show in People tab") {
            let families = FamilyGroupStore.listAll()
            Section("Families") {
                ForEach(families) { family in
                    let allIn = !records.isEmpty && records.allSatisfy {
                        FeaturedVideos.isFeatured($0, in: family.featuredVideos)
                    }
                    Toggle(family.name, isOn: Binding(
                        get: { allIn },
                        set: { FeaturedVideos.set(records, on: $0, forFamily: family.uuid) }))
                }
                // Rick 2026-10-09: "Thanksgiving at the Hudsons' — New Family →
                // Hudson Family", without a trip to the People tab.
                Button("New Family\u{2026}") { Self.addToNewFamily(records) }
            }
            let profiles = POIProfile.listAll().sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            if profiles.isEmpty {
                Text("No people in the People tab yet")
            } else {
                ForEach(profiles, id: \.uuid) { profile in
                    let allIn = !records.isEmpty && records.allSatisfy { FeaturedVideos.isFeatured($0, in: profile) }
                    Toggle(profile.displayName, isOn: Binding(
                        get: { allIn },
                        set: { FeaturedVideos.set(records, on: $0, for: profile.uuid) }))
                }
            }
        }
        .disabled(records.isEmpty)
    }

    /// Ask for a family name, create the family card (People tab), and put
    /// these videos on its page. A modal NSAlert with a text field, because
    /// a menu item can't host a SwiftUI text field and this menu is shared
    /// by several right-click menus (no host state to wire).
    @MainActor
    static func addToNewFamily(_ records: [VideoRecord]) {
        let alert = NSAlert()
        alert.messageText = "New Family"
        alert.informativeText = "Name the family, for example \u{201C}Hudson Family\u{201D}. "
            + "It gets a card in the People tab, and \(records.count == 1 ? "this video goes" : "these \(records.count) videos go") on its page."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Family name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let existing = FamilyGroupStore.listAll().first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) {
            FeaturedVideos.set(records, on: true, forFamily: existing.uuid)
            return
        }
        let group = FamilyGroup(name: name)
        do {
            try FamilyGroupStore.save(group)
            appLog.write("People: added family \(name) from a right-click")
        } catch {
            appLog.write("People: could not add family \(name) — \(error.localizedDescription)")
            return
        }
        FeaturedVideos.set(records, on: true, forFamily: group.uuid)
    }
}
