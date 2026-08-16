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

    @Test func thousandEventBatchStaysBounded() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HallieTranscriptFileStore(directoryURL: root)
        let events = (1...1_000).map {
            event(sequence: UInt64($0), text: "turn \($0)")
        }

        let clock = ContinuousClock()
        let elapsed = try clock.measure { try store.append(events) }

        #expect(elapsed < .seconds(2))
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
}
