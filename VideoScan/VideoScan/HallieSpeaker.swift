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
    /// sent to speech synthesis (HalliePronunciationLexicon: shipped table +
    /// user-editable pronunciations.json). Hallie's visible answer and
    /// catalog data are never rewritten.

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
    private var neuralAudioURLs: [URL] = []
    private var neuralChunksScheduled = 0
    private var neuralChunksPlayed = 0
    private var neuralSynthesisFinished = false
    /// Chunks the Apple voice reads once Bella's queued audio has played,
    /// set only when a later chunk failed after playback had begun.
    private var appleContinuation: [String] = []
    private var speechGeneration: UInt = 0

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Text → utterances (pure, tested)

    /// Sentences to speak: claim tags removed, bracketed basis noise
    /// removed, split at sentence ends so each gets its own breath.
    nonisolated static func sentences(
        _ text: String,
        lexicon: HalliePronunciationLexicon = .shipped
    ) -> [String] {
        var cleaned = spokenText(text, lexicon: lexicon)
        cleaned = cleaned.replacingOccurrences(of: #"\[c\d+\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        cleaned = cleaned.replacingOccurrences(of: " — ", with: ", ")
        // A sentence ends at . ! ? … followed by a space or the end of the
        // line — so "Cape_1993.mov" and "Richard H. Breen" stay whole. The
        // initial / abbreviation rule is the verifier's (one splitter
        // policy for prose and speech; live 2026-08-29).
        let pieces = cleaned.components(separatedBy: .newlines).flatMap { line -> [String] in
            var out: [String] = []
            var current = ""
            let chars = Array(line)
            for (index, character) in chars.enumerated() {
                current.append(character)
                let next = index + 1 < chars.count ? chars[index + 1] : " "
                if ".!?…".contains(character), next == " " || next == "\t",
                   !(character == "." && HallieCompositionVerifier.endsWithAbbreviation(String(current.dropLast()))) {
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
    nonisolated static func spokenText(
        _ text: String,
        lexicon: HalliePronunciationLexicon = .shipped
    ) -> String {
        var spoken = text
        let suffixes = [(#"\bJr\.?(?=[\s,;:!?)]|['’]s\b|$)"#, "Junior"),
                        (#"\bSr\.?(?=[\s,;:!?)]|['’]s\b|$)"#, "Senior")]
        for (pattern, replacement) in suffixes {
            spoken = spoken.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive])
        }
        return lexicon.apply(to: spoken).spoken
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

    /// `subject` is who the text is about (a CyberBrain id or name), so a
    /// name two records respell differently is said the way THAT person's
    /// record says (HalliePronunciationLexicon.personLayer).
    func speak(_ text: String, about subject: String? = nil) {
        stop()
        // Re-read per utterance: the file is tiny, the CyberBrain records are
        // mtime-cached, and an edit should be heard on the very next answer,
        // no restart. Layers: CyberBrain people → pronunciations.json → shipped.
        let lexicon = HalliePronunciationLexicon.resolved(subject: subject)
        let sentences = Self.sentences(text, lexicon: lexicon)
        guard !sentences.isEmpty else { return }
        let fired = lexicon.apply(to: Self.spokenText(text, lexicon: HalliePronunciationLexicon(entries: []))).fired
        if !fired.isEmpty {
            appLog.write("[hallie-voice] pronunciations: " + lexicon.logLine(for: fired))
        }

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

    /// Kokoro caps one utterance at 510 phoneme tokens, so the answer is
    /// chunked first (HallieSpeechChunker) and each chunk is synthesized in
    /// turn and queued on the same player node — AVAudioPlayerNode plays
    /// scheduled files back-to-back with no gap, so Bella starts on chunk 1
    /// while chunks 2..n are still being made. A chunk that still overflows
    /// is halved at a space outside any name and retried; only a chunk that
    /// fails after that hands the rest of the answer to the Apple voice.
    private func speakNeural(_ text: String, voice: HallieNeuralVoice, speed: Float) {
        isSpeaking = true
        let generation = speechGeneration
        var chunks = HallieSpeechChunker.chunks(sentences: Self.sentences(text))
        neuralTask = Task { [weak self] in
            let started = Date()
            var engine: AVAudioEngine?
            var node: AVAudioPlayerNode?
            var bufferNote = ""
            var playbackID = UUID()
            var totalFrames: Int64 = 0
            var sampleRate = 0.0
            var index = 0
            var retries = 0
            let abandoned = { @MainActor [weak self] () -> Bool in
                guard let self else { return true }
                return generation != self.speechGeneration || Task.isCancelled
            }
            do {
                while index < chunks.count {
                    let chunk = chunks[index]
                    guard let self, !abandoned() else { return }
                    let job = HallieNeuralSpeech.job(for: chunk, voice: voice, speed: speed)
                    self.neuralJob = job
                    let audioURL: URL
                    do {
                        audioURL = try await job.synthesize()
                    } catch let error where Self.isTokenOverflow(error) {
                        let (head, tail) = HallieSpeechChunker.halve(chunk)
                        guard let tail else { throw error }
                        retries += 1
                        appLog.write("[hallie-voice] chunk \(index + 1) of \(chunks.count) "
                                     + "(\(chunk.count) chars, ~\(HallieSpeechChunker.estimatedTokens(chunk)) est. tokens) "
                                     + "overflowed Kokoro's \(HallieSpeechChunker.kokoroMaxTokens)-token cap; split and retrying")
                        chunks.replaceSubrange(index...index, with: [head, tail])
                        continue
                    }
                    guard !abandoned() else {
                        HallieNeuralSpeech.removeTemporaryAudio(audioURL)
                        return
                    }
                    self.neuralAudioURLs.append(audioURL)
                    let file = try AVAudioFile(forReading: audioURL)
                    if engine == nil {
                        let newEngine = AVAudioEngine()
                        let newNode = AVAudioPlayerNode()
                        newEngine.attach(newNode)
                        newEngine.connect(newNode, to: newEngine.mainMixerNode, format: file.processingFormat)
                        // Raise the device buffer BEFORE the engine starts its
                        // I/O cycle so the larger size applies from the first frame.
                        bufferNote = HallieOutputBuffer.ensureMinimum()
                        newEngine.prepare()
                        try newEngine.start()
                        playbackID = UUID()
                        self.neuralPlaybackID = playbackID
                        self.neuralEngine = newEngine
                        self.neuralNode = newNode
                        self.neuralChunksScheduled = 0
                        self.neuralChunksPlayed = 0
                        self.neuralSynthesisFinished = false
                        engine = newEngine
                        node = newNode
                    }
                    guard let node else { return }
                    self.neuralChunksScheduled += 1
                    let id = playbackID
                    node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.neuralPlaybackID == id else { return }
                            self.neuralChunksPlayed += 1
                            if self.neuralSynthesisFinished,
                               self.neuralChunksPlayed >= self.neuralChunksScheduled {
                                self.finishNeuralPlayback()
                            }
                        }
                    }
                    if !node.isPlaying { node.play() }
                    totalFrames += file.length
                    sampleRate = file.processingFormat.sampleRate
                    index += 1
                }
                guard let self, let engine, !abandoned() else { return }
                self.neuralJob = nil
                self.neuralSynthesisFinished = true
                if self.neuralChunksPlayed >= self.neuralChunksScheduled { self.finishNeuralPlayback() }
                let duration = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
                appLog.write(String(
                    format: "[hallie-voice] %@ synthesized %.1fs of %d Hz audio in %.1fs (%@; %d chunk%@%@); engine → %@; %@",
                    voice.displayName, duration, Int(sampleRate),
                    Date().timeIntervalSince(started),
                    HallieNeuralSpeech.supportsWarmWorker ? "warm worker" : "one-shot helper",
                    chunks.count, chunks.count == 1 ? "" : "s",
                    retries > 0 ? ", \(retries) split on overflow" : "",
                    "\(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz",
                    bufferNote))
            } catch {
                guard let self, !abandoned() else { return }
                HallieNeuralSpeechDiagnostics.shared.recordFailure(error.localizedDescription)
                let failed = index < chunks.count ? chunks[index] : ""
                // In the app log, not just NSLog: live 8/25 the voice fell back
                // to Apple speech and nothing on disk said why.
                appLog.write("[hallie-voice] neural voice unavailable; using Apple speech — "
                             + "\(error.localizedDescription) "
                             + "[chunk \(index + 1) of \(chunks.count), \(failed.count) chars, "
                             + "~\(HallieSpeechChunker.estimatedTokens(failed)) est. tokens]")
                NSLog("VideoScan: Hallie neural voice unavailable; using Apple speech: %@",
                      error.localizedDescription)
                self.neuralTask = nil
                self.neuralJob = nil
                let remaining = Array(chunks[index...])
                if engine != nil, !self.neuralSynthesisFinished {
                    // Bella is mid-answer: let what is queued finish, then Apple
                    // reads the rest rather than cutting her off mid-sentence.
                    self.neuralSynthesisFinished = true
                    self.appleContinuation = remaining
                    if self.neuralChunksPlayed >= self.neuralChunksScheduled { self.finishNeuralPlayback() }
                } else {
                    self.speakWithApple(remaining.isEmpty ? Self.sentences(text) : remaining)
                }
            }
        }
    }

    /// KokoroSwift's `tooManyTokens`, as it reaches us from either helper
    /// mode: the one-shot helper's stderr names the case; a worker-mode
    /// helper built before the helper learned to describe its errors
    /// reports the enum's bare Foundation description ("error 0").
    nonisolated static func isTokenOverflow(_ error: Error) -> Bool {
        let detail = error.localizedDescription
        return detail.contains("tooManyTokens") || detail.contains("KokoroTTSError error 0")
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
        for url in neuralAudioURLs { HallieNeuralSpeech.removeTemporaryAudio(url) }
        neuralAudioURLs = []
        neuralChunksScheduled = 0
        neuralChunksPlayed = 0
        neuralSynthesisFinished = false
        appleContinuation = []
    }

    /// Natural end of Bella's audio (every scheduled chunk played back).
    private func finishNeuralPlayback() {
        let continuation = appleContinuation
        tearDownNeuralPlayback()
        neuralTask = nil
        neuralJob = nil
        if continuation.isEmpty {
            isSpeaking = false
        } else {
            speakWithApple(continuation)
        }
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

