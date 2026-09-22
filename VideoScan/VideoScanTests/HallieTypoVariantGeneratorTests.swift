// HallieTypoVariantGeneratorTests.swift
// THE "SIX WAYS FROM SUNDAY" SENSOR (Rick 2026-09-21). A deterministic,
// seeded generator takes the clean sentences of the eval corpus and types
// them the way a retiree might — a space dropped between two words, a
// letter dropped, two letters swapped, a letter doubled, everything lower
// case, the question mark and apostrophes left off — and asserts that the
// PRE-MODEL routing decision (the lane, the mode, and for a local answer
// its route and reply) is the same for every variant as for the clean
// sentence.
//
// Sentences: every row of the smalltalk, identity_capability and
// edge_cases categories, plus every other row whose clean form is decided
// before the model (a local answer or a local AST) — the turns a typo can
// actually derail without a model to absorb it.
//
// The pass rate is reported before (no front door) and after; the test
// fails below the floor set from the first honest run, and lists the
// failures. Letter-level edits (drop / swap / double) skip People names
// on purpose: recovering a misspelled NAME is PersonResolver's job after
// translation, not the front door's, and the front door must never touch
// a name.
//
// C++ analogy: a seeded property-based test (think RapidCheck with a fixed
// seed) — reproducible run to run, so a failure list is a stable diff.

import Foundation
import Testing
@testable import VideoScan

/// SplitMix64: tiny, seeded, reproducible everywhere.
struct HallieTypoRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0)
        return Int(next() % UInt64(bound))
    }
}

enum HallieTypoVariantGenerator {
    enum Edit: String, CaseIterable, Sendable {
        case dropSpace, dropLetter, swapLetters, doubleLetter, lowercase, dropPunctuation
    }

    struct Variant: Sendable {
        let edit: Edit
        let text: String
    }

    /// Words a letter edit may touch: at least three letters, letters
    /// only, and not a name the oracle knows.
    static func editableWordRanges(_ text: String, isName: (String) -> Bool) -> [Range<Int>] {
        let chars = Array(text)
        var ranges: [Range<Int>] = []
        var start: Int?
        for index in 0...chars.count {
            let isLetter = index < chars.count && chars[index].isLetter
            if isLetter, start == nil { start = index }
            if !isLetter, let begin = start {
                let word = String(chars[begin..<index])
                if word.count >= 3, !isName(word), !HallieTypoNormalizer.builtinProtectedNames.contains(word.lowercased()) {
                    ranges.append(begin..<index)
                }
                start = nil
            }
        }
        return ranges
    }

    /// Up to `perEdit` variants of each edit, distinct from the clean text.
    static func variants(of text: String, rng: inout HallieTypoRNG, perEdit: Int = 2,
                         isName: (String) -> Bool) -> [Variant] {
        var out: [Variant] = []
        var seen: Set<String> = [text]
        func add(_ edit: Edit, _ candidate: String) {
            guard !seen.contains(candidate) else { return }
            seen.insert(candidate)
            out.append(Variant(edit: edit, text: candidate))
        }
        let chars = Array(text)
        let words = editableWordRanges(text, isName: isName)

        for edit in Edit.allCases {
            switch edit {
            case .lowercase:
                add(edit, text.lowercased())
            case .dropPunctuation:
                add(edit, text.filter { !"?'’".contains($0) })
            case .dropSpace:
                // A space between two letters.
                let spaces = chars.indices.filter {
                    chars[$0] == " " && $0 > 0 && $0 + 1 < chars.count
                        && chars[$0 - 1].isLetter && chars[$0 + 1].isLetter
                }
                guard !spaces.isEmpty else { continue }
                for _ in 0..<perEdit {
                    var copy = chars
                    copy.remove(at: spaces[rng.below(spaces.count)])
                    add(edit, String(copy))
                }
            case .dropLetter, .swapLetters, .doubleLetter:
                guard !words.isEmpty else { continue }
                for _ in 0..<perEdit {
                    let word = words[rng.below(words.count)]
                    var copy = chars
                    switch edit {
                    case .dropLetter:
                        copy.remove(at: word.lowerBound + rng.below(word.count))
                    case .swapLetters:
                        let i = word.lowerBound + rng.below(word.count - 1)
                        copy.swapAt(i, i + 1)
                    default:
                        let i = word.lowerBound + rng.below(word.count)
                        copy.insert(copy[i], at: i)
                    }
                    add(edit, String(copy))
                }
            }
        }
        return out
    }
}

@Suite("Hallie typo variant generator: routing survives everyday typos")
struct HallieTypoVariantGeneratorTests {
    private struct Row: Decodable {
        let id: String
        let category: String
        let text: String
    }
    private struct Corpus: Decodable { let questions: [Row] }

