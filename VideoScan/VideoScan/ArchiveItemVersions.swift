// ArchiveItemVersions.swift
// Archive timeline — fold an item's VERSIONS into one card (Rick
// 2026-09-22: "1960s-with-music-3-songs" and "…cleaned" showed as two
// unrelated items; "video_name { access, preservation, restored, … }").
//
// App-side only: nothing on disk moves. The on-disk item-folder layout
// (docs, pending Rick's design approval) will make this exact; until then
// the grouping is read from the catalog's lineage links first and, failing
// those, from the names the app itself writes:
//
//   <stem>.vs.preserve.mkv        → preservation   (FFV1 lossless)
//   <stem>.vs.archive.mov         → access         (HEVC — the name predates the role)
//   <stem>.vs.edit.mov            → editable       (ProRes)
//   <stem>-vs-edit(_02).mov       → editable       (a promoted .vs.edit)
//   <stem>_balanced / _cleaned /
//     _restored / _fixed / …      → restored
//   <stem>_trimmed                → trimmed
//   <stem>_02                     → version 2      (a name collision at promote —
//                                                   ONLY when <stem> itself sits
//                                                   in the same folder)
//   <stem>                        → original
//
// Who groups with whom (conservative — a wrong merge hides a memory;
// codex #1644 found three wrong merges in the first cut):
//   1. An ESTABLISHED relationship wins: an item whose catalog derivedFrom
//      points at another archived item joins that item's card, whatever
//      the names say.
//   2. Every ORIGINAL is its own card. Two originals never fold on a
//      shared name — different dates ("1990-01-01_Birthday" vs
//      "1990-09-01_Birthday"), different formats, camera counters
//      ("Clip_01" / "Clip_02") are distinct recordings. The one exception
//      is the promote collision rule: "<name>_NN.<ext>" beside an exact
//      "<name>.<ext>" in the SAME folder, never for camera-counter stems.
//   3. A name-derived VERSION (the app's own .vs.* / _balanced / _cleaned
//      … outputs) joins an original only when exactly one candidate
//      exists: same stem, same year folder, a compatible date prefix
//      (an exact date match breaks a tie). A version WITHOUT a date
//      prefix (an Archive Angel output filed by its render date, e.g.
//      "Christmas1990-Part3-47mins.vs.archive.mov" in 1994) may join an
//      original in ANOTHER year — but only when its own year has none and
//      the whole archive holds exactly ONE candidate. Ambiguous → it stays
//      its own card, visible, never guessed.
//   4. Camera-counter stems never join across years.
// Pure over its input; O(n) with dictionary passes.

import Foundation

/// One version chip on a card.
struct ArchiveItemVersion: Identifiable, Equatable {
    enum Role: Int, Comparable {
        case original = 0, preservation, access, editable, restored, trimmed, converted, other
        static func < (a: Role, b: Role) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .original: return "original"
            case .preservation: return "preservation"
            case .access: return "access"
            case .editable: return "editable"
            case .restored: return "restored"
            case .trimmed: return "trimmed"
            case .converted: return "converted"
            case .other: return "version"
            }
        }

        var help: String {
            switch self {
            case .original: return "The file as it came in, copied byte-for-byte."
            case .preservation: return "Lossless FFV1 copy made because the original's format is at risk."
            case .access: return "Small HEVC copy that plays on anything."
            case .editable: return "ProRes copy for Final Cut."
            case .restored: return "Cleaned-up copy (audio balanced, corrected, or restored)."
            case .trimmed: return "Trimmed copy."
            case .converted: return "Re-encoded or reformatted copy."
            case .other: return "Another copy filed under the same name."
            }
        }
    }

    /// The asset record id of this version (same id the card context menu uses).
    let id: UUID
    let role: Role
    /// "version 2" for a second `.original`/collision; otherwise role.label.
    let label: String
    let archiveFilename: String
    let relPath: String
}

enum ArchiveItemVersions {

