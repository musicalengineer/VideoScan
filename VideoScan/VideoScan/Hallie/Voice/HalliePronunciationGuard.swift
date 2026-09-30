// HalliePronunciationGuard.swift
// What a LEARNED pronunciation may be (2026-09-21, GH #187).
//
// Two live defects came from poisoned learned overrides, not from code:
//   1. "Edward" → respelling "III". The regnal expander had already turned
//      "Edward III" into "Edward the Third", then the table replaced the
//      NAME: Hallie said "III the Third".
//   2. "see" → "KY | OK" /kˈI/, learned 2026-09-11 from Rick's sentence
//      "when you see KY … pronounce it Kentucky". For ten days Hallie said
//      "It's good to KYE you". Commit 440cf156 stopped a teach from
//      resolving a common word, but the entry already on disk stayed live.
//
// The general defence, one rule applied twice:
//   * WRITE time — a teach for an everyday English word is refused with an
//     honest sentence unless the word is also a known People/tree/CyberBrain
//     name ("Young", "Will"); a bare Roman numeral or an empty spoken form
//     is refused always.
//   * LOAD/APPLY time — the same test runs on every learned entry (person
//     records and pronunciations.json; the shipped table is audited and
//     exempt). A failing entry is IGNORED when speaking, never deleted — the
//     file is Rick's — with one log line per entry per launch.
//
// Pure text work plus two small caches. Think of it as a header of static
// predicates (≈ C++ `constexpr` tables) and two mutex-guarded memo objects.

import Foundation
import VideoScanCore

enum HalliePronunciationGuard {

    // MARK: - The closed list

    /// Everyday English: function words, pronouns, auxiliaries, and roughly
    /// the 300 most frequent content words, plus the words Hallie herself
    /// says every day ("record", "archive", "tree"). A pronunciation is kept
    /// for NAMES; a word-level override of any of these would respell it in
    /// every sentence Hallie speaks. Lowercase, compared after
    /// FamilyIdentityText.normalized. Deliberately does NOT contain the
    /// shipped family surnames (Lamb, Breen) — and a surname that IS on
    /// this list ("Young", "Will") still works when the tree carries it.
    static let commonWords: Set<String> = [
        // articles, determiners, conjunctions
        "a", "an", "the", "and", "or", "but", "nor", "so", "yet", "if", "because", "though", "although",
        "while", "until", "unless", "whether", "than", "then", "that", "this", "these", "those", "each",
        "every", "either", "neither", "both", "all", "any", "some", "no", "not", "none", "such", "other",
        "another", "same", "own", "few", "many", "much", "more", "most", "less", "least", "enough",
        // prepositions
        "of", "in", "on", "at", "to", "for", "by", "with", "from", "into", "onto", "upon", "over", "under",
        "about", "above", "below", "after", "before", "around", "between", "against", "during", "without",
        "within", "along", "across", "behind", "beyond", "near", "through", "toward", "towards", "among",
        "since", "off", "out", "up", "down", "as", "like", "via", "per",
        // pronouns
        "i", "me", "my", "mine", "myself", "we", "us", "our", "ours", "ourselves", "you", "your", "yours",
        "yourself", "he", "him", "his", "himself", "she", "her", "hers", "herself", "it", "its", "itself",
        "they", "them", "their", "theirs", "themselves", "who", "whom", "whose", "which", "what", "whatever",
        "someone", "something", "anyone", "anything", "everyone", "everything", "nobody", "nothing",
        "somebody", "one", "ones",
        // auxiliaries and modals
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does", "did", "done", "doing",
        "has", "have", "had", "having", "can", "could", "may", "might", "shall", "should", "will", "would",
        "must", "ought",
        // adverbs and question words
        "here", "there", "where", "when", "why", "how", "now", "just", "only", "also", "very", "too",
        "again", "still", "never", "always", "ever", "often", "sometimes", "usually", "already", "almost",
        "quite", "really", "rather", "even", "well", "back", "away", "once", "twice", "today", "tomorrow",
        "yesterday", "maybe", "perhaps", "together", "else", "soon", "later", "yes", "ok", "okay", "oh",
        "please", "thanks", "thank", "hello", "hi", "bye", "goodbye",
        // the most frequent verbs (and forms Hallie actually says)
        "say", "says", "said", "get", "gets", "got", "go", "goes", "went", "gone", "make", "makes", "made",
        "know", "knows", "knew", "known", "take", "takes", "took", "taken", "see", "sees", "saw", "seen",
        "come", "comes", "came", "think", "thinks", "thought", "look", "looks", "looked", "want", "wants",
        "give", "gives", "gave", "given", "use", "used", "find", "finds", "found", "tell", "tells", "told",
        "ask", "asked", "work", "worked", "seem", "feel", "felt", "try", "tried", "leave", "left", "call",
        "called", "need", "needs", "keep", "kept", "let", "put", "mean", "means", "meant", "become",
        "became", "show", "shows", "showed", "hear", "heard", "play", "played", "run", "move", "moved",
        "live", "lives", "lived", "living", "believe", "bring", "brought", "happen", "happened", "write",
        "wrote", "written", "sit", "stand", "lose", "lost", "pay", "paid", "meet", "met", "include",
        "continue", "set", "learn", "learned", "change", "changed", "lead", "understand", "watch", "follow",
        "stop", "open", "walk", "win", "remember", "love", "loved", "read", "record", "recorded", "records",
        "born", "died", "married", "start", "started", "turn", "help", "talk", "speak", "spoke", "begin",
        "began", "hold", "held", "wait", "stay", "stayed", "send", "sent", "build", "built", "die",
        // the most frequent nouns and adjectives
        "time", "times", "year", "years", "people", "way", "day", "days", "man", "men", "woman", "women",
        "child", "children", "life", "world", "thing", "things", "part", "place", "case", "week", "month",
        "home", "house", "room", "family", "name", "names", "word", "words", "story", "point", "fact",
        "number", "group", "problem", "hand", "head", "eye", "eyes", "face", "side", "end", "kind", "lot",
        "night", "school", "state", "water", "book", "job", "money", "photo", "photos", "picture", "video",
        "videos", "tape", "file", "files", "archive", "tree", "line", "question", "answer", "mother",
        "father", "son", "daughter", "wife", "husband", "brother", "sister", "parent", "parents",
        "good", "new", "first", "last", "long", "great", "little", "old", "big", "small", "large", "high",
        "different", "important", "right", "next", "early", "late", "young", "sure", "able", "best",
        "better", "bad", "true", "real", "whole", "full", "half", "free", "nice", "fine", "happy", "easy",
        "hard", "clear", "possible", "second", "third", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "hundred", "thousand",
    ]