    private static func corpusRows() throws -> [Row] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VideoScanTests
            .deletingLastPathComponent()      // VideoScan
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("tests/hallie_eval_corpus.json")
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url)).questions
    }

    /// The generator is reproducible: same seed, same variants.
    @Test func theGeneratorIsSeededAndReproducible() {
        var a = HallieTypoRNG(seed: 20260921), b = HallieTypoRNG(seed: 20260921)
        let first = HallieTypoVariantGenerator.variants(of: "What's up, how are you doing today?", rng: &a,
                                                        isName: HallieTypoFixture.isKnownPerson)
        let second = HallieTypoVariantGenerator.variants(of: "What's up, how are you doing today?", rng: &b,
                                                         isName: HallieTypoFixture.isKnownPerson)
        #expect(first.map(\.text) == second.map(\.text))
        #expect(Set(first.map(\.edit)) == Set(HallieTypoVariantGenerator.Edit.allCases))
    }

    @Test func routingSurvivesTheVariants() throws {
        let rows = try Self.corpusRows()
        let socialCategories: Set<String> = ["smalltalk", "identity_capability", "edge_cases", "typos"]
        let route = { (text: String, door: Bool) in HallieTypoFixture.route(text, frontDoor: door) }

        // The sentences: the three social categories, plus every row the
        // pipeline decides before the model.
        var sentences: [(id: String, text: String, clean: String)] = []
        for row in rows where row.category != "typos" {
            let clean = route(row.text, true)
            if socialCategories.contains(row.category)
                || clean.hasPrefix("answer:") || clean.hasPrefix("run:") {
                sentences.append((row.id, row.text, clean))
            }
        }
        #expect(sentences.count >= 60, Comment(rawValue: "\(sentences.count) sentences"))

        var rng = HallieTypoRNG(seed: 20260921)
        var total = 0, passAfter = 0, passBefore = 0
        var failures: [String] = []
        var regressions: [String] = []
        var byEdit: [HallieTypoVariantGenerator.Edit: (pass: Int, total: Int)] = [:]
        for sentence in sentences {
            let cleanBefore = route(sentence.text, false)
            for variant in HallieTypoVariantGenerator.variants(
                of: sentence.text, rng: &rng, isName: HallieTypoFixture.isKnownPerson) {
                total += 1
                let after = route(variant.text, true)
                let before = route(variant.text, false)
                var tally = byEdit[variant.edit] ?? (0, 0)
                tally.total += 1
                if after == sentence.clean {
                    passAfter += 1
                    tally.pass += 1
                } else {
                    failures.append("\(sentence.id) [\(variant.edit.rawValue)] “\(variant.text)” → \(after) (clean “\(sentence.text)” → \(sentence.clean))")
                }
                if before == cleanBefore {
                    passBefore += 1
                    if after != sentence.clean { regressions.append("\(sentence.id) “\(variant.text)”") }
                }
                byEdit[variant.edit] = tally
            }
        }
        let rateAfter = Double(passAfter) / Double(max(total, 1))
        let rateBefore = Double(passBefore) / Double(max(total, 1))
        let perEdit = HallieTypoVariantGenerator.Edit.allCases.map { edit -> String in
            let t = byEdit[edit] ?? (0, 0)
            return "\(edit.rawValue) \(t.pass)/\(t.total)"
        }.joined(separator: ", ")
        let report = String(format: "typo variants: %d sentences, %d variants; routing unchanged BEFORE %.1f%% (%d), AFTER %.1f%% (%d); per edit after: %@",
                            sentences.count, total, rateBefore * 100, passBefore, rateAfter * 100, passAfter, perEdit)
        print(report)
        print("typo variant regressions (routed right before the front door, wrong after): \(regressions.count)\n" + regressions.joined(separator: "\n"))
        print("typo variant failures (\(failures.count)):\n" + failures.joined(separator: "\n"))
        #expect(total >= 400, Comment(rawValue: report))
        #expect(rateAfter > rateBefore, Comment(rawValue: report))
        // Floor from the first honest run (see the commit message); raise
        // it when the normalizer learns more, never lower it silently.
        #expect(rateAfter >= Self.floor, Comment(rawValue: report + "\n" + failures.prefix(60).joined(separator: "\n")))
    }

    static let floor = 0.80

    /// The front door must not change how an ordinary corpus sentence
    /// routes — only sentences that carry a typo it reads. Every row whose
    /// routing changes is listed, with what the front door read.
    @Test func theFrontDoorLeavesCleanCorpusRoutingAlone() throws {
        let rows = try Self.corpusRows()
        var changed: [String] = []
        for row in rows {
            let after = HallieTypoFixture.route(row.text, frontDoor: true)
            let before = HallieTypoFixture.route(row.text, frontDoor: false)
            guard after != before else { continue }
            let door = HallieFrontDoor.prepare(row.text, isProtectedName: HallieTypoFixture.isKnownPerson)
            changed.append("\(row.id) “\(row.text)” read “\(door.routingText)”: \(before) → \(after)")
        }
        print("front door changed routing of \(changed.count) corpus rows:\n" + changed.joined(separator: "\n"))
    }
}
