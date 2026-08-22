import AVFoundation
import Foundation
import Testing
@testable import VideoScan

/// Hallie reads aloud in the app: what she says, and which voice.
struct HallieSpeakerTests {
    @Test func sentencesStripTagsAndBreatheAtSentenceEnds() {
        let text = "There are 7 catalog items matching that [c1]. Donna is confirmed in 5 of them [c2]. One of them is Cape_1993.mov — confirmed person tag Donna [c3]."
        #expect(HallieSpeaker.sentences(text) == [
            "There are 7 catalog items matching that.",
            "Donna is confirmed in 5 of them.",
            "One of them is Cape_1993.mov, confirmed person tag Donna.",
        ])
        #expect(HallieSpeaker.sentences("").isEmpty)
        #expect(HallieSpeaker.sentences("Hello — I'm Hallie Mae.").first?.contains("—") == false)
    }

    @Test func nameSuffixesAreExpandedBeforeSentenceSplitting() {
        let text = "Richard Breen Jr. is Richard Breen Sr.'s son. ROBERT BREEN JR, is also listed."
        #expect(HallieSpeaker.spokenText(text) ==
                "Richard Breen Junior is Richard Breen Senior's son. ROBERT BREEN Junior, is also listed.")
        #expect(HallieSpeaker.sentences(text) == [
            "Richard Breen Junior is Richard Breen Senior's son.",
            "ROBERT BREEN Junior, is also listed.",
        ])
        #expect(HallieSpeaker.spokenText("The file Jr.mov is untouched.") ==
                "The file Jr.mov is untouched.")
    }

    @Test func premiumVoicesRankFirstAndNoveltyVoicesLast() {
        let voices = HallieSpeaker.englishVoices()
        guard voices.count >= 2 else { return }   // a bare CI box may have one voice
        let first = voices.first!, last = voices.last!
        #expect(HallieSpeaker.rank(first) >= HallieSpeaker.rank(last))
        let novelty = voices.filter { ["Fred", "Albert", "Zarvox", "Bells"].contains($0.name) }
        for v in novelty { #expect(HallieSpeaker.rank(v) < 0, Comment(rawValue: v.name)) }
        let premium = voices.filter { $0.quality == .premium }
        for v in premium { #expect(HallieSpeaker.rank(v) >= 30, Comment(rawValue: v.name)) }
    }

    @Test func theChosenVoiceWinsWhenInstalledAndSpeakingIsOnByDefault() {
        guard let defaults = UserDefaults(suiteName: "HallieSpeakerTests.\(UUID().uuidString)") else {
            Issue.record("Could not create isolated user defaults")
            return
        }
        #expect(HallieSpeaker.isEnabled(defaults), "seniors shouldn't have to find a switch to hear her")
        defaults.set(false, forKey: HallieSpeaker.enabledKey)
        #expect(!HallieSpeaker.isEnabled(defaults))
        if let some = HallieSpeaker.englishVoices().last {
            defaults.set(some.identifier, forKey: HallieSpeaker.voiceKey)
            #expect(HallieSpeaker.bestVoice(defaults)?.identifier == some.identifier)
        }
        defaults.set("com.apple.nonexistent.voice", forKey: HallieSpeaker.voiceKey)
        #expect(HallieSpeaker.bestVoice(defaults)?.identifier == HallieSpeaker.englishVoices().first?.identifier,
                "an uninstalled choice falls back to the best installed")
    }

    @Test func neuralVoiceIdentifiersAreStableAndDoNotMasqueradeAsAppleVoices() {
        #expect(HallieNeuralVoice.choices.map(\.id) == [
            "kokoro:af_heart", "kokoro:af_bella", "kokoro:af_sarah", "kokoro:bf_emma",
        ])
        #expect(HallieNeuralVoice.selected("kokoro:af_heart")?.modelName == "af_heart")
        #expect(HallieNeuralVoice.selected("com.apple.voice.premium.en-US.Ava") == nil)

        guard let defaults = UserDefaults(suiteName: "HallieSpeakerTests.\(UUID().uuidString)") else {
            Issue.record("Could not create isolated user defaults")
            return
        }
        defaults.set("kokoro:af_heart", forKey: HallieSpeaker.voiceKey)
        #expect(HallieSpeaker.bestVoice(defaults)?.identifier == HallieSpeaker.englishVoices().first?.identifier,
                "Apple speech remains the fallback when the neural helper is unavailable")
    }

    @Test func bellaAndRelaxedPaceAreDefaultsButExplicitChoicesWin() {
        guard let defaults = UserDefaults(suiteName: "HallieSpeakerTests.\(UUID().uuidString)") else {
            Issue.record("Could not create isolated user defaults")
            return
        }
        #expect(HallieSpeaker.selectedNeuralVoice(defaults)?.id == "kokoro:af_bella")
        #expect(abs(HallieSpeaker.speedFactor(defaults) - 0.88) < 0.0001)

        defaults.set("kokoro:af_heart", forKey: HallieSpeaker.voiceKey)
        defaults.set(0.92, forKey: HallieSpeaker.speedKey)
        #expect(HallieSpeaker.selectedNeuralVoice(defaults)?.id == "kokoro:af_heart")
        #expect(abs(HallieSpeaker.speedFactor(defaults) - 0.92) < 0.0001)

        defaults.set("", forKey: HallieSpeaker.voiceKey)
        defaults.set(0.01, forKey: HallieSpeaker.speedKey)
        #expect(HallieSpeaker.selectedNeuralVoice(defaults) == nil)
        #expect(abs(HallieSpeaker.speedFactor(defaults) - 0.88) < 0.0001)
    }
}
