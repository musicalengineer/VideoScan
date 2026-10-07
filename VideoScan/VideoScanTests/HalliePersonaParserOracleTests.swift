// HalliePersonaParserOracleTests.swift
// GH #281 R3 (2026-10-06): the back-to-back oracle for the
// HalliePersonaQuestion.detect refactor (an if-chain of phrase alternatives
// turned into ordered phrase tables). N1007-D-Hallie-rewrite-eval §3 plan.
//
// `LegacyHalliePersonaQuestion` below is the PRE-REFACTOR detect copied
// VERBATIM from main@ebcd2f09 (with its private helper and vocabularies, so
// a later edit to the production lists cannot move both sides at once).
// The test runs legacy and production over every sentence in
// tests/fixtures/hallie_parser_sentences.json (all Hallie corpora incl. the
// STRICT lane, plus every Hallie*/Archivist* test literal), over cheap
// variants of each (lowercased, vocative before / after), and over a
// generated grid that reaches every phrase alternative, under two identity
// oracles. Any disagreement fails with the full list.
//
// Delete the legacy copy (in its own commit) once the refactor has lived on
// main for a while; the ordinary HalliePersonaQuestionTests stay.

import Foundation
import Testing
@testable import VideoScan

// swiftlint:disable cyclomatic_complexity function_body_length
/// FROZEN pre-refactor copy. Do not edit, do not "fix": it is the oracle.
enum LegacyHalliePersonaQuestion {
    typealias Ask = HalliePersonaQuestion.Ask

    static let secondPersonWords: Set<String> = ["you", "your", "yours", "yourself"]
    static let firstPersonWords: Set<String> = [
        "i", "i'm", "me", "my", "mine", "myself", "we", "us", "our", "ours",
    ]
    static let searchAndMediaWords: Set<String> = [
        "show", "find", "search", "play", "reveal", "open", "list", "count",
        "video", "videos", "clip", "clips", "photo", "photos", "picture",
        "pictures", "footage", "tape", "tapes", "recording", "recordings",
        "file", "files", "catalog", "archive", "transcript", "movie",
        "movies", "film", "films",
    ]
    static let requestLeads = [
        "can you", "could you", "would you", "will you", "do you know",
        "did you find", "have you got", "are you able to",
    ]
    static let vocatives = ["hallie mae", "hallie"]
    static let leadFillers: Set<String> = ["hey", "hi", "ok", "okay", "so", "please"]

    static let kinWords: [String] = [
        "mother", "mom", "mum", "mama", "father", "dad", "daddy", "papa",
        "parents", "grandmother", "grandma", "grandfather", "grandpa",
        "grandparents", "husband", "wife", "spouse", "children", "kids",
        "son", "sons", "daughter", "daughters", "brother", "brothers",
        "sister", "sisters", "siblings", "family", "ancestors",
    ]

