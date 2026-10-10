// HallieTagOnlyName.swift
// "the Hudsons", "Hudson family", "Aunt Bonnie" → the catalog person tag
// Rick actually typed (a tag-only name, no People profile). 2026-10-09.

import Foundation

/// Catalog ▸ People ▸ Families ▸ New Family… (25e3f42ca) tags videos with a
/// free-text group name ("<X> Family", or a bare "<X>") and creates no
/// People-tab profile. A visitor asks for that group in plural or "family"
/// form, which matched no tag exactly — and the plural then reached the
/// presence lane's spelling recovery as a one-edit "typo" of a profile's
/// maiden-name form, so "the <X>s" answered with ONE person's videos.
///
/// This maps a family-group phrase onto the tag Rick actually typed. It
/// only ever returns an existing tag string; it never invents a person and
/// never touches a phrase that already IS a tag.
///
/// C++ analogy: an `enum` with no cases is Swift's namespace-of-statics —
/// like a `struct` with only `static` member functions and a deleted ctor.
enum HallieTagOnlyName {

    /// Titles a visitor puts before a tagged first name ("Aunt Carol").
    static let kinTitles: Set<String> = ["aunt", "auntie", "uncle", "cousin"]

    /// The tag `typed` names as a family group, or nil.
    ///
    /// Family-group shapes (leading "the" ignored):
    ///   "<X> family" / "<X> families"   → stem X
    ///   "<X>s" / "<X>es" / "<X>'s"      → stem X (one word only)
    /// A tag matches when its words, minus "the" and "family", are exactly
    /// the stem. Several matches ("<X>" and "<X> Family") → the bare one,
    /// which the presence matcher's token-subset rule proves against both.
    static func resolve(_ typed: String, taggedNames: [String]) -> String? {
        let typedKey = key(typed)
        guard !typedKey.isEmpty else { return nil }
        let isExactTag = taggedNames.contains { key($0) == typedKey }
        // "Aunt Carol" → the tag "Carol": a kin title is how a visitor
        // says the name, never part of what Rick typed on the tag.
        let typedWords = words(typed)
        if !isExactTag, typedWords.count >= 2, kinTitles.contains(typedWords[0]) {
            let rest = typedWords.dropFirst().joined(separator: " ")
            if let tag = taggedNames.first(where: { key($0) == rest }) { return tag }
        }
        let stems = familyStems(of: typed)
        guard !stems.isEmpty else { return nil }
        var matches: [String] = []
        for tag in taggedNames where stems.contains(groupWords(of: tag)) {
            if !matches.contains(where: { key($0) == key(tag) }) { matches.append(tag) }
        }
        let best = matches.min {
            let (a, b) = (words($0).count, words($1).count)
            return a != b ? a < b : $0.lowercased() < $1.lowercased()
        }
        // Typed exactly as the best tag already: nothing to map. An exact
        // "<X> Family" still maps to a bare "<X>" tag when one exists, so
        // both spellings Rick used are searched.
        guard let best, key(best) != typedKey else { return nil }
        return best
    }

    /// Candidate stems (each a word list) for a family-group phrase; empty
    /// when the phrase is not family-group shaped.
    static func familyStems(of typed: String) -> [[String]] {
        var tokens = words(typed)
        if tokens.first == "the" { tokens.removeFirst() }
        guard !tokens.isEmpty else { return [] }
        if let last = tokens.last, last == "family" || last == "families" {
            tokens.removeLast()
            guard !tokens.isEmpty, !tokens.contains("family") else { return [] }
            // "the Hudson's family" / "the Hudsons family" too.
            return [tokens] + singulars(of: tokens)
        }
        // A bare plural is one word: "Hudsons". Two words ("Tim Jones")
        // are a person's name, never a group.
        guard tokens.count == 1 else { return [] }
        return singulars(of: tokens)
    }

    private static func singulars(of tokens: [String]) -> [[String]] {
        guard let last = tokens.last else { return [] }
        let head = Array(tokens.dropLast())
        var out: [[String]] = []
        for suffix in ["'s", "’s", "es", "s"] where last.hasSuffix(suffix) {
            let stem = String(last.dropLast(suffix.count))
            // A stem keeps 3+ letters ("Lees" → "lee"); "Bs" is no family.
            if stem.count >= 3 { out.append(head + [stem]) }
        }
        return out
    }

    /// A tag's group words: its words minus "the" and "family".
    private static func groupWords(of tag: String) -> [String] {
        words(tag).filter { $0 != "the" && $0 != "family" }
    }

