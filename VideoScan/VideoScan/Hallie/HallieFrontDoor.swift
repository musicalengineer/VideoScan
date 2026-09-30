// HallieFrontDoor.swift
// What every typed turn passes through before the pre-model lanes, in
// BOTH clients (HallieAppTurnCoordinator.execute and HallieShellCLI):
//
//   1. HallieTypoNormalizer — everyday typos read as their words
//      ("Hi Hallie how areyou?" → "Hi Hallie how are you?");
//   2. the greeting peel — a turn LED by a greeting and followed by a real
//      request routes the request ("hi hallie, who was donna's mother?"
//      → "who was donna's mother?"), so a greeting is never a search
//      keyword. The live miss of 2026-09-21 18:52 ran a transcript search
//      for "hi".
//
// The peel steps aside whenever the whole turn is already small talk the
// deterministic table answers ("hi hallie", "hi, how are you today" — the
// table peels its own salutation there and says hello back), and when
// what is left is a single word ("hello Donna" is left for the lanes that
// know what to do with a lone name).
//
// The original text is never replaced in the transcript: callers keep it
// and route `routingText`.
//
// C++ analogy: a small value-returning pipeline (two pure passes), like a
// lexer pre-pass that hands the parser a cleaned buffer while the caller
// keeps the source for diagnostics.

import Foundation

enum HallieFrontDoor {
    struct Outcome: Equatable, Sendable {
        let original: String
        /// The text the routing lanes and the translator read.
        let routingText: String
        let typo: HallieTypoNormalizer.Result
        /// "Hi Hallie," when a leading greeting was set aside.
        let peeledGreeting: String?

        /// At most two lines: `[hallie-typo] read “areyou” as “are you”`
        /// and `[hallie-greeting] set aside “Hi Hallie,”`.
        var logLines: [String] {
            var lines: [String] = []
            if let line = typo.logLine { lines.append(line) }
            if let peeledGreeting {
                lines.append("[hallie-greeting] set aside “\(peeledGreeting)”")
            }
            return lines
        }
    }

    /// The production name oracle: a People-tab name or alias, a
    /// CyberBrain person, a tree name or a tree surname. Asked only about
    /// a token the normalizer is about to rewrite.
    static func isProtectedName(_ token: String, context: HallieTurnExecutor.Context) -> Bool {
        HallieTurnExecutor.isInnerCircleName(token, context: context)
            || HallieTurnExecutor.isKnownPerson(token, context: context, acceptSurname: true)
    }

    static func prepare(
        _ question: String,
        isProtectedName: (String) -> Bool = { _ in false }
    ) -> Outcome {
        let typo = HallieTypoNormalizer.normalize(question, isProtectedName: isProtectedName)
        let peel = HallieGreetingPeel.peel(typo.text)
        return Outcome(
            original: question,
            routingText: peel?.rest ?? typo.text,
            typo: typo,
            peeledGreeting: peel?.greeting)
    }
}

enum HallieGreetingPeel {
    struct Peeled: Equatable, Sendable {
        /// The greeting as typed, with its trailing punctuation ("Hi Hallie,").
        let greeting: String
        /// Everything after it, as typed.
        let rest: String
    }

    /// Greetings that may lead a turn, as lower-case word sequences. Bare
    /// "morning" / "evening" are NOT here: "morning at the cape" is a search.
    static let leads: [[String]] = [
        ["good", "morning"], ["good", "afternoon"], ["good", "evening"], ["good", "day"],
        ["hi", "there"], ["hello", "there"], ["hey", "there"],
        ["hi"], ["hello"], ["hey"], ["hiya"], ["howdy"], ["heya"], ["hullo"], ["greetings"],
    ]

    /// Hallie's own name may follow the greeting.
    static let addressWords: [[String]] = [["hallie", "mae"], ["hallie"]]

    /// Nil when the turn is not greeting + request.
    static func peel(_ text: String) -> Peeled? {
        // Already small talk as a whole ("hi hallie", "hi how are you
        // today"): the table answers it, and "hi" may carry the kind word.
        if ArchivistConversationCommand.detect(text) != nil { return nil }

        let segments = HallieTypoNormalizer.tokenize(text)
        var index = 0
        // Skip leading whitespace.
        while index < segments.count, !segments[index].isWord {
            guard segments[index].text.allSatisfy(\.isWhitespace) else { return nil }
            index += 1
        }
        func matchWords(_ sequence: [String], from start: Int) -> Int? {
            var cursor = start
            for (offset, word) in sequence.enumerated() {
                if offset > 0 {
                    // Words of one greeting are separated by spaces only.
                    guard cursor < segments.count, !segments[cursor].isWord,
                          segments[cursor].text.allSatisfy({ $0 == " " }) else { return nil }
                    cursor += 1
                }
                guard cursor < segments.count, segments[cursor].isWord,
                      segments[cursor].text.lowercased() == word else { return nil }
                cursor += 1
            }
            return cursor
        }
        guard var cursor = leads.lazy.compactMap({ matchWords($0, from: index) }).first else {
            return nil
        }
        // "hi-8 tapes": a hyphen or apostrophe glues the greeting to a word.
        if cursor < segments.count, segments[cursor].text.first.map({ "-'’".contains($0) }) == true {
            return nil
        }
        // Optional ", Hallie" / " hallie mae".
        var probe = cursor
        if probe < segments.count, !segments[probe].isWord,
           segments[probe].text.allSatisfy({ " ,".contains($0) }) {
            probe += 1
        }
        if let after = addressWords.lazy.compactMap({ matchWords($0, from: probe) }).first {
            cursor = after
        }
        // Trailing separator: spaces and , ! . ; : — belong to the greeting.
        var greetingEnd = cursor
        if greetingEnd < segments.count, !segments[greetingEnd].isWord {
            let separator = segments[greetingEnd].text
            guard separator.allSatisfy({ " ,!.;:\u{2014}-\t".contains($0) }) else { return nil }
            greetingEnd += 1
        }
        let rest = segments[greetingEnd...].map(\.text).joined()
        let restWords = segments[greetingEnd...].filter(\.isWord).count
        guard restWords >= 2 else { return nil }
        let greeting = segments[..<greetingEnd].map(\.text).joined()
            .trimmingCharacters(in: .whitespaces)
        return Peeled(greeting: greeting, rest: rest)
    }
}
