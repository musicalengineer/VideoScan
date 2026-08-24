// HallieConversationLog.swift
// Private, structured development transcript for Hallie's app and shell.

import Darwin
import Foundation

struct HallieTranscriptEvent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    enum Client: String, Codable, Sendable {
        case app
        case shell
    }

    enum Kind: String, Codable, Sendable {
        case user
        case assistant
        case system
        case error
    }

    struct MediaEvidence: Codable, Equatable, Sendable {
        let recordID: UUID
        let filename: String
        let fullPath: String
        let playbackSeconds: Double?
        let bases: [String]
    }

    struct KnowledgeEvidence: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let attribution: String?
        /// A CyberBrain-relative locator, never the source document itself.
        let locator: String?
    }

    let version: Int
    let timestamp: Date
    let sessionID: UUID
    /// Optional batch label (`--log-run-id`) used to isolate headless eval
    /// events from the app's concurrent development transcript.
    let runID: String?
    let eventID: UUID
    let sequence: UInt64
    let client: Client
    let kind: Kind
    let text: String
    let queryDescription: String?
    let basisLine: String?
    let responder: String?
    let model: String?
    let route: String?
    let outcome: String?
    let offeredActions: [String]
    let mediaEvidence: [MediaEvidence]
    let knowledgeEvidence: [KnowledgeEvidence]
    /// Deterministic text outline of rich cards, including GEDCOM IDs. The
    /// chat bubble stays friendly; the private QA log retains every factual
    /// name/date/place rendered beside it.
    let attachmentOutline: [String]?
    /// "template" | "model" — who phrased an assistant answer. Optional so
    /// older lines (and non-answer events) decode unchanged. When "model",
    /// `text` keeps the claim tags ("… [c1]") for traceability.
    let composedBy: String?

    init(
        timestamp: Date = Date(),
        sessionID: UUID,
        runID: String? = nil,
        eventID: UUID = UUID(),
        sequence: UInt64,
        client: Client,
        kind: Kind,
        text: String,
        queryDescription: String? = nil,
        basisLine: String? = nil,
        responder: String? = nil,
        model: String? = nil,
        route: String? = nil,
        outcome: String? = nil,
        offeredActions: [String] = [],
        mediaEvidence: [MediaEvidence] = [],
        knowledgeEvidence: [KnowledgeEvidence] = [],
        attachmentOutline: [String]? = nil,
        composedBy: String? = nil
    ) {
        self.version = Self.schemaVersion
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.runID = runID
        self.eventID = eventID
        self.sequence = sequence
        self.client = client
        self.kind = kind
        self.text = text
        self.queryDescription = queryDescription
        self.basisLine = basisLine
        self.responder = responder
        self.model = model
        self.route = route
        self.outcome = outcome
        self.offeredActions = offeredActions
        self.mediaEvidence = mediaEvidence
        self.knowledgeEvidence = knowledgeEvidence
        self.attachmentOutline = attachmentOutline
        self.composedBy = composedBy
    }
}

enum HallieTranscriptStoreError: Error, Equatable {
    case unsafeDirectory
    case cannotOpen(Int32)
    case unsafeFile
    case lockFailed(Int32)
    case eventTooLarge(Int)
    case writeFailed(Int32)
    case syncFailed(Int32)
}

/// The synchronous filesystem boundary is separately testable. Production
/// calls it only from HallieConversationRecorder's actor executor.
struct HallieTranscriptFileStore: Sendable {
    static let maximumEncodedEventBytes = 256 * 1_024

    let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    static func production() -> HallieTranscriptFileStore? {
        guard let library = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return HallieTranscriptFileStore(directoryURL: library
            .appendingPathComponent("Logs/VideoScan/Hallie", isDirectory: true))
    }

    func append(_ events: [HallieTranscriptEvent]) throws {
        guard !events.isEmpty else { return }
        try prepareDirectory()
        for group in Dictionary(grouping: events, by: dayString(for:)) {
            let ordered = group.value.sorted {
                if $0.sessionID == $1.sessionID, $0.sequence != $1.sequence {
                    return $0.sequence < $1.sequence
                }
                return $0.timestamp < $1.timestamp
            }
            try append(ordered, to: "hallie-conversation-\(group.key).jsonl")
        }
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directoryURL.path) {
            let values = try directoryURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw HallieTranscriptStoreError.unsafeDirectory
            }
        } else {
            try manager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        guard chmod(directoryURL.path, mode_t(0o700)) == 0 else {
            throw HallieTranscriptStoreError.unsafeDirectory
        }
    }

    private func append(_ events: [HallieTranscriptEvent], to filename: String) throws {
        let url = directoryURL.appendingPathComponent(filename, isDirectory: false)
        let descriptor = Darwin.open(
            (url.path as NSString).fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else {
            throw HallieTranscriptStoreError.cannotOpen(errno)
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw HallieTranscriptStoreError.unsafeFile
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw HallieTranscriptStoreError.lockFailed(errno)
        }
        defer { flock(descriptor, LOCK_UN) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for event in events {
            var line = try encoder.encode(event)
            line.append(0x0A)
            guard line.count <= Self.maximumEncodedEventBytes else {
                throw HallieTranscriptStoreError.eventTooLarge(line.count)
            }
            try writeAll(line, to: descriptor)
        }
        guard fsync(descriptor) == 0 else {
            throw HallieTranscriptStoreError.syncFailed(errno)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var address = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, address, remaining)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw HallieTranscriptStoreError.writeFailed(errno)
                }
                remaining -= count
                address = address.advanced(by: count)
            }
        }
    }

    private func dayString(for event: HallieTranscriptEvent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: event.timestamp)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

actor HallieConversationRecorder {
    static let shared = HallieConversationRecorder(
        store: HallieTranscriptFileStore.production())

    private let store: HallieTranscriptFileStore?

    init(store: HallieTranscriptFileStore?) {
        self.store = store
    }

    /// Logging is diagnostic and must never make a Hallie turn fail.
    func append(_ events: [HallieTranscriptEvent]) {
        guard let store else { return }
        do {
            try store.append(events)
        } catch {
            appLog.write("[HallieTranscript] append failed: \(error)")
        }
    }
}
