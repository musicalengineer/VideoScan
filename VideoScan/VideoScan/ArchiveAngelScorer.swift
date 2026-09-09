// ArchiveAngelScorer.swift
// Archive Angel — Stage 1 candidate selection (docs/archive_angel_design.md §3).
//
// PURE CORE. Takes Sendable inputs projected from VideoRecord, returns a
// verdict per candidate: eligible with a score AND the evidence lines that
// produced it, or rejected with the hard-floor reason. The number only
// orders the list; the lines are what the user reads in the review sheet.
// Machines write evidence, humans decide (project rule). No media I/O here,
// no main-actor access — table-testable and O(candidates).
//
// Rick 2026-09-09: candidates = important-but-unarchived; importance from
// stars, people, dates, play history ("a lot of play"), metadata richness
// ("a lot of metadata"); never junk ("transitions, weird teeny bits").

import Foundation
import VideoScanCore

// MARK: - Inputs

/// One catalog record as the scorer sees it. Built by
/// `ArchiveAngelCandidate.init(record:...)` on the main actor; everything
/// here is a value so the walk can run off-main.
struct ArchiveAngelCandidate: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var streamTypeRaw: String
    var isPlayable: String
    var starRating: Int
    var mediaDisposition: MediaDisposition
    var archiveStage: ArchiveStage
    var junkScore: Int
    var confirmedPeople: [String]
    var detectedPeople: [String]
    var suspectedPeople: [String]
    var hasUserNotes: Bool
    var tagCount: Int
    var hasCaptions: Bool
    var hasOCRText: Bool
    var hasEmbeddedDate: Bool
    var hasTapeOrClipName: Bool
    var userDate: String?
    var inferredRecordDate: Date?
    var inferredDateConfidence: Float?
    var formatAtRisk: Bool
    var audioProblem: String?
    /// True when this record is one half of a correlated MXF pair — the
    /// Combine output is the candidate, never the half.
    var isPairedHalf: Bool
    /// True when a duplicate of this file already sits in the archive.
    var hasArchivedDuplicate: Bool
    /// True when the file has no duplicate anywhere (single copy).
    var isOnlyCopy: Bool
    /// Volume role of the file's current home.
    var volumeRole: VolumeRole
    var volumeName: String
    var volumeOnline: Bool
    var isOnMasterArchive: Bool
    /// Spotlight `kMDItemUseCount` / in-app play count, whichever is larger.
    var useCount: Int
    var lastUsed: Date?

    init(id: UUID = UUID(), filename: String = "clip.mov", fullPath: String = "/Volumes/X/clip.mov",
         sizeBytes: Int64 = 1_000_000_000, durationSeconds: Double = 60,
         streamTypeRaw: String = StreamType.videoAndAudio.rawValue, isPlayable: String = "Yes",
         starRating: Int = 0, mediaDisposition: MediaDisposition = .unreviewed,
         archiveStage: ArchiveStage = .none, junkScore: Int = 0,
         confirmedPeople: [String] = [], detectedPeople: [String] = [], suspectedPeople: [String] = [],
         hasUserNotes: Bool = false, tagCount: Int = 0, hasCaptions: Bool = false, hasOCRText: Bool = false,
         hasEmbeddedDate: Bool = false, hasTapeOrClipName: Bool = false,
         userDate: String? = nil, inferredRecordDate: Date? = nil, inferredDateConfidence: Float? = nil,
         formatAtRisk: Bool = false, audioProblem: String? = nil,
         isPairedHalf: Bool = false, hasArchivedDuplicate: Bool = false, isOnlyCopy: Bool = false,
         volumeRole: VolumeRole = .workspace, volumeName: String = "X", volumeOnline: Bool = true,
         isOnMasterArchive: Bool = false, useCount: Int = 0, lastUsed: Date? = nil) {
        self.id = id; self.filename = filename; self.fullPath = fullPath; self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds; self.streamTypeRaw = streamTypeRaw; self.isPlayable = isPlayable
        self.starRating = starRating; self.mediaDisposition = mediaDisposition; self.archiveStage = archiveStage
        self.junkScore = junkScore; self.confirmedPeople = confirmedPeople; self.detectedPeople = detectedPeople
        self.suspectedPeople = suspectedPeople; self.hasUserNotes = hasUserNotes; self.tagCount = tagCount
        self.hasCaptions = hasCaptions; self.hasOCRText = hasOCRText; self.hasEmbeddedDate = hasEmbeddedDate
        self.hasTapeOrClipName = hasTapeOrClipName; self.userDate = userDate
        self.inferredRecordDate = inferredRecordDate; self.inferredDateConfidence = inferredDateConfidence
        self.formatAtRisk = formatAtRisk; self.audioProblem = audioProblem; self.isPairedHalf = isPairedHalf
        self.hasArchivedDuplicate = hasArchivedDuplicate; self.isOnlyCopy = isOnlyCopy
        self.volumeRole = volumeRole; self.volumeName = volumeName; self.volumeOnline = volumeOnline
        self.isOnMasterArchive = isOnMasterArchive; self.useCount = useCount; self.lastUsed = lastUsed
    }
}