    /// Lowercased, diacritic-folded words; an apostrophe INSIDE a word is
    /// kept so the possessive stays visible to `singulars`.
    private static func words(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive],
                      locale: Locale(identifier: "en_US"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" })
            // "Hudsons'" → "hudsons"; the inner "'s" of "hudson's" stays.
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    /// The tag spelled exactly as `typed` (case / diacritics aside), or nil.
    static func exactTag(_ typed: String, taggedNames: [String]) -> String? {
        let typedKey = key(typed)
        guard !typedKey.isEmpty else { return nil }
        return taggedNames.first { key($0) == typedKey }
    }

    /// True when `typed` names a tag: exactly, as a family group, or after
    /// a kin title.
    static func namesATag(_ typed: String, taggedNames: [String]) -> Bool {
        exactTag(typed, taggedNames: taggedNames) != nil
            || resolve(typed, taggedNames: taggedNames) != nil
    }

    private static func key(_ value: String) -> String {
        words(value).joined(separator: " ")
    }
}

extension HallieTurnExecutor {
    /// Every distinct confirmed person-tag spelling in the catalog, first
    /// spelling wins (case-insensitive). One pass over the snapshots.
    static func confirmedTagNames(_ context: Context) -> [String] {
        var seen: Set<String> = []
        var tagged: [String] = []
        for record in context.presenceRecords {
            for tag in record.confirmedPeople where seen.insert(tag.name.lowercased()).inserted {
                tagged.append(tag.name)
            }
        }
        return tagged
    }

    /// The aggregate fallback's "is this anchor a person?" oracle (GH #182):
    /// a People / CyberBrain / tree person, the owner, or a tag-only name —
    /// "show me videos with <First>" read as a co-occurrence must reach her
    /// tagged videos, not "I couldn't resolve the anchor" (probe 2026-10-09).
    static func isSearchablePerson(_ name: String, context: Context) -> Bool {
        isKnownPerson(name, context: context)
            || HallieOwnerResolver.isOwnerSpelling(name, owner: context.speakers.ownerName)
            || HallieTagOnlyName.namesATag(name, taggedNames: confirmedTagNames(context))
    }

    /// Tag-only names (Catalog ▸ People ▸ New Person… / New Family…, no
    /// People profile) reach the tag Rick typed. Runs BEFORE spelling
    /// recovery, which would otherwise take "the <X>s" for a one-edit typo
    /// of a profile's maiden-name form. Returns basis notes (empty = no
    /// change worth saying).
    ///   • a person term naming a family group or "Aunt <tag>" → that tag;
    ///   • a person term that already IS a tag is left exactly as typed
    ///     (golden answers pin the typed spelling in the query text);
    ///   • a family-shaped KEYWORD naming a tag ("hudsons") → a person;
    ///   • a lone kin-title keyword the question says right before a named
    ///     person ("Aunt Bonnie" → person bonnie + keyword "aunt") → dropped:
    ///     it is how the visitor names her, not a word in the video.
    /// A People-tab name is never rewritten — the profile wins.
    static func mapTagOnlyNames(
        _ effective: inout ArchivistQueryAST.Presence, question: String, context: Context
    ) -> [String] {
        let tagged = confirmedTagNames(context)
        guard !tagged.isEmpty else { return [] }
        var notes: [String] = []
        var people = (effective.people ?? []).map { typed -> String in
            guard !isPeopleTabPerson(typed, context: context) else { return typed }
            if let tag = HallieTagOnlyName.resolve(typed, taggedNames: tagged) {
                notes.append("“\(typed)” is the person tag “\(tag)”")
                return tag
            }
            return typed
        }
        var keywords: [String] = []
        for word in effective.keywords ?? [] {
            if !HallieTagOnlyName.familyStems(of: word).isEmpty,
               !isPeopleTabPerson(word, context: context),
               let tag = HallieTagOnlyName.resolve(word, taggedNames: tagged) {
                if !people.contains(where: { $0.lowercased() == tag.lowercased() }) { people.append(tag) }
                notes.append("“\(word)” is the family tagged “\(tag)”, so I searched that tag")
                continue
            }
            keywords.append(word)
        }
        let lowered = question.lowercased()
        keywords.removeAll { word in
            let title = word.lowercased().trimmingCharacters(in: .whitespaces)
            guard HallieTagOnlyName.kinTitles.contains(title) else { return false }
            return people.contains { lowered.contains(title + " " + $0.lowercased()) }
        }
        effective.people = people.isEmpty ? nil : people
        effective.keywords = keywords.isEmpty ? nil : keywords
        return notes
    }
}