    /// `word` is on the closed list (case- and diacritic-insensitive).
    static func isCommonWord(_ word: String) -> Bool {
        commonWords.contains(FamilyIdentityText.normalized(word))
    }

    // MARK: - Verdicts

    /// Why an override is refused (write time) or ignored (apply time).
    enum Refusal: LocalizedError, Equatable, Sendable {
        /// The written word is everyday English and nobody the archive
        /// knows carries it as a name.
        case commonWord(String)
        /// The spoken form is a bare Roman numeral ("III") — a suffix the
        /// regnal expander already handles, never a way of saying a name.
        case numeral(word: String, spoken: String)
        /// Nothing to say.
        case empty(String)

        /// Hallie's honest sentence to the person teaching.
        var reply: String {
            switch self {
            case .commonWord(let word):
                return "I keep pronunciations for names; \u{201C}\(word)\u{201D} is an everyday word, so I left it alone."
            case .numeral(let word, let spoken):
                return "I haven't changed how I say \(word) \u{2014} \u{201C}\(spoken)\u{201D} is a Roman numeral, not a way of saying a name. Tell me in words, like \u{201C}the third\u{201D}."
            case .empty(let word):
                return "I didn't hear a way to say \(word), so I left it alone."
            }
        }

        var errorDescription: String? { reply }

        /// For basis lines: why, in a few words.
        var shortReason: String {
            switch self {
            case .commonWord(let word): return "\u{201C}\(word)\u{201D} is an everyday word, not a name"
            case .numeral(_, let spoken): return "\u{201C}\(spoken)\u{201D} is a Roman numeral"
            case .empty: return "empty spoken form"
            }
        }

        /// The `[hallie-voice]` line for an entry ignored at apply time.
        var ignoredLogLine: String {
            switch self {
            case .commonWord(let word):
                return "[hallie-voice] ignored learned pronunciation for common word \u{201C}\(word)\u{201D}"
            case .numeral(let word, let spoken):
                return "[hallie-voice] ignored learned pronunciation for \u{201C}\(word)\u{201D}: spoken form \u{201C}\(spoken)\u{201D} is a Roman numeral"
            case .empty(let word):
                return "[hallie-voice] ignored learned pronunciation for \u{201C}\(word)\u{201D}: empty spoken form"
            }
        }
    }

    /// The one test, shared by write and apply. `spoken` is the stored
    /// respelling (alternatives " | "-joined; the FIRST is what is said).
    /// `isKnownName` is consulted only for a word on the closed list, so a
    /// caller can make it lazy and expensive.
    static func refusal(
        written: String, spoken: String, phonemes: String?,
        isKnownName: (String) -> Bool
    ) -> Refusal? {
        let word = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = HalliePronunciationLexicon.alternatives(spoken).first ?? ""
        let hasPhonemes = !(phonemes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        // A numeral is refused even beside phonemes: those were derived
        // FROM the numeral and would reach Kokoro as garbage.
        if HalliePronunciationLexicon.isRegnalNumeralRespelling(first) {
            return .numeral(word: word, spoken: first)
        }
        if first.isEmpty && !hasPhonemes { return .empty(word) }
        if isCommonWord(word), !isKnownName(word) { return .commonWord(word) }
        return nil
    }

    // MARK: - Once-per-launch log

    /// Remembers which ignored entries were already logged in this process
    /// (≈ a mutex-guarded `std::set<std::string>`). Production uses
    /// `.shared`; tests make their own so the "once" is per test.
    final class OnceLog: @unchecked Sendable {
        static let shared = OnceLog()
        private let lock = NSLock()
        private var logged: Set<String> = []

        /// Write `refusal.ignoredLogLine` the first time this entry is seen.
        func note(_ refusal: Refusal, entry: HalliePronunciationLexicon.Entry, log: LogSink?) {
            let key = "\(refusal.ignoredLogLine)|\(entry.spoken)|\(entry.phonemes ?? "")"
            let first = lock.withLock { logged.insert(key).inserted }
            if first { log?.write(refusal.ignoredLogLine) }
        }
    }
}

// MARK: - Known names

/// Every single word that names somebody the archive knows — People-tab
/// profiles, tree people, CyberBrain people — plus the shipped lexicon's
/// audited family words. Built ONLY from those sources, never from the
/// learned lexicon itself, so a poisoned entry cannot vouch for itself (the
/// old `knownSpelling` looked in the lexicon first, which is how "see" kept
/// counting as a name).
struct HallieKnownNames: Sendable, Equatable {
    private(set) var keys: Set<String>