    /// Fold versions into cards. Every input item appears exactly once —
    /// as a card or as a chip on one — so nothing can vanish from the
    /// archive view.
    static func group(_ items: [ArchiveTimelineItem]) -> [ArchiveTimelineItem] {
        struct Member {
            let item: ArchiveTimelineItem
            var role: ArchiveItemVersion.Role
            /// Normalized stem, date prefix and version tokens removed.
            let key: String
            /// First date prefix, lowercased ("1990-xx-xx", "1990-12-25"), or nil.
            let date: String?
            /// The date prefix carries a real year (not "xxxx…").
            let dated: Bool
            let folder: String
        }

        var members: [Member] = items.map { item in
            let (key, role) = analyze(item.archiveFilename)
            let date = datePrefix(item.archiveFilename)
            return Member(item: item, role: role, key: key, date: date,
                          dated: date.map { ArchiveTimelinePath.plausibleYear(String($0.prefix(4))) != nil } ?? false,
                          folder: (item.relPath as NSString).deletingLastPathComponent.lowercased())
        }
        let n = members.count
        var indexByID: [UUID: Int] = [:]
        for (i, m) in members.enumerated() { indexByID[m.item.id] = i }

        // (1) Established relationships: catalog lineage inside this set.
        //     (≈ a parent pointer; -1 = none.)
        var parent = [Int](repeating: -1, count: n)
        for i in 0..<n {
            if let p = members[i].item.derivedFromID, let j = indexByID[p], j != i {
                parent[i] = j
                if members[i].role == .original {
                    members[i].role = role(forDerivationKind: members[i].item.derivationKind)
                }
            }
        }

        // (2) Promote collisions: "<name>_NN.<ext>" with "<name>.<ext>" in
        //     the same folder, never for camera counters.
        var nameIndex: [String: Int] = [:]         // "folder/filename" (lowercased) → member
        for (i, m) in members.enumerated() {
            nameIndex[m.folder + "/" + m.item.archiveFilename.lowercased()] = i
        }
        for i in 0..<n where parent[i] < 0 && members[i].role == .original {
            if let j = collisionSibling(members[i].item.archiveFilename, folder: members[i].folder, in: nameIndex),
               j != i {
                parent[i] = j
                members[i].role = .other
            }
        }

        // Groups: index-based; each group remembers its first member for output order.
        var groupOf = [Int](repeating: -1, count: n)
        var groupMembers: [[Int]] = []
        func newGroup() -> Int { groupMembers.append([]); return groupMembers.count - 1 }

        // Anchors: every original with no relationship is its own card.
        var anchorsByKey: [String: [Int]] = [:]    // key → anchor member indices
        for i in 0..<n where parent[i] < 0 && members[i].role == .original {
            groupOf[i] = newGroup()
            anchorsByKey[members[i].key, default: []].append(i)
        }

        // (3) Name-derived versions → exactly one candidate original, else their own card
        //     (shared with same-stem unattached versions of the same year and date).
        var looseGroups: [String: Int] = [:]
        func nameTarget(_ i: Int) -> Int {
            let m = members[i]
            let all = anchorsByKey[m.key] ?? []
            let sameYear = all.filter { members[$0].item.year == m.item.year && datesCompatible(m.date, members[$0].date) }
            if let d = m.date {
                let exact = sameYear.filter { members[$0].date == d }
                if exact.count == 1 { return groupOf[exact[0]] }
            }
            if sameYear.count == 1 { return groupOf[sameYear[0]] }
            if sameYear.isEmpty, !m.dated, !isGeneric(m.key) {
                // Cross-year only for an undated-prefix version of a unique original.
                let anyYear = all.filter { datesCompatible(m.date, members[$0].date) }
                if anyYear.count == 1 { return groupOf[anyYear[0]] }
            }
            let lk = "\(m.item.year.map(String.init) ?? "undated")|\(m.date ?? "")|\(m.key)"
            if let g = looseGroups[lk] { return g }
            let g = newGroup()
            looseGroups[lk] = g
            return g
        }

        // Resolve every member; relationship chains follow the parent
        // pointer (cycle-guarded — a cycle falls back to the name rules).
        var visiting = [Bool](repeating: false, count: n)
        func resolve(_ i: Int) -> Int {
            if groupOf[i] >= 0 { return groupOf[i] }
            visiting[i] = true
            defer { visiting[i] = false }
            let g: Int
            if parent[i] >= 0, !visiting[parent[i]] {
                g = resolve(parent[i])
            } else if members[i].role == .original {
                g = newGroup()
            } else {
                g = nameTarget(i)
            }
            groupOf[i] = g
            return g
        }
        for i in 0..<n {
            let g = resolve(i)
            groupMembers[g].append(i)
        }

        return groupMembers
            .filter { !$0.isEmpty }
            .map { idx in idx.sorted() }
            .sorted { $0[0] < $1[0] }
            .map { idx in
                let ms = idx.map { members[$0] }
                // The card's face: an original with a date prefix, else any
                // original, else a collision copy, else the first dated
                // member, else the first.
                let primary = ms.first { $0.role == .original && $0.dated }
                    ?? ms.first { $0.role == .original }
                    ?? ms.first { $0.role == .other }
                    ?? ms.first { $0.dated }
                    ?? ms[0]
                var seenOriginal = 1
                let versions: [ArchiveItemVersion] = ms
                    .sorted { ($0.role, $0.item.archiveFilename) < ($1.role, $1.item.archiveFilename) }
                    .map { m in
                        var label = m.role.label
                        if (m.role == .original || m.role == .other) && m.item.id != primary.item.id {
                            seenOriginal += 1
                            label = "version \(seenOriginal)"
                        }
                        return ArchiveItemVersion(id: m.item.id, role: m.item.id == primary.item.id ? .original : m.role,
                                                  label: m.item.id == primary.item.id ? primary.role.label : label,
                                                  archiveFilename: m.item.archiveFilename, relPath: m.item.relPath)
                    }
                var card = primary.item
                card.versions = ms.count > 1 ? versions : []
                // The card sits in the primary's year (the memory's year).
                return card
            }
    }

    // MARK: Name analysis

