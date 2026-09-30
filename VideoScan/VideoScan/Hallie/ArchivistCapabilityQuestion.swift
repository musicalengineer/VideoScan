// ArchivistCapabilityQuestion.swift
// "can we change donna's biography?" is a question about what Hallie can DO,
// not a request for the biography. Rick's demo (2026-08-17) showed the
// translator dutifully turning it into a biography lookup. This pure
// classifier runs BEFORE translation and answers honestly with no model call:
// what is not possible yet, and what she can offer instead.

import Foundation

enum ArchivistCapabilityQuestion: Equatable {
    /// Editing / adding / correcting family knowledge (biography, fact,
    /// date, note); "can you remember / learn …".
    case editKnowledge(subject: String?)
    /// A media action outside the read-only contract (delete, export,
    /// email, upload …).
    case unsupportedMediaAction(verb: String)
    /// "can you play a video for me?" / "can you show me a video?" — asked
    /// with nothing to look for (eval ic009, 2026-09-01). The answer is
    /// yes, with one example ask; the word "me" is never a search term.
    case playback
    /// "can you help me find things in the archive, or just tell me about
    /// them?" (ic015) — what she searches by, and that she also tells.
    case searchHelp

    private static let modalLead: [String] = [
        "can we", "can you", "can i", "could we", "could you", "could i",
        "would you", "will you", "are you able to", "is it possible to",
        "is there a way to", "how do i", "how do we", "how can i",
        "how can we", "how would i", "do you know how to", "please",
        "i want to", "i'd like to", "id like to", "i would like to",
        "let's", "lets", "we should", "i need to", "we need to",
        "would it be possible to", "may i", "might we", "hallie",
    ]

    private static let editVerbs: Set<String> = [
        "change", "edit", "update", "add", "correct", "fix", "modify",
        "rewrite", "revise", "amend", "adjust", "rename", "record", "save",
        "write", "enter", "set", "put", "insert", "append", "delete", "remove",
        "erase", "retract", "annotate", "note", "log", "capture", "attach",
        "upload", "import", "teach", "tell",
    ]

    private static let learnPhrases: [String] = [
        "remember", "learn", "memorize", "memorise", "keep in mind",
        "take a note", "make a note", "take note", "note that", "note down",
        "write down", "jot down", "store", "retain",
    ]

    private static let knowledgeNouns: Set<String> = [
        "biography", "biographies", "bio", "bios", "fact", "facts", "date",
        "dates", "birthday", "birthdate", "birth", "death", "name", "names",
        "note", "notes", "story", "stories", "anecdote", "anecdotes",
        "tree", "profile", "profiles", "entry", "entries", "spelling", "info",
        "information", "details", "detail", "knowledge", "memory", "memories",
        "record", "records", "history", "relationship", "relationships",
        "alias", "aliases", "nickname", "nicknames", "brain", "cyberbrain",
        "gedcom", "genealogy", "family",
    ]

    private static let mediaVerbs: Set<String> = [
        "delete", "trash", "erase", "move", "copy", "duplicate", "export",
        "email", "mail", "send", "share", "upload", "burn", "convert",
        "transcode", "download", "print", "backup", "archive", "compress",
        "rename", "edit", "trim", "cut", "combine", "merge", "stitch",
        "publish", "post",
    ]

    private static let mediaNouns: Set<String> = [
        "video", "videos", "clip", "clips", "file", "files", "movie", "movies",
        "recording", "recordings", "footage", "it", "them", "this", "that",
        "these", "those", "one", "ones", "media", "photo", "photos", "picture",
        "pictures", "reel", "reels", "tape", "tapes",
    ]

    /// Verbs that mean the user wants to SEE something — those go to the
    /// normal pipeline no matter what other words appear.
    private static let readVerbs: Set<String> = [
        "show", "play", "find", "search", "list", "count", "who", "what",
        "when", "where", "which", "how many", "tell me about", "watch",
        "reveal", "open", "display", "get", "give",
    ]

    /// Verbs that open a capability ask about PLAYING when nothing
    /// specific follows ("can you play a video").
    private static let playbackVerbs: Set<String> = [
        "play", "show", "open", "watch", "display", "pull", "bring",
    ]

    /// Verbs that open a capability ask about FINDING ("can you help me
    /// find things", "can you search the archive").
    private static let searchVerbs: Set<String> = [
        "help", "find", "search", "look", "locate", "browse",
    ]

    /// The closed vocabulary of a content-free ask. ANY other word — a
    /// name, a year, a place, "first", "baby" — means the person asked for
    /// something specific and the normal pipeline must run.
    private static let assistanceFiller: Set<String> = [
        "a", "an", "the", "me", "us", "for", "some", "any", "one", "of", "our",
        "my", "your", "please", "up", "something", "anything", "things",
        "stuff", "in", "from", "archive", "archives", "catalog", "catalogue",
        "collection", "library", "family", "videos", "video", "clip", "clips",
        "movie", "movies", "film", "films", "file", "files", "footage",
        "recording", "recordings", "tape", "tapes", "media", "just", "or",
        "and", "also", "about", "them", "tell", "what", "do", "you", "know",
        "can", "it", "with", "here", "on", "this", "too", "at", "all", "to",
        "through", "around", "through", "there", "is", "are", "have", "we",
        "i", "want", "like", "see", "get", "able", "possible", "hallie",
    ]

