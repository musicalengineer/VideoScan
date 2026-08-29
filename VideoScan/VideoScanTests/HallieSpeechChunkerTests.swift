import Foundation
import Testing
@testable import VideoScan

/// Kokoro dies past 510 phoneme tokens per utterance (live 2026-08-26, a
/// ~600-character list of great-great-grandfathers). Every chunk Hallie
/// hands the helper must fit with room to spare, and no cut may land
/// inside a name or a number.
struct HallieSpeechChunkerTests {
    private static let lineageSentence =
        "Richard Breen's great-great-grandfathers are Patrick Breen, through his father Richard H. Breen Senior and grandfather Thomas Breen; Michael Sullivan, through his mother Mary Sullivan Breen and her father John Sullivan; William Dwyer, through Thomas Breen's wife Catherine Dwyer Breen and her father James Dwyer; and Daniel Murphy, through Mary Sullivan's mother Ellen Murphy Sullivan and her father Cornelius Murphy."

    /// A synthetic answer of at least `characters` characters, built from
    /// sentence-shaped lineage prose so the sentence splitter has work to do.
    private static func lineageAnswer(characters: Int) -> String {
        var out = ""
        var generation = 2
        while out.count < characters {
            out += "Richard Breen's great-great-grandfather number \(generation) is Patrick Breen, through his father Richard H. Breen Senior, born in 1838, and grandfather Thomas Breen, born 1861. "
            generation += 1
        }
        return out
    }

    private static func chunks(_ text: String, budget: Int = HallieSpeechChunker.defaultBudget) -> [String] {
        HallieSpeechChunker.chunks(sentences: HallieSpeaker.sentences(text), budget: budget)
    }

    @Test func tokenEstimateChargesDigitsForTheirSpokenWords() {
        #expect(HallieSpeechChunker.estimatedTokens("abc def") == 7)
        #expect(HallieSpeechChunker.estimatedTokens("1938") == 16)
        #expect(HallieSpeechChunker.estimatedTokens("") == 0)
        #expect(HallieSpeechChunker.defaultBudget < HallieSpeechChunker.kokoroMaxTokens)
    }

    @Test func emptyAndWhitespaceProduceNoChunks() {
        #expect(HallieSpeechChunker.chunks(sentences: []).isEmpty)
        #expect(HallieSpeechChunker.chunks(sentences: ["", "   ", "\n"]).isEmpty)
        #expect(Self.chunks("").isEmpty)
        #expect(Self.chunks("   \n  ").isEmpty)
    }

    @Test func shortAnswersStayWhole() {
        let text = "Donna is confirmed in 5 of them. One of them is Cape_1993.mov."
        #expect(Self.chunks(text) == [text])
    }

