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

struct HallieSpeechPace: Identifiable, Equatable, Sendable {
    let factor: Double
    let displayName: String

    var id: Double { factor }

    static let choices = [
        HallieSpeechPace(factor: 0.84, displayName: "Unhurried — 84%"),
        HallieSpeechPace(factor: 0.88, displayName: "Relaxed — 88%"),
        HallieSpeechPace(factor: 0.92, displayName: "Natural — 92%"),
        HallieSpeechPace(factor: 1.00, displayName: "Standard — 100%"),
    ]
}

@MainActor
final class HallieSpeaker: NSObject, ObservableObject {
    static let shared = HallieSpeaker()

    nonisolated static let enabledKey = "archivist.speakAnswers"
    nonisolated static let voiceKey = "archivist.speakVoice"
    nonisolated static let speedKey = "archivist.speakSpeed"
    nonisolated static let defaultVoiceID = "kokoro:af_bella"
    nonisolated static let defaultSpeedFactor = 0.88
    nonisolated static let pitch: Float = 0.95

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var neuralTask: Task<Void, Never>?
    private var neuralJob: HallieNeuralSpeechJob?
    private var neuralPlayer: AVAudioPlayer?
    private var neuralAudioURL: URL?
    private var speechGeneration: UInt = 0

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Text → utterances (pure, tested)

    /// Sentences to speak: claim tags removed, bracketed basis noise
    /// removed, split at sentence ends so each gets its own breath.
    nonisolated static func sentences(_ text: String) -> [String] {
        var cleaned = spokenText(text)
        cleaned = cleaned.replacingOccurrences(of: #"\[c\d+\]"#, with: "", options: .regularExpression)
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

    /// Expand suffixes before sentence splitting and speech synthesis. This
    /// keeps "Richard Breen Jr." together and makes both Apple and Kokoro say
    /// "Junior" rather than guessing at the abbreviation.
    nonisolated static func spokenText(_ text: String) -> String {
        var spoken = text
        let suffixes = [(#"\bJr\.?(?=[\s,;:!?)]|['’]s\b|$)"#, "Junior"),
                        (#"\bSr\.?(?=[\s,;:!?)]|['’]s\b|$)"#, "Senior")]
        for (pattern, replacement) in suffixes {
            spoken = spoken.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive])
        }
        return spoken
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

    /// Bella is Hallie's default when no preference has ever been saved.
    /// An explicit empty value still means "Best installed Apple voice".
    nonisolated static func selectedNeuralVoice(
        _ defaults: UserDefaults = .standard
    ) -> HallieNeuralVoice? {
        let identifier = defaults.object(forKey: voiceKey) == nil
            ? defaultVoiceID
            : defaults.string(forKey: voiceKey)
        return HallieNeuralVoice.selected(identifier)
    }

    nonisolated static func speedFactor(_ defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: speedKey) != nil else {
            return Float(defaultSpeedFactor)
        }
        let stored = defaults.double(forKey: speedKey)
        guard (0.5...1.5).contains(stored) else { return Float(defaultSpeedFactor) }
        return Float(stored)
    }

    // MARK: - Speaking

    func speak(_ text: String) {
        stop()
        let sentences = Self.sentences(text)
        guard !sentences.isEmpty else { return }

        if let voice = Self.selectedNeuralVoice(),
           HallieNeuralSpeech.isInstalled {
            speakNeural(
                sentences.joined(separator: " "),
                voice: voice,
                speed: Self.speedFactor())
        } else {
            speakWithApple(sentences)
        }
    }

    private func speakWithApple(_ sentences: [String]) {
        let voice = Self.bestVoice()
        for sentence in sentences {
            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Self.speedFactor()
            utterance.pitchMultiplier = Self.pitch
            utterance.postUtteranceDelay = 0.18
            synthesizer.speak(utterance)
        }
        isSpeaking = true
    }

    private func speakNeural(_ text: String, voice: HallieNeuralVoice, speed: Float) {
        isSpeaking = true
        let generation = speechGeneration
        let job = HallieNeuralSpeech.job(for: text, voice: voice, speed: speed)
        neuralJob = job
        neuralTask = Task { [weak self] in
            do {
                let audioURL = try await job.synthesize()
                guard let self, generation == self.speechGeneration, !Task.isCancelled else {
                    HallieNeuralSpeech.removeTemporaryAudio(audioURL)
                    return
                }
                let player = try AVAudioPlayer(contentsOf: audioURL)
                player.delegate = self
                player.prepareToPlay()
                self.neuralAudioURL = audioURL
                self.neuralPlayer = player
                self.neuralJob = nil
                if !player.play() {
                    throw HallieNeuralSpeech.Failure.missingOutput
                }
            } catch {
                guard let self, generation == self.speechGeneration, !Task.isCancelled else { return }
                NSLog("VideoScan: Hallie neural voice unavailable; using Apple speech: %@",
                      error.localizedDescription)
                self.neuralTask = nil
                self.neuralJob = nil
                self.speakWithApple(Self.sentences(text))
            }
        }
    }

    func stop() {
        speechGeneration &+= 1
        neuralTask?.cancel()
        neuralTask = nil
        neuralJob?.cancel()
        neuralJob = nil
        neuralPlayer?.stop()
        neuralPlayer = nil
        HallieNeuralSpeech.removeTemporaryAudio(neuralAudioURL)
        neuralAudioURL = nil
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

extension HallieSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.neuralPlayer else { return }
            self.neuralPlayer = nil
            self.neuralTask = nil
            self.neuralJob = nil
            HallieNeuralSpeech.removeTemporaryAudio(self.neuralAudioURL)
            self.neuralAudioURL = nil
            self.isSpeaking = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard player === self.neuralPlayer else { return }
            NSLog("VideoScan: Hallie neural audio playback failed: %@",
                  error?.localizedDescription ?? "unknown playback error")
            self.neuralPlayer = nil
            self.neuralTask = nil
            self.neuralJob = nil
            HallieNeuralSpeech.removeTemporaryAudio(self.neuralAudioURL)
            self.neuralAudioURL = nil
            self.isSpeaking = false
        }
    }
}