    /// A content-free "can you play / show / find … ?" is a question about
    /// what Hallie can do. Nil when any word outside the closed vocabulary
    /// appears — that is a real request and goes to the pipeline.
    private static func assistanceQuestion(
        words: [String], firstWord: String
    ) -> ArchivistCapabilityQuestion? {
        let allowed = assistanceFiller.union(playbackVerbs).union(searchVerbs)
        guard words.allSatisfy({ allowed.contains($0) }) else { return nil }
        if playbackVerbs.contains(firstWord) {
            return .playback
        }
        if searchVerbs.contains(firstWord) {
            return .searchHelp
        }
        return nil
    }

    static func detect(_ text: String) -> ArchivistCapabilityQuestion? {
        var lowered = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = lowered.last, "?!.".contains(last) {
            lowered.removeLast()
        }
        lowered = lowered.trimmingCharacters(in: .whitespaces)
        guard !lowered.isEmpty else { return nil }

        var hadModal = false
        var stripped = lowered
        var changed = true
        while changed {
            changed = false
            for lead in modalLead where stripped.hasPrefix(lead + " ")
                || stripped == lead {
                stripped = String(stripped.dropFirst(lead.count))
                    .trimmingCharacters(in: .whitespaces)
                hadModal = true
                changed = true
            }
        }
        let words = stripped.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        guard let firstWord = words.first else { return nil }

        // Learning / remembering: "can you remember that…", "learn her
        // birthday", "will you remember".
        if hadModal || firstWord == "remember" || firstWord == "learn" {
            for phrase in learnPhrases where stripped.hasPrefix(phrase) {
                return .editKnowledge(subject: subject(in: stripped))
            }
        }
        // "tell me about donna" is a read; "tell hallie that…" is teaching.
        if firstWord == "tell", words.count > 1, words[1] == "me" { return nil }
        // "can you play a video for me?" / "can you help me find things in
        // the archive?" — a modal plus a content-free ask is a question
        // about her powers, answered yes with an example. "can you show me
        // donna in 1994?" has content and stays a search.
        if hadModal, let assistance = assistanceQuestion(words: words, firstWord: firstWord) {
            return assistance
        }
        if firstWord == "get" || firstWord == "give" || readVerbs.contains(firstWord) {
            return nil
        }
        // "how many" / "how old" / "how do i change" — only the last is
        // capability, and the modal strip already handled it.
        if firstWord == "how" { return nil }

        let wordSet = Set(words)
        let mentionsKnowledge = !wordSet.isDisjoint(with: knowledgeNouns)
            || stripped.contains("family tree") || stripped.contains("birth date")
        let mentionsMedia = !wordSet.isDisjoint(with: mediaNouns)

        if editVerbs.contains(firstWord), mentionsKnowledge {
            return .editKnowledge(subject: subject(in: stripped))
        }
        if firstWord == "add" || firstWord == "put" || firstWord == "record",
           hadModal || mentionsKnowledge {
            return .editKnowledge(subject: subject(in: stripped))
        }
        if mediaVerbs.contains(firstWord), mentionsMedia || hadModal {
            return .unsupportedMediaAction(verb: firstWord)
        }
        // "can you edit …" with a modal but no recognised noun still means
        // an edit request; be honest rather than searching for "edit".
        if hadModal, editVerbs.contains(firstWord), !mediaVerbs.contains(firstWord) {
            return .editKnowledge(subject: subject(in: stripped))
        }
        return nil
    }

    /// The person the request is about, when the sentence makes it plain:
    /// "donna's biography", "the biography for donna", "about donna".
    /// Nil is fine — the offer then has no name in it.
    static func subject(in text: String) -> String? {
        if let match = text.firstMatch(of: /([a-z][a-z\-]*(?: [a-z][a-z\-]*)?)'s\b/) {
            let candidate = String(match.1)
            let leading = candidate.split(separator: " ").map(String.init)
            let dropped = leading.drop { stopwordsForSubject.contains($0) }
            let name = dropped.joined(separator: " ")
            if !name.isEmpty { return capitalized(name) }
        }
        for marker in [" for ", " about ", " of ", " on "] {
            guard let range = text.range(of: marker) else { continue }
            let tail = text[range.upperBound...]
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            let name = tail.prefix(2).filter { !stopwordsForSubject.contains($0) }
            if let first = name.first, !knowledgeNouns.contains(first),
               !mediaNouns.contains(first) {
                return capitalized(name.joined(separator: " "))
            }
        }
        return nil
    }

    private static let stopwordsForSubject: Set<String> = [
        "the", "a", "an", "my", "our", "her", "his", "their", "your", "this",
        "that", "some", "any", "in", "to", "please", "we", "you", "i", "can",
        "change", "edit", "update", "add", "fix", "correct",
    ]

    private static func capitalized(_ name: String) -> String {
        name.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
