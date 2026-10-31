// CaptionTextQualityTests.swift
// GH #402: the verdict that keeps a degenerate VLM generation (`!!!!…`)
// out of the captions table. Logic (every rule and every carve-out),
// unicode, poisoned input, and scale (100k captions under a time budget).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Caption text quality — degenerate generations are not captions")
struct CaptionTextQualityTests {

    private func isDegenerate(_ s: String) -> Bool { CaptionTextQuality.verdict(s).isDegenerate }

    // MARK: - Rule (d): empty

    @Test("empty and whitespace-only text is degenerate", arguments: ["", " ", "\n\t  ", "\u{3000}"])
    func emptyIsDegenerate(_ s: String) {
        #expect(CaptionTextQuality.verdict(s) == .degenerate(reason: "empty"))
    }

    // MARK: - Rule (a): one character class dominates

    @Test("a run of one to three punctuation characters is degenerate",
          arguments: ["!!!!!!!!!!!!", "!!!!!!!!!", ".........", "----------", "!.!.!.!.!.", "! ! ! ! ! ! ! !",
                      String(repeating: "!", count: 120)])
    func punctuationRunIsDegenerate(_ s: String) {
        #expect(isDegenerate(s), "\(s)")
    }

    @Test("a single letter repeated past 8 characters is degenerate", arguments: ["aaaaaaaaa", "a!a!a!a!a!", "zzzzzzzzzzzzzzzz"])
    func letterRunIsDegenerate(_ s: String) {
        if case .degenerate(let reason) = CaptionTextQuality.verdict(s) {
            #expect(reason.contains("make up"), "rule (a) named: \(reason)")
        } else {
            Issue.record("expected degenerate: \(s)")
        }
    }

    @Test("a digit loop longer than a burn-in is degenerate; a burn-in made of few digits is not")
    func digitCarveOut() {
        #expect(!isDegenerate("11-11-11 11:11"))
        #expect(!isDegenerate("11/11/11"))
        #expect(isDegenerate("1111111111"))    // a 1-digit unit ×10: rule (p), not a burn-in
        #expect(isDegenerate(String(repeating: "1", count: 25)))
        #expect(isDegenerate(String(repeating: "0", count: 40)))
    }

    @Test("a word built from few letters is a word, not a repetition")
    func fewLetterWordIsUsable() {
        #expect(!isDegenerate("MISSISSIPPI"))
        #expect(!isDegenerate("Mississippi River"))
        #expect(!isDegenerate("═══ 1991 ═══"))
    }

    @Test("the boundary: 8 characters is too short for rule (a); 9 is not")
    func lengthBoundary() {
        #expect(!isDegenerate("aaaaaaaa"))     // 8
        #expect(isDegenerate("aaaaaaaaa"))     // 9
    }

    @Test("the 90 % share boundary")
    func shareBoundary() {
        // 9 of 10 non-space characters are 'a' (90 %), one 'b' is the 2nd of the
        // top three — two letters in the set, so it reads as a word.
        #expect(!isDegenerate("aaaaaaaaab"))
        // 9 '!' + one 'x' + ... : '!' and 'x' are the set; one alnum → degenerate.
        #expect(isDegenerate("!!!!!!!!!x"))
        // 8 of 10 '!' plus two distinct letters outside the top three would be
        // impossible (top three covers them); spread over 5 letters is usable.
        #expect(!isDegenerate("!!!!!!abcde"))
    }

    // MARK: - Rule (b): token repetition

    @Test("the same token six times in a row is degenerate",
          arguments: ["the the the the the the", "The, the, THE, the. the the", "date date date date date date date"])
    func tokenRunIsDegenerate(_ s: String) {
        guard case .degenerate(let reason) = CaptionTextQuality.verdict(s) else {
            Issue.record("expected degenerate: \(s)"); return
        }
        #expect(reason.contains("repeated"), "rule (p) or (b) named: \(reason)")
    }

