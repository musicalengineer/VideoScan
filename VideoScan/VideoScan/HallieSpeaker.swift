// HallieSpeaker.swift
// Hallie reads her answers aloud in the app (Rick 2026-08-22: "if I use
// the app's Hallie directly in-app, there's no audio" — and, from the
// iPad demo, "a soft-spoken librarian, gentle but firm, a teeny bit
// slower"). On-device AVSpeechSynthesizer: the best installed English
// voice (Premium > Enhanced > default), an unhurried rate, a slightly
// lower pitch, one utterance per sentence so long answers breathe, claim
// tags stripped. Nothing leaves the Mac.
//
// Better voices: System Settings → Accessibility → Spoken Content →
// System Voice → Manage Voices… → download e.g. Ava, Zoe, Allison
// (Premium). The picker in Hallie's settings lists what is installed.

import AVFoundation
import Combine
import Foundation

@MainActor
final class HallieSpeaker: NSObject, ObservableObject {
    static let shared = HallieSpeaker()

    nonisolated static let enabledKey = "archivist.speakAnswers"
    nonisolated static let voiceKey = "archivist.speakVoice"
    /// 0.85 × the system default — "a teeny bit slower".
    nonisolated static let rateFactor: Float = 0.85
    nonisolated static let pitch: Float = 0.95

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Text → utterances (pure, tested)

    /// Sentences to speak: claim tags removed, bracketed basis noise
    /// removed, split at sentence ends so each gets its own breath.
    nonisolated static func sentences(_ text: String) -> [String] {
        var cleaned = text.replacingOccurrences(of: #"\[c\d+\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: " — ", with: ", ")
        // A sentence ends at . ! ? … followed by a space or the end of the
        // line — so "Cape_1993.mov" and "Richard H. Breen" stay whole.
        let pieces = cleaned.components(separatedBy: .newlines).flatMap { line -> [String] in
            var out: [String] = []
            var current = ""
            let chars = Array(line)
            for (index, character) in chars.enumerated() {
                current.append(character)
                let next = index + 1 < chars.count ? chars[index + 1] : " "
                if ".!?…".contains(character), next == " " || next == "\t",
                   !(character == "." && current.count >= 2 && current.dropLast().last?.isUppercase == true && current.count <= 3) {
                    out.append(current); current = ""
                }
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
        return pieces
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " .", with: ".") }
            .filter { $0.count > 1 }
    }

    /// Rank installed English voices: Premium, then Enhanced, then the
    /// default; a preferred-name list breaks ties (the softer voices
    /// first); novelty voices last.
    nonisolated static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        var score = 0
        switch voice.quality {
        case .premium: score += 30
        case .enhanced: score += 20
        default: break
        }
        let preferred = ["ava", "zoe", "allison", "samantha", "nicky", "joelle", "susan", "karen", "moira", "tessa", "evan", "nathan", "tom", "aaron"]
        let name = voice.name.lowercased()
        if let index = preferred.firstIndex(where: { name.hasPrefix($0) }) { score += 12 - index }
        if voice.language.lowercased() == "en-us" { score += 2 }
        let novelty = ["fred", "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos", "good news", "jester", "organ", "superstar", "trinoids", "whisper", "wobble", "zarvox", "junior", "ralph", "kathy", "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley"]
        if novelty.contains(where: { name.hasPrefix($0) }) { score -= 50 }
        return score
    }

    nonisolated static func englishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("en") }
            .sorted { rank($0) != rank($1) ? rank($0) > rank($1) : $0.name < $1.name }
    }

    nonisolated static func bestVoice(_ defaults: UserDefaults = .standard) -> AVSpeechSynthesisVoice? {
        let voices = englishVoices()
        if let chosen = defaults.string(forKey: voiceKey),
           let voice = voices.first(where: { $0.identifier == chosen }) {
            return voice
        }
        return voices.first
    }

    nonisolated static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        stop()
        let voice = Self.bestVoice()
        for sentence in Self.sentences(text) {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.rateFactor
            utterance.pitchMultiplier = Self.pitch
            utterance.postUtteranceDelay = 0.18
            synthesizer.speak(utterance)
        }
        isSpeaking = !Self.sentences(text).isEmpty
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    /// A short line so a newly chosen voice can be judged.
    func audition() {
        speak("Hello — I'm Hallie Mae. This is how I sound.")
    }
}

extension HallieSpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if !synthesizer.isSpeaking { self.isSpeaking = false }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
