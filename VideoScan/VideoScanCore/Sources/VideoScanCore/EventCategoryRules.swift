// EventCategoryRules.swift
// Events v1 — stage C: WHICH KIND of event a recording's own words suggest
// (docs/design/events_design.md §3.C; docs/design/events_v1_plan_2026_10_14.md §2).
//
// A pure rule table. Each of the nine categories is a `static let`
// instance of `EventCategory` carrying the phrases that count as SEEN (a
// scene caption), SAID (the transcript), the negative cues that cancel a
// hit found near them ("Happy Birthday" from a television; "last
// Christmas" is a mention, not a Christmas), and the EventLabeler event
// ids that count as "name only" (a word in a file or folder name) or
// "date only" (a calendar day, a family birthday).
//
// Design principle 9: strength is a WORD from evaluated evidence rules —
// "seen and said", "seen", "said", "name only", "date only" — never a
// number and never a model's self-assessment. A bare mention of a holiday
// in speech ("we'll see you at Christmas") is not evidence of the holiday:
// the SAID phrases are occasion phrases, not the holiday's name alone.
//
// Pure and `Sendable`: the planner runs it off the main actor over every
// witness in the catalog. Cost: each caption and the transcript are
// lowercased ONCE per recording, then every category's phrase list is
// searched in that text; the 100k-row scale test pins the budget.
//
// (For Rick: the categories are `static let` instances of one struct —
// C++ `static const EventCategory kBirthday{…}` — and `all` is the table
// the rules walk. There is no switch to grow when a category is added.)

import Foundation

// MARK: - Evidence (what the rules return)

/// Where one line of evidence came from. Kept with the line (design
/// principle 4: evidence keeps its source).
public enum EventEvidenceSource: String, Sendable, Codable, CaseIterable {
    case caption, transcript, fileName, folderName, calendar, birthday

    /// "caption", "transcript", "file name", "folder name", "calendar", "birthday".
    public var words: String {
        switch self {
        case .caption: return "caption"
        case .transcript: return "transcript"
        case .fileName: return "file name"
        case .folderName: return "folder name"
        case .calendar: return "calendar"
        case .birthday: return "birthday"
        }
    }
}

/// One line the page can show: the words, their source, and the moment in
/// the clip when a caption said it (transcripts are untimed in v1).
public struct EventEvidenceLine: Sendable, Hashable, Codable {
    public let source: EventEvidenceSource
    public let words: String
    /// Seconds into the clip; captions only.
    public let timestamp: Double?

    public init(source: EventEvidenceSource, words: String, timestamp: Double? = nil) {
        self.source = source
        self.words = words
        self.timestamp = timestamp
    }
}

/// How strongly one recording's own words support a category. Ordered
/// weakest → strongest so `max()` picks the best member of a group.
public enum EventEvidenceStrength: Int, Sendable, Comparable, CaseIterable, Codable {
    case dateOnly = 0, nameOnly, said, seen, seenAndSaid

    public static func < (a: EventEvidenceStrength, b: EventEvidenceStrength) -> Bool { a.rawValue < b.rawValue }

    /// The word the page shows.
    public var words: String {
        switch self {
        case .seenAndSaid: return "seen and said"
        case .seen: return "seen"
        case .said: return "said"
        case .nameOnly: return "name only"
        case .dateOnly: return "date only"
        }
    }

    /// The rule, as data: what the recording had → its strength. Pure.
    static func of(seen: Bool, said: Bool, name: Bool, date: Bool) -> EventEvidenceStrength? {
        if seen && said { return .seenAndSaid }
        if seen { return .seen }
        if said { return .said }
        if name { return .nameOnly }
        if date { return .dateOnly }
        return nil
    }
}

/// One category's evidence for one recording.
public struct EventCategoryEvidence: Sendable, Equatable {
    /// `EventCategory.name`.
    public let category: String
    public let strength: EventEvidenceStrength
    /// Seen, said, then name and date lines — in that order.
    public let lines: [EventEvidenceLine]

    public init(category: String, strength: EventEvidenceStrength, lines: [EventEvidenceLine]) {
        self.category = category
        self.strength = strength
        self.lines = lines
    }
}

// MARK: - The categories (data)

