// ArchivistGraphQuery+FieldGuards.swift
// The deterministic field guards: what a sentence plainly asks for — a
// place, a date or age, a relation, the whole person — decided from the
// words, so a model that has settled on `death` for a whole conversation
// cannot answer the wrong field (Rick, live 2026-09-07, four times).
//
// `ArchivistGraphQuery.init(_:voices:question:)` consults these in a fixed
// order: place, then relation, then biography. Pure functions of the
// question text (and the payload's subject words); no state, no I/O.
// Moved out of ArchivistGraphExecutor.swift on 2026-09-07 night unchanged —
// behaviour is pinned by HalliePlaceQuestionTests and
// HallieRelationGuardSubjectTests.

import Foundation

extension ArchivistGraphQuery {
    /// The relation a sentence plainly asks for, or nil. Rick, live
    /// 2026-09-07: "whom did he marry", "who was his spouse" and "who did
    /// john hastings marry?" ALL came back with the man's death — the model
    /// answered `death` for every question in a conversation that had been
    /// about a dead earl for twenty turns, and the deterministic layer had
    /// nothing to say about it. These are decidable from the words, exactly
    /// like the place questions above, so they are decided here.
    ///
    /// Only unambiguous single-relation asks: "his parents", "who did X
    /// marry". A sentence naming two relations, or none, is left alone.
    static func asksForRelation(_ question: String, subject people: [String] = []) -> Relation? {
        let q = question.lowercased()
        // "tell me about dad" (strict replay, 2026-09-07): the relative word
        // IS the resolved subject (person=dad), not a relation asked of him.
        // Forcing `.father` answered "Richard Harding Breen Sr's father was
        // George Breen" for a question about Rick's father himself.
        let subjectWords = Set(people.flatMap {
            $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        })
        let table: [(pattern: String, relation: Relation)] = [
            (#"\bgreat[- ]great[- ]grandparents?\b"#, .greatGreatGrandparents),
            (#"\bgreat[- ]grandparents?\b"#, .greatGrandparents),
            (#"\bgrandparents\b"#, .grandparents),
            (#"\bgrandfather\b|\bgrandpa\b"#, .grandfather),
            (#"\bgrandmother\b|\bgrandma\b"#, .grandmother),
            (#"\bparents\b"#, .parents),
            (#"\bfather\b|\bdad\b"#, .father),
            (#"\bmother\b|\bmom\b"#, .mother),
            (#"\bsiblings?\b"#, .siblings),
            (#"\bbrothers?\b"#, .brother),
            (#"\bsisters?\b"#, .sister),
            (#"\bchildren\b|\bkids\b"#, .children),
            (#"\bsons?\b"#, .son),
            (#"\bdaughters?\b"#, .daughter),
            (#"\bspouse\b|\bmarry\b|\bmarried\b|\bwed\b|\bwedded\b"#, .spouse),
            (#"\bhusband\b"#, .husband),
            (#"\bwife\b"#, .wife),
            (#"\bcousins?\b"#, .cousins),
            (#"\buncles?\b"#, .uncle),
            (#"\baunts?\b"#, .aunt),
        ]
        let hits = table.compactMap { entry -> Relation? in
            guard let range = q.range(of: entry.pattern, options: .regularExpression) else { return nil }
            if subjectWords.contains(String(q[range])) { return nil }
            return entry.relation
        }
        guard hits.count == 1 else { return nil }
        return hits[0]
    }

    /// "tell me about X" / "tell me all about X" / "who is X" — a request for
    /// the whole person, not one field. Rick, live 2026-09-07: after a long
    /// run of turns about a dead earl, even "tell me all about Edward III"
    /// came back as "has passed on and has been resting in peace since 21
    /// June 1377". The model had settled on `death` for the conversation.
    ///
    /// Only claims a sentence that asks for the person and nothing narrower —
    /// the place and relation guards run first, so "tell me about his
    /// parents" and "tell me about where he was born" never reach this.
    static func asksForABiography(_ question: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return q.range(of: #"^(hallie[, ]+)?(please\s+)?(tell\s+me\s+(all\s+)?about|tell\s+me\s+more\s+about|who\s+(is|was)|what\s+do\s+you\s+know\s+about|describe)\b"#,
                       options: .regularExpression) != nil
    }

    static func mentionsDeath(_ question: String) -> Bool {
        question.lowercased().range(of: #"\b(die|died|dies|death|buried|burial|interred)\b"#,
                                    options: .regularExpression) != nil
    }

    static func mentionsBirth(_ question: String) -> Bool {
        question.lowercased().range(of: #"\b(born|birth|birthplace)\b"#,
                                    options: .regularExpression) != nil
    }

    /// A death cue with no birth cue. Kept for the follow-up resolver; the
    /// guard above now abstains outright when both appear.
    static func asksAboutDeath(_ question: String) -> Bool {
        mentionsDeath(question) && !mentionsBirth(question)
    }

    /// A relative appears as a POSSESSED subject — "his father", "her
    /// parents", "John's mother" — which makes the sentence about someone
    /// other than the resolved person. Nested subjects are not expressible on
    /// this route (codex #1181).
    static func namesARelative(_ question: String) -> Bool {
        question.lowercased().range(
            of: #"\b(his|her|their|my|our|[a-z]+'s)\s+(father|mother|dad|mom|parents?|grandfather|grandmother|grandparents?|brother|sister|siblings?|son|daughter|children|kids|wife|husband|spouse|uncle|aunt|cousins?)\b"#,
            options: .regularExpression) != nil
    }

    /// The sentence asks WHEN or HOW OLD — a date or a derived age. A
    /// relation word inside such a sentence is a subject, never the thing
    /// being asked for.
    static func asksForADateOrAge(_ question: String) -> Bool {
        question.lowercased().range(
            of: #"\bwhen\b|\bwhat\s+(year|date|age)\b|\bhow\s+old\b|\bage\s+(at|when)\b"#,
            options: .regularExpression) != nil
    }

    /// Does this sentence ask WHERE rather than when? Narrow on purpose: it
    /// only claims a question whose subject is plainly the place, so
    /// "tell me about X" keeps the biography and only the place asks move.
    /// A death cue is required to reach `.deathPlace`; everything else that
    /// asks a place is a birth ask, which is what people actually type.
    static func asksForAPlace(_ question: String) -> Bool {
        let q = question.lowercased()
        // "where was/were/did … born", "where is … buried"
        if q.range(of: #"\bwhere\s+(was|were|is|are|did|do|does)\b"#,
                   options: .regularExpression) != nil { return true }
        // "tell me about where he was born" — "where" and its verb separated
        // by the subject. Caught by this suite's own ordering test: the
        // biography guard claimed the sentence because the pattern above
        // requires the verb to follow "where" immediately. A "where" anywhere
        // beside a birth or death word is a place question.
        if q.range(of: #"\bwhere\b"#, options: .regularExpression) != nil,
           q.range(of: #"\b(born|birth|died|die|dies|death|buried|burial)\b"#,
                   options: .regularExpression) != nil { return true }
        // "what/which country|city|town|state|county|place|part of the world"
        if q.range(of: #"\b(what|which)\s+(country|city|town|state|county|province|region|place|village|parish)\b"#,
                   options: .regularExpression) != nil { return true }
        // "born in what country", "place of birth", "birthplace"
        if q.range(of: #"\bborn\s+(in|at)\s+(what|which|where)\b"#,
                   options: .regularExpression) != nil { return true }
        if q.range(of: #"\bbirth\s*place\b|\bplace\s+of\s+(birth|death)\b"#,
                   options: .regularExpression) != nil { return true }
        return false
    }
}
