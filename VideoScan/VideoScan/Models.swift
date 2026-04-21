import Foundation
import SwiftUI
import Combine

// MARK: - Stream Type

enum StreamType: String, Codable {
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

enum PairConfidence: String, Codable, Comparable {
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

// MARK: - Duplicate Confidence

enum DuplicateConfidence: String, Codable, Comparable {
    case high   = "High"
    case medium = "Medium"
    case low    = "Low"

    var textColor: Color {
        switch self {
        case .high:   return .red
        case .medium: return .orange
        case .low:    return .yellow
        }
    }

    static func < (lhs: DuplicateConfidence, rhs: DuplicateConfidence) -> Bool {
        let order: [DuplicateConfidence] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

enum DuplicateDisposition: String, Codable {
    case none      = ""
    case keep      = "Keep"
    case review    = "Review"
    case extraCopy = "Extra copy"

    var textColor: Color {
        switch self {
        case .none:      return .secondary
        case .keep:      return .green
        case .review:    return .orange
        case .extraCopy: return .red
        }
    }
}

// MARK: - Video Record

class VideoRecord: Identifiable, Codable {
    var id: UUID = UUID()

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

    // Avid bin metadata (populated by cross-referencing .avb files)
    var avidClipName: String = ""
    var avidMobID: String = ""
    var avidMaterialUUID: String = ""
    var avidBinFile: String = ""
    var avidMobType: String = ""
    var avidMediaPath: String = ""     // original media path from Avid bin
    var avidTapeName: String = ""
    var avidEditRate: Double = 0
    var avidTracks: String = ""        // e.g. "V1, A1-A2"

    var hasAvidMetadata: Bool {
        !avidClipName.isEmpty || !avidMobID.isEmpty
    }

    var pairedWith: VideoRecord?
    /// Set during decode; CatalogStore resolves it to a real `pairedWith`
    /// reference after the entire array has been decoded.
    var pendingPairedWithID: UUID?
    var pairGroupID: UUID?
    var pairConfidence: PairConfidence?
    var duplicateGroupID: UUID?
    var duplicateConfidence: DuplicateConfidence?
    var duplicateDisposition: DuplicateDisposition = .none
    var duplicateReasons: String = ""
    var duplicateBestMatchFilename: String = ""
    var duplicateGroupCount: Int = 0

    /// Hostname of the machine that originally cataloged this record.
    /// Empty on records scanned locally; populated on import from another
    /// machine's exported catalog so the UI can show "from <host>".
    var sourceHost: String = ""

    var streamType: StreamType {
        StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed
    }

    // MARK: - Sort keys
    //
    // SwiftUI Table's `value:` parameter on TableColumn requires a KeyPath
    // whose value type conforms to `Comparable`. Date? and parsed strings
    // don't qualify directly, so these computed keys give the table a stable
    // numeric/Date sort field while the cell content keeps showing the
    // human-friendly string.

    /// Resolution sorted by total pixel count. Files with no resolution
    /// (audio-only, ffprobe failed) sort to the bottom.
    var pixelCount: Int {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Int(parts[1].trimmingCharacters(in: .whitespaces))
        else { return 0 }
        return w * h
    }

    /// Non-optional creation date for sorting; missing dates sort to the
    /// far past so descending order surfaces real dates first.
    var dateCreatedSortKey: Date { dateCreatedRaw ?? .distantPast }

    /// Same idea for modification date.
    var dateModifiedSortKey: Date { dateModifiedRaw ?? .distantPast }

    init() {}

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, filename, ext, streamTypeRaw, size, sizeBytes, duration, durationSeconds
        case dateCreated, dateModified, dateCreatedRaw, dateModifiedRaw
        case container, videoCodec, resolution, frameRate, videoBitrate, totalBitrate
        case colorSpace, bitDepth, scanType, audioCodec, audioChannels, audioSampleRate
        case timecode, tapeName, isPlayable, partialMD5, fullPath, directory, notes
        case avidClipName, avidMobID, avidMaterialUUID, avidBinFile, avidMobType
        case avidMediaPath, avidTapeName, avidEditRate, avidTracks
        case pairedWithID, pairGroupID, pairConfidence
        case duplicateGroupID, duplicateConfidence, duplicateDisposition
        case duplicateReasons, duplicateBestMatchFilename, duplicateGroupCount
        case sourceHost
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                          = try c.decodeIfPresent(UUID.self,                 forKey: .id) ?? UUID()
        filename                    = try c.decodeIfPresent(String.self,               forKey: .filename) ?? ""
        ext                         = try c.decodeIfPresent(String.self,               forKey: .ext) ?? ""
        streamTypeRaw               = try c.decodeIfPresent(String.self,               forKey: .streamTypeRaw) ?? ""
        size                        = try c.decodeIfPresent(String.self,               forKey: .size) ?? ""
        sizeBytes                   = try c.decodeIfPresent(Int64.self,                forKey: .sizeBytes) ?? 0
        duration                    = try c.decodeIfPresent(String.self,               forKey: .duration) ?? ""
        durationSeconds             = try c.decodeIfPresent(Double.self,               forKey: .durationSeconds) ?? 0
        dateCreated                 = try c.decodeIfPresent(String.self,               forKey: .dateCreated) ?? ""
        dateModified                = try c.decodeIfPresent(String.self,               forKey: .dateModified) ?? ""
        dateCreatedRaw              = try c.decodeIfPresent(Date.self,                 forKey: .dateCreatedRaw)
        dateModifiedRaw             = try c.decodeIfPresent(Date.self,                 forKey: .dateModifiedRaw)
        container                   = try c.decodeIfPresent(String.self,               forKey: .container) ?? ""
        videoCodec                  = try c.decodeIfPresent(String.self,               forKey: .videoCodec) ?? ""
        resolution                  = try c.decodeIfPresent(String.self,               forKey: .resolution) ?? ""
        frameRate                   = try c.decodeIfPresent(String.self,               forKey: .frameRate) ?? ""
        videoBitrate                = try c.decodeIfPresent(String.self,               forKey: .videoBitrate) ?? ""
        totalBitrate                = try c.decodeIfPresent(String.self,               forKey: .totalBitrate) ?? ""
        colorSpace                  = try c.decodeIfPresent(String.self,               forKey: .colorSpace) ?? ""
        bitDepth                    = try c.decodeIfPresent(String.self,               forKey: .bitDepth) ?? ""
        scanType                    = try c.decodeIfPresent(String.self,               forKey: .scanType) ?? ""
        audioCodec                  = try c.decodeIfPresent(String.self,               forKey: .audioCodec) ?? ""
        audioChannels               = try c.decodeIfPresent(String.self,               forKey: .audioChannels) ?? ""
        audioSampleRate             = try c.decodeIfPresent(String.self,               forKey: .audioSampleRate) ?? ""
        timecode                    = try c.decodeIfPresent(String.self,               forKey: .timecode) ?? ""
        tapeName                    = try c.decodeIfPresent(String.self,               forKey: .tapeName) ?? ""
        isPlayable                  = try c.decodeIfPresent(String.self,               forKey: .isPlayable) ?? ""
        partialMD5                  = try c.decodeIfPresent(String.self,               forKey: .partialMD5) ?? ""
        fullPath                    = try c.decodeIfPresent(String.self,               forKey: .fullPath) ?? ""
        directory                   = try c.decodeIfPresent(String.self,               forKey: .directory) ?? ""
        notes                       = try c.decodeIfPresent(String.self,               forKey: .notes) ?? ""
        avidClipName                = try c.decodeIfPresent(String.self,               forKey: .avidClipName) ?? ""
        avidMobID                   = try c.decodeIfPresent(String.self,               forKey: .avidMobID) ?? ""
        avidMaterialUUID            = try c.decodeIfPresent(String.self,               forKey: .avidMaterialUUID) ?? ""
        avidBinFile                 = try c.decodeIfPresent(String.self,               forKey: .avidBinFile) ?? ""
        avidMobType                 = try c.decodeIfPresent(String.self,               forKey: .avidMobType) ?? ""
        avidMediaPath               = try c.decodeIfPresent(String.self,               forKey: .avidMediaPath) ?? ""
        avidTapeName                = try c.decodeIfPresent(String.self,               forKey: .avidTapeName) ?? ""
        avidEditRate                = try c.decodeIfPresent(Double.self,               forKey: .avidEditRate) ?? 0
        avidTracks                  = try c.decodeIfPresent(String.self,               forKey: .avidTracks) ?? ""
        pendingPairedWithID         = try c.decodeIfPresent(UUID.self,                 forKey: .pairedWithID)
        pairGroupID                 = try c.decodeIfPresent(UUID.self,                 forKey: .pairGroupID)
        pairConfidence              = try c.decodeIfPresent(PairConfidence.self,       forKey: .pairConfidence)
        duplicateGroupID            = try c.decodeIfPresent(UUID.self,                 forKey: .duplicateGroupID)
        duplicateConfidence         = try c.decodeIfPresent(DuplicateConfidence.self,  forKey: .duplicateConfidence)
        duplicateDisposition        = try c.decodeIfPresent(DuplicateDisposition.self, forKey: .duplicateDisposition) ?? .none
        duplicateReasons            = try c.decodeIfPresent(String.self,               forKey: .duplicateReasons) ?? ""
        duplicateBestMatchFilename  = try c.decodeIfPresent(String.self,               forKey: .duplicateBestMatchFilename) ?? ""
        duplicateGroupCount         = try c.decodeIfPresent(Int.self,                  forKey: .duplicateGroupCount) ?? 0
        sourceHost                  = try c.decodeIfPresent(String.self,               forKey: .sourceHost) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                          forKey: .id)
        try c.encode(filename,                    forKey: .filename)
        try c.encode(ext,                         forKey: .ext)
        try c.encode(streamTypeRaw,               forKey: .streamTypeRaw)
        try c.encode(size,                        forKey: .size)
        try c.encode(sizeBytes,                   forKey: .sizeBytes)
        try c.encode(duration,                    forKey: .duration)
        try c.encode(durationSeconds,             forKey: .durationSeconds)
        try c.encode(dateCreated,                 forKey: .dateCreated)
        try c.encode(dateModified,                forKey: .dateModified)
        try c.encodeIfPresent(dateCreatedRaw,     forKey: .dateCreatedRaw)
        try c.encodeIfPresent(dateModifiedRaw,    forKey: .dateModifiedRaw)
        try c.encode(container,                   forKey: .container)
        try c.encode(videoCodec,                  forKey: .videoCodec)
        try c.encode(resolution,                  forKey: .resolution)
        try c.encode(frameRate,                   forKey: .frameRate)
        try c.encode(videoBitrate,                forKey: .videoBitrate)
        try c.encode(totalBitrate,                forKey: .totalBitrate)
        try c.encode(colorSpace,                  forKey: .colorSpace)
        try c.encode(bitDepth,                    forKey: .bitDepth)
        try c.encode(scanType,                    forKey: .scanType)
        try c.encode(audioCodec,                  forKey: .audioCodec)
        try c.encode(audioChannels,               forKey: .audioChannels)
        try c.encode(audioSampleRate,             forKey: .audioSampleRate)
        try c.encode(timecode,                    forKey: .timecode)
        try c.encode(tapeName,                    forKey: .tapeName)
        try c.encode(isPlayable,                  forKey: .isPlayable)
        try c.encode(partialMD5,                  forKey: .partialMD5)
        try c.encode(fullPath,                    forKey: .fullPath)
        try c.encode(directory,                   forKey: .directory)
        try c.encode(notes,                       forKey: .notes)
        try c.encode(avidClipName,                forKey: .avidClipName)
        try c.encode(avidMobID,                   forKey: .avidMobID)
        try c.encode(avidMaterialUUID,            forKey: .avidMaterialUUID)
        try c.encode(avidBinFile,                 forKey: .avidBinFile)
        try c.encode(avidMobType,                 forKey: .avidMobType)
        try c.encode(avidMediaPath,               forKey: .avidMediaPath)
        try c.encode(avidTapeName,                forKey: .avidTapeName)
        try c.encode(avidEditRate,                forKey: .avidEditRate)
        try c.encode(avidTracks,                  forKey: .avidTracks)
        try c.encodeIfPresent(pairedWith?.id,     forKey: .pairedWithID)
        try c.encodeIfPresent(pairGroupID,        forKey: .pairGroupID)
        try c.encodeIfPresent(pairConfidence,     forKey: .pairConfidence)
        try c.encodeIfPresent(duplicateGroupID,   forKey: .duplicateGroupID)
        try c.encodeIfPresent(duplicateConfidence, forKey: .duplicateConfidence)
        try c.encode(duplicateDisposition,        forKey: .duplicateDisposition)
        try c.encode(duplicateReasons,            forKey: .duplicateReasons)
        try c.encode(duplicateBestMatchFilename,  forKey: .duplicateBestMatchFilename)
        try c.encode(duplicateGroupCount,         forKey: .duplicateGroupCount)
        try c.encode(sourceHost,                  forKey: .sourceHost)
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

// MARK: - Volume Phase (lifecycle)

enum VolumePhase: String, CaseIterable, Codable {
    case noCatalog    = "NO CATALOG"
    case cataloged    = "Cataloged"
    case reviewed     = "Reviewed"
    case consolidated = "Consolidated"
    case archived     = "Archived"

    // Legacy decoding: "New" → .noCatalog
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "New" { self = .noCatalog; return }
        guard let v = VolumePhase(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                    debugDescription: "Unknown VolumePhase: \(raw)")
        }
        self = v
    }

