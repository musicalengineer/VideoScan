// ArchivistRecordQuestion.swift
// Model-free recogniser for a question about ONE video (2026-09-02):
// "who is in New Hampshire.mov", "does it have my name in it", "tell me
// all about this video, including the metadata … /Volumes/…/New
// Hampshire.mov", "who else is in it". Runs before translation, in the
// style of ArchivistSelectionDateQuestion, and produces a `record` AST
// the executor answers from that record's own fields — so these can
// never become the catalog-wide keyword sweeps they were on 2026-09-02
// ("29 videos: 10 where someone says 'new hampshire'…").
//
// A record reference is EITHER a media filename / path in the text
// (extracted exactly, spaces before the extension included) OR a
// selection pronoun ("this video", "it", "this one") next to a record
// verb (who is in / who else / does it have / has … in it / is <name> in
// / tell me about / examine). A pronoun with no record verb is not ours:
// "when was this filmed" stays on the selection-date lane, "how old is
// Donna here" on the temporal route, "videos of dad" goes to the
// translator. With ONLY a pronoun the date / metadata noun must sit
// beside the referent ("the date of it", "does it have a date", "about
// this one") — a noun anywhere in the sentence is not a record question
// (codex #976 item 5: "can you tell me the date on things").
//
// (For Rick: a handful of NSRegularExpression literals compiled once,
// like static `std::regex` members; `detect` is a pure function.)

import Foundation

enum ArchivistRecordQuestion {
    typealias Record = ArchivistQueryAST.Record

    /// The record question, or nil when the sentence is not about one video.
    static func detect(_ question: String) -> Record? {
        let text = question
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        // Never a media action, never an age question.
        if matches(openerGuard, lower) || matches(ageGuard, lower) { return nil }

        // 1. The reference: a named file, else a selection pronoun.
        let file = fileReference(in: text)
        var masked = lower
        if let file {
            // A plain word so `\b` still works after it (a non-word marker
            // such as "«file»" silently ends every referent pattern).
            masked = lower.replacingCharacters(in: file.range, with: fileMask)
        }
        let hasSelection = matches(selectionPronoun, masked)
        guard file != nil || hasSelection else { return nil }

        // 2. Verbs. "does it have a date" is a date ask, not a people ask
        // (the generic "does it have …" form is otherwise people).
        let people = matches(peopleVerb, masked) && !matches(hasOnlyADate, masked)
        let examine = matches(examineVerb, masked)
        let aboutStrong: Bool
        let date: Bool
        if file != nil {
            aboutStrong = matches(aboutVerb, masked) || matches(metadataAnywhere, masked)
            date = matches(dateNoun, masked) || matches(dateWhenFile, masked)
        } else {
            // With only a pronoun the noun must be NEXT to the referent:
            // "when was this filmed" belongs to the selection-date lane,
            // "can you tell me the date on things" to nobody here.
            aboutStrong = matches(aboutVerb, masked)
            date = matches(dateBesideReferent, masked)
        }

        // 3. Names.
        let names = peopleNames(in: text, masked: masked, fileRange: file?.range)
        let asksMe = matches(myName, masked)
        var peopleList = names
        if asksMe, !peopleList.contains("me") { peopleList.append("me") }
        peopleList = Array(peopleList.prefix(ArchivistQueryAST.maxListItems))

        // 4. Operations. With only a pronoun, a name list is never enough
        // on its own — "It's pouring rain here in the Berkshires today"
        // has "it" and a capitalised word, and is nobody's record
        // question (eval sm022); a record VERB must be there. A named
        // file plus names ("New Hampshire.mov: tim, nancy") still counts.
        var operations: [Record.Operation] = []
        if aboutStrong {
            operations = [.about]
        } else {
            if people || (file != nil && !peopleList.isEmpty) { operations.append(.people) }
            if date { operations.append(.date) }
            if operations.isEmpty {
                // A bare file name, or "examine it": the whole dossier.
                if file != nil || examine { operations = [.about] } else { return nil }
            }
        }

        let reference: Record.Reference = file.map { .file(name: $0.name) } ?? .currentSelection
        return Record(reference: reference, operations: operations,
                      people: peopleList.isEmpty ? nil : peopleList)
    }

