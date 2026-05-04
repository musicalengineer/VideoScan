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
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
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
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
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

    // Media lifecycle
    var lifecycleStage: LifecycleStage = .cataloged
    var mediaDisposition: MediaDisposition = .unreviewed
    var archiveStage: ArchiveStage = .none
    var masterLocation: String = ""           // e.g. "Mac Studio SSD"
    var backupDestinations: [BackupEntry] = []
    var junkScore: Int = 0
    var junkReasons: [String] = []
    var starRating: Int = 0                   // 0 = unrated, 1-3 stars
    var combinedFromPairID: UUID?             // links back to source pair group

    /// Hostname of the machine that originally cataloged this record.
    /// Empty on records scanned locally; populated on import from another
    /// machine's exported catalog so the UI can show "from <host>".
    var sourceHost: String = ""

    /// Provenance captured at scan time: which machine ran the scan, what
    /// kind of volume the file lived on (local/smb/nfs/afp), the volume's
    /// stable UUID if available, and the remote server name for network
    /// mounts. Populated automatically in ScanEngine.probeFile; refreshed
    /// on every rescan so old records backfill naturally.
    var scanContext: ScanContext = ScanContext()

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

    /// Human-readable volume name pulled from `fullPath`. For paths under
    /// `/Volumes/<X>/…` this is `X`; for anything else it's the last path
    /// component. Used as a sortable/displayable column in the results
    /// table so the user can group-browse by volume.
    var volumeName: String {
        VolumeReachability.volumeName(forPath: fullPath)
    }

    /// Filename tint color based on archival/disposition status.
    /// Priority: damaged (red) → junk (gray) → archived (green) →
    /// master (blue) → in-progress (orange) → flagged (yellow) → default (primary).
    var filenameColor: Color {
        if streamType == .ffprobeFailed || streamType == .noStreams {
            return .red
        }
        if mediaDisposition == .confirmedJunk {
            return .secondary
        }
        if mediaDisposition == .suspectedJunk {
            return Color.secondary.opacity(0.7)
        }
        if archiveStage >= .backedUp && !backupDestinations.isEmpty {
            return .green
        }
        if archiveStage == .masterAssigned {
            return .blue
        }
        if mediaDisposition == .important || mediaDisposition == .recoverable
            || archiveStage >= .healthy {
            return .orange
        }
        return .primary
    }

    /// Quick archive-health traffic light: green (safe), yellow (in progress), red (needs attention).
    var archiveHealth: ArchiveHealth {
        if mediaDisposition == .confirmedJunk || mediaDisposition == .suspectedJunk {
            return .notApplicable
        }
        let hasAV = streamType == .videoAndAudio
        let isReviewed = mediaDisposition == .important || mediaDisposition == .recoverable
        let isArchived = archiveStage >= .backedUp
        let hasBackup = !backupDestinations.isEmpty

        if hasAV && isReviewed && isArchived && hasBackup {
            return .safe
        } else if isReviewed || archiveStage >= .healthy {
            return .inProgress
        } else {
            return .needsAttention
        }
    }

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
        case lifecycleStage, mediaDisposition, archiveStage, masterLocation, backupDestinations
        case junkScore, junkReasons
        case starRating, combinedFromPairID
        case sourceHost
        case scanContext
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                          = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filename                    = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        ext                         = try c.decodeIfPresent(String.self, forKey: .ext) ?? ""
        streamTypeRaw               = try c.decodeIfPresent(String.self, forKey: .streamTypeRaw) ?? ""
        size                        = try c.decodeIfPresent(String.self, forKey: .size) ?? ""
        sizeBytes                   = try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        duration                    = try c.decodeIfPresent(String.self, forKey: .duration) ?? ""
        durationSeconds             = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        dateCreated                 = try c.decodeIfPresent(String.self, forKey: .dateCreated) ?? ""
        dateModified                = try c.decodeIfPresent(String.self, forKey: .dateModified) ?? ""
        dateCreatedRaw              = try c.decodeIfPresent(Date.self, forKey: .dateCreatedRaw)
        dateModifiedRaw             = try c.decodeIfPresent(Date.self, forKey: .dateModifiedRaw)
        container                   = try c.decodeIfPresent(String.self, forKey: .container) ?? ""
        videoCodec                  = try c.decodeIfPresent(String.self, forKey: .videoCodec) ?? ""
        resolution                  = try c.decodeIfPresent(String.self, forKey: .resolution) ?? ""
        frameRate                   = try c.decodeIfPresent(String.self, forKey: .frameRate) ?? ""
        videoBitrate                = try c.decodeIfPresent(String.self, forKey: .videoBitrate) ?? ""
        totalBitrate                = try c.decodeIfPresent(String.self, forKey: .totalBitrate) ?? ""
        colorSpace                  = try c.decodeIfPresent(String.self, forKey: .colorSpace) ?? ""
        bitDepth                    = try c.decodeIfPresent(String.self, forKey: .bitDepth) ?? ""
        scanType                    = try c.decodeIfPresent(String.self, forKey: .scanType) ?? ""
        audioCodec                  = try c.decodeIfPresent(String.self, forKey: .audioCodec) ?? ""
        audioChannels               = try c.decodeIfPresent(String.self, forKey: .audioChannels) ?? ""
        audioSampleRate             = try c.decodeIfPresent(String.self, forKey: .audioSampleRate) ?? ""
        timecode                    = try c.decodeIfPresent(String.self, forKey: .timecode) ?? ""
        tapeName                    = try c.decodeIfPresent(String.self, forKey: .tapeName) ?? ""
        isPlayable                  = try c.decodeIfPresent(String.self, forKey: .isPlayable) ?? ""
        partialMD5                  = try c.decodeIfPresent(String.self, forKey: .partialMD5) ?? ""
        fullPath                    = try c.decodeIfPresent(String.self, forKey: .fullPath) ?? ""
        directory                   = try c.decodeIfPresent(String.self, forKey: .directory) ?? ""
        notes                       = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        avidClipName                = try c.decodeIfPresent(String.self, forKey: .avidClipName) ?? ""
        avidMobID                   = try c.decodeIfPresent(String.self, forKey: .avidMobID) ?? ""
        avidMaterialUUID            = try c.decodeIfPresent(String.self, forKey: .avidMaterialUUID) ?? ""
        avidBinFile                 = try c.decodeIfPresent(String.self, forKey: .avidBinFile) ?? ""
        avidMobType                 = try c.decodeIfPresent(String.self, forKey: .avidMobType) ?? ""
        avidMediaPath               = try c.decodeIfPresent(String.self, forKey: .avidMediaPath) ?? ""
        avidTapeName                = try c.decodeIfPresent(String.self, forKey: .avidTapeName) ?? ""
        avidEditRate                = try c.decodeIfPresent(Double.self, forKey: .avidEditRate) ?? 0
        avidTracks                  = try c.decodeIfPresent(String.self, forKey: .avidTracks) ?? ""
        pendingPairedWithID         = try c.decodeIfPresent(UUID.self, forKey: .pairedWithID)
        pairGroupID                 = try c.decodeIfPresent(UUID.self, forKey: .pairGroupID)
        pairConfidence              = try c.decodeIfPresent(PairConfidence.self, forKey: .pairConfidence)
        duplicateGroupID            = try c.decodeIfPresent(UUID.self, forKey: .duplicateGroupID)
        duplicateConfidence         = try c.decodeIfPresent(DuplicateConfidence.self, forKey: .duplicateConfidence)
        duplicateDisposition        = try c.decodeIfPresent(DuplicateDisposition.self, forKey: .duplicateDisposition) ?? .none
        duplicateReasons            = try c.decodeIfPresent(String.self, forKey: .duplicateReasons) ?? ""
        duplicateBestMatchFilename  = try c.decodeIfPresent(String.self, forKey: .duplicateBestMatchFilename) ?? ""
        duplicateGroupCount         = try c.decodeIfPresent(Int.self, forKey: .duplicateGroupCount) ?? 0
        sourceHost                  = try c.decodeIfPresent(String.self, forKey: .sourceHost) ?? ""
        lifecycleStage              = try c.decodeIfPresent(LifecycleStage.self, forKey: .lifecycleStage) ?? .cataloged
        mediaDisposition            = try c.decodeIfPresent(MediaDisposition.self, forKey: .mediaDisposition) ?? .unreviewed
        archiveStage                = try c.decodeIfPresent(ArchiveStage.self, forKey: .archiveStage) ?? .none
        masterLocation              = try c.decodeIfPresent(String.self, forKey: .masterLocation) ?? ""
        backupDestinations          = try c.decodeIfPresent([BackupEntry].self, forKey: .backupDestinations) ?? []
        junkScore                   = try c.decodeIfPresent(Int.self, forKey: .junkScore) ?? 0
        junkReasons                 = try c.decodeIfPresent([String].self, forKey: .junkReasons) ?? []
        starRating                  = try c.decodeIfPresent(Int.self, forKey: .starRating) ?? 0
        combinedFromPairID          = try c.decodeIfPresent(UUID.self, forKey: .combinedFromPairID)
        scanContext                 = try c.decodeIfPresent(ScanContext.self, forKey: .scanContext) ?? ScanContext()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(filename, forKey: .filename)
        try c.encode(ext, forKey: .ext)
        try c.encode(streamTypeRaw, forKey: .streamTypeRaw)
        try c.encode(size, forKey: .size)
        try c.encode(sizeBytes, forKey: .sizeBytes)
        try c.encode(duration, forKey: .duration)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(dateCreated, forKey: .dateCreated)
        try c.encode(dateModified, forKey: .dateModified)
        try c.encodeIfPresent(dateCreatedRaw, forKey: .dateCreatedRaw)
        try c.encodeIfPresent(dateModifiedRaw, forKey: .dateModifiedRaw)
        try c.encode(container, forKey: .container)
        try c.encode(videoCodec, forKey: .videoCodec)
        try c.encode(resolution, forKey: .resolution)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(videoBitrate, forKey: .videoBitrate)
        try c.encode(totalBitrate, forKey: .totalBitrate)
        try c.encode(colorSpace, forKey: .colorSpace)
        try c.encode(bitDepth, forKey: .bitDepth)
        try c.encode(scanType, forKey: .scanType)
        try c.encode(audioCodec, forKey: .audioCodec)
        try c.encode(audioChannels, forKey: .audioChannels)
        try c.encode(audioSampleRate, forKey: .audioSampleRate)
        try c.encode(timecode, forKey: .timecode)
        try c.encode(tapeName, forKey: .tapeName)
        try c.encode(isPlayable, forKey: .isPlayable)
        try c.encode(partialMD5, forKey: .partialMD5)
        try c.encode(fullPath, forKey: .fullPath)
        try c.encode(directory, forKey: .directory)
        try c.encode(notes, forKey: .notes)
        try c.encode(avidClipName, forKey: .avidClipName)
        try c.encode(avidMobID, forKey: .avidMobID)
        try c.encode(avidMaterialUUID, forKey: .avidMaterialUUID)
        try c.encode(avidBinFile, forKey: .avidBinFile)
        try c.encode(avidMobType, forKey: .avidMobType)
        try c.encode(avidMediaPath, forKey: .avidMediaPath)
        try c.encode(avidTapeName, forKey: .avidTapeName)
        try c.encode(avidEditRate, forKey: .avidEditRate)
        try c.encode(avidTracks, forKey: .avidTracks)
        try c.encodeIfPresent(pairedWith?.id, forKey: .pairedWithID)
        try c.encodeIfPresent(pairGroupID, forKey: .pairGroupID)
        try c.encodeIfPresent(pairConfidence, forKey: .pairConfidence)
        try c.encodeIfPresent(duplicateGroupID, forKey: .duplicateGroupID)
        try c.encodeIfPresent(duplicateConfidence, forKey: .duplicateConfidence)
        try c.encode(duplicateDisposition, forKey: .duplicateDisposition)
        try c.encode(duplicateReasons, forKey: .duplicateReasons)
        try c.encode(duplicateBestMatchFilename, forKey: .duplicateBestMatchFilename)
        try c.encode(duplicateGroupCount, forKey: .duplicateGroupCount)
        try c.encode(sourceHost, forKey: .sourceHost)
        try c.encode(lifecycleStage, forKey: .lifecycleStage)
        try c.encode(mediaDisposition, forKey: .mediaDisposition)
        try c.encode(archiveStage, forKey: .archiveStage)
        if !masterLocation.isEmpty {
            try c.encode(masterLocation, forKey: .masterLocation)
        }
        if !backupDestinations.isEmpty {
            try c.encode(backupDestinations, forKey: .backupDestinations)
        }
        try c.encode(junkScore, forKey: .junkScore)
        if !junkReasons.isEmpty {
            try c.encode(junkReasons, forKey: .junkReasons)
        }
        if starRating > 0 {
            try c.encode(starRating, forKey: .starRating)
        }
        if combinedFromPairID != nil {
            try c.encode(combinedFromPairID, forKey: .combinedFromPairID)
        }
        if scanContext.isPopulated || scanContext.scannedAt != nil {
            try c.encode(scanContext, forKey: .scanContext)
        }
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

