// HalliePronunciationDrillMode.swift
// "Hallie, let's practice names" (Rick, 2026-08-29). Hallie puts one name
// at a time to Rick — shown as text and spoken by the voice with whatever
// it currently does — and Rick judges: "right", "no — MahGill", "either
// MahGill or MicGill", "skip", "stop". A correction is kept through the
// same writer as a one-off "pronounce X like Y", then Hallie says
// "OK, noted — McGill" with the name SPOKEN the new way (the read-back),
// and moves on. The session resumes where it left off.
//
// Pure and client-agnostic, like HallieTellingMode: text in, decisions and
// wording out. No I/O, no model. The chat window and the shell both drive
// it, so the drill cannot drift between them. Deterministic parsing only —
// a judgement must never depend on a model's mood.

import Foundation
import VideoScanCore

enum HalliePronunciationDrillMode {

    // MARK: - Session

    /// Live state while drilling. Owned by the client (chat window state /
    /// shell Session / web session), advanced only through this enum.
    struct Session: Equatable, Sendable {
        let list: PronunciationDrillList
        /// Index into `list.items` of the name currently put to Rick; nil
        /// when the sheet is exhausted.
        var index: Int?
        /// This session's counts (the closing line and the log line).
        var taught = 0
        var judgedOk = 0
        var skipped = 0

        var current: PronunciationDrillList.Item? {
            guard let index, index < list.items.count else { return nil }
            return list.items[index]
        }

        /// Names still pending at or after the current one.
        func remaining(store: PronunciationDrillStore) -> Int {
            guard let index else { return 0 }
            return list.items[index...].filter { store.status(for: $0.key).isPending }.count
        }
    }

    // MARK: - What a turn means

    /// A respelling reply: one or more alternatives, first = spoken, and
    /// optionally the name it is for (when Rick named it: "Edith is Ee-dith").
    struct Correction: Equatable, Sendable {
        let word: String?
        let alternatives: [String]
    }

    enum Reply: Equatable, Sendable {
        /// "let's practice names", "practice pronunciations".
        case start
        /// "next name" / "next": move on, leaving the current name untested.
        case next
        /// "right" / "correct" / "yes".
        case judgedOk
        /// "no — MahGill", "say it like MahGill", "either MahGill or
        /// MicGill", "pronounce McGill like MahGill", "Edith is Ee-dith".
        case teach(Correction)
        /// A descriptive hint ("with a short a on the La", "Latta rhymes
        /// with data"), for the current name unless one is named.
        case hint(HalliePronunciationHintTelling)
        /// "skip".
        case skip
        /// "stop" / "that's enough".
        case stop
        /// A question, or a different conversation: the drill steps aside.
        case leave
        /// Words the drill could not read; stay on the same name and say
        /// what it accepts.
        case unrecognized
    }