    // MARK: - File reference

    struct FileReference: Equatable {
        let name: String
        /// Range in the (whitespace-collapsed) question text.
        let range: Range<String.Index>
    }

    /// A media filename or path in the text, extracted exactly. The first
    /// non-space run ending in a media extension is the core. A word
    /// before it that begins with "/" is the path's head and the name is
    /// taken verbatim from there ("/Volumes/X/QuicktimeMovies/New
    /// Hampshire.mov", "/volumes/a/new hampshire.mov"); otherwise the
    /// name is the longest run of words ending at the core that does not
    /// cross a stop word ("file", "video", "in", "who", "does" …) or a
    /// punctuation break, case-insensitive ("new hampshire.mov",
    /// "Christmas 1994 Part 2.mkv"; codex #976 item 4 — the old rule kept
    /// only capitalised words and read "new hampshire.mov" as
    /// "hampshire.mov"). Nil when no word ends in a media extension; a
    /// bare stem after "this video" ("this video New Hampshire") is taken
    /// as a file name too, resolved by stem downstream.
    static func fileReference(in text: String) -> FileReference? {
        let words = wordRanges(in: text)
        // The core is a word ending in a media extension — or a bare
        // ".mov" after a space ("Long Sequence - New Hampshire Christmas
        // .mov" is a real catalog name), which is the tail of a spaced
        // name, never a file on its own.
        guard let coreIndex = words.firstIndex(where: { range in
            let word = cleanedWord(text[range])
            return Record.endsWithMediaExtension(word)
                || (word.hasPrefix(".") && range.lowerBound != text.startIndex
                    && Record.endsWithMediaExtension("x" + word))
        }) else {
            return stemAfterMediaNoun(in: text, words: words)
        }
        let start: Int
        if cleanedWord(text[words[coreIndex]]).hasPrefix("/") {
            start = coreIndex
        } else if let head = pathHead(before: coreIndex, words: words, text: text) {
            start = head
        } else {
            start = nameStart(before: coreIndex, words: words, text: text)
        }
        var lower = words[start].lowerBound
        var upper = words[coreIndex].upperBound
        // Trim wrapping punctuation / quotes from the span.
        while lower < upper, leadingPunctuation.contains(text[lower]) { lower = text.index(after: lower) }
        while upper > lower, trailingPunctuation.contains(text[text.index(before: upper)]) {
            upper = text.index(before: upper)
        }
        let name = String(text[lower..<upper])
        guard Record.endsWithMediaExtension(name) else { return nil }
        return FileReference(name: name, range: lower..<upper)
    }

    /// The nearest word before the core that begins with "/" — the head of
    /// a path whose components may contain spaces and ordinary words
    /// ("/Volumes/A/the new hampshire.mov"). The scan crosses stop words
    /// but not a punctuation break or a sentence verb ("is", "who",
    /// "tell"), so "check /Volumes/A and tell me who is in new
    /// hampshire.mov" names "new hampshire.mov", not one long path.
    private static func pathHead(before coreIndex: Int, words: [Range<String.Index>], text: String) -> Int? {
        var index = coreIndex
        while index > 0 {
            let raw = String(text[words[index - 1]])
            let cleaned = cleanedWord(text[words[index - 1]])
            if cleaned.hasPrefix("/") { return index - 1 }
            if raw.hasSuffix(":") || raw.hasSuffix(",") || raw.hasSuffix(";") || raw.hasSuffix("?")
                || raw.hasSuffix("!") || raw.hasSuffix(".") || sentenceVerbs.contains(cleaned.lowercased()) {
                return nil
            }
            index -= 1
        }
        return nil
    }