/// One category's rules. Phrases are lowercase and matched on word
/// boundaries; a hit is cancelled when a negative cue sits within
/// `EventCategoryRules.negativeCueWindow` characters of it.
public struct EventCategory: Sendable, Hashable {
    public let name: String
    /// Phrases in a scene caption that mean the camera SAW the occasion.
    public let seen: [String]
    /// Occasion phrases in the transcript — a greeting, a ritual — never
    /// the holiday's bare name (that is a mention).
    public let said: [String]
    /// Cues near a seen hit that cancel it (a screen, a poster).
    public let seenNot: [String]
    /// Cues near a said hit that cancel it (a television; "last Christmas").
    public let saidNot: [String]
    /// EventLabeler event ids whose NAME labels count as "name only".
    public let nameEvents: Set<String>
    /// EventLabeler event ids whose CALENDAR labels count as "date only".
    public let calendarEvents: Set<String>
    /// Whether a family-birthday label counts as "date only".
    public let takesBirthdayLabels: Bool

    private init(_ name: String, seen: [String], said: [String], seenNot: [String] = EventCategory.screenCues,
                 saidNot: [String], nameEvents: Set<String>, calendarEvents: Set<String> = [],
                 takesBirthdayLabels: Bool = false) {
        self.name = name
        self.seen = seen
        self.said = said
        self.seenNot = seenNot
        self.saidNot = saidNot
        self.nameEvents = nameEvents
        self.calendarEvents = calendarEvents
        self.takesBirthdayLabels = takesBirthdayLabels
    }

    /// A caption describing a screen, a poster or a photograph is not the
    /// occasion itself.
    static let screenCues = ["television", "tv screen", "on a screen", "on the screen", "on a tv", "poster",
                             "painting", "photograph", "framed photo", "a picture of", "computer screen"]
    /// Speech from a set, or about another time's occasion — a mention.
    static let broadcastCues = ["on tv", "on the tv", "television", "on the radio", "commercial", "the movie",
                                "in the movie", "on screen", "remember", "years ago", "back when", "next week",
                                "next month", "next year", "last year"]

    public static let birthday = EventCategory(
        "Birthday",
        seen: ["birthday", "cake with candles", "cake with lit candles", "blowing out the candles", "blowing out candles",
               "candles on a cake", "candles on the cake", "lit candles", "party hats", "birthday cake"],
        said: ["happy birthday", "blow out the candles", "blow out your candles", "make a wish", "birthday cake",
               "birthday boy", "birthday girl", "how old are you today"],
        saidNot: broadcastCues + ["last birthday", "next birthday", "birthday is coming", "birthday's coming",
                                  "birthday next", "birthday last"],
        nameEvents: ["birthday"],
        takesBirthdayLabels: true)

    public static let christmas = EventCategory(
        "Christmas",
        seen: ["christmas", "santa", "wrapped gifts", "wrapped presents", "ornaments", "ornament", "stockings",
               "nativity", "tinsel", "garland", "under the tree"],
        said: ["merry christmas", "christmas morning", "christmas eve", "christmas tree", "christmas dinner",
               "open your presents", "open the presents", "opening presents", "santa came", "santa brought",
               "under the tree", "stocking"],
        saidNot: broadcastCues + ["last christmas", "next christmas", "before christmas", "after christmas",
                                  "until christmas", "till christmas", "by christmas", "christmas list"],
        nameEvents: ["christmas"],
        calendarEvents: ["christmas"])

    public static let thanksgiving = EventCategory(
        "Thanksgiving",
        seen: ["thanksgiving", "roast turkey", "roasted turkey", "turkey dinner", "carving a turkey", "carving the turkey",
               "whole turkey"],
        said: ["happy thanksgiving", "thanksgiving dinner", "thanksgiving day", "carve the turkey", "pass the stuffing",
               "what are you thankful for", "thankful for"],
        saidNot: broadcastCues + ["last thanksgiving", "next thanksgiving", "before thanksgiving", "after thanksgiving"],
        nameEvents: ["thanksgiving"],
        calendarEvents: ["thanksgiving"])

    public static let easter = EventCategory(
        "Easter",
        seen: ["easter", "egg hunt", "easter eggs", "easter basket", "easter bunny", "dyeing eggs", "coloring eggs"],
        said: ["happy easter", "egg hunt", "easter basket", "easter bunny", "easter egg", "find the eggs"],
        saidNot: broadcastCues + ["last easter", "next easter", "before easter", "after easter"],
        nameEvents: ["easter"],
        calendarEvents: ["easter"])

    public static let halloween = EventCategory(
        "Halloween",
        seen: ["halloween", "trick or treat", "trick-or-treat", "jack-o", "jack o'lantern", "carved pumpkin",
               "carving a pumpkin", "carving pumpkins", "halloween costume", "halloween costumes"],
        said: ["happy halloween", "trick or treat", "trick-or-treat", "halloween costume", "carve the pumpkin"],
        saidNot: broadcastCues + ["last halloween", "next halloween", "before halloween", "after halloween"],
        nameEvents: ["halloween"],
        calendarEvents: ["halloween"])