    @Test("five in a row, or six not in a row, is usable")
    func tokenRunBoundary() {
        #expect(!isDegenerate("the the the the the end"))
        #expect(!isDegenerate("the cat the dog the man the end the hat the"))
    }

    // MARK: - Rule (p): periodic loops (reviewer round, GH #402)

    @Test("a periodic loop of a short unit is degenerate, whatever its characters",
          arguments: [String(repeating: "!", count: 100_000) + "ab",
                      "1991-1991-1991-1991-1991-1991-1991", "19911991199119911991199119911991",
                      "abababababababababababab", "!a!b!a!b!a!b!a!b!a!b!a!b", "hahahahahaha",
                      "12341234123412341234", "the the the the the"])
    func periodicLoopIsDegenerate(_ s: String) {
        #expect(isDegenerate(s), "usable: \(s.prefix(40))… (\(s.count) chars)")
    }

    @Test("legitimate OCR / burn-in strings stay usable under every rule",
          arguments: ["11-11-11 11:11", "12/25/1999", "JUN 21 1991", "'97", "MISSISSIPPI", "REC", "SP",
                      "AM 10:30", "00:00:00", "00:00:00:00", "1991", "N/A", "none", "no date visible",
                      "Donaudampfschifffahrtsgesellschaftskapitän", "יום הולדת שמח", "一九九一年六月二十一日",
                      "12:00:00 AM 1/1/2000", "SP 0:12:34"])
    func legitIsUsable(_ s: String) {
        #expect(CaptionTextQuality.verdict(s) == .usable, "refused: \(s)")
    }

    @Test("the period boundaries: 3 repeats, or a 9-character unit, is not a loop")
    func periodBoundaries() {
        #expect(!isDegenerate("abcabcabc"))                                    // 9 chars, unit 3 × 3
        #expect(isDegenerate("abcabcabcabc"))                                  // unit 3 × 4
        #expect(!isDegenerate("birthday!birthday!birthday!birthday!"))         // unit 9 > maxPeriod
    }

    @Test("channel words are the catalog's captions.kind values")
    func channelWords() {
        #expect(CaptionChannel.allCases.map(\.rawValue) == ["scene", "ocrDate", "ocrText"])
    }

    @Test("VideoRecord.usableOCRDates drops the junk and keeps order")
    func usableOCRDatesAccessor() {
        let r = VideoRecord()
        r.ocrDateCandidates = [SceneCaption(timestamp: 1, text: "!!!!!!!!!!!!"),
                               SceneCaption(timestamp: 2, text: "JUN 21 1991"),
                               SceneCaption(timestamp: 3, text: "1991-1991-1991-1991-1991")]
        #expect(r.usableOCRDates.map(\.text) == ["JUN 21 1991"])
        #expect(VideoRecord().usableOCRDates.isEmpty)
    }

    // MARK: - Rule (c): no letter or digit

    @Test("longer than 3 characters with no letter or digit is degenerate", arguments: ["?!?!", "....", "-- --", "~~~~", "()()"])
    func noAlnumIsDegenerate(_ s: String) {
        #expect(isDegenerate(s), "\(s)")
    }

    @Test("3 characters or fewer with no letter or digit stays usable (too little to judge)", arguments: ["!", "?", "--", "..."])
    func shortNoAlnumIsUsable(_ s: String) {
        #expect(!isDegenerate(s), "\(s)")
    }

    // MARK: - Legitimate answers

    @Test("legitimate short answers are usable",
          arguments: ["none", "NONE", "no date visible", "JUN 21 1991", "1991", "N/A", "unknown",
                      "MAR 14 1991 03:42PM", "12/25/88", "AM 10:42", "PLAY ▶", "9:41"])
    func shortAnswersAreUsable(_ s: String) {
        #expect(CaptionTextQuality.verdict(s) == .usable, "\(s)")
    }