// MARK: - Outputs

/// One printed reason. `points` is shown in the expanded view only.
struct ArchiveAngelEvidence: Sendable, Equatable, Codable {
    var points: Int
    var line: String
}

/// Why a record never made the list. Reported as counts per reason so the
/// user can see the floor working (design §3.2, §6).
enum ArchiveAngelRejection: String, Sendable, Codable, CaseIterable {
    case notVideo = "Not a video"
    case alreadyArchived = "Already in the archive"
    case duplicateArchived = "A copy is already in the archive"
    case volumeOffline = "Volume offline"
    case tooShort = "Too short (under 1 min unrated, 8 s if you marked it)"
    case junk = "Marked junk"
    case suspectedJunk = "Looks like junk (machine evidence, unrated)"
    case notPlayable = "Not playable / un-probeable"
    case pairedHalf = "Half of an A/V pair — combine first"
}

enum ArchiveAngelVerdict: Sendable, Equatable {
    case eligible(score: Int, evidence: [ArchiveAngelEvidence])
    case rejected(ArchiveAngelRejection)
}

struct ArchiveAngelPick: Sendable, Equatable, Identifiable {
    var candidate: ArchiveAngelCandidate
    var score: Int
    var evidence: [ArchiveAngelEvidence]
    var id: UUID { candidate.id }
}

struct ArchiveAngelSelection: Sendable, Equatable {
    var picks: [ArchiveAngelPick]
    /// Eligible but beyond `count` — reported as "N more would qualify".
    var overflow: Int
    var rejected: [ArchiveAngelRejection: Int]
    var rejectedTotal: Int { rejected.values.reduce(0, +) }
}

// MARK: - Weights (one table; tune here, never in the logic)

struct ArchiveAngelWeights: Sendable, Equatable {
    var threeStars = 100
    var twoStars = 40
    var oneStar = 10
    var confirmedPersonEach = 25
    var confirmedPersonCap = 75
    var machinePersonEach = 8
    var machinePersonCap = 24
    var playHistoryCap = 40
    var playedRecentlyBonus = 5
    var richnessEach = 5
    var richnessCap = 40
    var dateKnown = 20
    var dateLowConfidence = 5
    var durationSweetBand = 10
    var formatAtRisk = 15
    var onlyCopy = 15
    var riskyVolume = 10
    /// Floor for a clip with a HUMAN mark (star, confirmed person, note or
    /// user date): a 20 s moment someone rated is still a moment.
    var minimumDurationSeconds = 8.0
    /// Floor for an UNMARKED clip — Rick 2026-09-09: "videos under 1 minute
    /// should be excluded due to lack of content"; below this, with no
    /// human signal, it is a transition or a tail.
    var minimumDurationUnmarkedSeconds = 60.0
    var sweetBandSeconds: ClosedRange<Double> = 120...7200
    var junkFloor = 5
    var dateConfidenceKnown: Float = 0.8

    static let standard = ArchiveAngelWeights()
}

// MARK: - Scorer

enum ArchiveAngelScorer {

