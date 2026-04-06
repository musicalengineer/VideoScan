import Foundation
import SwiftUI
import Combine

// MARK: - Stream Type

enum StreamType: String {
    case videoAndAudio = "Video+Audio"
    case videoOnly     = "Video only"
    case audioOnly     = "Audio only"
    case noStreams      = "No A/V streams"
    case ffprobeFailed = "ffprobe failed"

    var needsCorrelation: Bool {
        self == .videoOnly || self == .audioOnly
    }
}

// MARK: - Pair Confidence

enum PairConfidence: String, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    var color: Color {
        switch self {
        case .high:   return Color.green.opacity(0.22)
        case .medium: return Color.orange.opacity(0.22)
        case .low:    return Color.clear
        }
    }

    var textColor: Color {
        switch self {
        case .high:   return .green
        case .medium: return .orange
        case .low:    return .secondary
        }
    }

    static func < (lhs: PairConfidence, rhs: PairConfidence) -> Bool {
        let order: [PairConfidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Video Record

class VideoRecord: Identifiable {
    let id = UUID()

    var filename: String = ""
    var ext: String = ""
    var streamTypeRaw: String = ""
    var size: String = ""
    var sizeBytes: Int64 = 0
    var duration: String = ""
    var durationSeconds: Double = 0
    var dateCreated: String = ""
    var dateModified: String = ""
    var dateCreatedRaw: Date?
    var dateModifiedRaw: Date?
    var container: String = ""
    var videoCodec: String = ""
    var resolution: String = ""
    var frameRate: String = ""
    var videoBitrate: String = ""
    var totalBitrate: String = ""
    var colorSpace: String = ""
    var bitDepth: String = ""
    var scanType: String = ""
    var audioCodec: String = ""
    var audioChannels: String = ""
    var audioSampleRate: String = ""
    var timecode: String = ""
    var tapeName: String = ""
    var isPlayable: String = ""
    var partialMD5: String = ""
    var fullPath: String = ""
    var directory: String = ""
    var notes: String = ""
    var wasCacheHit: Bool = false   // transient — not persisted to SQLite cache

    var pairedWith: VideoRecord?
    var pairGroupID: UUID?
    var pairConfidence: PairConfidence?

    var streamType: StreamType {
        StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed
    }

    var rowColor: Color {
        if let conf = pairConfidence {
            return conf.color
        }
        switch streamType {
        case .videoOnly:     return Color.yellow.opacity(0.25)
        case .audioOnly:     return Color.yellow.opacity(0.25)
        case .noStreams:     return Color.gray.opacity(0.15)
        case .ffprobeFailed: return Color.red.opacity(0.15)
        default:             return Color.clear
        }
    }
}

// MARK: - Catalog Scan Target

enum CatalogTargetStatus: String {
    case idle        = "Idle"
    case discovering = "Discovering…"
    case scanning    = "Scanning"
    case paused      = "Paused"
    case complete    = "Complete"
    case stopped     = "Stopped"
    case error       = "Error"

    var isIdle: Bool { self == .idle }
    var isActive: Bool { self == .scanning || self == .paused || self == .discovering }
    var isPaused: Bool { self == .paused }

    var color: Color {
        switch self {
        case .idle:        return .secondary.opacity(0.4)
        case .discovering: return .yellow
        case .scanning:    return .green
        case .paused:      return .yellow
        case .complete:    return .blue
        case .stopped:     return .orange
        case .error:       return .red
        }
    }
}

@MainActor
final class CatalogScanTarget: ObservableObject, Identifiable {
    let id = UUID()
    @Published var searchPath: String
    @Published var status: CatalogTargetStatus = .idle
    @Published var filesFound: Int = 0
    @Published var filesScanned: Int = 0
    @Published var elapsedSecs: Double = 0.0

    var scanTask: Task<Void, Never>?
    let pauseGate = PauseGate()
    private var taskStarted: Date?
    private var timerTask: Task<Void, Never>?

    init(searchPath: String) { self.searchPath = searchPath }

    func startElapsedTimer() {
        taskStarted = Date()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run { [weak self] in
                    guard let self, let s = self.taskStarted else { return }
                    self.elapsedSecs = Date().timeIntervalSince(s)
                }
            }
        }
    }

    func stopElapsedTimer() {
        timerTask?.cancel()
        if let s = taskStarted { elapsedSecs = Date().timeIntervalSince(s) }
    }

    func reset() {
        scanTask?.cancel(); timerTask?.cancel()
        Task { await pauseGate.resume() }
        status = .idle; filesFound = 0; filesScanned = 0; elapsedSecs = 0
        scanTask = nil; timerTask = nil; taskStarted = nil
    }
}

// MARK: - Dashboard Types

enum ScanPhase: String {
    case idle        = "Idle"
    case discovering = "Discovering"
    case probing     = "Probing"
    case writingCSV  = "Writing CSV"
    case complete    = "Complete"
}

struct VolumeProgress: Identifiable {
    let id = UUID()
    let rootPath: String
    var volumeName: String
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var cacheHits: Int = 0
    var errors: Int = 0
    var isWalking: Bool = true
}

struct ThroughputSample {
    let timestamp: Date
    let filesPerSecond: Double
}

// MARK: - ffprobe JSON Models

struct FFProbeOutput: Codable {
    let streams: [FFStream]?
    let format: FFFormat?
}

struct FFStream: Codable {
    let codec_type: String?
    let codec_name: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let bit_rate: String?
    let color_space: String?
    let bits_per_raw_sample: String?
    let field_order: String?
    let channels: Int?
    let sample_rate: String?
    let tags: [String: String]?
}

struct FFFormat: Codable {
    let format_name: String?
    let format_long_name: String?
    let duration: String?
    let size: String?
    let bit_rate: String?
    let tags: [String: String]?
}
