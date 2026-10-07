// HallieSuperlativeCorrection.swift
// The turn AFTER a ranking that corrects its SCOPE, not its kind. Live
// 2026-09-26 (Rick, 20:48–20:49 ET): "find the earliest birth year for
// richard's tree" ranked the whole tree and answered Gruffudd ap Einion
// b. 780 — Donna's line. Rick said "that is donna's line", and Hallie
// wrote Donna's biography; "that person b. 780 is donna's ancestor, not
// mine. I want mine" drew Rick's. Both are corrections of the previous
// answer's scope: the same superlative, over the side he meant.
//
// Pure text → the corrected scope. The caller (preTranslation) applies it
// only while ConversationMemory remembers a superlative; the same words
// with nothing to correct route as they always did. A fresh scoped
// question ("who is the oldest person on donna's side") is never read as
// a correction — it is its own ranking.
//
// Forms, first match wins:
//   stated target — "I want mine", "not mine", "that's not my side",
//                   "I meant rick", "no, I meant for rick", "for rick",
//                   "what about donna's side", "donna's side", "mine",
//                   "that is my line" / "those are our ancestors"
//   the other side — "that is donna's line", "those are donna's
//                   ancestors"
//
// 2026-10-07 (end-to-end replay): "that is my line" after "who was the
// oldest person in the family tree?" used to mean "that one is mine, rank
// the spouse's side" and answered from Donna's ancestors. Said by the
// speaker, "my line" names the line they want ranked — the owner's own
// ancestors, the same target as "I want mine". The named form ("that is
// donna's line") keeps Rick's 2026-09-26 ruling: the other side.

import Foundation

enum HallieSuperlativeCorrection {
    typealias Scope = HallieLineageQuestion.SuperlativeScope

    private static let sideNouns = #"(?:line|side|ancestors?|ancestry|lineage|family\s+tree|tree|family|branch|people|kin|folks|relatives?|forebears?)"#
    private static let ownerWords = #"(?:me|mine|myself|us|ours|ourselves|my\s+(?:own|side|line|ancestors|ancestry|family|tree|people|lineage|branch)|our\s+(?:side|line|ancestors|ancestry|family|tree|people|lineage|branch))"#
    /// A name is a run of name TOKENS — never a demonstrative, a verb or
    /// an article — so "that is rick's line" is never the person "That Is
    /// Rick" (caught RED by the first run of HallieSuperlativeScopeTests).
    private static let nameToken = #"(?:(?!(?:that|that's|thats|this|those|these|is|are|was|were|it's|its|it|he|she|he's|she's|not|no|the|a|an|my|our|for|and|but|so|ok|okay|i|meant|mean|want)\b)[a-z][a-z'.-]*)"#
    private static let name = "(" + nameToken + #"(?:\s+"# + nameToken + "){0,3}?)"

    /// The corrected scope, or nil when the text is not a scope correction.
    static func scope(in text: String) -> Scope? {
        let lower = HallieLineageQuestion.normalize(text)
        guard !lower.isEmpty, lower.split(separator: " ").count <= 24 else { return nil }
        guard lower.firstMatch(of: HallieLineageQuestion.mediaNoun) == nil else { return nil }
        // A question in its own right is never a correction of the last one.
        guard HallieLineageQuestion.detect(lower) == nil else { return nil }

        func named(_ raw: Substring?) -> String? {
            guard let raw else { return nil }
            return HallieLineageQuestion.scopeName(String(raw))
        }
        func target(owner: Substring?, name raw: Substring?) -> Scope? {
            if owner != nil { return .ancestorsOf(nil) }
            guard let n = named(raw) else { return nil }
            return .ancestorsOf(n)
        }

        // 1. A stated target.
        if let re = try? Regex(#"\b(?:i want|i wanted|i'd like|give me|show me|use|try)\s+"# + ownerWords + #"\b"#),
           lower.firstMatch(of: re) != nil {
            return .ancestorsOf(nil)
        }
        if let re = try? Regex(#"\bnot\s+"# + ownerWords + #"\b"#), lower.firstMatch(of: re) != nil {
            return .ancestorsOf(nil)
        }
        if let re = try? Regex(#"\b(?:i meant|i mean|meant|make (?:it|that)|do (?:it|that))\s+(?:for\s+)?(?:("# + ownerWords + #")|"# + name + #")(?:'s?)?(?:\s+"# + sideNouns + #")?\s*$"#),
           let m = lower.firstMatch(of: re) {
            if let scope = target(owner: m.output[1].substring, name: m.output[2].substring) { return scope }
        }
        if let re = try? Regex(#"^(?:(?:no|ok|okay|hmm|well|and|so),?\s+)*(?:for|now for|and for|what about|how about|try|do)\s+(?:("# + ownerWords + #")|"# + name + #")(?:'s?)?(?:\s+"# + sideNouns + #")?\s*$"#),
           let m = lower.firstMatch(of: re) {
            if let scope = target(owner: m.output[1].substring, name: m.output[2].substring) { return scope }
        }
        if let re = try? Regex(#"^(?:(?:no|ok|okay|hmm|well),?\s+)*"# + ownerWords + #"$"#), lower.firstMatch(of: re) != nil {
            return .ancestorsOf(nil)
        }
        if let re = try? Regex(#"^(?:(?:no|ok|okay|hmm|well),?\s+)*"# + name + #"'s\s+"# + sideNouns + #"\s*$"#),
           let m = lower.firstMatch(of: re) {
            if let scope = target(owner: nil, name: m.output[1].substring) { return scope }
        }
        // "that's not rick's side" → Rick's.
        if let re = try? Regex(#"\bnot\s+(?:(my|our)|"# + name + #"'s)\s+"# + sideNouns + #"\b"#),
           let m = lower.firstMatch(of: re) {
            if let scope = target(owner: m.output[1].substring, name: m.output[2].substring) { return scope }
        }
        // 2. "that is donna's line" → the other side; "that is my line" →
        //    the speaker's own line (replay 2026-10-07: it ranked the
        //    spouse's side instead).
        if let re = try? Regex(#"\b(?:that|that's|that is|those are|these are|this is|he is|she is|he's|she's|it's|it is|is|are|was|were)\s+(?:(my|our)|"# + name + #"'s)\s+"# + sideNouns + #"\b"#),
           let m = lower.firstMatch(of: re) {
            if m.output[1].substring != nil { return .ancestorsOf(nil) }
            if let n = named(m.output[2].substring) { return .otherSideOf(n) }
        }
        return nil
    }
}