    public static let wedding = EventCategory(
        "Wedding",
        seen: ["wedding", "bride", "groom", "wedding dress", "bridal", "wedding cake", "bouquet"],
        said: ["the bride", "the groom", "you may kiss", "best man", "maid of honor", "maid of honour", "newlyweds",
               "i now pronounce", "the wedding day", "getting married", "just got married", "here comes the bride",
               "the happy couple", "the wedding party"],
        saidNot: broadcastCues + ["last wedding", "next wedding", "before the wedding", "after the wedding"],
        nameEvents: ["wedding"])

    public static let beachVacation = EventCategory(
        "Beach / vacation",
        seen: ["beach", "seashore", "ocean waves", "sandcastle", "sand castle", "surfboard", "boardwalk", "snorkel",
               "beach umbrella", "beach towel", "sand dunes"],
        said: ["on vacation", "on our vacation", "the beach", "at the beach", "road trip", "the ocean", "low tide",
               "high tide", "in the sand", "look at the waves"],
        saidNot: broadcastCues + ["last vacation", "next vacation", "last summer at the beach"],
        nameEvents: ["vacation", "beach", "lake", "cape", "disney", "camp"])

    public static let musicPerformance = EventCategory(
        "Music / performance",
        seen: EventCategory.instruments.flatMap { ["playing the \($0)", "playing a \($0)", "playing \($0)"] }
            + ["on stage", "concert", "recital", "band performing", "performing on", "singing into a microphone",
               "singing into the microphone", "at the piano", "at a piano", "behind a drum kit", "drum kit"],
        said: ["the recital", "at the recital", "the concert", "at the concert", "take it from the top", "sound check",
               "encore", "jam session", "from the top", "one more time", "let's play that again", "the next song",
               "this next one", "give it up for"],
        saidNot: broadcastCues + ["last recital", "next recital", "last concert", "next concert"],
        nameEvents: ["recital"])

    public static let graduation = EventCategory(
        "Graduation",
        seen: ["graduation", "cap and gown", "caps and gowns", "diploma", "mortarboard", "graduates", "graduate"],
        said: ["graduation ceremony", "graduation day", "got my diploma", "got her diploma", "got his diploma",
               "your diploma", "commencement", "class of", "congratulations graduate", "congratulations graduates",
               "you graduated", "throw your caps", "pomp and circumstance"],
        saidNot: broadcastCues + ["last graduation", "next graduation", "before graduation", "after graduation"],
        nameEvents: ["graduation"])

    static let instruments = ["guitar", "piano", "keyboard", "drums", "violin", "bass", "saxophone", "trumpet", "flute",
                              "cello", "clarinet", "accordion", "banjo", "ukulele", "synthesizer", "organ"]

    /// The nine, in the order the page lists them.
    public static let all: [EventCategory] = [
        birthday, christmas, thanksgiving, easter, halloween, wedding, beachVacation, musicPerformance, graduation,
    ]

    public static func named(_ name: String) -> EventCategory? { all.first { $0.name == name } }

    /// Two categories can be one occasion when they are the same, when
    /// either is a vacation (a vacation may contain a birthday, design
    /// §3.D), or when one is a performance at a celebration. Everything
    /// else — two holidays, a holiday and a birthday — stays apart in v1
    /// (conservative; "mixed" waits for Rick's word).
    public static func compatible(_ a: String, _ b: String) -> Bool {
        if a == b || a == beachVacation.name || b == beachVacation.name { return true }
        return performancePartners.contains(a == musicPerformance.name ? b : (b == musicPerformance.name ? a : ""))
    }

    static let performancePartners: Set<String> = [birthday.name, christmas.name, wedding.name, graduation.name]
}

// MARK: - The rules (pure)

public enum EventCategoryRules {

    /// Characters either side of a hit searched for a negative cue.
    public static let negativeCueWindow = 48

    /// Every category one recording's words support, with its lines. Pure;
    /// nothing allocated for a recording with no hits beyond the lowercased
    /// texts. `labels` are the EventLabeler's (calendar, birthday, name).
    public static func evidence(captions: [SceneCaption], transcript: String?, labels: [EventLabel])
    -> [EventCategoryEvidence] {
        let lowered = captions.map { ($0, $0.text.lowercased()) }
        let original = transcript ?? ""
        let speech = original.lowercased()
        var out: [EventCategoryEvidence] = []
        for category in EventCategory.all {
            let seen = seenLine(category, in: lowered)
            let said = speech.isEmpty ? nil : saidLine(category, original: original, lower: speech)
            let names = nameLines(category, labels: labels)
            let dates = dateLines(category, labels: labels)
            guard let strength = EventEvidenceStrength.of(seen: seen != nil, said: said != nil,
                                                          name: !names.isEmpty, date: !dates.isEmpty) else { continue }
            out.append(EventCategoryEvidence(category: category.name, strength: strength,
                                             lines: [seen, said].compactMap { $0 } + names + dates))
        }
        return out
    }