    private static let identityStopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "do",
        "does", "did", "can", "could", "would", "should", "will", "to", "of",
        "in", "on", "for", "with", "and", "or", "but", "you", "your", "yours",
        "yourself", "it", "its", "this", "that", "what", "why", "how", "when",
        "where", "who", "which", "as", "at", "from", "about", "into", "than",
        "then", "if", "please", "born", "old", "still", "ever", "any", "have",
        "has", "had", "get", "got", "live", "die", "died", "dead", "alive",
        "come", "grow", "up", "hallie", "mae", "many", "much",
    ]

    static func detect(_ question: String, isInnerCircleName: (String) -> Bool) -> Ask? {
        guard question.count <= 200 else { return nil }
        var text = question
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "?.!,;: "))
        guard !text.isEmpty else { return nil }

        // Peel the vocative: "hallie, where were you born" / "…, hallie".
        for name in vocatives {
            if text.hasSuffix(", " + name) || text.hasSuffix(" " + name) {
                text = String(text.dropLast(name.count + (text.hasSuffix(", " + name) ? 2 : 1)))
                break
            }
        }
        var words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        while let first = words.first, leadFillers.contains(first) { words.removeFirst() }
        if words.first == "hallie" {
            words.removeFirst()
            if words.first == "mae" { words.removeFirst() }
        }
        guard !words.isEmpty else { return nil }

        // Archive cues: a catalog year, a search or media word.
        if words.contains(where: {
            guard $0.count == 4, let year = Int($0) else { return false }
            return ArchivistQueryAST.yearRange.contains(year)
        }) { return nil }
        guard Set(words).isDisjoint(with: searchAndMediaWords) else { return nil }
        // No "you" at all: not this shape, and — before any oracle is
        // asked — nothing is loaded for it (the identity sources are lazy
        // and a translated question must not pull them in for nothing).
        guard words.contains(where: secondPersonWords.contains) else { return nil }
        // A third party: a typed capitalised word past the first token
        // (never her own name), or a curated known name of any width.
        let typedNames = question
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .dropFirst()
            .filter {
                $0.first?.isUppercase == true
                    && !["hallie", "mae", "i", "i'm"].contains($0.lowercased())
            }
        guard typedNames.isEmpty else { return nil }

        // Request leads peeled: "can you tell me where you were born" keeps
        // its second "you"; "do you know where donna was born" loses its
        // only one. "tell me" is a lead too — its "me" is not the owner
        // asking about himself ("tell me about your family").
        var remaining = words
        var opening = " " + remaining.joined(separator: " ") + " "
        for lead in requestLeads where opening.hasPrefix(" \(lead) ") {
            remaining.removeFirst(lead.split(separator: " ").count)
            break
        }
        opening = " " + remaining.joined(separator: " ") + " "
        if opening.hasPrefix(" tell me ") || opening.hasPrefix(" tell us ") {
            remaining.removeFirst(2)
        }
        // The owner is in it: a relationship / owner question, not hers.
        guard Set(remaining).isDisjoint(with: firstPersonWords) else { return nil }
        guard remaining.contains(where: secondPersonWords.contains) else { return nil }
        // Last, because it is the one check that costs a load.
        guard !containsKnownPerson(words, isInnerCircleName: isInnerCircleName) else { return nil }

        let padded = " " + remaining.joined(separator: " ") + " "
        // Relatives: "your father", "your mother's job", "did you have children".
        for kin in kinWords {
            if padded.contains(" your \(kin) ") || padded.contains(" your \(kin)'s ")
                || padded.contains(" you have \(kin) ") || padded.contains(" you have any \(kin) ")
                || padded.contains(" you have a \(kin) ") || padded.contains(" you ever have \(kin) ")
                || padded.contains(" you ever have any \(kin) ") || padded.contains(" you ever have a \(kin) ") {
                return .relatives(kin)
            }
        }
        if padded.contains(" you married ") || padded.contains(" you ever married ")
            || padded.contains(" you ever marry ") || padded.contains(" you marry ") {
            return .relatives("husband")
        }
        // Vital facts.
        if padded.contains(" born ") || padded.contains(" birthplace ") || padded.contains(" birthday ")
            || padded.contains(" birth date ") || padded.contains(" date of birth ") {
            if padded.contains(" birthday ") || padded.contains(" birth date ")
                || padded.contains(" date of birth ") { return .birthdate }
            let opener = remaining.first ?? ""
            if opener == "when" || padded.contains(" what year ") || padded.contains(" what day ")
                || padded.contains(" what date ") { return .birthdate }
            if opener == "where" || padded.contains(" what town ") || padded.contains(" what city ")
                || padded.contains(" what country ") || padded.contains(" what place ")
                || padded.contains(" what state ") || padded.contains(" birthplace ") { return .birthplace }
            return .birthdate
        }
        if padded.contains(" how old ") || padded.contains(" your age ") || padded.contains(" age are you ") {
            return .age
        }
        if padded.contains(" die ") || padded.contains(" died ") || padded.contains(" death ")
            || padded.contains(" dead ") || padded.contains(" alive ") || padded.contains(" pass away ")
            || padded.contains(" passed away ") || padded.contains(" still living ")
            || padded.contains(" still around ") {
            return .death
        }
        if padded.contains(" where are you from ") || padded.contains(" where do you come from ")
            || padded.contains(" where did you come from ") || padded.contains(" where did you grow up ")
            || padded.contains(" where were you raised ") || padded.contains(" where are you originally from ")
            || padded.contains(" where you grew up ") || padded.contains(" where did you live ")
            || padded.contains(" where do you live ") {
            return .origin
        }
        return nil
    }

    private static func containsKnownPerson(_ words: [String],
                                            isInnerCircleName: (String) -> Bool) -> Bool {
        let maximum = min(3, words.count)
        guard maximum > 0 else { return false }
        for width in 1...maximum {
            for start in 0...(words.count - width) {
                let span = words[start..<(start + width)]
                if width == 1, identityStopwords.contains(span[span.startIndex]) { continue }
                if isInnerCircleName(span.joined(separator: " ")) { return true }
            }
        }
        return false
    }
}
// swiftlint:enable cyclomatic_complexity function_body_length

/// Shared by the parser oracles: the committed sentence set.
enum HallieParserOracleInputs {
    private struct Fixture: Decodable { let sentences: [String] }

    static func sentences() throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VideoScanTests
            .deletingLastPathComponent()      // VideoScan
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("tests/fixtures/hallie_parser_sentences.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).sentences
    }
}

@Suite("Persona parser: refactor matches the frozen legacy detect on every input")
struct HalliePersonaParserOracleTests {

