// ArchiveItemVersions.swift
// Archive timeline — fold an item's VERSIONS into one card (Rick
// 2026-09-22: "1960s-with-music-3-songs" and "…cleaned" showed as two
// unrelated items; "video_name { access, preservation, restored, … }").
//
// App-side only: nothing on disk moves. The on-disk item-folder layout
// (docs, pending Rick's design approval) will make this exact; until then
// the grouping is read from the names the app itself writes:
//
//   <stem>.vs.preserve.mkv        → preservation   (FFV1 lossless)
//   <stem>.vs.archive.mov         → access         (HEVC — the name predates the role)
//   <stem>.vs.edit.mov            → editable       (ProRes)
//   <stem>-vs-edit(_02).mov       → editable       (a promoted .vs.edit)
//   <stem>_balanced / _cleaned /
//     _restored / _fixed / …      → restored
//   <stem>_trimmed                → trimmed
//   <stem>_02                     → version 2      (a name collision at promote)
//   <stem>                        → original
//
// Who groups with whom (conservative — a wrong merge hides a memory):
//   • Same normalized stem in the SAME year folder.
//   • A version WITHOUT a date prefix (an Archive Angel output such as
//     "Christmas1990-Part3-47mins.vs.archive.mov", which the Angel filed by
//     its own render date) may also join a same-stem item in ANOTHER year —
//     the card then sits in the original's year, which is where it belongs.
//   • Camera-counter stems ("Clip 01", "MVI_1234") never group across years.
// Pure over its input; O(n) with one dictionary pass.

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
        struct Member { let item: ArchiveTimelineItem; let role: ArchiveItemVersion.Role; let dated: Bool; let key: String }

        let members: [Member] = items.map { item in
            let (key, role) = analyze(item.archiveFilename)
            return Member(item: item, role: role,
                          dated: ArchiveTimelinePath.leadingYear(in: item.archiveFilename) != nil,
                          key: key)
        }

        // Pass 1: groups of DATED members by (year, key). Generic stems key
        // on the exact filename stem instead, so they only group with their
        // own .vs.* siblings.
        var groups: [String: [Int]] = [:]          // groupKey → member indices
        var order: [String] = []
        func groupKey(_ m: Member) -> String { "\(m.item.year.map(String.init) ?? "undated")|\(m.key)" }
        for (i, m) in members.enumerated() where m.dated || m.role == .original {
            let k = groupKey(m)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        // Pass 2: undated-prefix versions join a same-stem group in their own
        // year if one exists, else any year's (their year is the render
        // date, not the memory's); else they form their own group.
        var byStem: [String: [String]] = [:]       // key → group keys holding it
        for k in order { byStem[String(k.split(separator: "|", maxSplits: 1)[1]), default: []].append(k) }
        for (i, m) in members.enumerated() where !(m.dated || m.role == .original) {
            let own = groupKey(m)
            let target: String
            if groups[own] != nil {
                target = own
            } else if !isGeneric(m.key), let other = byStem[m.key]?.first {
                target = other
            } else {
                target = own
                order.append(own)
                byStem[m.key, default: []].append(own)
            }
            groups[target, default: []].append(i)
        }

        return order.map { k in
            let ms = groups[k, default: []].map { members[$0] }
            // The card's face: an original with a date prefix, else any
            // original, else the first dated member, else the first.
            let primary = ms.first { $0.role == .original && $0.dated }
                ?? ms.first { $0.role == .original }
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

    /// (normalized key, role) for an archive filename.
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

        // Strip version tokens until stable, then collision suffixes.
        var base = stem
        base = base.replacingOccurrences(of: #"-vs-(edit|preserve|archive)(_\d{2})?$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive])
        while let b = ArchiveAngelNaming.derivativeBaseStem(base) { base = b }
        base = base.replacingOccurrences(of: #" cleaned$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if base.range(of: #"_\d{2}$"#, options: .regularExpression) != nil, role == .original {
            base = String(base.dropLast(3))
            role = .other
        }
        let key = base.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
        return (key.isEmpty ? filename.lowercased() : key, role)
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

    private static func isGeneric(_ key: String) -> Bool {
        ArchiveNameAdvisor.isGenericStem(key) || key.count < 6
    }
}