    /// The first caption with a seen phrase not cancelled by a cue.
    static func seenLine(_ category: EventCategory, in captions: [(SceneCaption, String)]) -> EventEvidenceLine? {
        for (caption, lower) in captions {
            guard let hit = PhraseMatch.firstHit(of: category.seen, in: lower, unless: category.seenNot,
                                                 window: negativeCueWindow) else { continue }
            return EventEvidenceLine(source: .caption, words: PhraseMatch.snippet(caption.text, lower: lower, around: hit),
                                     timestamp: caption.timestamp)
        }
        return nil
    }

    /// The first said phrase not cancelled by a cue, with its surroundings
    /// (from the original transcript, so the card shows Rick's own words
    /// as they were spoken, not a lowercased copy).
    static func saidLine(_ category: EventCategory, original: String, lower: String) -> EventEvidenceLine? {
        guard let hit = PhraseMatch.firstHit(of: category.said, in: lower, unless: category.saidNot,
                                             window: negativeCueWindow) else { return nil }
        return EventEvidenceLine(source: .transcript, words: PhraseMatch.snippet(original, lower: lower, around: hit))
    }

    /// Name labels (file first, then folder) for this category.
    static func nameLines(_ category: EventCategory, labels: [EventLabel]) -> [EventEvidenceLine] {
        labels.compactMap { label in
            guard label.source == .name, category.nameEvents.contains(label.event),
                  case .word(let place, _) = label.why else { return nil }
            return EventEvidenceLine(source: place == "file" ? .fileName : .folderName, words: label.reason)
        }
    }

    /// Calendar and family-birthday labels for this category.
    static func dateLines(_ category: EventCategory, labels: [EventLabel]) -> [EventEvidenceLine] {
        labels.compactMap { label in
            switch label.source {
            case .calendar where category.calendarEvents.contains(label.event):
                return EventEvidenceLine(source: .calendar, words: label.reason)
            case .birthday where category.takesBirthdayLabels:
                return EventEvidenceLine(source: .birthday, words: label.reason)
            default:
                return nil
            }
        }
    }
}

// MARK: - Phrase matching (pure)

/// Word-bounded phrase search over an already-lowercased text. (For Rick:
/// a hand-rolled `strstr` with boundary checks — no regex engine, because
/// this runs over every caption of every recording in the catalog.)
enum PhraseMatch {

    /// The first phrase found with no cue within `window` characters of it.
    /// A cancelled hit keeps looking later in the text (up to a few hits).
    static func firstHit(of phrases: [String], in text: String, unless cues: [String], window: Int) -> Range<String.Index>? {
        for phrase in phrases {
            var from = text.startIndex
            var tries = 0
            while tries < 8, let r = range(of: phrase, in: text, from: from) {
                if !hasCue(cues, in: text, near: r, window: window) { return r }
                from = r.upperBound
                tries += 1
            }
        }
        return nil
    }

    /// `phrase` in `text` at or after `from`, bounded by non-letters.
    static func range(of phrase: String, in text: String, from: String.Index) -> Range<String.Index>? {
        var start = from
        while start < text.endIndex, let r = text.range(of: phrase, range: start..<text.endIndex) {
            if isBoundary(text, before: r.lowerBound) && isBoundary(text, after: r.upperBound) { return r }
            start = text.index(after: r.lowerBound)
        }
        return nil
    }

    static func hasCue(_ cues: [String], in text: String, near r: Range<String.Index>, window: Int) -> Bool {
        guard !cues.isEmpty else { return false }
        let lo = text.index(r.lowerBound, offsetBy: -window, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex
        let near = text[lo..<hi]
        return cues.contains { near.contains($0) }
    }

    /// Up to `pad` characters either side of the hit, newlines flattened,
    /// taken from the ORIGINAL text (same indices: lowercasing keeps the
    /// character count for the Latin text these rules read).
    static func snippet(_ original: String, lower: String, around r: Range<String.Index>, pad: Int = 60) -> String {
        let text = original.count == lower.count ? original : lower
        let lo = text.index(r.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        let core = text[lo..<hi].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return (lo == text.startIndex ? "" : "…") + core + (hi == text.endIndex ? "" : "…")
    }

    private static func isBoundary(_ text: String, before i: String.Index) -> Bool {
        i == text.startIndex || !text[text.index(before: i)].isLetter
    }

    private static func isBoundary(_ text: String, after i: String.Index) -> Bool {
        i == text.endIndex || !text[i].isLetter
    }
}