    // MARK: - Detection

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: #"^(?:hallie|hey hallie|ok hallie|okay hallie)[,!]?\s+"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static let startPattern = try! NSRegularExpression(
        pattern: #"^(?:(?:let's|lets|let us|can we|could we|shall we|i want to|i'd like to|time to)\s+)?(?:practice|practise|drill|rehearse|go through|run through|work on)\s+(?:the\s+|some\s+|our\s+|my\s+|family\s+)?(?:names|name pronunciations?|pronunciations?|pronouncing names|the names|name sheet|pronunciation sheet)(?:\s+(?:with me|together|now|please))?[.!]?$"#,
        options: [.caseInsensitive])

    private static let nextPattern = try! NSRegularExpression(
        pattern: #"^(?:ok[,]?\s+|okay[,]?\s+)?(?:next|next name|next one|go on|carry on|move on|another|another one|give me another|the next name)(?:\s+please)?[.!]?$"#,
        options: [.caseInsensitive])

    private static let okPattern = try! NSRegularExpression(
        pattern: #"^(?:ok[,]?\s+|okay[,]?\s+|yes[,]?\s+|yep[,]?\s+)?(?:right|correct|yes|yep|yup|yeah|good|fine|perfect|exactly|that's right|thats right|that's it|thats it|that's correct|thats correct|sounds right|you got it|got it|nailed it|spot on|that's good|thats good|good enough|that works)(?:[,!.]?\s*(?:hallie|thanks|thank you))?[.!]?$"#,
        options: [.caseInsensitive])

    private static let skipPattern = try! NSRegularExpression(
        pattern: #"^(?:skip|skip it|skip that|skip this one|skip that one|pass|pass on that|not sure|don't know|dont know|no idea|i don't know|i dont know|later|come back to it|come back to that)(?:\s+please)?[.!]?$"#,
        options: [.caseInsensitive])

    private static let stopPattern = try! NSRegularExpression(
        pattern: #"^(?:ok[,]?\s+|okay[,]?\s+)?(?:stop|stop practicing|stop practising|stop the drill|that's enough|thats enough|enough|enough for now|that's enough for now|that's all|thats all|that'll do|we're done|were done|i'm done|im done|done|done for now|let's stop|lets stop|quit|end the drill|end practice|finish|that's it for now|thats it for now)(?:\s+(?:hallie|thanks|thank you|for now|for today))?[.!]?$"#,
        options: [.caseInsensitive])

    /// "no — MahGill", "no, MahGill", "no it's MahGill", "nope: muh-GILL",
    /// "wrong, MahGill". Group 1 = the respelling(s).
    private static let noPattern = try! NSRegularExpression(
        pattern: #"^(?:no|nope|nah|wrong|not quite|not right|incorrect|close|almost|not really)\b[,.;:!]?\s*(?:—|–|-|:)?\s*(?:it's|it is|its|it should be|it's more like|more like|try|say|say it like|say it as|pronounce it|pronounce it like|pronounce it as|like)?[,:]?\s*(.+?)[.!]?$"#,
        options: [.caseInsensitive])

    /// "say it like MahGill", "pronounce it MahGill", "it's MahGill",
    /// "try MahGill", "more like MahGill", "it should be muh-GILL".
    private static let sayItPattern = try! NSRegularExpression(
        pattern: #"^(?:please\s+)?(?:say it|pronounce it|say that|pronounce that|it's|it is|its|it should be|it goes|it's more like|more like|try|should be|make it|use)\s*(?:like|as|:)?\s+(.+?)[.!]?$"#,
        options: [.caseInsensitive])

    /// "either MahGill or MicGill", "MahGill or MicGill", "MahGill | MicGill".
    private static let alternativesPattern = try! NSRegularExpression(
        pattern: #"^(?:either\s+)?(\S+(?:\s\S+)?)\s*(?:,?\s+or\s+|\|)\s*(\S+(?:\s\S+)?)(?:\s*(?:,?\s+or\s+|\|)\s*(\S+(?:\s\S+)?))?[.!]?$"#,
        options: [.caseInsensitive])

    /// "Edith is Ee-dith", "McGill = MahGill", "McGill: MahGill". Group 1 =
    /// the name, group 2 = the respelling(s).
    private static let namedPattern = try! NSRegularExpression(
        pattern: #"^([\p{L}'’-]+)\s*(?:is|=|:|is said|is pronounced|goes|sounds like|is more like|should be)\s+(.+?)[.!]?$"#,
        options: [.caseInsensitive])

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func capture(_ regex: NSRegularExpression, _ text: String, group: Int = 1) -> String? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    /// Ordinary words a bare reply could be mistaken for ("it's fine").
    private static let notRespellings: Set<String> = [
        "fine", "good", "ok", "okay", "right", "correct", "wrong", "close", "perfect", "bad", "better",
        "worse", "different", "same", "it", "that", "this", "hard", "tough", "nothing", "something",
        "great", "lovely", "nice", "true", "false", "sure", "maybe", "no", "yes",
    ]

    /// A correction only when every alternative is a plausible respelling.
    private static func alternatives(_ text: String) -> [String]? {
        guard let parts = HallieTellingMode.respellingAlternatives(text),
              !parts.contains(where: { notRespellings.contains($0.lowercased()) }) else { return nil }
        return parts
    }

    /// The drill opener, with or without a session ("let's practice names").
    static func detectStart(_ text: String) -> Bool {
        matches(startPattern, clean(text))
    }

    /// What a turn means while a name is up. Pure; the caller applies it.
    static func classify(_ text: String, session: Session) -> Reply {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return .unrecognized }
        if cleaned.hasSuffix("?") { return .leave }
        if HallieTellingMode.detectOpening(text) != nil { return .leave }
        if matches(startPattern, cleaned) { return .start }
        if matches(stopPattern, cleaned) { return .stop }
        if matches(skipPattern, cleaned) { return .skip }
        if matches(nextPattern, cleaned) { return .next }
        if matches(okPattern, cleaned) { return .judgedOk }

        // "pronounce McGill like MahGill or MicGill" — the one-off form,
        // naming the word. Works for the current name or any other.
        if let told = HallieTellingMode.detectPronunciation(cleaned) {
            return .teach(Correction(word: told.word, alternatives: told.alternatives))
        }
        // "Latta should be pronounced with a short a on the La" (named), or
        // "with a short a on the La" / "stress on the first syllable" about
        // the name that is up.
        if let hinted = HallieTellingMode.detectPronunciationHint(cleaned)
            ?? session.current.flatMap({ HallieTellingMode.detectPronunciationHint("\($0.name) \(cleaned)") }) {
            return .hint(hinted)
        }
        // "no — MahGill" / "no, it's MahGill".
        if let rest = capture(noPattern, cleaned),
           let alternatives = alternatives(rest) {
            return .teach(Correction(word: nil, alternatives: alternatives))
        }
        // "say it like MahGill" / "pronounce it MahGill" / "it's MahGill".
        if let rest = capture(sayItPattern, cleaned),
           let alternatives = alternatives(rest) {
            return .teach(Correction(word: nil, alternatives: alternatives))
        }
        // "Edith is Ee-dith" — the name must be the one up, or one on the
        // sheet, so an ordinary sentence ("Donna is lovely") is not a teach.
        if let word = capture(namedPattern, cleaned), let rest = capture(namedPattern, cleaned, group: 2),
           let alternatives = alternatives(rest) {
            let key = FamilyIdentityText.normalized(word)
            if session.current?.key == key || session.list.items.contains(where: { $0.key == key }) {
                return .teach(Correction(word: word, alternatives: alternatives))
            }
        }
        // "either MahGill or MicGill" / "MahGill or MicGill".
        if matches(alternativesPattern, cleaned),
           let alternatives = alternatives(cleaned), alternatives.count > 1 {
            return .teach(Correction(word: nil, alternatives: alternatives))
        }
        // A bare respelling ("muh-GILL", "Ee-dith") while a name is up.
        if session.current != nil, !cleaned.contains(" "),
           let alternatives = alternatives(cleaned),
           alternatives.count == 1,
           FamilyIdentityText.normalized(alternatives[0]) != session.current?.key {
            return .teach(Correction(word: nil, alternatives: alternatives))
        }
        return .unrecognized
    }

    // MARK: - Wording

    /// Opening: the first pending name. `resumed` when the sheet already
    /// has judgements from an earlier session.
    static func openingReply(_ session: Session, remaining: Int, resumed: Bool) -> String {
        guard let item = session.current else { return exhaustedReply(session) }
        let lead = resumed
            ? "Picking up where we left off — \(remaining) name\(remaining == 1 ? "" : "s") to go."
            : "Let's practice — \(remaining) name\(remaining == 1 ? "" : "s") on the sheet."
        return lead + " Tell me \"right\", \"skip\", or how to say it. " + putName(item)
    }

    /// The name put to Rick: shown as text; the voice says it with whatever
    /// it currently does.
    static func putName(_ item: PronunciationDrillList.Item) -> String {
        "Next name: \(item.name)."
    }

    static func judgedOkReply(_ session: Session) -> String {
        guard let item = session.current else { return "Good. " + exhaustedReply(session) }
        return "Good. " + putName(item)
    }

    static func skippedReply(_ session: Session) -> String {
        guard let item = session.current else { return "Skipped. " + exhaustedReply(session) }
        return "Skipped. " + putName(item)
    }

    static func nextReply(_ session: Session) -> String {
        guard let item = session.current else { return exhaustedReply(session) }
        return "We'll come back to that one. " + putName(item)
    }

    /// After a teach: the read-back FIRST (spoken with the new entry in
    /// force), then the next name. `word` is the name that was taught.
    static func taughtReply(word: String, alternatives: [String], hint: HalliePronunciationHint? = nil,
                            session: Session, movedOn: Bool) -> String {
        var text = HallieTellingMode.pronunciationReadBack(word)
        if let hint, let respelling = alternatives.first {
            text += " From your hint (\(hint.description)), I'll say \(word) as \(respelling)."
        }
        if alternatives.count > 1 {
            text += " I'll say \(alternatives[0]) and keep \(alternatives.dropFirst().joined(separator: " and ")) too."
        }
        if let item = session.current {
            text += movedOn ? " " + putName(item) : " Still on: \(item.name)."
        } else {
            text += " " + exhaustedReply(session)
        }
        return text
    }

    /// A hint Hallie could not map: ask for a spelling, stay on the name.
    static func hintNeedsSpellingReply(_ told: HalliePronunciationHintTelling, session: Session) -> String {
        var text = HallieTellingMode.hintNeedsSpellingReply(told)
        if let item = session.current { text += " Still on: \(item.name)." }
        return text
    }

    static func failedTeachReply(word: String, error: String, session: Session) -> String {
        var text = "I couldn't save that — \(error). Saying \(word) the new way won't stick, sorry."
        if let item = session.current { text += " Still on: \(item.name)." }
        return text
    }

    static func unrecognizedReply(_ session: Session) -> String {
        guard let item = session.current else { return exhaustedReply(session) }
        return "I didn't catch that as a judgement. Say \"right\", \"skip\", \"next\", \"stop\", or how to say it — for example \"say it like MahGill\" or \"either MahGill or MicGill\". Still on: \(item.name)."
    }

    /// Closing with the session's counts. `nextName` is where the next
    /// session picks up.
    static func closingReply(_ session: Session, nextName: String?) -> String {
        var text = "That's enough for now — " + tallyLine(session) + "."
        if let nextName {
            text += " We'll pick up at \(nextName) next time."
        } else {
            text += " Every name on the sheet has been judged."
        }
        return text
    }

    static func exhaustedReply(_ session: Session) -> String {
        "That's every name on the sheet — " + tallyLine(session) + ". New names will appear here as the tree and People tab grow."
    }

    static func tallyLine(_ session: Session) -> String {
        "taught \(session.taught), judged OK \(session.judgedOk), skipped \(session.skipped)"
    }

    /// The private-log line (counts only, no names — codex #861).
    static func logLine(_ session: Session) -> String {
        "[hallie-voice] drill: taught \(session.taught), judged-ok \(session.judgedOk), skipped \(session.skipped) (session)"
    }

    static let basisLine = "Basis: name drill — judged by you, no model call, no catalog query."
}