// MARK: - Lifecycle Stage (which tab shows this file)

enum LifecycleStage: String, Codable, CaseIterable {
    case cataloged = "Cataloged"
    case reviewing = "In Triage"
    case archived  = "Archived"
}

// MARK: - Media Disposition (per-file lifecycle)

enum MediaDisposition: String, Codable, CaseIterable {
    case unreviewed    = "Unreviewed"
    case important     = "Important"
    case recoverable   = "Recoverable"
    case suspectedJunk = "Suspected Junk"
    case confirmedJunk = "Confirmed Junk"

    var icon: String {
        switch self {
        case .unreviewed:    return "circle"
        case .important:     return "star.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unreviewed:    return .secondary
        case .important:     return .blue
        case .recoverable:   return .teal
        case .suspectedJunk: return .orange
        case .confirmedJunk: return .red
        }
    }
}

enum ArchiveStage: String, Codable, CaseIterable, Comparable {
    case none            = "None"
    case healthy         = "Healthy"
    case masterAssigned  = "Master"
    case backedUp        = "Backed Up"
    case readyForArchive = "Ready"
    case archived        = "Archived"

    var icon: String {
        switch self {
        case .none:            return "circle"
        case .healthy:         return "heart.fill"
        case .masterAssigned:  return "crown.fill"
        case .backedUp:        return "doc.on.doc.fill"
        case .readyForArchive: return "checkmark.seal.fill"
        case .archived:        return "archivebox.fill"
        }
    }