    var icon: String {
        switch self {
        case .noCatalog:    return "circle"
        case .cataloged:    return "list.bullet"
        case .reviewed:     return "checkmark.circle"
        case .consolidated: return "arrow.triangle.merge"
        case .archived:     return "archivebox"
        }
    }

    var color: Color {
        switch self {
        case .noCatalog:    return .secondary
        case .cataloged:    return .blue
        case .reviewed:     return .green
        case .consolidated: return .purple
        case .archived:     return .mint
        }
    }

    /// Next phase in the lifecycle, or nil if already archived.
    var next: VolumePhase? {
        guard let idx = Self.allCases.firstIndex(of: self),
              idx + 1 < Self.allCases.count else { return nil }
        return Self.allCases[idx + 1]
    }
}

// MARK: - Volume Row (value type for Table display)

struct VolumeRow: Identifiable {
    let id: UUID                    // matches CatalogScanTarget.id
    let name: String                // friendly volume name
    let path: String                // full search path
    let status: CatalogTargetStatus
    let connection: String          // "Connected", "Offline", "Remote"
    let connectionColor: Color
    let files: Int
    let errors: Int
    let mediaBytes: Int64
    let phase: VolumePhase
    let lastScanned: Date?
    let isReachable: Bool
    let isNetwork: Bool
    let catalogStatusText: String
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
        case .paused:      return .cyan       // was .yellow — collided with discovering
        case .complete:    return .blue
        case .stopped:     return .orange
        case .error:       return .red
        }
    }
}

