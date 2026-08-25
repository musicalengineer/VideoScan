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

    /// Family-specific spellings are transformed only in the private string
    /// sent to speech synthesis. Hallie's visible answer and catalog data are
    /// never rewritten. Add carefully heard corrections here as Rick audits
    /// Bella on real family names.
    nonisolated static let familyNamePronunciations: [(written: String, spoken: String)] = [
        ("Edith", "EE-dith"),
    ]

    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var neuralTask: Task<Void, Never>?
    private var neuralJob: HallieNeuralSpeechJob?
    /// Bella's WAV plays through an AVAudioEngine graph, not AVAudioPlayer
    /// (2026-08-25). With the Babyface at 512 frames / 44.1 kHz and nothing
    /// compiling, AVAudioPlayer still stammered while browsers were clean;
    /// the engine converts the 24 kHz mono file to the device format in
    /// software and feeds the HAL one steady stream, the way browsers do.
    private var neuralEngine: AVAudioEngine?
    private var neuralNode: AVAudioPlayerNode?
    private var neuralPlaybackID = UUID()
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

    /// Expand suffixes and audited family names before sentence splitting and
    /// speech synthesis. The caller's display string remains unchanged.
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
        for pronunciation in familyNamePronunciations {
            let name = NSRegularExpression.escapedPattern(for: pronunciation.written)
            spoken = spoken.replacingOccurrences(
                of: #"\b"# + name + #"\b"#,
                with: pronunciation.spoken,
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
            // Every road to the Apple voice is logged (Rick 8/25: "we need
            // to see why and when it falls back").
            let why = Self.selectedNeuralVoice() == nil
                ? "no neural voice selected (\(UserDefaults.standard.string(forKey: Self.voiceKey) ?? "default"))"
                : "neural voice not installed at \(HallieNeuralSpeech.installationDirectory.path)"
            appLog.write("[hallie-voice] using Apple speech — \(why)")
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
            var synthesizedAudioURL: URL?
            let started = Date()
            do {
                let audioURL = try await job.synthesize()
                synthesizedAudioURL = audioURL
                guard let self, generation == self.speechGeneration, !Task.isCancelled else {
                    HallieNeuralSpeech.removeTemporaryAudio(audioURL)
                    return
                }
                let file = try AVAudioFile(forReading: audioURL)
                let engine = AVAudioEngine()
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: file.processingFormat)
                // Raise the device buffer BEFORE the engine starts its
                // I/O cycle so the larger size applies from the first frame.
                let buffer = HallieOutputBuffer.ensureMinimum()
                engine.prepare()
                try engine.start()
                let playbackID = UUID()
                self.neuralPlaybackID = playbackID
                self.neuralAudioURL = audioURL
                self.neuralEngine = engine
                self.neuralNode = node
                self.neuralJob = nil
                node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.neuralPlaybackID == playbackID else { return }
                        self.finishNeuralPlayback()
                    }
                }
                node.play()
                let duration = Double(file.length) / file.processingFormat.sampleRate
                appLog.write(String(
                    format: "[hallie-voice] %@ synthesized %.1fs of %d Hz audio in %.1fs (%@); engine → %@; %@",
                    voice.displayName, duration, Int(file.processingFormat.sampleRate),
                    Date().timeIntervalSince(started),
                    HallieNeuralSpeech.supportsWarmWorker ? "warm worker" : "one-shot helper",
                    "\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz",
                    buffer))
            } catch {
                HallieNeuralSpeech.removeTemporaryAudio(synthesizedAudioURL)
                guard let self, generation == self.speechGeneration, !Task.isCancelled else { return }
                HallieNeuralSpeechDiagnostics.shared.recordFailure(error.localizedDescription)
                // In the app log, not just NSLog: live 8/25 the voice fell back
                // to Apple speech and nothing on disk said why.
                appLog.write("[hallie-voice] neural voice unavailable; using Apple speech — "
                             + "\(error.localizedDescription)")
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
        tearDownNeuralPlayback()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    private func tearDownNeuralPlayback() {
        neuralPlaybackID = UUID()   // orphan any in-flight completion
        neuralNode?.stop()
        neuralEngine?.stop()
        neuralNode = nil
        neuralEngine = nil
        HallieNeuralSpeech.removeTemporaryAudio(neuralAudioURL)
        neuralAudioURL = nil
    }

    /// Natural end of Bella's file (engine completion, data played back).
    private func finishNeuralPlayback() {
        tearDownNeuralPlayback()
        neuralTask = nil
        neuralJob = nil
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

