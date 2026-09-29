// ArchiveNameAdvisor.swift
// Promote-Helper slice 3 (Rick 2026-08-19): "Clip 01.dv tells nobody
// anything — rename it ON THE WAY to the archive, master untouched."
// Pure helpers behind the Assess panel's prepare strip and the Promote
// sheet's name field: is the current stem generic camera noise, and what
// name can the catalog itself suggest (people/tags — the date prefix is
// already part of every archive filename, so the year is never repeated).

import Foundation

enum ArchiveNameAdvisor {

    /// Camera/deck/counter stems that carry no meaning: "clip 01",
    /// "IMG_1234", "MVI_0042", "00005", "untitled", "Sequence 1", tape
    /// counters, plain timestamps.
    static func isGenericStem(_ stem: String) -> Bool {
        let s = stem.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return true }
        // Strip separators for the pattern tests.
        let compact = s.replacingOccurrences(of: "[ _\\-.]+", with: "", options: .regularExpression)
        if compact.range(of: "^[0-9]+$", options: .regularExpression) != nil { return true }
        let prefixes = ["clip", "img", "mvi", "dsc", "dscn", "gopr", "gp", "mov", "video", "untitled",
                        "sequence", "capture", "export", "output", "tape", "scan", "track", "title",
                        "file", "recording", "avseq", "vts", "mts", "m2ts", "pict", "sdv", "hdv"]
        for p in prefixes {
            if compact == p { return true }
            if compact.hasPrefix(p),
               compact.dropFirst(p.count).range(of: "^[0-9]+[a-z]?$", options: .regularExpression) != nil {
                return true
            }
        }
        // Pure timestamp stems: 19970704, 1997-07-04 12.30.45, etc.
        if compact.range(of: "^(19|20)[0-9]{6,12}$", options: .regularExpression) != nil { return true }
        return false
    }

    /// A suggestion from what the catalog already knows: confirmed/detected
    /// people first, then tags — CamelCased and joined. Nil when the
    /// catalog has nothing better than the filename (the field stays empty
    /// and the user types the meaning only they know).
    static func suggestedTitle(people: [String], tags: [String]) -> String? {
        let words = (people.prefix(3) + tags.prefix(2))
            .map { camel($0) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        guard !unique.isEmpty else { return nil }
        return unique.joined(separator: "_")
    }

    /// "cape cod vacation" → "CapeCodVacation".
    static func camel(_ s: String) -> String {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }
}