    init(keys: Set<String> = []) { self.keys = keys }

    /// Forename-shaped words that FamilyNameTokens treats as function words:
    /// a capitalised "Will" or "May" in a PRIMARY name is that person's name.
    private static let capitalisedPrimaryNames: Set<String> = ["will", "may"]

    /// The name words of one person, by FamilyNameTokens' rule (whole alias,
    /// name-shaped primary word, name-shaped word of a non-notes alias) —
    /// so "see" inside "Llanlowell Llan Hywel and see note" never counts.
    static func nameKeys(primary: String, aliases: [String]) -> [String] {
        var out: [String] = []
        let primaryWords = FamilyNameTokens.words(primary)
        if primaryWords.count == 1 { out.append(FamilyIdentityText.normalized(primaryWords[0])) }
        out += FamilyNameTokens.nameWords(ofPrimaryName: primary).map(FamilyIdentityText.normalized)
        out += primaryWords.filter {
            $0.first?.isUppercase == true && capitalisedPrimaryNames.contains(FamilyIdentityText.normalized($0))
        }.map(FamilyIdentityText.normalized)
        for alias in aliases {
            let aliasWords = FamilyNameTokens.words(alias)
            if aliasWords.count == 1 { out.append(FamilyIdentityText.normalized(aliasWords[0])) }
            out += FamilyNameTokens.nameWords(ofAlias: alias, primaryName: primary).map(FamilyIdentityText.normalized)
        }
        return out.filter { !$0.isEmpty }
    }

    /// Accumulate one person's names.
    mutating func add(primary: String, aliases: [String]) {
        keys.formUnion(Self.nameKeys(primary: primary, aliases: aliases))
    }

    mutating func formUnion(_ other: HallieKnownNames) { keys.formUnion(other.keys) }

    func contains(_ word: String) -> Bool { keys.contains(FamilyIdentityText.normalized(word)) }

    /// The shipped table's written words (Lamb, Breen, McGill …): audited.
    static let shipped = HallieKnownNames(
        keys: Set(HalliePronunciationLexicon.shipped.entries.map { FamilyIdentityText.normalized($0.written) }))

    /// Build from whatever sources the caller already holds.
    static func from(
        profiles: [(primary: String, aliases: [String])] = [],
        graph: GedcomFamilyGraph? = nil,
        cyberBrainPeople: [CyberBrainPerson] = []
    ) -> HallieKnownNames {
        var names = HallieKnownNames.shipped
        for profile in profiles { names.add(primary: profile.primary, aliases: profile.aliases) }
        if let graph {
            for person in graph.people.values {
                names.add(primary: person.name, aliases: person.alternateNames)
            }
        }
        for person in cyberBrainPeople { names.add(primary: person.canonicalName, aliases: person.aliases) }
        return names
    }
}

/// Apply-time source of known names for the voice: CyberBrain people (via
/// PersonPronunciationCache, mtime-keyed) plus the family tree ONLY when it
/// is already decoded in this process (FamilyGraphSharedCache.cachedGraph —
/// never a load, never a wait on the loader's lock, so speaking can't
/// beachball). Built lazily, and only when a learned entry is actually on
/// the closed list; memoised per tree token.
final class HallieKnownNamesLive: @unchecked Sendable {
    static let shared = HallieKnownNamesLive()

    private let lock = NSLock()
    private var treeToken: UUID?
    private var treeNames = HallieKnownNames()

    func current(cyberBrainRootURL: URL?, log: LogSink?) -> HallieKnownNames {
        var names = HallieKnownNames.shipped
        if let root = cyberBrainRootURL {
            names.formUnion(PersonPronunciationCache.shared.knownNames(rootURL: root, log: log))
        }
        if let cached = FamilyGraphSharedCache.shared.cachedGraph() {
            let tree: HallieKnownNames = lock.withLock {
                if treeToken != cached.token {
                    treeNames = HallieKnownNames.from(graph: cached.graph)
                    treeToken = cached.token
                }
                return treeNames
            }
            names.formUnion(tree)
        }
        return names
    }
}
