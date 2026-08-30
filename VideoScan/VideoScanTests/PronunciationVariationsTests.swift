import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// The variations generator behind the picker (Rick 2026-08-29): the
/// candidate matrix for the family's names, cue ordering, de-duplication,
/// the rhyme path through a gold-lexicon fixture, scale, and — when the
/// Kokoro helper is installed — that the Latta variants synthesize to
/// distinct audio.
@Suite("Pronunciation variations")
struct PronunciationVariationsTests {

    /// No gold lexicon: the respelling rules alone decide.
    private static let noGold = MisakiGoldLexicon(url: nil)

    private func phonemes(_ name: String, hint: HalliePronunciationHint? = nil, respellings: [String] = []) -> [String] {
        PronunciationVariations.candidates(for: name, hint: hint, respellings: respellings, gold: Self.noGold).map(\.phonemes)
    }

    private func respellings(_ name: String, hint: HalliePronunciationHint? = nil, respellings: [String] = []) -> [String] {
        PronunciationVariations.candidates(for: name, hint: hint, respellings: respellings, gold: Self.noGold).map(\.respelling)
    }

    // MARK: - 1. The matrix

    @Test func lattaWithNoHintOffersRicksFiveInOrder() {
        // The order in the task brief, then the long-a reading.
        #expect(respellings("Latta") == ["LAT-uh", "LAD-uh", "LAH-tah", "la-TAH", "LAT-ah", "LAY-tuh"])
        #expect(phonemes("Latta") == ["lˈætə", "lˈæɾə", "lˈɑtɑ", "lətˈɑ", "lˈætɑ", "lˈAtə"])
        let first = PronunciationVariations.candidates(for: "Latta", gold: Self.noGold)[1]
        #expect(first.label == "short a, stress on the 1st, flapped t, like ladder")
        #expect(first.spokenForm(word: "Latta") == "[Latta](/lˈæɾə/)")
    }

    @Test func lattaWithShortAOnLaLeadsWithLatUhThenLadder() {
        let hint = HalliePronunciationHint.vowel(letter: "a", length: .short, syllable: "La")
        let candidates = PronunciationVariations.candidates(for: "Latta", hint: hint, gold: Self.noGold)
        #expect(candidates.map(\.respelling) == ["LAT-uh", "LAD-uh", "LAT-ah", "LAH-tah", "la-TAH", "LAY-tuh"])
        #expect(candidates[0].label == "from your hint (short a on La)")
        #expect(candidates[1].label == "from your hint (short a on La), flapped t, like ladder")
    }

    @Test func lattaWithSyllablesHintLeadsWithTheHintFilesReadingDisplayedFromItsPhonemes() {
        let hint = HalliePronunciationHint.syllables([.init(text: "La", exemplar: "Lag"), .init(text: "Tah", exemplar: nil)])
        // Without the gold lexicon the "as in Lag" exemplar cannot be looked
        // up; the hint file's "LA-tah" reading (lˈætɑ) still comes first,
        // shown as it sounds.
        #expect(respellings("Latta", hint: hint).prefix(3) == ["LAT-ah", "LAT-uh", "LAD-uh"])
        #expect(phonemes("Latta", hint: hint).first == "lˈætɑ")
    }

    @Test func lattaWithSyllablesHintAndGoldPinsTheShortAFromLag() throws {
        let gold = try Self.goldFixture(["lag": "lˈæɡ", "data": "dˈAɾə", "gill": "ɡˈɪl"])
        let hint = HalliePronunciationHint.syllables([.init(text: "La", exemplar: "Lag"), .init(text: "Tah", exemplar: nil)])
        let candidates = PronunciationVariations.candidates(for: "Latta", hint: hint, gold: gold)
        #expect(candidates.map(\.phonemes).prefix(3) == ["lˈætɑ", "lˈætə", "lˈæɾə"])
        #expect(candidates.prefix(3).allSatisfy { $0.label.hasPrefix("from your hint (La (as in Lag) and Tah)") })
    }

    @Test func stressHintMovesTheStressToTheFront() {
        #expect(respellings("Latta", hint: .stress(.second)).first == "la-TAH")
        #expect(phonemes("Latta", hint: .stress(.second)).first == "lətˈɑ")
        #expect(respellings("Edith", hint: .stress(.first)).first == "EE-dith")
    }