    /// The first word of a spaced filename ending at the core: walk back
    /// while the previous word is not a stop word and no punctuation
    /// break sits between ("who is in New Hampshire.mov" → "New"; "the
    /// video hampshire.mov" → the core itself). A word that opens with a
    /// quote or bracket is the name's first word.
    private static func nameStart(before coreIndex: Int, words: [Range<String.Index>], text: String) -> Int {
        // A core that itself opens a quote is the whole name.
        if let first = text[words[coreIndex]].first, leadingPunctuation.contains(first) { return coreIndex }
        var start = coreIndex
        var index = coreIndex
        while index > 0 {
            let previousRange = words[index - 1]
            let previous = String(text[previousRange])
            let cleaned = cleanedWord(text[previousRange])
            guard !cleaned.isEmpty,
                  !filenameStopWords.contains(cleaned.lowercased()),
                  !previous.hasSuffix(":"), !previous.hasSuffix(","), !previous.hasSuffix(";"),
                  !previous.hasSuffix("?"), !previous.hasSuffix("!"), !previous.hasSuffix(".") else { break }
            start = index - 1
            index -= 1
            if let first = previous.first, leadingPunctuation.contains(first) { break }
        }
        return start
    }

    /// "this video New Hampshire and …" → "New Hampshire": capitalised
    /// words right after a media noun, stopping at the first lowercase word.
    private static func stemAfterMediaNoun(in text: String, words: [Range<String.Index>]) -> FileReference? {
        var index = 0
        while index + 2 < words.count + 1 && index + 1 < words.count {
            let first = cleanedWord(text[words[index]]).lowercased()
            let second = cleanedWord(text[words[index + 1]]).lowercased()
            if ["this", "that", "the"].contains(first), mediaNouns.contains(second) {
                var cursor = index + 2
                var taken: [Range<String.Index>] = []
                while cursor < words.count {
                    let word = cleanedWord(text[words[cursor]])
                    guard let firstChar = word.first, firstChar.isUppercase,
                          !stemStopWords.contains(word.lowercased()) else { break }
                    taken.append(words[cursor])
                    let raw = String(text[words[cursor]])
                    cursor += 1
                    if raw.hasSuffix(",") || raw.hasSuffix(":") || raw.hasSuffix("?") { break }
                }
                if let firstTaken = taken.first, let lastTaken = taken.last {
                    var upper = lastTaken.upperBound
                    while upper > firstTaken.lowerBound,
                          trailingPunctuation.contains(text[text.index(before: upper)]) {
                        upper = text.index(before: upper)
                    }
                    let range = firstTaken.lowerBound..<upper
                    return FileReference(name: String(text[range]), range: range)
                }
                return nil
            }
            index += 1
        }
        return nil
    }

    // MARK: - Names

