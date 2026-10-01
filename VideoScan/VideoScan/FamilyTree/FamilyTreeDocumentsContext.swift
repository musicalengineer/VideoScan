// FamilyTreeDocumentsContext.swift
// What the inspector's Documents panel shows BESIDE each document (Rick,
// 2026-10-01: "a real person-records list"):
//
//   • GROUPS — rows by kind in a fixed order: Birth, Death, Marriage,
//     Military, Census, Other (`PersonDocumentKind` declaration order).
//   • YEAR and SOURCE SITE — for a document filed through Record Finder
//     ("I found a record…"), the research dossier holds a `.recordFinder`
//     finding whose `documentPath` names the filed file. Its `date` is the
//     record's year; the site is the first part of the document's note
//     ("irishgenealogy.ie: Civil birth 1904 …"), accepted only when the
//     finding's title names the same site. A document added by hand has
//     neither, and shows neither — nothing is guessed.
//   • RESEARCH — how many findings in the person's dossier Rick marked
//     Confirmed, for the "Research" line under the list.
//
// All pure except `load`, which reads ONE dossier.json (≤ 500 findings ×
// ≤ 1 KB ≈ 0.5 MB worst case) and is called off the main actor. Nothing
// is cached here; the panel holds the one result for the person on screen.
//
// (For Rick: `struct … Sendable` ≈ an immutable value the compiler has
// checked may be handed to a worker thread.)

import Foundation

/// Year and site for one filed document; both nil for a hand-added one.
struct PersonDocumentDetails: Equatable, Sendable {
    var year: String?
    var site: String?
}

/// One heading of the panel and its rows (already newest first).
struct PersonDocumentGroup: Identifiable, Equatable {
    let kind: PersonDocumentKind
    let rows: [PersonDocumentRow]
    var id: String { kind.rawValue }
}

/// Everything the panel shows that comes from the research dossier.
struct PersonDocumentsResearch: Equatable, Sendable {
    /// Keyed by document id.
    var details: [UUID: PersonDocumentDetails] = [:]
    /// Findings Rick marked Confirmed in the Research pane.
    var confirmedFindings = 0

    static let empty = PersonDocumentsResearch()

    // MARK: Grouping

    /// Rows by kind, in the panel's order; empty kinds are left out. The
    /// rows keep their incoming order (newest first) inside each group.
    /// O(rows) — one person's documents, never the tree.
    static func grouped(_ rows: [PersonDocumentRow]) -> [PersonDocumentGroup] {
        var byKind: [PersonDocumentKind: [PersonDocumentRow]] = [:]
        for row in rows { byKind[row.document.kind, default: []].append(row) }
        return PersonDocumentKind.allCases.compactMap { kind in
            guard let rows = byKind[kind], !rows.isEmpty else { return nil }
            return PersonDocumentGroup(kind: kind, rows: rows)
        }
    }

    /// The rows in the order the panel draws them (group by group) — the
    /// order Quick Look's arrows walk.
    static func displayOrder(_ rows: [PersonDocumentRow]) -> [PersonDocumentRow] {
        grouped(rows).flatMap(\.rows)
    }

    // MARK: Derivation (pure)

    /// Match each row to the Record Finder finding that filed it.
    static func derive(rows: [PersonDocumentRow], dossier: ResearchDossier?) -> PersonDocumentsResearch {
        guard let dossier else { return .empty }
        var out = PersonDocumentsResearch()
        out.confirmedFindings = dossier.findings.filter { $0.verdict == .confirmed }.count
        let filed = dossier.findings.filter { $0.source == .recordFinder && $0.documentPath != nil }
        guard !filed.isEmpty else { return out }
        for row in rows {
            guard let folder = row.personFolder?.lastPathComponent else { continue }
            // `People/<folder>/Documents/<file>` — compared on the last three
            // components, so the archive's mount point never matters.
            let tail = "\(folder)/\(FamilyAssetStore.documentsFolderName)/\(row.document.filename)"
            guard let finding = filed.first(where: { Self.path($0.documentPath, endsWith: tail) }) else { continue }
            var details = PersonDocumentDetails()
            details.year = Self.year(in: finding.date)
            details.site = Self.site(note: row.document.note, findingTitle: finding.title)
            if details != PersonDocumentDetails() { out.details[row.document.id] = details }
        }
        return out
    }

    /// The four-digit year a filing recorded ("1904"), else nil.
    static func year(in date: String?) -> String? {
        guard let date = date?.trimmingCharacters(in: .whitespacesAndNewlines),
              date.count >= 4 else { return nil }
        let head = String(date.prefix(4))
        return head.allSatisfy(\.isNumber) ? head : nil
    }

    /// "irishgenealogy.ie" from the note "irishgenealogy.ie: Civil birth …",
    /// only when the finding's title ("Civil birth — irishgenealogy.ie")
    /// names the same site; otherwise nil (the note may have been written
    /// by hand).
    static func site(note: String, findingTitle: String) -> String? {
        guard let colon = note.range(of: ": ") else { return nil }
        let site = note[..<colon.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty, site.count <= 120, findingTitle.contains("— \(site)") else { return nil }
        return site
    }

    private static func path(_ path: String?, endsWith tail: String) -> Bool {
        guard let path else { return false }
        return path == tail || path.hasSuffix("/" + tail)
    }

    // MARK: Loading (off the main actor)

    /// Read the person's dossier and derive. A missing or unreadable
    /// dossier gives `.empty` — the panel then shows no years, no sites and
    /// a zero count, never an error (the Research pane reports damage).
    static func load(rows: [PersonDocumentRow], researchKey: String?, store: ResearchStore?) -> PersonDocumentsResearch {
        guard let researchKey, let store,
              let dossier = try? store.loadDossier(key: researchKey) else { return .empty }
        return derive(rows: rows, dossier: dossier)
    }
}
