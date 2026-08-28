// GedcomFamilyGraph+Writer.swift
// Minimal GEDCOM 5.5.1 writer: exactly what the parser reads, so a merged
// tree can be saved as ONE .ged next to its sources and load through the
// same loader as any export (2026-08-27). Round-trip is pinned in
// GedcomMergeTests.
//
// Written: HEAD (SOUR, GEDC, CHAR, a NOTE with the provenance sentence,
// and VideoScan's own `_VS_SOURCE` / `_VS_ROOT` lines the parser reads
// back), then every INDI — roots first, in root order, so a reader that
// only knows the first-INDI convention still lands on Rick — with NAME
// (primary and alternates), SEX, BIRT/DEAT DATE+PLAC, FAMC, FAMS,
// _FSFTID; then every FAM with HUSB, WIFE, CHIL, MARR DATE; then TRLR.
// Sources, notes and everything else the parser ignores are NOT carried
// over — the source files stay on disk untouched for that.
//
// Memory: the whole text is built in one String. A 32k-person merge is
// ~12 lines per person ≈ 400k lines ≈ 15 MB — bounded by the tree size,
// which the parser already holds in memory.

import Foundation

extension GedcomFamilyGraph {

    /// The tree as GEDCOM text. `provenance` becomes the HEAD NOTE.
    public func gedcomText(provenance: String? = nil, now: Date = Date()) -> String {
        var lines: [String] = []
        lines.reserveCapacity(people.count * 12 + families.count * 5 + 16)
        lines.append("0 HEAD")
        lines.append("1 SOUR VideoScan")
        lines.append("2 NAME VideoScan family-tree merge")
        lines.append("1 DATE " + Self.gedcomDate(now))
        lines.append("1 GEDC")
        lines.append("2 VERS 5.5.1")
        lines.append("2 FORM LINEAGE-LINKED")
        lines.append("1 CHAR UTF-8")
        if let provenance, !provenance.isEmpty {
            Self.appendNote(provenance, level: 1, to: &lines)
        }
        for name in sourceFileNames { lines.append("1 _VS_SOURCE " + name) }
        for id in rootPersonIDs { lines.append("1 _VS_ROOT " + id) }

        let rootSet = Set(rootPersonIDs)
        let ordered = rootPersonIDs.compactMap { people[$0] }
            + Self.sortedPointers(people.keys.filter { !rootSet.contains($0) }).compactMap { people[$0] }
        for p in ordered {
            lines.append("0 \(p.id) INDI")
            lines.append("1 NAME " + Self.gedcomName(p.name, surnames: [p.surname].compactMap { $0 }))
            for alt in p.alternateNames {
                lines.append("1 NAME " + Self.gedcomName(alt, surnames: [p.surname].compactMap { $0 } + p.alternateSurnames))
            }
            if !p.sex.isEmpty { lines.append("1 SEX " + p.sex) }
            if p.birthDate != nil || p.birthPlace != nil {
                lines.append("1 BIRT")
                if let d = p.birthDate { lines.append("2 DATE " + d) }
                if let pl = p.birthPlace { lines.append("2 PLAC " + pl) }
            }
            if p.deathDate != nil || p.deathPlace != nil {
                lines.append("1 DEAT")
                if let d = p.deathDate { lines.append("2 DATE " + d) }
                if let pl = p.deathPlace { lines.append("2 PLAC " + pl) }
            }
            let famc = p.childOfFamilies.isEmpty ? [p.childOfFamily].compactMap { $0 } : p.childOfFamilies
            for f in famc { lines.append("1 FAMC " + f) }
            for f in p.spouseOfFamilies { lines.append("1 FAMS " + f) }
            if let fsid = p.familySearchID { lines.append("1 _FSFTID " + fsid) }
        }
        for fid in Self.sortedPointers(families.keys) {
            let fam = families[fid]!
            lines.append("0 \(fid) FAM")
            if let h = fam.husband { lines.append("1 HUSB " + h) }
            if let w = fam.wife { lines.append("1 WIFE " + w) }
            for c in fam.children { lines.append("1 CHIL " + c) }
            if let m = fam.marriageDate {
                lines.append("1 MARR")
                lines.append("2 DATE " + m)
            }
        }
        lines.append("0 TRLR")
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Richard Harding Breen Jr" with surname "Breen" → "Richard Harding
    /// /Breen/ Jr". The first run of tokens equal to one of `surnames`
    /// gets the slashes; a name carrying none of them is written plain
    /// (and reads back with no surname, as it was parsed).
    static func gedcomName(_ display: String, surnames: [String]) -> String {
        let tokens = display.split(separator: " ").map(String.init)
        for surname in surnames {
            let want = surname.split(separator: " ").map(String.init)
            guard !want.isEmpty, tokens.count >= want.count else { continue }
            for start in 0...(tokens.count - want.count)
            where Array(tokens[start..<(start + want.count)]) == want {
                let before = tokens[..<start].joined(separator: " ")
                let after = tokens[(start + want.count)...].joined(separator: " ")
                return [before, "/" + surname + "/", after].filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return display
    }

    /// GEDCOM NOTE with CONT lines for newlines and CONC splits at 200
    /// characters (the 5.5.1 line-length rule; the parser ignores NOTE
    /// entirely, this is for the human reading the file).
    static func appendNote(_ text: String, level: Int, to lines: inout [String]) {
        var first = true
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(raw)
            var tag = first ? "NOTE" : "CONT"
            let lvl = first ? level : level + 1
            first = false
            repeat {
                let chunk = rest.prefix(200)
                lines.append("\(lvl) \(tag) \(chunk)")
                rest = rest.dropFirst(chunk.count)
                tag = "CONC"
            } while !rest.isEmpty
        }
    }

    /// "27 AUG 2026" (GEDCOM's own date spelling, UTC).
    static func gedcomDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date).uppercased()
    }
}
