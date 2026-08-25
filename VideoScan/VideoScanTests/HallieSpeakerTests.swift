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

    @Test func familyPronunciationsChangeSpeechButNotDisplayedText() {
        let displayed = "Edith Breen appears beside Meredith Breen."
        #expect(HallieSpeaker.spokenText(displayed) ==
                "EE-dith Breen appears beside Meredith Breen.")
        #expect(displayed == "Edith Breen appears beside Meredith Breen.")
        #expect(HallieSpeaker.familyNamePronunciations.contains {
            $0.written == "Edith" && $0.spoken == "EE-dith"
        })
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

@Suite(.serialized)
struct HallieNeuralSpeechWorkerTests {
    private func fakeInstallation(
        failFirstSpawn: Bool = false,
        failEverySpawn: Bool = false,
        malformedAudio: Bool = false,
        delayedRequestID: String? = nil
    ) throws -> (directory: URL, spawnFile: URL, requestFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieNeuralWorkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent(HallieNeuralSpeech.executableName)
        let spawnFile = directory.appendingPathComponent("spawns")
        let requestFile = directory.appendingPathComponent("requests")
        let firstFailure = failFirstSpawn ? """
            if [ "$spawn_number" -eq 1 ]; then
                IFS= read -r ignored
                echo "fixture helper exited under load" >&2
                exit 9
            fi
            """ : ""
        let everyFailure = failEverySpawn ? """
            IFS= read -r ignored
            echo "final fixture crash reason" >&2
            exit 23
            """ : ""
        let audioBase64 = malformedAudio
            ? "UklGRiYAAABXQVZFWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWA=="
            : "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YQIAAAAAAA=="
        let requestDelay = delayedRequestID.map { requestID in
            """
            if [ "$request_id" = "\(requestID)" ]; then
                /bin/sleep 2
            fi
            """
        } ?? ""
        let script = """
            #!/bin/sh
            printf 'x' >> '\(spawnFile.path)'
            spawn_number=$(wc -c < '\(spawnFile.path)' | tr -d ' ')
            \(everyFailure)
            \(firstFailure)
            while IFS= read -r line; do
                request_id=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\\1/')
                output_dir=$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"outputDirectory":"([^"]+)".*/\\1/')
                printf '%s\n' "$request_id" >> '\(requestFile.path)'
                \(requestDelay)
                /bin/mkdir -p "$output_dir"
                printf '%s' '\(audioBase64)' \
                    | /usr/bin/base64 -D > "$output_dir/hallie-af_bella.wav"
                printf '@hallie-response@{"id":"%s","ok":true}\n' "$request_id"
            done
            """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (directory, spawnFile, requestFile)
    }