    /// Every phrase alternative the old if-chain spelled out, crossed with
    /// every kin word, so each leaf is reached even if no corpus uses it.
    static func generatedGrid() -> [String] {
        let kinFrames = [
            "who was your %@", "what was your %@'s name", "did you have %@",
            "did you have any %@", "did you have a %@", "did you ever have %@",
            "did you ever have any %@", "did you ever have a %@",
            "hallie, tell me about your %@", "can you tell me about your %@",
            "so do you have %@?", "your %@", "you have %@ hallie mae",
        ]
        var grid: [String] = []
        for kin in LegacyHalliePersonaQuestion.kinWords {
            for frame in kinFrames { grid.append(String(format: frame, kin)) }
            // kin vs married vs vitals precedence
            grid.append("were you married to your \(kin)")
            grid.append("when was your \(kin) born")
        }
        grid += [
            "were you married", "were you ever married", "did you ever marry", "did you marry",
            "who did you marry", "are you married", "you married?",
            "where were you born", "when were you born", "what year were you born",
            "what day were you born", "what date were you born", "what town were you born in",
            "what city were you born in", "what country were you born in", "what place were you born",
            "what state were you born in", "what is your birthplace", "when is your birthday",
            "what is your birth date", "what is your date of birth", "were you born", "you were born where",
            "how old are you", "what is your age", "what age are you", "your age",
            "did you die", "when did you die", "are you dead", "are you alive", "did you pass away",
            "have you passed away", "are you still living", "are you still around", "how did your death happen",
            "where are you from", "where do you come from", "where did you come from",
            "where did you grow up", "where were you raised", "where are you originally from",
            "tell me where you grew up", "where did you live", "where do you live",
            "how are you", "what can you do", "who are you", "are you there",
            "do you know where donna was born", "can you tell me where you were born",
            "could you tell us when you were born", "will you", "can you", "tell me", "tell us your age",
            "ok so hey please hallie mae how old are you", "hi hallie", "hallie", "hallie mae", "",
            "   ", "?!", "how old were you in 1994", "how old were you in 2105", "how old were you in 1066",
            "where were you born, Hallie Mae?", "where were you born Hallie", "Where Were You Born",
            "where were you and Donna born", "how old are you, Rick", "is Donna your mother",
            "where were you born\u{2019}s", "who was your mother\u{2019}s father",
            "how am i related to you", "how old are we, you and i", "how old is your school",
            "what was school like for you", "where did you go to school, grandpa joe",
            String(repeating: "where were you born ", count: 12),
        ]
        // Two cues in one sentence: these pin the ORDER of the tables
        // (kin > married > birth > age > death > origin), which single-cue
        // sentences cannot (a mutation moving age after origin survived
        // without them, R3 red check 2026-10-07).
        let cues = ["how old are you", "where are you from", "when did you die", "where were you born",
                    "were you ever married", "who was your father", "did you have any kids", "what is your age"]
        for first in cues {
            for second in cues where second != first {
                grid.append("\(first) and \(second)")
            }
        }
        return grid
    }

    static func variants(of sentence: String) -> [String] {
        [sentence, sentence.lowercased(), "hallie, " + sentence, sentence + ", hallie?",
         "Hallie Mae " + sentence]
    }

    /// Two identity oracles: nobody is known, and a fixed small circle
    /// (one-, two- and three-word names, one of them a kin word).
    static var oracles: [(label: String, isKnown: (String) -> Bool)] { [
        ("none", { _ in false }),
        ("circle", { ["donna", "rick", "mom", "grandpa joe", "school", "aunt mary ellen"].contains($0) }),
    ] }

    @Test func theRefactoredDetectAgreesWithTheLegacyCopyOnEveryInput() throws {
        let corpus = try HallieParserOracleInputs.sentences()
        #expect(corpus.count > 5_000, "the sentence fixture shrank: \(corpus.count)")
        var inputs: [String] = []
        for sentence in corpus + Self.generatedGrid() { inputs += Self.variants(of: sentence) }

        var disagreements: [String] = []
        var claimed: [String: Int] = [:]
        for oracle in Self.oracles {
            for input in inputs {
                let legacy = LegacyHalliePersonaQuestion.detect(input, isInnerCircleName: oracle.isKnown)
                let current = HalliePersonaQuestion.detect(input, isInnerCircleName: oracle.isKnown)
                if legacy != current {
                    disagreements.append("[\(oracle.label)] \(input.debugDescription) legacy=\(String(describing: legacy)) new=\(String(describing: current))")
                }
                if let legacy { claimed[legacy.description, default: 0] += 1 }
            }
        }
        #expect(disagreements.isEmpty,
                "\(disagreements.count) of \(inputs.count * Self.oracles.count):\n\(disagreements.prefix(60).joined(separator: "\n"))")
        // Not vacuous: every Ask kind and every kin word is produced.
        for kind in ["birthplace", "birthdate", "age", "death", "origin"] {
            #expect(claimed[kind, default: 0] > 0, "no input produced \(kind)")
        }
        for kin in LegacyHalliePersonaQuestion.kinWords {
            #expect(claimed["relatives(\(kin))", default: 0] > 0, "no input produced relatives(\(kin))")
        }
        print("HalliePersonaParserOracle: \(inputs.count) inputs x \(Self.oracles.count) oracles, \(claimed.values.reduce(0, +)) claimed")
    }
}