    /// (normalized key, role) for an archive filename. The key excludes
    /// the date prefix (compared separately, see `datePrefix`) and the
    /// app's version tokens. A trailing `_NN` is NOT stripped here — only
    /// `group` can decide it is a collision (it needs the folder's siblings).
    static func analyze(_ filename: String) -> (key: String, role: ArchiveItemVersion.Role) {
        var stem = (filename as NSString).deletingPathExtension
        stem = stripDatePrefixes(stem)
        let lower = stem.lowercased()
        var role: ArchiveItemVersion.Role = .original
        if lower.contains(".vs.preserve") || lower.contains("-vs-preserve") { role = .preservation }
        else if lower.contains(".vs.archive") || lower.contains("-vs-archive") { role = .access }
        else if lower.contains(".vs.edit") || lower.contains("-vs-edit") { role = .editable }
        else if lower.range(of: #"[_-](balanced|cleaned|restored|fixed|corrections|preserve_balanced)$|_denoise[a-z0-9]*$| cleaned$"#,
                            options: .regularExpression) != nil { role = .restored }
        else if lower.range(of: #"[_-]trimmed$"#, options: .regularExpression) != nil { role = .trimmed }
        else if lower.range(of: #"[_-](reformatted|converted|reencoded|proxy)$|_nv12(_\d+)?$"#,
                            options: .regularExpression) != nil { role = .converted }

        // Strip version tokens until stable.
        var base = stem
        base = base.replacingOccurrences(of: #"-vs-(edit|preserve|archive)(_\d{2})?$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        while let b = ArchiveAngel.derivativeBaseStem(base) { base = b }
        base = base.replacingOccurrences(of: #" cleaned$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let key = base.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        return (key.isEmpty ? filename.lowercased() : key, role)
    }

    /// The FIRST date prefix of a filename, lowercased — "1990-xx-xx",
    /// "1990-12-25", "1997", "xxxx-xx-xx" — or nil when there is none.
    /// Part of the grouping identity: two different dates never fold.
    static func datePrefix(_ filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        guard let r = stem.range(of: #"^(\d{4}|xxxx)(-[0-9x]{2}){0,2}(?=[_ ])"#,
                                 options: [.regularExpression, .caseInsensitive]),
              r.upperBound < stem.endIndex else { return nil }
        return stem[r].lowercased()
    }

    /// Two date prefixes can name the same day: every component is equal
    /// or unknown ("xx"/"xxxx"/absent). nil = no prefix = fully unknown.
    static func datesCompatible(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return true }
        let pa = a.split(separator: "-"), pb = b.split(separator: "-")
        for k in 0..<max(pa.count, pb.count) {
            guard k < pa.count, k < pb.count else { continue }
            let x = pa[k], y = pb[k]
            if x.allSatisfy({ $0 == "x" }) || y.allSatisfy({ $0 == "x" }) { continue }
            if x != y { return false }
        }
        return true
    }

    /// "1990-xx-xx_1990-xx-xx_Christmas" → "Christmas" (promote once
    /// doubled the prefix on some files).
    static func stripDatePrefixes(_ stem: String) -> String {
        var s = stem
        while let r = s.range(of: #"^(\d{4}|xxxx)(-[0-9x]{2}){0,2}[_ ]+"#, options: .regularExpression) {
            let rest = s[r.upperBound...]
            if rest.isEmpty { break }
            s = String(rest)
        }
        return s
    }

    /// The promote collision rule, read back: "<name>_NN.<ext>" (NN ≥ 02)
    /// is a second copy of "<name>.<ext>" only when that exact file sits
    /// in the same folder, and never when either stem is a camera counter
    /// ("Clip_01"/"Clip_02" are distinct recordings).
    private static func collisionSibling(_ filename: String, folder: String,
                                         in nameIndex: [String: Int]) -> Int? {
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        guard let r = stem.range(of: #"_\d{2}$"#, options: .regularExpression),
              let nn = Int(stem[r].dropFirst()), nn >= 2 else { return nil }
        let baseStem = String(stem[..<r.lowerBound])
        guard !baseStem.isEmpty else { return nil }
        let baseName = ext.isEmpty ? baseStem : baseStem + "." + ext
        guard let j = nameIndex[folder + "/" + baseName.lowercased()] else { return nil }
        if ArchiveNameAdvisor.isGenericStem(stripDatePrefixes(baseStem))
            || ArchiveNameAdvisor.isGenericStem(stripDatePrefixes(stem)) { return nil }
        return j
    }

    /// The chip for a catalog-linked version whose name carries no token.
    private static func role(forDerivationKind kind: String?) -> ArchiveItemVersion.Role {
        switch kind {
        case BalanceAudioFix.derivationKind?, RebuildAudioFix.derivationKind?,
             ExternalRepairAdoption.derivationKind?: return .restored
        case TrimPlan.derivationKind?: return .trimmed
        default: return .other
        }
    }

    private static func isGeneric(_ key: String) -> Bool {
        ArchiveNameAdvisor.isGenericStem(key) || key.count < 6
    }
}