    @Test func sentencesMergeGreedilyUpToTheBudget() {
        let sentences = ["Alpha one.", "Beta two.", "Gamma three.", "Delta four."]
        let chunks = HallieSpeechChunker.chunks(sentences: sentences, budget: 23)
        #expect(chunks == ["Alpha one. Beta two.", "Gamma three.", "Delta four."])
        for chunk in chunks { #expect(HallieSpeechChunker.estimatedTokens(chunk) <= 23) }
        // Nothing is lost or reordered.
        #expect(chunks.joined(separator: " ") == sentences.joined(separator: " "))
    }

    @Test func oneLongSentenceSplitsAtClauseBoundariesFirst() {
        let chunks = HallieSpeechChunker.fit(Self.lineageSentence, budget: 160)
        #expect(chunks.count >= 3)
        for chunk in chunks {
            #expect(HallieSpeechChunker.estimatedTokens(chunk) <= 160, "over budget: \(chunk)")
            // Clause cuts keep their punctuation and never leave a dangling space.
            #expect(chunk == chunk.trimmingCharacters(in: .whitespaces))
        }
        // Reassembly (modulo the separator spaces we dropped) is the original.
        #expect(chunks.joined(separator: " ") == Self.lineageSentence)
        // A semicolon boundary was used, so a chunk ends with ";".
        #expect(chunks.contains { $0.hasSuffix(";") })
    }

    @Test func halvingNeverCutsInsideANameOrANumber() {
        // No clause punctuation at all: forced to halve at a space.
        let text = "Then Richard H. Breen Senior met Mary Sullivan Breen near Cape Cod on June 4 1961 with 1200 guests present"
        let (head, tail) = HallieSpeechChunker.halve(text)
        #expect(tail != nil)
        #expect(head + " " + (tail ?? "") == text)
        let names = ["Richard H. Breen Senior", "Mary Sullivan Breen", "Cape Cod", "June 4 1961", "1200 guests"]
        for name in names {
            #expect(head.contains(name) || (tail ?? "").contains(name), "split inside \(name): \(head) | \(tail ?? "")")
        }
        // A sentence that is nothing but a name still halves somewhere rather than failing…
        let allName = "Richard H. Breen Senior Mary Sullivan Breen"
        #expect(HallieSpeechChunker.halve(allName).1 != nil)
        // …and a single word cannot be halved.
        #expect(HallieSpeechChunker.halve("Supercalifragilistic").1 == nil)
    }

    @Test func fitDegradesToHalvingWhenClausesAreStillTooLong() {
        let words = Array(repeating: "Patrick Breen", count: 40).joined(separator: " and ")
        let chunks = HallieSpeechChunker.fit(words, budget: 120)
        #expect(chunks.count >= 6)
        for chunk in chunks {
            #expect(HallieSpeechChunker.estimatedTokens(chunk) <= 120)
            #expect(!chunk.hasPrefix("Breen"), "a name was cut: \(chunk)")
        }
        #expect(chunks.joined(separator: " ") == words)
    }

    @Test func liveSixHundredCharacterAnswerFitsInTwoToFourChunks() {
        let text = Self.lineageAnswer(characters: 600)
        let chunks = Self.chunks(text)
        // Each fixture sentence is ~200 estimated tokens against a 320
        // budget, so whole sentences need one chunk apiece (4). The earlier
        // 2–3 rested on the speaker splitting "Richard H. Breen" at the
        // initial (fixed 2026-08-29, live miss #10); a name is never cut.
        #expect((2...4).contains(chunks.count), "\(chunks.count) chunks")
        for chunk in chunks {
            #expect(HallieSpeechChunker.estimatedTokens(chunk) <= HallieSpeechChunker.defaultBudget)
            #expect(!chunk.hasPrefix("Breen"), "a name was cut: \(chunk)")
            #expect(!chunk.hasSuffix("Richard H."), "a name was cut: \(chunk)")
        }
    }

    @Test func fiveThousandCharacterLineageAnswerNeverExceedsKokorosCap() {
        let text = Self.lineageAnswer(characters: 5_000)
        let chunks = Self.chunks(text)
        #expect(chunks.count >= 12)
        var total = 0
        for chunk in chunks {
            let estimate = HallieSpeechChunker.estimatedTokens(chunk)
            #expect(estimate <= HallieSpeechChunker.defaultBudget)
            #expect(estimate < HallieSpeechChunker.kokoroMaxTokens)
            #expect(!chunk.isEmpty)
            total += chunk.count
        }
        // Only the joining spaces are dropped; every character is spoken once.
        let spoken = HallieSpeaker.sentences(text).joined(separator: " ")
        #expect(abs(total + chunks.count - 1 - spoken.count) <= 0)
    }

    @Test func dateHeavyAnswersChunkShorterThanProse() {
        let dates = Array(repeating: "Thomas Breen was born in 1838, married in 1861, and died in 1912.", count: 12).joined(separator: " ")
        let chunks = Self.chunks(dates)
        // 12 × 66 chars = ~800 chars of prose would be ~3 chunks; digits make it more.
        #expect(chunks.count >= 4)
        for chunk in chunks {
            #expect(HallieSpeechChunker.estimatedTokens(chunk) <= HallieSpeechChunker.defaultBudget)
            #expect(chunk.count < 260, "date-heavy chunk too long for Kokoro (measured cap 300–350 chars): \(chunk.count)")
        }
    }

    @Test func tokenOverflowIsRecognisedFromEitherHelperMode() {
        struct Plain: Error {}
        #expect(HallieSpeaker.isTokenOverflow(HallieNeuralSpeech.Failure.synthesis(
            5, "Swift/ErrorType.swift:254: Fatal error: Error raised at top level: KokoroSwift.KokoroTTS.KokoroTTSError.tooManyTokens")))
        #expect(HallieSpeaker.isTokenOverflow(HallieNeuralSpeech.Failure.synthesis(
            -1, "The operation couldn’t be completed. (KokoroSwift.KokoroTTS.KokoroTTSError error 0.)")))
        #expect(!HallieSpeaker.isTokenOverflow(HallieNeuralSpeech.Failure.synthesis(9, "fixture helper exited under load")))
        #expect(!HallieSpeaker.isTokenOverflow(Plain()))
    }
}

/// Runs the real helper when Rick's Kokoro install is present; otherwise skipped.
struct HallieSpeechChunkerLiveTests {
    @Test(.enabled(if: HallieNeuralSpeech.isInstalled, "Kokoro helper not installed in ~/Library/Application Support/VideoScan/HallieKokoro"))
    func installedKokoroSynthesizesEveryChunkOfALongLineageAnswer() async throws {
        var text = ""
        while text.count < 600 {
            text += "Richard Breen's great-great-grandfather is Patrick Breen, through his father Richard H. Breen Senior, born in 1838, and grandfather Thomas Breen. "
        }
        let chunks = HallieSpeechChunker.chunks(sentences: HallieSpeaker.sentences(text))
        #expect(chunks.count >= 2)
        // The unchunked answer is exactly what died live on 2026-08-26.
        #expect(HallieSpeechChunker.estimatedTokens(text) > HallieSpeechChunker.kokoroMaxTokens)

        let voice = HallieNeuralVoice.choices[1]   // Bella
        for chunk in chunks {
            let job = HallieNeuralSpeech.job(for: chunk, voice: voice, speed: 0.88)
            let url = try await job.synthesize()
            defer { HallieNeuralSpeech.removeTemporaryAudio(url) }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            #expect(size > 44, "empty WAV for chunk: \(chunk.prefix(40))…")
        }
    }
}