    @Test("a long real caption is usable")
    func longCaptionIsUsable() {
        let s = "A man in a plaid shirt plays an acoustic guitar in a wood-panelled living room while two children sit on a brown sofa; a 1980s console television and a Christmas tree are visible behind them."
        #expect(CaptionTextQuality.verdict(s) == .usable)
    }

    @Test("a caption that is one long word is usable")
    func oneLongWordIsUsable() {
        #expect(CaptionTextQuality.verdict("Supercalifragilisticexpialidocious") == .usable)
        #expect(CaptionTextQuality.verdict("HAPPYBIRTHDAYGRANDMA1991") == .usable)
    }

    // MARK: - Unicode

    @Test("fullwidth exclamation runs and box-drawing runs are degenerate",
          arguments: ["！！！！", "！！！！！！！！！！！！", "━━━━━━━━━━", "═══════════", "││││││││││", "😀😀😀😀😀😀😀😀😀😀"])
    func unicodeRunsAreDegenerate(_ s: String) {
        #expect(isDegenerate(s), "\(s)")
    }

    @Test("non-Latin real text is usable")
    func nonLatinIsUsable() {
        #expect(!isDegenerate("一九九一年六月二十一日"))
        #expect(!isDegenerate("Привет, бабушка"))
        #expect(!isDegenerate("Café ☕ 1991"))
    }

    @Test("surrounding whitespace is ignored")
    func trims() {
        #expect(CaptionTextQuality.verdict("   JUN 21 1991 \n") == .usable)
        #expect(isDegenerate("   !!!!!!!!!!!   "))
    }

    // MARK: - partition / usable (the shared filter)

    @Test("partition keeps order and counts what it refused")
    func partitionKeepsOrder() {
        let caps = [
            SceneCaption(timestamp: 1, text: "!!!!!!!!!!!!"),
            SceneCaption(timestamp: 2, text: "JUN 21 1991"),
            SceneCaption(timestamp: 3, text: "the the the the the the"),
            SceneCaption(timestamp: 4, text: "none"),
        ]
        let (kept, refused) = CaptionTextQuality.partition(caps)
        #expect(kept.map(\.timestamp) == [2, 4])
        #expect(refused == 2)
        #expect(CaptionTextQuality.usable(caps) == kept)
        #expect(CaptionTextQuality.partition([]).refused == 0)
    }

    // MARK: - Isolation: poisoned input never traps

    @Test("poisoned input: control characters, lone combining marks, 1 MB of '!' and NULs")
    func poisonedInput() {
        #expect(isDegenerate("\u{0}\u{0}\u{0}\u{0}\u{0}"))
        // Lone combining marks fold into ONE grapheme cluster: too short to
        // judge, so usable — the point is that it does not trap.
        _ = CaptionTextQuality.verdict("\u{301}\u{301}\u{301}\u{301}")
        #expect(isDegenerate(String(repeating: "\u{301}!", count: 10)))
        #expect(isDegenerate(String(repeating: "!", count: 1_000_000)))
        #expect(!isDegenerate("1991\u{0}"))
    }

    // MARK: - Scale: 100k captions under a time budget

    @Test("scale: 100k mixed captions classified within 5 s, counts exact")
    func scale() {
        var caps: [SceneCaption] = []
        caps.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let text: String
            switch i % 4 {
            case 0: text = "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
            case 1: text = "JUN \(i % 28 + 1) 19\(i % 100)"
            case 2: text = "A family gathers around a table in a kitchen with a cake and candles, frame \(i)."
            default: text = "none"
            }
            caps.append(SceneCaption(timestamp: Double(i), text: text))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let (kept, refused) = CaptionTextQuality.partition(caps)
        let elapsed = clock.now - start
        #expect(refused == 25_000)
        #expect(kept.count == 75_000)
        #expect(elapsed < .seconds(5), "100k verdicts took \(elapsed)")
    }
}