    /// The verdict for one record. Pure.
    static func verdict(_ c: ArchiveAngelCandidate,
                        weights w: ArchiveAngelWeights = .standard,
                        now: Date = Date()) -> ArchiveAngelVerdict {
        if let rejection = hardFloor(c, weights: w) { return .rejected(rejection) }

        var lines: [ArchiveAngelEvidence] = []
        func add(_ points: Int, _ line: String) { lines.append(.init(points: points, line: line)) }

        switch c.starRating {
        case 3...: add(w.threeStars, "You rated it best (★★★)")
        case 2:    add(w.twoStars, "You rated it better (★★)")
        case 1:    add(w.oneStar, "You rated it good (★)")
        default:   break
        }

        if !c.confirmedPeople.isEmpty {
            let pts = min(w.confirmedPersonCap, w.confirmedPersonEach * c.confirmedPeople.count)
            add(pts, c.confirmedPeople.joined(separator: ", ") + " (confirmed)")
        }
        var seen = Set<String>()
        let machineOnly = (c.detectedPeople + c.suspectedPeople).filter {
            !c.confirmedPeople.contains($0) && seen.insert($0).inserted
        }
        if !machineOnly.isEmpty {
            let pts = min(w.machinePersonCap, w.machinePersonEach * machineOnly.count)
            add(pts, "Looks like " + machineOnly.joined(separator: ", ") + " (machine)")
        }

        if c.useCount > 0 {
            var pts = min(w.playHistoryCap, Int((4.0 * log2(1.0 + Double(c.useCount))).rounded()))
            var line = c.useCount == 1 ? "Played once" : "Played \(c.useCount) times"
            if let last = c.lastUsed {
                line += ", last on " + Self.dayFormatter.string(from: last)
                if now.timeIntervalSince(last) < 365 * 86_400 { pts += w.playedRecentlyBonus }
            }
            add(pts, line)
        }

        var richness: [String] = []
        if c.hasUserNotes { richness.append("notes") }
        if c.tagCount > 0 { richness.append(c.tagCount == 1 ? "1 tag" : "\(c.tagCount) tags") }
        if !c.confirmedPeople.isEmpty { richness.append("people") }
        if c.hasCaptions { richness.append("captions") }
        if c.hasOCRText { richness.append("on-screen text") }
        if c.inferredRecordDate != nil || c.userDate != nil { richness.append("date") }
        if c.hasEmbeddedDate { richness.append("camera date") }
        if c.hasTapeOrClipName { richness.append("tape/clip name") }
        if c.starRating > 0 { richness.append("rating") }
        if !richness.isEmpty {
            add(min(w.richnessCap, w.richnessEach * richness.count),
                "Has " + richness.joined(separator: ", "))
        }

        if let userDate = c.userDate, !userDate.isEmpty {
            add(w.dateKnown, "Dated \(userDate) (yours)")
        } else if let d = c.inferredRecordDate {
            let conf = c.inferredDateConfidence ?? 0
            if conf >= w.dateConfidenceKnown {
                add(w.dateKnown, "Dated " + Self.dayFormatter.string(from: d)
                    + String(format: " (consensus %.2f)", conf))
            } else {
                add(w.dateLowConfidence, "Date uncertain — "
                    + Self.dayFormatter.string(from: d) + String(format: " (%.2f)", conf))
            }
        } else if c.hasEmbeddedDate {
            add(w.dateKnown, "Dated by the camera")
        }

        if w.sweetBandSeconds.contains(c.durationSeconds) {
            add(w.durationSweetBand, Self.durationText(c.durationSeconds))
        }
        if c.formatAtRisk { add(w.formatAtRisk, "At-risk format — archive sooner") }
        if c.isOnlyCopy { add(w.onlyCopy, "This is the only copy") }
        switch c.volumeRole {
        case .workspace, .backup, .archive, .cloud, .system: break
        case .unassigned: add(w.riskyVolume, "Lives on \(c.volumeName) (no role assigned)")
        }
        if let problem = c.audioProblem, !problem.isEmpty {
            add(0, "Audio: \(problem) — will balance")
        }

        return .eligible(score: lines.reduce(0) { $0 + $1.points }, evidence: lines)
    }

    /// Hard floor (design §3.2): the reasons a record is never a candidate.
    /// Order = the reason the user should hear first.
    static func hardFloor(_ c: ArchiveAngelCandidate,
                          weights w: ArchiveAngelWeights = .standard) -> ArchiveAngelRejection? {
        switch c.streamTypeRaw {
        case StreamType.videoAndAudio.rawValue, StreamType.videoOnly.rawValue: break
        default: return .notVideo
        }
        if c.isOnMasterArchive || c.archiveStage >= .masterAssigned { return .alreadyArchived }
        if c.hasArchivedDuplicate { return .duplicateArchived }
        if c.isPlayable.lowercased().hasPrefix("no") || c.isPlayable.lowercased().contains("unsupported") {
            return .notPlayable
        }
        if c.isPairedHalf { return .pairedHalf }
        let humanMarked = c.starRating > 0 || !c.confirmedPeople.isEmpty || c.hasUserNotes
            || !(c.userDate ?? "").isEmpty
        let floor = humanMarked ? w.minimumDurationSeconds : w.minimumDurationUnmarkedSeconds
        if c.durationSeconds < floor { return .tooShort }
        switch c.mediaDisposition {
        case .confirmedJunk: return .junk
        case .suspectedJunk where c.starRating == 0: return .suspectedJunk
        default: break
        }
        if c.junkScore >= w.junkFloor && c.starRating == 0 { return .suspectedJunk }
        if !c.volumeOnline { return .volumeOffline }
        return nil
    }

    /// Score every candidate, sort, take `count`. Tie-break: older date first
    /// (older tape is at more risk), then larger file (more to lose), then name.
    static func select(_ candidates: [ArchiveAngelCandidate], count: Int,
                       weights w: ArchiveAngelWeights = .standard,
                       now: Date = Date()) -> ArchiveAngelSelection {
        var picks: [ArchiveAngelPick] = []
        picks.reserveCapacity(candidates.count)
        var rejected: [ArchiveAngelRejection: Int] = [:]
        for c in candidates {
            switch verdict(c, weights: w, now: now) {
            case .eligible(let score, let evidence):
                picks.append(.init(candidate: c, score: score, evidence: evidence))
            case .rejected(let reason):
                rejected[reason, default: 0] += 1
            }
        }
        picks.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let ad = a.candidate.inferredRecordDate ?? .distantFuture
            let bd = b.candidate.inferredRecordDate ?? .distantFuture
            if ad != bd { return ad < bd }
            if a.candidate.sizeBytes != b.candidate.sizeBytes { return a.candidate.sizeBytes > b.candidate.sizeBytes }
            return a.candidate.filename < b.candidate.filename
        }
        let kept = Array(picks.prefix(max(0, count)))
        return .init(picks: kept, overflow: max(0, picks.count - kept.count), rejected: rejected)
    }

    // MARK: helpers

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func durationText(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(sec) s" }
        return "\(sec) s"
    }
}
