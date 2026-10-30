import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie private conversation log", .serialized)
struct HallieConversationLogTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_hallie_log_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root
    }

    private func event(
        date: Date = Date(timeIntervalSince1970: 1_786_838_400),
        sequence: UInt64 = 1,
        text: String = "Where was Donna?",
        sessionID: UUID = UUID()
    ) -> HallieTranscriptEvent {
        HallieTranscriptEvent(
            timestamp: date,
            sessionID: sessionID,
            eventID: UUID(),
            sequence: sequence,
            client: .app,
            kind: .user,
            text: text,
            model: "fixture-model")
    }

    @Test func appendsDecodableJSONLWithPrivatePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logDirectory = root.appendingPathComponent("Hallie")
        let store = HallieTranscriptFileStore(directoryURL: logDirectory)
        let sessionID = UUID()

        try store.append([
            event(sequence: 1, sessionID: sessionID),
            event(sequence: 2, text: "Cape Cod", sessionID: sessionID),
        ])

        let files = try FileManager.default.contentsOfDirectory(
            at: logDirectory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let lines = try String(contentsOf: files[0], encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(
            HallieTranscriptEvent.self, from: Data($0.utf8)) }
        #expect(decoded.map(\.sequence) == [1, 2])
        #expect(decoded.map(\.text) == ["Where was Donna?", "Cape Cod"])
        #expect(decoded.allSatisfy { $0.attachmentOutline == nil })

        let directoryMode = try FileManager.default.attributesOfItem(
            atPath: logDirectory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: files[0].path)[.posixPermissions] as? NSNumber
        #expect(directoryMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    @Test func rotatesByUTCDate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let first = Date(timeIntervalSince1970: 1_786_838_399)
        let second = Date(timeIntervalSince1970: 1_786_838_400)

        try store.append([
            event(date: first, sequence: 1),
            event(date: second, sequence: 2),
        ])

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .sorted()
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.hasPrefix("hallie-conversation-") })
        #expect(names.allSatisfy { $0.hasSuffix(".jsonl") })
    }

    /// The day key names log files already on disk, so its output is
    /// pinned exactly: UTC midnight boundaries, a leap day, before the
    /// epoch, zero padding. (The calendar behind it was hoisted out of the
    /// per-event path 2026-09-26; this is what keeps that refactor honest.)
    @Test func dayFileNamesArePinnedAtUTCBoundaries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let pins: [(TimeInterval, String)] = [
            (1_786_838_399, "2026-08-15"),   // 23:59:59Z
            (1_786_838_400, "2026-08-16"),   // 00:00:00Z
            (951_782_400, "2000-02-29"),     // leap day
            (-1, "1969-12-31"),              // before the epoch
            (4_102_444_799, "2099-12-31"),
        ]
        for (seconds, day) in pins {
            #expect(HallieTranscriptFileStore.utcDayString(Date(timeIntervalSince1970: seconds)) == day)
        }
        try store.append(pins.enumerated().map { event(date: Date(timeIntervalSince1970: $0.element.0), sequence: UInt64($0.offset + 1)) })
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(names == pins.map { "hallie-conversation-\($0.1).jsonl" }.sorted())
    }

    /// Agreement with an independent UTC formatter across 5,000 instants
    /// spread over two centuries — any drift in the shared calendar shows.
    @Test func dayStringAgreesWithAnIndependentUTCFormatter() {
        let reference = ISO8601DateFormatter()
        reference.timeZone = TimeZone(identifier: "UTC")
        reference.formatOptions = [.withFullDate]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let date = Date(timeIntervalSince1970: .random(in: -2_208_988_800...4_102_444_799, using: &generator))
            #expect(HallieTranscriptFileStore.utcDayString(date) == reference.string(from: date), "\(date)")
        }
    }

    @Test func refusesSymlinkedLogDirectoryWithoutTouchingDestination() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside,
                                                withIntermediateDirectories: false)
        let link = root.appendingPathComponent("Hallie")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: outside)
        let store = HallieTranscriptFileStore(directoryURL: link)

        #expect(throws: HallieTranscriptStoreError.unsafeDirectory) {
            try store.append([event()])
        }
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: outside.path).isEmpty)
    }

    @Test func rejectsUnboundedMessageBeforeWritingIt() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)

        #expect(throws: (any Error).self) {
            try store.append([event(text: String(
                repeating: "x",
                count: HallieTranscriptFileStore.maximumEncodedEventBytes))])
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey])
        #expect(files.count == 1)
        #expect(try files[0].resourceValues(forKeys: [.fileSizeKey]).fileSize == 0)
    }

    // A transcript search carried every hit with every basis string —
    // 461 KB, then 1.1 MB — and the whole turn was refused, so the eval
    // graded eight questions as "produced no matched turn" (2026-09-01).
    @Test func oversizedEvidenceIsTrimmedRatherThanDroppingTheTurn() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let evidence = (1...3_000).map { index in
            HallieTranscriptEvent.MediaEvidence(
                recordID: UUID(), filename: "clip-\(index).mov",
                fullPath: "/Volumes/Archive/clip-\(index).mov", playbackSeconds: 12.5,
                bases: (1...6).map { "transcript hit \($0): " + String(repeating: "word ", count: 40) })
        }
        let event = HallieTranscriptEvent(
            sessionID: UUID(), eventID: UUID(), sequence: 3, client: .shell,
            kind: .assistant, text: "35 videos: 22 where someone says “school”.",
            queryDescription: "presence: says school", route: "presence",
            outcome: "answered", mediaEvidence: evidence)

        try store.append([event])

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first)
        let line = try #require(String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HallieTranscriptEvent.self, from: Data(line.utf8))
        #expect(decoded.text == event.text)
        #expect(decoded.outcome == "answered")
        #expect(decoded.mediaEvidence.count == HallieTranscriptEvent.boundedEvidenceItems)
        #expect(decoded.mediaEvidence[0].bases.count == HallieTranscriptEvent.boundedBasesPerItem)
        #expect(decoded.queryDescription?.contains("evidence trimmed for the log: 3000 media") == true)
        #expect(line.utf8.count <= HallieTranscriptFileStore.maximumEncodedEventBytes)
    }

    @Test func evidenceTooLargeEvenWhenTrimmedIsStrippedNotDropped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let excerpt = String(repeating: "spoken word ", count: 3_000)   // ~36 KB per basis
        let evidence = (1...40).map { index in
            HallieTranscriptEvent.MediaEvidence(
                recordID: UUID(), filename: "clip-\(index).mov",
                fullPath: "/Volumes/Archive/clip-\(index).mov", playbackSeconds: nil,
                bases: [excerpt, excerpt, excerpt])
        }
        let event = HallieTranscriptEvent(
            sessionID: UUID(), eventID: UUID(), sequence: 3, client: .shell,
            kind: .assistant, text: "15 videos where someone says “westford house”.",
            route: "presence", outcome: "answered", mediaEvidence: evidence)

        try store.append([event])

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first)
        let line = try #require(String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(HallieTranscriptEvent.self, from: Data(line.utf8))
        #expect(decoded.text == event.text)
        #expect(decoded.mediaEvidence.isEmpty)
        #expect(decoded.queryDescription?.contains("evidence stripped for the log: 40 media") == true)
    }

    @Test func thousandEventBatchStaysBounded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let events = (1...1_000).map {
            event(sequence: UInt64($0), text: "turn \($0)")
        }

        let clock = ContinuousClock()
        let elapsed = try clock.measure { try store.append(events) }

        // 2 s on a quiet machine; ×1.5 only when a Debug battery has the
        // machine busy (2.99 s on the M5 under full-battery load), ×3 on GitHub.
        let ceiling = PerformanceLane.loadAwareDebugCeiling(.seconds(2))
        #expect(elapsed < ceiling, "1,000-event append took \(elapsed), ceiling \(ceiling) (\(PerformanceLane.loadDescription()))")
        let file = try #require(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first)
        let lineCount = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").count
        #expect(lineCount == 1_000)
    }

    @Test func concurrentAppAndShellStyleAppendsNeverInterleaveJSON() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 1...32 {
                group.addTask {
                    try store.append([
                        event(sequence: UInt64(index), text: "writer \(index)"),
                    ])
                }
            }
            try await group.waitForAll()
        }

        let file = try #require(FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil).first)
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 32)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try lines.map { try decoder.decode(
            HallieTranscriptEvent.self, from: Data($0.utf8)) }
        #expect(Set(decoded.map(\.sequence)) == Set((1...32).map(UInt64.init)))
    }

    // PER-TURN LATENCY (BACKLOG "Hallie benchmark 2026-10-28 follow-ups" #2).
    // Timestamps are whole seconds, so the harness could not report a median
    // or p90 per question. The shell now stamps each assistant/error event
    // with the milliseconds since its user turn, from a monotonic clock.

    private func shellSession() -> HallieShellCLI.Session {
        HallieShellCLI.Session(
            records: [], profiles: [], graph: nil, cyberBrain: nil,
            speakers: .init(ownerName: "Rick Breen", archivistName: "Hallie Mae"),
            model: "fixture-model", runID: "latency-run")
    }

    @Test func shellAnswerCarriesMillisecondsSinceItsUserTurn() {
        var state = shellSession()
        let start = ContinuousClock.now
        let user = HallieShellCLI.transcriptEvent(
            kind: .user, text: "how many videos from 1991", now: start, state: &state)
        let first = HallieShellCLI.transcriptEvent(
            kind: .assistant, text: "I have 148 videos from 1991.",
            now: start.advanced(by: .milliseconds(1_234)), state: &state)
        // A split question logs one assistant event per clause; each carries
        // the time since the ONE user turn, so the last clause is the turn's.
        let second = HallieShellCLI.transcriptEvent(
            kind: .error, text: "Something went wrong.",
            now: start.advanced(by: .milliseconds(2_500)), state: &state)

        #expect(user.latencyMs == nil)
        #expect(first.latencyMs == 1_234)
        #expect(second.latencyMs == 2_500)
    }

    @Test func shellEventWithoutAUserTurnHasNoLatency() {
        var state = shellSession()
        let system = HallieShellCLI.transcriptEvent(
            kind: .system, text: ":reset", state: &state)
        let orphan = HallieShellCLI.transcriptEvent(
            kind: .assistant, text: "Hello, Rick.", state: &state)
        #expect(system.latencyMs == nil)
        #expect(orphan.latencyMs == nil)
    }

    @Test func latencySurvivesTheLogAndOldLinesDecodeWithoutIt() throws {
        let event = HallieTranscriptEvent(
            sessionID: UUID(), sequence: 2, client: .shell, kind: .assistant,
            text: "Answered.", latencyMs: 87)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let line = try #require(String(data: try encoder.encode(event), encoding: .utf8))
        #expect(line.contains("\"latencyMs\":87"))
        #expect(event.boundedForLog().latencyMs == 87)
        #expect(event.strippedForLog().latencyMs == 87)

        // A line written before this field existed still decodes.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any])
        object.removeValue(forKey: "latencyMs")
        let old = try decoder.decode(HallieTranscriptEvent.self,
                                     from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.latencyMs == nil)
        #expect(old.text == "Answered.")
    }
}
