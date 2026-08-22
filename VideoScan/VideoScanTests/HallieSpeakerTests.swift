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
        let defaults = UserDefaults(suiteName: "HallieSpeakerTests.\(UUID().uuidString)")!
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
}