    @Test func warmWorkerIsReusedThenLeavesMemoryAfterIdleTimeout() async throws {
        let fixture = try fakeInstallation()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let diagnostics = HallieNeuralSpeechDiagnostics()
        let worker = HallieNeuralSpeechWorker(
            installationDirectory: fixture.directory,
            idleTimeoutSeconds: 0.10,
            requestTimeoutSeconds: 1,
            diagnostics: diagnostics)
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))

        let first = try await worker.synthesize(
            requestID: "one", text: "Hello", voice: voice, speed: 0.88)
        let second = try await worker.synthesize(
            requestID: "two", text: "Still there?", voice: voice, speed: 0.88)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(await worker.totalSpawns == 1)

        HallieNeuralSpeech.removeTemporaryAudio(first)
        HallieNeuralSpeech.removeTemporaryAudio(second)
        try await Task.sleep(for: .milliseconds(250))

        let third = try await worker.synthesize(
            requestID: "three", text: "Back again", voice: voice, speed: 0.88)
        #expect(await worker.totalSpawns == 2)
        HallieNeuralSpeech.removeTemporaryAudio(third)
        await worker.shutdown()
    }

    @Test func workerCrashRespawnsOnceAndRetainsTheReason() async throws {
        let fixture = try fakeInstallation(failFirstSpawn: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let diagnostics = HallieNeuralSpeechDiagnostics()
        let worker = HallieNeuralSpeechWorker(
            installationDirectory: fixture.directory,
            idleTimeoutSeconds: 10,
            requestTimeoutSeconds: 1,
            diagnostics: diagnostics)
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))

        let output = try await worker.synthesize(
            requestID: "retry", text: "Please retry", voice: voice, speed: 0.88)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(await worker.totalSpawns == 2)
        #expect(diagnostics.snapshot().retryRecoveryCount == 1)
        #expect(diagnostics.snapshot().failureCount == 0)

        HallieNeuralSpeech.removeTemporaryAudio(output)
        await worker.shutdown()
    }

    @Test func diagnosticsRetainOnlyBoundedFailureDetail() {
        let diagnostics = HallieNeuralSpeechDiagnostics()
        diagnostics.recordFailure(String(repeating: "x", count: 4_096))
        let snapshot = diagnostics.snapshot()
        #expect(snapshot.failureCount == 1)
        #expect(snapshot.lastFailure?.count == 1_024)
    }

    @Test func doubleCrashRetainsFinalStderrAndExitStatus() async throws {
        let fixture = try fakeInstallation(failEverySpawn: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let worker = HallieNeuralSpeechWorker(
            installationDirectory: fixture.directory,
            idleTimeoutSeconds: 10,
            requestTimeoutSeconds: 1,
            diagnostics: HallieNeuralSpeechDiagnostics())
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))

        do {
            _ = try await worker.synthesize(
                requestID: "double-crash", text: "Fail", voice: voice, speed: 0.88)
            Issue.record("a helper that crashed twice unexpectedly succeeded")
        } catch let HallieNeuralSpeech.Failure.synthesis(status, detail) {
            #expect(status == 23)
            #expect(detail.contains("final fixture crash reason"))
        } catch {
            Issue.record("unexpected double-crash error: \(error)")
        }
        #expect(await worker.totalSpawns == 2)
        await worker.shutdown()
    }

    @Test func malformedWAVIsRetriedAndRejected() async throws {
        let fixture = try fakeInstallation(malformedAudio: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let worker = HallieNeuralSpeechWorker(
            installationDirectory: fixture.directory,
            idleTimeoutSeconds: 10,
            requestTimeoutSeconds: 1,
            diagnostics: HallieNeuralSpeechDiagnostics())
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))

        await #expect(throws: HallieNeuralSpeech.Failure.self) {
            _ = try await worker.synthesize(
                requestID: "bad-wave", text: "Fail", voice: voice, speed: 0.88)
        }
        #expect(await worker.totalSpawns == 2)
        await worker.shutdown()
    }

    @Test func supersededRequestCannotTearDownTheNewWorker() async throws {
        let fixture = try fakeInstallation(delayedRequestID: "old")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let worker = HallieNeuralSpeechWorker(
            installationDirectory: fixture.directory,
            idleTimeoutSeconds: 10,
            requestTimeoutSeconds: 5,
            diagnostics: HallieNeuralSpeechDiagnostics())
        let voice = try #require(HallieNeuralVoice.selected("kokoro:af_bella"))

        let old = Task {
            try await worker.synthesize(
                requestID: "old", text: "Old", voice: voice, speed: 0.88)
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.requestFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let newest = try await worker.synthesize(
            requestID: "new", text: "New", voice: voice, speed: 0.88)
        #expect(FileManager.default.fileExists(atPath: newest.path))
        do {
            _ = try await old.value
            Issue.record("the superseded request unexpectedly completed")
        } catch is CancellationError {
            // Expected: latest utterance wins.
        } catch {
            Issue.record("unexpected superseded-request error: \(error)")
        }

        HallieNeuralSpeech.removeTemporaryAudio(newest)
        await worker.shutdown()
    }

    @Test func capabilityMarkerDistinguishesLegacyAndWarmHelpers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HallieCapabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!HallieNeuralSpeech.supportsWarmWorker(in: directory))
        try Data().write(to: directory.appendingPathComponent(HallieNeuralSpeech.workerCapabilityName))
        #expect(HallieNeuralSpeech.supportsWarmWorker(in: directory))
    }
}