    @Test func rhymesWithUsesTheGoldTail() throws {
        let gold = try Self.goldFixture(["data": "dˈAɾə"])
        let candidates = PronunciationVariations.candidates(for: "Latta", hint: .rhymes(with: "data"), gold: gold)
        #expect(candidates.first == .init(phonemes: "lˈAɾə", respelling: "LAY-duh", label: "rhymes with data"))
        // Without the gold lexicon the rhyme cannot be read: the systematic list alone.
        #expect(respellings("Latta", hint: .rhymes(with: "data")).first == "LAT-uh")
    }

    @Test func ricksOwnRespellingsComeFirstExactly() {
        let candidates = PronunciationVariations.candidates(for: "Latta", respellings: ["Lah-Tah", "Latt-Uh"], gold: Self.noGold)
        #expect(candidates[0] == .init(phonemes: "lˈɑtɑ", respelling: "LAH-tah", label: "as you spelled it"))
        #expect(candidates[1] == .init(phonemes: "lˈætə", respelling: "LATT-uh", label: "as you spelled it"))
        // The systematic LAT-uh (same phonemes) is folded into his spelling.
        #expect(candidates.filter { $0.phonemes == "lˈætə" }.count == 1)
        #expect(candidates.map(\.respelling).dropFirst(2).first == "LAD-uh")
    }

    @Test func mcGillOffersMuhGillFirstAndMickGill() {
        let list = respellings("McGill")
        #expect(list.first == "muh-GILL")
        #expect(list.contains("MICK-gill"))
        #expect(phonemes("McGill").first == "məɡˈɪl")
        #expect(phonemes("McGill").contains("mˈɪkɡɪl"))
        // The prefix never carries the stress by default; Mick/Mack are labelled.
        let mick = PronunciationVariations.candidates(for: "McGill", gold: Self.noGold).first { $0.respelling == "mick-GILL" }
        #expect(mick?.label == "short i, stress on the 2nd, Mick")
    }

    @Test func edithLeadsWithEeDith() {
        #expect(respellings("Edith").prefix(3) == ["EE-dith", "EH-dith", "uh-DITH"])
        #expect(phonemes("Edith").first == "ˈidɪθ")
    }

    @Test func namesWithNoHintGetThreeToSixDistinctReadings() {
        for name in ["Donna", "Timmy", "Breen", "Foley", "Harding", "Ronan", "Hendour", "Nathaniel", "Bethiah", "McCarthy", "McLaughlin"] {
            let list = PronunciationVariations.candidates(for: name, gold: Self.noGold)
            #expect((3...6).contains(list.count), "\(name): \(list.map(\.respelling))")
            #expect(Set(list.map(\.phonemes)).count == list.count, "\(name) repeats a sound")
            #expect(list.allSatisfy { !$0.respelling.isEmpty && !$0.label.isEmpty })
            #expect(list.allSatisfy { $0.phonemes.contains("ˈ") }, "\(name): every candidate carries primary stress")
        }
        #expect(respellings("Breen") == ["BREEN", "BRAYN", "BREHN"])
        #expect(phonemes("McCarthy").first == "məkˈɑɹθi")
        // A doubled consonant across the boundary is one sound.
        #expect(phonemes("McCarthy").contains("mˈɪkəɹθi"))
    }

    @Test func unreadableNamesGiveNothingRatherThanAGuess() {
        #expect(PronunciationVariations.candidates(for: "Xqz", gold: Self.noGold).isEmpty)
        #expect(PronunciationVariations.candidates(for: "", gold: Self.noGold).isEmpty)
        #expect(PronunciationVariations.candidates(for: "Zoë", gold: Self.noGold).isEmpty)
        // A typed respelling still yields a candidate for an unreadable name.
        let typed = PronunciationVariations.candidates(for: "Xqz", respellings: ["EKS-kyoo-zee"], gold: Self.noGold)
        #expect(typed.count == 1 && typed[0].label == "as you spelled it")
    }

    // MARK: - 2. Dedup, paging, limits

