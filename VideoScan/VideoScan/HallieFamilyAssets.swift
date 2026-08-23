// HallieFamilyAssets.swift
// Where the family's photos and crests live (Rick 2026-08-22 21:40:
// "in the archive under photos or in the app directory or both?" →
// BOTH: originals in the Master Archive so they get the RAID's 3-2-1
// protection; App Support only as the fallback root and for thumbnails).
//
// codex owns the full `FamilyAssetStore` (lookup, hardening, tests) on
// feature/family-assets. This file is only the folder convention both
// sides compile against, so the "put it here" prompt and his store agree
// on paths. Pure path arithmetic; creates nothing.

import Foundation

enum HallieFamilyAssets {
    static let archiveSubfolder = "Family Tree"

    /// `<root>/Family Tree/` — the Master Archive when designated, else
    /// App Support. The root is published by the app at launch (and on
    /// re-designation) so the pure answer paths never touch the model.
    nonisolated(unsafe) static var archiveRootPath: String? = nil

    static var assetsRoot: URL {
        if let root = archiveRootPath {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(archiveSubfolder, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("VideoScan/family-tree/assets", isDirectory: true)
    }

    static var peopleFolder: URL { assetsRoot.appendingPathComponent("People", isDirectory: true) }
    static var crestsFolder: URL { assetsRoot.appendingPathComponent("Crests", isDirectory: true) }

    /// `Crests/<Surname>.(png|jpg|jpeg|heic)` when present. Case-insensitive
    /// on the surname; the first extension found wins. Nil = no crest yet.
    static func crestURL(surname: String) -> URL? {
        let folder = crestsFolder
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        let wanted = surname.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let exts = ["png", "jpg", "jpeg", "heic"]
        for name in names.sorted() {
            let url = folder.appendingPathComponent(name)
            let stem = url.deletingPathExtension().lastPathComponent
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            guard stem == wanted, exts.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            return url
        }
        return nil
    }

    /// `People/<Name>/` — the name as written, minus path-hostile characters.
    static func photoFolder(forPerson name: String) -> URL? {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\\")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return peopleFolder.appendingPathComponent(cleaned, isDirectory: true)
    }
}

/// Text rendering of attachments for the shell / eval harness.
enum HallieAttachmentText {
    static func lines(_ attachments: [HallieAttachment]) -> [String] {
        var out: [String] = []
        func person(_ p: HalliePersonCard) -> String {
            var s = p.name
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