    var color: Color {
        switch self {
        case .none:            return .secondary
        case .healthy:         return .green
        case .masterAssigned:  return .blue
        case .backedUp:        return .purple
        case .readyForArchive: return .mint
        case .archived:        return .indigo
        }
    }

    static func < (lhs: ArchiveStage, rhs: ArchiveStage) -> Bool {
        let order: [ArchiveStage] = allCases
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

// MARK: - Archive Health (traffic-light summary)

enum ArchiveHealth {
    case safe            // green: reviewed, has A/V, backed up
    case inProgress      // yellow: partially classified or archived
    case needsAttention  // red: unreviewed, no backups
    case notApplicable   // junk — no badge

    var icon: String {
        switch self {
        case .safe:           return "checkmark.shield.fill"
        case .inProgress:     return "clock.badge.checkmark"
        case .needsAttention: return "exclamationmark.shield.fill"
        case .notApplicable:  return ""
        }
    }

    var color: Color {
        switch self {
        case .safe:           return .green
        case .inProgress:     return .yellow
        case .needsAttention: return .red
        case .notApplicable:  return .clear
        }
    }

    var label: String {
        switch self {
        case .safe:           return "Safe"
        case .inProgress:     return "In Progress"
        case .needsAttention: return "Needs Attention"
        case .notApplicable:  return ""
        }
    }

    var detail: String {
        switch self {
        case .safe:           return "Reviewed, has audio/video, backed up"
        case .inProgress:     return "Partially reviewed or archived"
        case .needsAttention: return "Not yet reviewed or backed up"
        case .notApplicable:  return ""
        }
    }
}

// MARK: - Backup Entry

struct BackupEntry: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String           // "LTA_Crucial", "iCloud", "Breen's NAS"
    let kind: BackupKind
    let date: Date

    enum BackupKind: String, Codable, CaseIterable {
        case local   = "Local"       // external drive, same network
        case cloud   = "Cloud"       // iCloud, Backblaze, S3
        case offsite = "Offsite"     // physically elsewhere (son's NAS, etc.)

        var icon: String {
            switch self {
            case .local:   return "externaldrive.fill"
            case .cloud:   return "icloud.fill"
            case .offsite: return "building.2.fill"
            }
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

// MARK: - Volume Role

enum VolumeRole: String, CaseIterable, Codable {
    case unassigned  = "Unassigned"
    case original    = "Original"
    case backup      = "Backup"
    case archive     = "Archive"
    case lta         = "Long-Term Archive"

    var icon: String {
        switch self {
        case .unassigned: return "questionmark.circle"
        case .original:   return "film.stack"
        case .backup:     return "doc.on.doc"
        case .archive:    return "archivebox.fill"
        case .lta:        return "icloud.fill"
        }
    }

    var color: Color {
        switch self {
        case .unassigned: return .secondary
        case .original:   return .orange
        case .backup:     return .blue
        case .archive:    return .green
        case .lta:        return .mint
        }
    }

    var shortLabel: String {
        switch self {
        case .unassigned: return "—"
        case .original:   return "ORIG"
        case .backup:     return "BKUP"
        case .archive:    return "ARCH"
        case .lta:        return "LTA"
        }
    }
}

enum VolumeTrust: String, CaseIterable, Codable {
    case unknown    = "Unknown"
    case reliable   = "Reliable"
    case aging      = "Aging"
    case unreliable = "Unreliable"

    var icon: String {
        switch self {
        case .unknown:    return "questionmark.circle"
        case .reliable:   return "checkmark.shield.fill"
        case .aging:      return "exclamationmark.triangle"
        case .unreliable: return "xmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown:    return .secondary
        case .reliable:   return .green
        case .aging:      return .yellow
        case .unreliable: return .red
        }
    }
}

// MARK: - Volume Media Technology

enum VolumeMediaTech: String, CaseIterable, Codable {
    case unknown = "Unknown"
    case ssd     = "SSD"
    case hdd     = "HDD"
    case raid0   = "RAID-0"
    case raid1   = "RAID-1"
    case raid5   = "RAID-5"
    case raid10  = "RAID-10"
    case cloud   = "Cloud"
    case network = "Network"

    var icon: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .ssd:     return "internaldrive"
        case .hdd:     return "externaldrive"
        case .raid0,
             .raid1,
             .raid5,
             .raid10:  return "externaldrive.connected.to.line.below"
        case .cloud:   return "icloud"
        case .network: return "network"
        }
    }

    /// Multi-disk redundancy: a single-disk failure doesn't lose the volume.
    var isRedundant: Bool {
        switch self {
        case .raid1, .raid5, .raid10, .cloud: return true
        default: return false
        }
    }

    /// RAID-0 doubles failure probability with no redundancy — never an
    /// archive destination, even when new.
    var isFragile: Bool { self == .raid0 }
}

// MARK: - Destination Policy (computed)

/// How appropriate a volume is as a *destination* for archived media.
/// Pure function of role + trust + mediaTech + age + reachability.
enum DestinationPolicy: String {
    case preferred
    case acceptable
    case discouraged
    case forbidden

    var label: String {
        switch self {
        case .preferred:   return "Preferred"
        case .acceptable:  return "Acceptable"
        case .discouraged: return "Discouraged"
        case .forbidden:   return "Forbidden"
        }
    }

    var color: Color {
        switch self {
        case .preferred:   return .green
        case .acceptable:  return .yellow
        case .discouraged: return .orange
        case .forbidden:   return .red
        }
    }

    var icon: String {
        switch self {
        case .preferred:   return "checkmark.seal.fill"
        case .acceptable:  return "checkmark.circle"
        case .discouraged: return "exclamationmark.triangle.fill"
        case .forbidden:   return "xmark.octagon.fill"
        }
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
    /// What role this volume plays in the archival workflow.
    @Published var role: VolumeRole = .unassigned
    /// How trustworthy this volume is (age/reliability).
    @Published var trust: VolumeTrust = .unknown
    /// Filesystem name (APFS, HFS+, exFAT, NTFS, SMB, …). User-entered.
    @Published var filesystem: String = ""
    /// Storage medium / topology (SSD, HDD, RAID-0/-1/-5, cloud, network).
    @Published var mediaTech: VolumeMediaTech = .unknown
    /// Year the volume was placed in service. Drives the age penalty in
    /// `destinationPolicy`.
    @Published var purchaseYear: Int?
    /// Total capacity in terabytes. Free-form display, not an enforced limit.
    @Published var capacityTB: Double?
    /// User notes — model number, serial, location, history, etc.
    @Published var notes: String = ""

    /// Computed archival-destination suitability. Rules (first match wins):
    ///   1. RAID-0 or trust=Unreliable → Forbidden
    ///   2. Offline → Discouraged (can't write to it now)
    ///   3. Role not Archive/LTA → Acceptable (it's not meant as a target)
    ///   4. Trust=Aging → Discouraged
    ///   5. ≥12 yr old, or ≥8 yr old without redundancy → Discouraged
    ///   6. Trust=Unknown on plain HDD/Network → Acceptable
    ///   7. Else → Preferred
    var destinationPolicy: DestinationPolicy {
        if mediaTech.isFragile { return .forbidden }
        if trust == .unreliable { return .forbidden }
        if !isReachable { return .discouraged }

        let isDestRole = (role == .archive || role == .lta)
        if !isDestRole { return .acceptable }

        if trust == .aging { return .discouraged }

        if let year = purchaseYear {
            let now = Calendar.current.component(.year, from: Date())
            let age = now - year
            if age >= 12 { return .discouraged }
            if age >= 8 && !mediaTech.isRedundant { return .discouraged }
        }

        if trust == .unknown
            && !mediaTech.isRedundant
            && mediaTech != .ssd
            && mediaTech != .cloud {
            return .acceptable
        }

        return .preferred
    }

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
