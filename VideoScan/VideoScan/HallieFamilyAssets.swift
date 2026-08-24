// HallieFamilyAssets.swift
// Where the family's photos and crests live (Rick 2026-08-22 21:40:
// "in the archive under photos or in the app directory or both?" →
// BOTH: originals in the Master Archive so they get the RAID's 3-2-1
// protection; App Support only as the fallback root and for thumbnails).
//
// Path authority and validation live in FamilyAssetStore. This file now
// contains only the shell/eval attachment renderer.

import Foundation

/// Text rendering of attachments for the shell / eval harness.
enum HallieAttachmentText {
    static func lines(_ attachments: [HallieAttachment]) -> [String] {
        var out: [String] = []
        func person(_ p: HalliePersonCard) -> String {
            var s = "\(p.name) [GEDCOM \(p.gedcomID)]"
            if let y = p.years { s += " (\(y))" }
            if let b = p.birthPlace { s += " — \(b)" }
            return s
        }
        for a in attachments {
            switch a {
            case .photo(let p):
                out.append("[photo] \(p.personName): \(p.fileURL.path)")
            case .crest(let surname, let url):
                out.append("[crest] \(surname): \(url.path)")
            case .lineage(let card):
                out.append("[lineage] \(card.title) — \(card.generations.count) of \(card.requested) generations")
                out.append("  \(person(card.root))")
                for g in card.generations {
                    out.append("  \(g.label): " + g.people.map(person).joined(separator: "; "))
                }
            case .tree(let card):
                out.append("[tree] \(card.title) — \(card.peopleCount) people, depth \(card.depth)")
                func walk(_ n: HallieTreeCard.Node, indent: Int) {
                    var s = String(repeating: "  ", count: indent + 1) + person(n.person)
                    if !n.spouses.isEmpty { s += " ⚭ " + n.spouses.map(\.name).joined(separator: ", ") }
                    out.append(s)
                    for c in n.children { walk(c, indent: indent + 1) }
                }
                for r in card.roots { walk(r, indent: 0) }
            case .photoRequest(let name, let folder):
                out.append("[photo request] \(name): put a photo in \(folder.path)")
            }
        }
        return out
    }
}