    /// Names to give verdicts on, in order of appearance, pronouns mapped
    /// to "me", never the file's own words, never a date word.
    static func peopleNames(in text: String, masked: String, fileRange: Range<String.Index>?) -> [String] {
        var found: [String] = []
        func add(_ raw: String) {
            let entry = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:?!\"'“”‘’()"))
            guard !entry.isEmpty else { return }
            let key = entry.lowercased()
            if ArchivistRecordExecutor.isFirstPerson(key) {
                if !found.contains("me") { found.append("me") }
                return
            }
            // A name is one to three word tokens, none of them a question
            // or date word: "tim" yes, "who is" no, "the metadata whether it
            // has rick" no (the token filter is what keeps a clause out).
            let tokens = key.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
            guard !tokens.isEmpty, tokens.count <= 3,
                  !tokens.contains(where: nonNameTokens.contains),
                  !nameStopWords.contains(key), !dateWords.contains(key),
                  !found.contains(where: { $0.lowercased() == key }) else { return }
            found.append(entry)
        }
        func addList(_ list: String) {
            for part in list.components(separatedBy: ",")
                .flatMap({ $0.components(separatedBy: " and ") })
                .flatMap({ $0.components(separatedBy: " or ") })
                .flatMap({ $0.components(separatedBy: " & ") }) {
                add(part)
            }
        }
        // The masked text is lowercase; recover the original spelling by
        // offset (masking only shortens the file span, which comes AFTER
        // nothing we capture from — captures are taken from the masked
        // text and re-capitalised by the executor's display rules).
        for regex in [listAfterCue, hasNamesInIt, isNameIn, whetherNameIn] {
            let range = NSRange(masked.startIndex..., in: masked)
            for match in regex.matches(in: masked, options: [], range: range) where match.numberOfRanges > 1 {
                guard let captured = Range(match.range(at: 1), in: masked) else { continue }
                addList(String(masked[captured]))
            }
        }
        if !found.isEmpty { return capitalise(found, from: text) }
        // Fallback: capitalised words that are not the sentence opener,
        // not inside the file name, and not a known non-name.
        for range in wordRanges(in: text) {
            if range.lowerBound == text.startIndex { continue }
            if let fileRange, range.overlaps(fileRange) { continue }
            let word = cleanedWord(text[range])
            guard let first = word.first, first.isUppercase, word.count > 1,
                  !capitalisedNonNames.contains(word.lowercased()),
                  !leadWords.contains(word.lowercased()) else { continue }
            add(word)
        }
        return found
    }

    /// The captured names as the person typed them (case preserved).
    private static func capitalise(_ names: [String], from text: String) -> [String] {
        let lower = text.lowercased()
        return names.map { name in
            guard name != "me", let range = lower.range(of: name) else { return name }
            return String(text[range])
        }
    }

    // MARK: - Patterns

    /// What a named file becomes in the masked text (a word, see `detect`).
    private static let fileMask = "fileref"
    private static let referent =
        #"(?:fileref|this video|this one|this clip|this tape|this file|this recording|this movie|the selected video|the selection|this|that|it|there)"#
    private static let selectionPronoun = rx(
        #"\b(?:this video|this one|this clip|this tape|this file|this recording|this movie|the selected video|the selection|this|that|it)\b"#)
    private static let openerGuard = rx(#"^(?:hallie[, ]+)?(?:please )?(?:play|open|reveal|show me|find|list|search for) "#)
    private static let ageGuard = rx(#"\bhow old\b|\bwhat age\b|\bborn yet\b|\bwould have been\b"#)
    private static let peopleVerb = rx(
        #"\bwho(?:'s| is| are| was| were| else is| else was| all is)?(?: all| else)? (?:in|on|appears in|appear in|shows up in|is in|are in) \#(referent)\b"#
        // "who else" only as the whole question (cs003) — not as two words
        // inside a longer sentence that happens to contain "it".
        + #"|^(?:hallie[, ]+)?who else(?: is| was| is there| was there)?(?: in \#(referent))?\??$"#
        + #"|\bwhat(?:'s| is)? in \#(referent)\b"#
        + #"|\b(?:does|did|do) \#(referent) (?:have|has|contain|include|feature|show)\b"#
        + #"|\b(?:has|have|contains?|includes?|features?) .+? in (?:it|this|that|there|fileref)\b"#
        + #"|\bis .+? in \#(referent)\b"#
        // "names" / "my name" need the record nearby: a file reference in
        // front, or "in <this/it/that>" after. A bare "it" elsewhere in the
        // sentence is not a selection (live 9/02: "I know it is confusing …
        // can you read their names for me?" asked for the People tab).
        + #"|\bfileref\b.{0,80}\b(?:people'?s? )?names?\b"#
        + #"|\b(?:people'?s? )?names?\b.{0,40}\b(?:in|of|from|on) \#(referent)\b"#
        + #"|\bfileref\b.{0,80}\bmy name\b"#
        + #"|\bmy name\b.{0,24}\bin \#(referent)\b"#)
    /// The dossier asks, each with the referent beside the ask.
    private static let aboutVerb = rx(
        #"\b(?:all|everything|more|anything) about \#(referent)\b"#
        + #"|\btell me about \#(referent)\b"#
        + #"|\bdescribe \#(referent)\b"#
        + #"|\bmetadata (?:of|on|for|in|from|about|behind) \#(referent)\b"#
        + #"|\#(referent)(?:'s)? metadata\b"#
        + #"|\b(?:details|info|information) (?:on|about|for) \#(referent)\b"#
        + #"|\bwhat (?:do you know|can you tell me) about \#(referent)\b"#)
    /// With a file NAMED in the sentence, "metadata" anywhere is the
    /// dossier ("tell me all about this video, including the metadata
    /// whether it has rick in it: /Volumes/…"). Never on a bare pronoun.
    private static let metadataAnywhere = rx(#"\bmetadata\b"#)
    private static let examineVerb = rx(#"\b(?:examine|inspect|look at|analy[sz]e|check) \#(referent)\b"#)
    /// "does it have a date?" — the whole object is the date, so the
    /// generic "does it have …" people form does not apply.
    private static let hasOnlyADate = rx(
        #"\b(?:does|did|do) \#(referent) (?:have|has|contain|include|show) (?:a |the |any |no |its )?dates?\b(?: (?:on|in) \#(referent)\b)?\s*[?.!]*$"#)
    /// A date word anywhere — only with a file named in the sentence.
    private static let dateNoun = rx(#"\b(?:a |the |any |its |no )?dates?\b|\bdated\b"#)
    private static let dateWhenFile = rx(#"\bwhen\b|\bwhat year\b|\bwhich year\b|\bhow old\b"#)
    /// With only a pronoun, the date word must sit beside the referent:
    /// "the date of it", "does it have a date", "is this dated". "when
    /// was this filmed" is the selection-date lane's; "the date on
    /// things" is nobody's here.
    private static let dateBesideReferent = rx(
        #"\b(?:a |the |any |its |no )?dates?\b (?:of|on|for|in|from|behind) \#(referent)\b"#
        + #"|\#(referent) (?:has|have|had|is|was|got|carries|carry) (?:a |the |any |no |its )?dates?\b"#
        + #"|\#(referent)(?:'s)? dates?\b"#
        + #"|\bits dates?\b"#
        + #"|\b(?:is|was) \#(referent) dated\b"#
        + #"|\#(referent) (?:is |was )?dated\b"#)
    private static let myName = rx(#"\bmy (?:own )?name\b|\b(?:has|have|is|am) (?:i|me|myself) in\b"#)
    private static let listAfterCue = rx(
        #"\b(?:like|such as|named|names?:|for example|e\.g\.,?)\s+(.+?)(?:\s+and\s+(?:a |the )?dates?\b|[?.!]|$)"#)
    private static let hasNamesInIt = rx(#"\b(?:has|have|contains?|includes?|features?) (.+?) in (?:it|this|that|there|fileref)\b"#)
    private static let isNameIn = rx(#"\bis (.+?) in \#(referent)\b"#)
    private static let whetherNameIn = rx(#"\b(?:whether|if) (?:it|this|that|fileref) (?:has|have|contains?|includes?) (.+?) in\b"#)

    private static let leadWords: Set<String> = [
        "file", "video", "videos", "clip", "tape", "movie", "recording", "footage",
        "the", "of", "in", "on", "about", "examine", "called", "named", "this",
        "that", "is", "for", "and", "with", "from", "at", "to", "a", "an", "it",
        "into", "check", "search", "inspect", "open", "play", "select",
    ]
    /// Words a spaced filename never crosses when read backwards from its
    /// extension: the lead words plus question words, auxiliaries,
    /// pronouns and conjunctions ("does New Hampshire.mov have…" stops at
    /// "does"; "who is in new hampshire.mov" stops at "in").
    private static let filenameStopWords: Set<String> = leadWords.union([
        "who", "whom", "whose", "what", "when", "where", "which", "why", "how",
        "does", "do", "did", "is", "are", "was", "were", "has", "have", "had",
        "can", "could", "would", "will", "should", "shall", "may", "might", "must",
        "tell", "show", "see", "look", "find", "get", "give", "read", "describe",
        "analyze", "analyse", "watch", "reveal", "list",
        "me", "you", "i", "we", "us", "my", "your", "our", "his", "her", "their", "its",
        "please", "hallie", "or", "but", "if", "whether", "not", "no", "yes", "so",
        "then", "than", "also", "too", "again", "like", "such", "as", "e.g.", "eg",
        "by", "up", "out", "over", "there", "here", "these", "those", "some", "any",
        "all", "both", "each", "every", "either", "neither", "one", "ones",
        "files", "clips", "tapes", "movies", "recordings", "metadata", "people",
        "person", "everyone", "anybody", "anyone", "someone", "including", "whats",
        "what's", "who's", "where's", "when's", "it's", "that's", "there's",
    ])
    /// Words a path scan (looking backwards for the "/" head) will not
    /// cross: a sentence verb between the core and a "/" word means the
    /// "/" word is not this file's head.
    private static let sentenceVerbs: Set<String> = [
        "who", "whom", "what", "when", "where", "which", "why", "how",
        "is", "are", "was", "were", "does", "do", "did", "has", "have", "had",
        "can", "could", "would", "will", "should", "tell", "show", "examine",
        "check", "look", "search", "find", "play", "open", "hallie", "please",
        "whether", "if", "about",
    ]
    private static let mediaNouns: Set<String> = [
        "video", "clip", "tape", "file", "movie", "recording", "footage",
    ]
    private static let stemStopWords: Set<String> = ["and", "to", "for", "if", "whether", "hallie", "i"]
    private static let nameStopWords: Set<String> = [
        "a", "an", "the", "this", "that", "it", "there", "anyone", "anybody",
        "someone", "somebody", "people", "person", "names", "name", "peoples",
        "people's", "family", "everyone", "everybody", "who", "anything",
        "something", "fileref", "file", "video", "them", "him", "her", "us", "we",
        "you", "hallie", "kids", "the kids", "all", "of", "each", "both",
    ]
    /// A captured entry containing any of these is a clause, not a name.
    private static let nonNameTokens: Set<String> = [
        "who", "whom", "is", "are", "was", "were", "what", "which", "in", "on",
        "it", "this", "that", "the", "a", "an", "and", "or", "date", "dates",
        "name", "names", "people", "anyone", "someone", "has", "have", "had",
        "see", "if", "whether", "there", "any", "all", "else", "of", "to",
        "for", "with", "about", "metadata", "fileref", "video", "file", "text",
        "search", "examine", "including", "tell", "me", "my", "your", "its",
        "when", "where", "how", "does", "do", "did", "not", "no", "yes",
    ]
    private static let dateWords: Set<String> = [
        "date", "dates", "a date", "the date", "any date", "its date", "when", "year",
        "the year", "a year", "time", "the time", "dated",
    ]
    private static let capitalisedNonNames: Set<String> = [
        "i", "hallie", "catalog", "finder", "volumes", "mov", "mp4", "mkv",
        "new", "hampshire", "christmas", "thanksgiving", "easter", "cape", "cod",
        "quicktime", "avid", "mxf", "ok", "okay",
    ]
    private static let leadingPunctuation: Set<Character> = ["(", "[", "\"", "'", "“", "‘", "<", "«"]
    private static let trailingPunctuation: Set<Character> = [")", "]", "\"", "'", "”", "’", ">", "»", ",", ";", ":", "?", "!", "."]

    // MARK: - Helpers

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // Force-unwrap is deliberate: compile-time literals; a bad one
        // should fail the first test, not hide.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whitespace-separated word spans of `text`.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    /// A word without wrapping punctuation ("(New" → "New", "Hampshire.mov?" → "Hampshire.mov").
    private static func cleanedWord(_ word: Substring) -> String {
        var value = Substring(word)
        while let first = value.first, leadingPunctuation.contains(first) { value = value.dropFirst() }
        while let last = value.last, trailingPunctuation.contains(last) { value = value.dropLast() }
        return String(value)
    }
}