// MARK: - Combine Pair Item

struct CombinePairItem: Identifiable {
    let id = UUID()
    let video: VideoRecord
    let audio: VideoRecord
}

// MARK: - Discovered Volume

struct DiscoveredVolume: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isNetwork: Bool
    let totalBytes: Int64
    let freeBytes: Int64
    let alreadyAdded: Bool

    var totalFormatted: String { Formatting.humanSize(totalBytes) }
    var usedFormatted: String { Formatting.humanSize(totalBytes - freeBytes) }
}

// MARK: - Catalog Scan Target

@MainActor
final class CatalogScanTarget: ObservableObject, Identifiable {
    let id = UUID()
    @Published var searchPath: String
    @Published var status: CatalogTargetStatus = .idle
    @Published var filesFound: Int = 0
    @Published var filesScanned: Int = 0
    @Published var elapsedSecs: Double = 0.0
    /// Whether the search path is currently mounted/reachable. Updated by
    /// VideoScanModel on launch and on NSWorkspace mount/unmount notifications.
    @Published var isReachable: Bool = true
    /// When this volume's catalog was last updated (scan completed).
    @Published var lastScannedDate: Date?
    /// Lifecycle phase — user-assigned workflow state.
    @Published var phase: VolumePhase = .noCatalog

    var scanTask: Task<Void, Never>?
    let pauseGate = PauseGate()
    private var taskStarted: Date?
    private var timerTask: Task<Void, Never>?

    init(searchPath: String) {
        self.searchPath = searchPath
        self.isReachable = VolumeReachability.isReachable(path: searchPath)
    }

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
    case paused      = "Paused"
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
