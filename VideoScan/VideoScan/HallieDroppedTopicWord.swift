// HallieDroppedTopicWord.swift
// A holiday, family event or family place the reader SAID must survive into
// the catalog query, whatever the translator returned.
//
// Live, three times (2026-09-22, 09-24, 09-25): "Christmas videos from 2006"
// came back from the local translator as `shape=presence year=2006` — the
// word "Christmas" gone — and Hallie answered "There are 864 catalog items
// from 2006". True, cited, and not the question: the ledger's signature
// shape (a constraint misses and the answer is a different question, asked
// with full confidence). The translator prompt already carries this exact
// example; a prompt is a courtesy, this is the guarantee.
//
// Scope is deliberately the curated `ArchivistKeywordAliases` groups only —
// the place/holiday/event words the catalog search already treats as
// topics. No open-vocabulary guessing: an arbitrary content word the model
// dropped may have been dropped on purpose (a name, a filler, a kin word).
//
// Not applied when:
//   * the turn is a refinement or paging re-run (the AST was built from the
//     previous turn on purpose — "without christmas" removes it);
//   * the question negates anything ("not", "without", "except", "n't") —
//     the dropped word may be the thing excluded;
//   * the word is part of a person's name the AST already carries;
//   * any AST keyword or spoken term already covers the group (by alias:
//     "xmas" covers "christmas").

import Foundation

enum HallieDroppedTopicWord {
    /// Group members the question names that no AST term covers, in
    /// question order. Pure.
    static func missing(
        question: String,
        people: [String],
        terms: [String]
    ) -> [String] {
        let lowered = question.lowercased()
        if lowered.range(of: #"\b(not|without|except|excluding|never|no)\b|n['’]t\b"#,
                         options: .regularExpression) != nil {
            return []
        }
        let asked = ArchivistKeywordText.significantTokens(question)
        guard !asked.isEmpty else { return [] }
        let nameTokens = Set(people.flatMap { ArchivistKeywordText.tokens($0) })
        let termTokens = terms.map { ArchivistKeywordText.significantTokens($0) }

        var found: [(position: Int, phrase: String)] = []
        for (index, group) in ArchivistKeywordAliases.tokenizedGroups.enumerated() {
            // The longest member the question contains, so "down the cape"
            // is reported as the reader's phrase rather than a fragment.
            let hits = group
                .compactMap { member -> (Int, [String])? in
                    guard let at = position(of: member, in: asked) else { return nil }
                    return (at, member)
                }
                .sorted { $0.1.count > $1.1.count }
            guard let (at, member) = hits.first else { continue }
            if !nameTokens.isDisjoint(with: member) { continue }
            let covered = termTokens.contains { term in
                group.contains { position(of: $0, in: term) != nil }
            }
            if covered { continue }
            let phrase = ArchivistKeywordAliases.groups[index]
                .first { ArchivistKeywordText.significantTokens($0) == member }
                ?? member.joined(separator: " ")
            found.append((at, phrase))
        }
        return found.sorted { $0.position < $1.position }.map(\.phrase)
    }

    /// Index of `needle` as a contiguous run inside `haystack`, or nil.
    static func position(of needle: [String], in haystack: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return start
        }
        return nil
    }

    /// The basis note for words put back.
    static func note(_ words: [String]) -> String {
        let quoted = words.map { "“\($0)”" }.joined(separator: ", ")
        let verb = words.count == 1 ? "is" : "are"
        return "\(quoted) \(verb) in the question but the translator left \(words.count == 1 ? "it" : "them") out, so I searched for \(words.count == 1 ? "it" : "them") too"
    }
}
