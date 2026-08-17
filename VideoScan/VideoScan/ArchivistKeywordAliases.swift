import Foundation

/// Small, deterministic place/event alias table for Hallie's keyword search.
///
/// Why this exists: the translator keeps the user's own words as keywords
/// ("down the cape"), but the catalog spells places the way files were named
/// ("CapeCod_June_1997.mp4", "Cape-1992-archive.mkv"). Stopword-stripped
/// token matching (see `ArchivistKeywordText`) already bridges most of that
/// gap; this table covers the spellings tokens cannot bridge on their own —
/// "xmas" vs "christmas", "capecod" written as one word, "the vineyard" for
/// Martha's Vineyard.
///
/// This is knowledge-in-data on the deterministic side of the translator
/// boundary: no model call, no fuzzy matching, and every alias hit is cited
/// in the evidence line ("filename tokens 'cape cod' via alias of 'down the
/// cape'"). Extend it by adding a group; order inside a group is irrelevant.
///
/// Rules for adding a group (keep precision high — this is an OR over the
/// group, so every member must genuinely mean the same place/event):
///   * Members are matched by their significant tokens (stopwords dropped),
///     so "the cape", "down the cape", and "cape" all reduce to ["cape"] and
///     do not need separate entries — list them anyway when it documents the
///     family idiom Rick actually says.
///   * A member such as "capecod" (one token) is what lets "Cape Cod" match
///     lowercase filenames that never had a camelCase boundary to split on.
///   * Do NOT add a broad word to a narrow group ("morning" to christmas):
///     that widens every question about the narrow term.
enum ArchivistKeywordAliases {
    /// Each inner array is one equivalence group of family phrases.
    static let groups: [[String]] = [
        // Places
        ["cape", "cape cod", "capecod", "the cape", "down the cape",
         "down cape", "on the cape"],
        ["martha's vineyard", "marthas vineyard", "the vineyard", "vineyard"],
        ["the lake", "lake", "at the lake"],
        // Holidays and family events
        ["christmas", "xmas", "x-mas"],
        ["birthday", "bday", "b-day", "b day"],
        ["thanksgiving", "tgiving", "turkey day"],
        ["fourth of july", "4th of july", "july 4th", "july fourth",
         "independence day"],
        ["halloween", "hallowe'en"],
        ["new year's", "new years", "new year's eve", "new years eve", "nye"],
        ["graduation", "grad"],
        // Rick: add Montana, Westford, Nana's house, etc. here as needed.
    ]

    /// Significant-token forms of every group member, keyed by group index.
    /// Built once; the table is tiny.
    static let tokenizedGroups: [[[String]]] = groups.map { group in
        group.map { ArchivistKeywordText.significantTokens($0) }
            .filter { !$0.isEmpty }
    }

    /// Alias token lists for a keyword: the significant-token forms of every
    /// OTHER member of every group the keyword belongs to. Membership is by
    /// significant tokens, so "down the cape" belongs to the cape group even
    /// though it is not spelled out identically. Empty when the keyword is in
    /// no group. Result order is deterministic (group order, then member
    /// order) so evidence citations are stable.
    static func aliases(for keyword: String) -> [[String]] {
        let own = ArchivistKeywordText.significantTokens(keyword)
        guard !own.isEmpty else { return [] }
        var seen: Set<[String]> = [own]
        var result: [[String]] = []
        for group in tokenizedGroups where group.contains(own) {
            for member in group where seen.insert(member).inserted {
                result.append(member)
            }
        }
        return result
    }
}