    @Test func allCandidatesAreDistinctAndBoundedAndPaged() {
        let all = PronunciationVariations.allCandidates(for: "Latta", gold: Self.noGold)
        #expect(Set(all.map(\.phonemes)).count == all.count)
        #expect(all.count <= PronunciationVariations.maximum)
        #expect(all.count == 11)
        #expect(PronunciationVariations.candidates(for: "Latta", limit: 2, gold: Self.noGold).count == 2)
        #expect(PronunciationVariations.candidates(for: "Latta", limit: 0, gold: Self.noGold).isEmpty)
        // The page after the last is empty (the picker asks for a spelling).
        #expect(HalliePronunciationPicker.makeOffer(word: "Latta", round: 0, gold: Self.noGold)?.candidates.count == 5)
        #expect(HalliePronunciationPicker.makeOffer(word: "Latta", round: 2, gold: Self.noGold)?.candidates.count == 1)
        #expect(HalliePronunciationPicker.makeOffer(word: "Latta", round: 3, gold: Self.noGold) == nil)
    }

    @Test func respellingFromPhonemesReadsTheWayItSounds() {
        #expect(PronunciationVariations.respelling(fromPhonemes: "lˈAɾə") == "LAY-duh")
        #expect(PronunciationVariations.respelling(fromPhonemes: "lˈætɑ") == "LAT-ah")
        #expect(PronunciationVariations.respelling(fromPhonemes: "məɡˈɪl") == "muh-GILL")
        #expect(PronunciationVariations.respelling(fromPhonemes: "ˈælən") == "AL-uhn")
        #expect(PronunciationVariations.respelling(fromPhonemes: "ˈidɪθ") == "EE-dith")
        #expect(PronunciationVariations.normalisedRespelling("Lah-Tah") == "LAH-tah")
        #expect(PronunciationVariations.normalisedRespelling("MahGill") == "MAH-gill")
        #expect(PronunciationVariations.normalisedRespelling("muh-GILL") == "muh-GILL")
    }

    // MARK: - 3. Scale

    @Test func twoThousandNamesGenerateInUnderASecond() {
        let syllables = ["ka", "ren", "mo", "lin", "ta", "bur", "ney", "shaw", "del", "ric", "mc", "ley", "don", "va"]
        var names: [String] = []
        var seed: UInt64 = 7
        for _ in 0..<2_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let count = Int(seed >> 60) % 3 + 1
            var name = ""
            for part in 0..<count {
                let index = Int((seed >> (8 * UInt64(part))) & 0xFF) % syllables.count
                name += syllables[index]
            }
            names.append(name.prefix(1).uppercased() + name.dropFirst())
        }
        let started = Date()
        var total = 0
        for name in names { total += PronunciationVariations.candidates(for: name, gold: Self.noGold).count }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "2,000 names took \(elapsed)s")
        #expect(total > 2_000)
    }

    // MARK: - 4. Kokoro smoke (skipped without the helper)

    /// The five Latta variants Rick will hear are five different waveforms
    /// on the installed helper — the override syntax is live, and the flap
    /// (ɾ) and stress marks are honoured. Output goes to the temp dir only.
    @Test(.enabled(if: HallieNeuralSpeech.isInstalled))
    func lattaVariantsSynthesizeToDistinctAudio() async throws {
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))
        let candidates = PronunciationVariations.candidates(for: "Latta", limit: 5, gold: Self.noGold)
        var fingerprints: Set<Data> = []
        for candidate in candidates {
            let job = HallieNeuralSpeechJob(text: candidate.spokenForm(word: "Latta") + ".", voice: voice, speed: 0.88)
            let url = try await job.synthesize()
            defer { HallieNeuralSpeech.removeTemporaryAudio(url) }
            let data = try Data(contentsOf: url)
            #expect(data.count > 20_000, "\(candidate.respelling) produced \(data.count) bytes")
            fingerprints.insert(data)
        }
        #expect(fingerprints.count == candidates.count, "two variants rendered identically")
    }

    // MARK: - Fixtures

    /// A tiny us_gold.json in the temp dir (never the real bundle).
    private static func goldFixture(_ table: [String: String]) throws -> MisakiGoldLexicon {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("us_gold-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: table).write(to: url)
        return MisakiGoldLexicon(url: url)
    }
}
