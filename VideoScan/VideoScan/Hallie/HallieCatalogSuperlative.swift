// HallieCatalogSuperlative.swift
// "play the longest video in the archive" / "what's the biggest file in
// the collection" / "show me the shortest one" (eval cs030, design §3.5
// step 5). Before this the media resolver read "archive" as content and
// handed the remainder to the translator, whose `aggregate` guess
// dead-ended. Now the sentence is a LOCAL ordered run: every matching
// record sorted by running time or size on disk (or by date for
// "the oldest video in the archive"), the asked-for one named, and the
// play verb honoured through the same `playAfterAnswer` road every
// list answer already takes — no media is opened here.
//
// Pure: words and memory in, an Intent out. Nil means "not this shape";
// a bare "and the newest?" is left to the follow-up resolver's own
// date-order lane so nothing it pinned changes.

import Foundation

enum HallieCatalogSuperlative {
    typealias Exec = HallieTurnExecutor

    /// What the sentence asked for, before it becomes an Intent.
    struct Ask: Equatable {
        let order: Exec.OrderRequest.Order
        /// 1-based: "the longest" = 1, "the second longest" = 2.
        let ordinal: Int
        let verb: ArchivistFollowUpResolver.MediaVerb?
        /// "video" / "clip" / "recording" → video; "file" / "one" → any.
        let mediaKind: ArchivistQueryAST.MediaKind?
        /// The sentence named the whole archive / catalog / collection /
        /// library, so the last list is NOT the scope.
        let scoped: Bool
    }

    // Words that may open the sentence without changing it.
    private static let lead: Set<String> = [
        "ok", "okay", "so", "and", "then", "now", "please", "hallie", "hey",
        "hi", "can", "could", "would", "you", "just", "also", "well", "um",
    ]
    private static let playVerbs: Set<String> = ["play", "watch"]
    private static let revealVerbs: Set<String> = ["reveal"]
    private static let showVerbs: Set<String> = [
        "show", "open", "display", "find", "pull", "bring", "give", "get",
        "pick", "select", "list", "view",
    ]
    /// "what is" / "which one is" / "tell me": a question, no media verb.
    private static let askWords: Set<String> = ["what", "whats", "what's", "which", "tell"]
    /// Between the verb and the superlative: "me the", "us up the", "is the very".
    private static let preFiller: Set<String> = [
        "me", "us", "up", "out", "is", "s", "the", "a", "an", "our", "my",
        "your", "one", "very", "single", "whole", "entire", "of", "all",
    ]
    private static let superlatives: [String: Exec.OrderRequest.Order] = [
        "longest": .longest, "lengthiest": .longest,
        "shortest": .shortest, "briefest": .shortest,
        "biggest": .largest, "largest": .largest, "heaviest": .largest,
        "smallest": .smallest, "tiniest": .smallest, "lightest": .smallest,
        "newest": .newest, "latest": .newest,
        "oldest": .oldest, "earliest": .oldest,
    ]
    private static let ordinals: [String: Int] = [
        "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4,
        "fifth": 5, "5th": 5, "sixth": 6, "6th": 6, "seventh": 7, "7th": 7,
        "eighth": 8, "8th": 8, "ninth": 9, "9th": 9, "tenth": 10, "10th": 10,
    ]
    /// The noun after the superlative: video-shaped → `.video`; a file or
    /// a bare "one" → any record.
    private static let videoNouns: Set<String> = [
        "video", "videos", "clip", "clips", "recording", "recordings",
        "movie", "movies", "tape", "tapes", "footage",
    ]
    private static let anyNouns: Set<String> = [
        "file", "files", "one", "ones", "item", "items", "thing", "things", "entry",
    ]
    private static let scopeLinks: Set<String> = ["in", "of", "from", "across", "within"]
    private static let scopeFiller: Set<String> = [
        "the", "our", "my", "your", "this", "whole", "entire", "family", "video", "media",
    ]
    private static let scopeNouns: Set<String> = [
        "archive", "archives", "catalog", "catalogue", "collection", "library",
    ]
    private static let trailing: Set<String> = [
        "please", "hallie", "for", "me", "us", "now", "then", "thanks", "there", "is", "have", "we", "you", "do",
    ]

    /// The ask in these words, or nil when the sentence is not this shape.
    static func detect(_ question: String) -> Ask? {
        guard question.count <= 256 else { return nil }
        var words = ArchivistFollowUpResolver.normalizedWords(question)
        guard !words.isEmpty, words.count <= 16 else { return nil }
        words = Array(words.drop { lead.contains($0) })
        var i = 0
        var verb: ArchivistFollowUpResolver.MediaVerb?
        if let first = words.first {
            if playVerbs.contains(first) { verb = .play; i = 1 }
            else if revealVerbs.contains(first) { verb = .reveal; i = 1 }
            else if showVerbs.contains(first) { verb = .show; i = 1 }
            else if askWords.contains(first) { i = 1 }
        }
        var ordinal = 1
        while i < words.count {
            if preFiller.contains(words[i]) { i += 1; continue }
            if let n = ordinals[words[i]], ordinal == 1 { ordinal = n; i += 1; continue }
            break
        }
        guard i < words.count, let order = superlatives[words[i]] else { return nil }
        i += 1
        var mediaKind: ArchivistQueryAST.MediaKind?
        var sawNoun = false
        if i < words.count {
            if videoNouns.contains(words[i]) { mediaKind = .video; sawNoun = true; i += 1 }
            else if anyNouns.contains(words[i]) { sawNoun = true; i += 1 }
        }
        var scoped = false
        if i < words.count, scopeLinks.contains(words[i]) {
            i += 1
            while i < words.count, scopeFiller.contains(words[i]) { i += 1 }
            guard i < words.count, scopeNouns.contains(words[i]) else { return nil }
            scoped = true
            i += 1
        }
        while i < words.count, trailing.contains(words[i]) { i += 1 }
        guard i == words.count else { return nil }
        // A bare "the newest?" / "and the oldest" is the follow-up
        // resolver's date-order lane, unchanged; a bare length/size
        // superlative needs a noun or a scope to be anything at all.
        guard sawNoun || scoped else { return nil }
        return Ask(order: order, ordinal: ordinal, verb: verb, mediaKind: mediaKind, scoped: scoped)
    }

    /// The ordered run for this sentence: the whole catalog when it named
    /// the archive (or nothing is remembered), else the last list / count
    /// / age the memory still carries, exactly as "and the newest?" does.
    static func detect(
        _ question: String,
        playAfterAnswer: Bool,
        memory: Exec.ConversationMemory
    ) -> Exec.Intent? {
        guard let ask = detect(question) else { return nil }
        let scope: Exec.RefinableQuery
        let ast: ArchivistQueryAST
        let subject: String
        if !ask.scoped, let last = memory.lastRefinable {
            scope = last
            switch last {
            case .list(let lastAST, _): ast = lastAST
            case .wholeCatalog: ast = .presence(.init(mediaKind: nil))
            }
            subject = "the last question"
        } else if let kind = ask.mediaKind {
            ast = .presence(.init(mediaKind: kind))
            scope = .list(ast, anyOfPeople: false)
            subject = "every \(kind.rawValue) in the catalog"
        } else {
            ast = .presence(.init(mediaKind: nil))
            scope = .wholeCatalog
            subject = "the whole catalog"
        }
        let keyName: String
        switch ask.order.key {
        case .date: keyName = "date"
        case .duration: keyName = "length"
        case .size: keyName = "size"
        }
        return Exec.Intent(
            originalQuestion: question,
            ast: ast,
            playAfterAnswer: playAfterAnswer || ask.verb == .play,
            refinementNote: "\(subject) sorted by \(keyName) (\(ask.order.word) first)",
            order: Exec.OrderRequest(order: ask.order, ordinal: ask.ordinal, scope: scope))
    }
}
