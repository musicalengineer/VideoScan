// SoundCopyFinder.swift
// "A copy with sound is here" (Rick 2026-10-10). When SoundPresencePolicy
// flags a picture with no sound track, say where the family can watch the
// same footage WITH sound — or, failing that, which sound file it can be
// combined with, and why.
//
// NO NEW "SAME CONTENT" MATCHING. A copy to watch is what the catalog's
// existing engines already decided, nothing weaker:
//   exact copies ....... the duplicate engine's group (duplicateGroupID)
//   same footage ....... Find Similar Footage's group (footage.groupID)
//   the archive copy ... VideoScanModel.archivedCopy(of:) (promote link /
//                        digest index)
// A same-length file elsewhere is NOT a copy (Rick: duration alone is too
// weak).
//
// SOUND TO COMBINE WITH (SoundPairRanker). Correlate refuses a picture whose
// length is unknown unless the two names are the same Avid clip key (GH
// #125) — right for bulk auto-pairing, and why Rick's
// Thanksgiving2009-DVD.m2v (an MPEG-2 elementary stream: no duration in its
// header) "has no audio pair". Elementary / demuxed streams are paired here
// instead, as CANDIDATES with their reasons, never silently:
//   * the sound file is audio-only and in the SAME FOLDER or the SAME
//     FOOTAGE GROUP as the picture;
//   * the lengths agree within a tight tolerance (max(0.5 s, 0.1 %): a
//     90-minute DVD and its .ac3 agree to a few hundredths of a second),
//     using the catalog's length, else the length a full Verify measured;
//   * with the picture's length never measured, a same-name-start sound
//     file is listed as "may be" — a full Verify measures the picture,
//     and only then is Combine offered.
//
// Which copy to watch: the keeper precedence the duplicate engine elects
// with (DuplicateKeeperPolicy.ElectionKey: archive › RAID › HDD › SSD, your
// marks, quality, path), with the archive copy first — and never a copy
// whose drive is not connected (that one is named, to connect, not chosen).
//
// SHAPE (the Copies & Advice pattern, CopiesAdvice+Projection.swift):
//   gather   main actor, ONE pass over `records` (four compares per
//            record), and only for a file the policy flagged or a user
//            action — O(records) time, O(group + folder) memory; never in
//            a view body.
//   decide   pure, off the main actor, one directory stat per candidate
//            drive (CopiesAdviceDisk.driveIsConnected).
// The 100k-record budget is pinned by SoundCopyFinderScaleTests.
//
// READ-ONLY. Nothing here muxes, moves or pairs. "Combine with its sound"
// opens the existing Combine sheet; the person starts the mux there.

import Foundation
import VideoScanCore

/// One record as the lookup sees it — a value, so it can leave the main actor.
struct SoundCopyCandidate: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var fullPath: String
    /// The drive's display name ("FamilyArchive").
    var volume: String
    var durationSeconds: Double
    var isArchiveCopy: Bool
    /// The duplicate engine's election key (keeper precedence).
    var electionKey: DuplicateKeeperPolicy.ElectionKey
    /// "exact copy", "same footage", "archive copy", "sound file".
    var relation: String
}

/// An audio-only record beside the picture, and how it is beside it.
struct SoundPairSource: Sendable, Equatable {
    var audio: SoundCopyCandidate
    var sameFolder: Bool
    var sameFootage: Bool
}

/// One ranked "this may be its sound" answer, with the reason in words.
struct SoundPairCandidate: Sendable, Equatable, Identifiable {
    var audio: SoundCopyCandidate
    var sameFolder: Bool
    var sameFootage: Bool
    var sameNameStart: Bool
    /// |picture − sound| in seconds; nil when the picture's length was
    /// never measured (then this is only "may be").
    var lengthDelta: Double?

    var id: UUID { audio.id }
    /// Lengths measured on both sides and within the tolerance.
    var lengthMatches: Bool { lengthDelta != nil }

    /// "same folder, same name start, same length 1:30:22 (0.03 s apart)".
    var reason: String {
        var parts: [String] = []
        if sameFolder { parts.append("same folder") }
        if sameFootage { parts.append("same footage group") }
        if sameNameStart { parts.append("same name start") }
        let length = SoundPairRanker.clock(audio.durationSeconds)
        if let d = lengthDelta {
            parts.append("same length \(length)" + (d >= 0.005 ? String(format: " (%.2f s apart)", d) : ""))
        } else {
            parts.append("its sound runs \(length); this picture's length isn't recorded yet")
        }
        return parts.joined(separator: ", ")
    }
}

/// Ranks the sound files a picture can be combined with. Pure.
enum SoundPairRanker {

    /// Tight: half a second, or 0.1 % of the length (5.4 s at 90 min).
    /// Correlate's own gate is 2 %; this one only lists, so it can be
    /// stricter and still find a DVD's .ac3 (they agree to hundredths).
    nonisolated static func tolerance(_ seconds: Double) -> Double { max(0.5, 0.001 * seconds) }

    /// Candidates, best first. `pictureSeconds` nil = never measured.
    nonisolated static func rank(pictureName: String, pictureSeconds: Double?,
                                 sources: [SoundPairSource]) -> [SoundPairCandidate] {
        let stem = SoundCopyFinder.nameStem(pictureName)
        let picture = pictureSeconds.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        let out = sources.compactMap { s -> SoundPairCandidate? in
            let named = !stem.isEmpty && SoundCopyFinder.nameStem(s.audio.filename) == stem
            let base = SoundPairCandidate(audio: s.audio, sameFolder: s.sameFolder, sameFootage: s.sameFootage,
                                          sameNameStart: named, lengthDelta: nil)
            guard let picture else { return named ? base : nil }   // unmeasured: name start or nothing
            let sound = s.audio.durationSeconds
            guard sound > 0, sound.isFinite else { return nil }
            let delta = abs(picture - sound)
            guard delta <= tolerance(max(picture, sound)) else { return nil }
            var c = base
            c.lengthDelta = delta
            return c
        }
        return out.sorted(by: better)
    }

    /// Measured before unmeasured; closer length; same name start; same
    /// folder; then the name (deterministic).
    nonisolated static func better(_ a: SoundPairCandidate, _ b: SoundPairCandidate) -> Bool {
        if a.lengthMatches != b.lengthMatches { return a.lengthMatches }
        if let da = a.lengthDelta, let db = b.lengthDelta, abs(da - db) > 0.001 { return da < db }
        if a.sameNameStart != b.sameNameStart { return a.sameNameStart }
        if a.sameFolder != b.sameFolder { return a.sameFolder }
        return a.audio.filename < b.audio.filename
    }

    /// "1:30:22" / "4:05".
    nonisolated static func clock(_ seconds: Double) -> String {
        CopiesAdviceInput.durationText(seconds).isEmpty ? "an unknown length" : CopiesAdviceInput.durationText(seconds)
    }
}

/// What the main actor hands the off-main decision.
struct SoundCopyInput: Sendable {
    var recordID: UUID
    var filename: String
    /// How long the picture runs: the catalog's length, else the length a
    /// full Verify measured (an .m2v header records none). nil = unknown.
    var pictureSeconds: Double?
    /// Same-content records (duplicate group, footage group, archive link)
    /// that HAVE a sound track.
    var copiesWithSound: [SoundCopyCandidate]
    /// Audio-only records in the same folder or the same footage group.
    var soundFiles: [SoundPairSource]
}

/// The answer, in the words the person reads.
enum SoundCopyAdvice: Sendable, Equatable {
    /// "Watch the copy with sound: <name> (<volume>)" — Reveal / Play.
    case watch(SoundCopyCandidate)
    /// Every copy with sound is on a drive that is not connected.
    case connect(SoundCopyCandidate)
    /// "Combine with its sound (<file>)" — opens the Combine sheet.
    case combine(SoundPairCandidate)
    /// Same folder / footage and the same name start, but this picture's
    /// length was never measured, so the lengths can't be compared yet.
    case maybeCombine(SoundPairCandidate)
    case none

    var candidate: SoundCopyCandidate? {
        switch self {
        case .watch(let c), .connect(let c): return c
        case .combine(let p), .maybeCombine(let p): return p.audio
        case .none: return nil
        }
    }

    /// The one line under "No sound — this copy has no audio track".
    var line: String {
        switch self {
        case .watch(let c):
            return "Watch the copy with sound: \(c.filename) (\(c.volume))"
        case .connect(let c):
            return "A copy with sound is on \(c.volume), which is not connected: \(c.filename)"
        case .combine(let p):
            return "Combine with its sound (\(p.audio.filename)) — \(p.reason)"
        case .maybeCombine(let p):
            return "Its sound may be \(p.audio.filename) — \(p.reason). Run a full Verify… to measure "
                + "this picture's length, then it can be combined"
        case .none:
            return "No copy with sound is in the catalog."
        }
    }
}

enum SoundCopyFinder {

    // MARK: Decide (pure)

    /// The answer for `input`, given which drives are connected.
    nonisolated static func decide(_ input: SoundCopyInput,
                                   isConnected: (String) -> Bool) -> SoundCopyAdvice {
        let ranked = input.copiesWithSound
            .filter { $0.electionKey.availability > 0 }     // retired drives never count
            .sorted(by: betterCopy)
        if let online = ranked.first(where: { isConnected($0.fullPath) }) { return .watch(online) }
        if let offline = ranked.first { return .connect(offline) }
        return combineAdvice(input, isConnected: isConnected)
    }

    /// Archive copy first, then the keeper election (lexicographic max).
    nonisolated static func betterCopy(_ a: SoundCopyCandidate, _ b: SoundCopyCandidate) -> Bool {
        if a.isArchiveCopy != b.isArchiveCopy { return a.isArchiveCopy }
        return a.electionKey > b.electionKey
    }

    /// The top-ranked sound file on a connected drive: Combine when the
    /// lengths are measured and agree, "may be" when the picture's length
    /// was never measured.
    nonisolated static func combineAdvice(_ input: SoundCopyInput,
                                          isConnected: (String) -> Bool) -> SoundCopyAdvice {
        let ranked = SoundPairRanker.rank(pictureName: input.filename, pictureSeconds: input.pictureSeconds,
                                          sources: input.soundFiles.filter { isConnected($0.audio.fullPath) })
        guard let top = ranked.first else { return .none }
        return top.lengthMatches ? .combine(top) : .maybeCombine(top)
    }

    /// The leading word of a name, lowercased: "Thanksgiving2009-DVD.m2v"
    /// → "thanksgiving2009". Shorter than 4 characters says nothing ("" ).
    nonisolated static func nameStem(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let word = base.prefix { !"-_ .".contains($0) }.lowercased()
        return word.count >= 4 ? word : ""
    }

    // MARK: Gather (main actor, one pass)

    /// The lookup's input for `rec`. ONE pass over `records`; call from a
    /// `.task` or an action, never a view body.
    @MainActor
    static func gather(for rec: VideoRecord, model: VideoScanModel) -> SoundCopyInput {
        let policy = model.duplicateKeeperPolicy()
        func candidate(_ r: VideoRecord, _ relation: String) -> SoundCopyCandidate {
            SoundCopyCandidate(id: r.id, filename: r.filename, fullPath: r.fullPath,
                               volume: VolumeReachability.volumeName(forPath: r.fullPath),
                               durationSeconds: r.durationSeconds, isArchiveCopy: model.isArchiveElement(r),
                               electionKey: policy.electionKey(for: r, technicalScore: DuplicateDetector.keeperScore(r)),
                               relation: relation)
        }
        let members = members(of: rec, in: model.records)
        var copies = members.sameContent.map { candidate($0.record, $0.relation) }
        if let archived = model.archivedCopy(of: rec), archived !== rec, hasSound(archived),
           !copies.contains(where: { $0.id == archived.id }) {
            copies.append(candidate(archived, "archive copy"))
        }
        let sound = members.soundFiles.map {
            SoundPairSource(audio: candidate($0.record, "sound file"), sameFolder: $0.sameFolder, sameFootage: $0.sameFootage)
        }
        return SoundCopyInput(recordID: rec.id, filename: rec.filename, pictureSeconds: pictureSeconds(rec),
                              copiesWithSound: copies, soundFiles: sound)
    }

    /// What the one pass collects.
    struct Members {
        var sameContent: [(record: VideoRecord, relation: String)] = []
        var soundFiles: [(record: VideoRecord, sameFolder: Bool, sameFootage: Bool)] = []
    }

    /// ONE pass, four compares per record (two UUIDs, the stream type, one
    /// folder string). Removed and set-aside records never count.
    @MainActor
    static func members(of rec: VideoRecord, in records: [VideoRecord]) -> Members {
        let dup = rec.duplicateGroupID
        let foot = rec.footage?.groupID
        let folder = rec.directory
        let audioOnly = StreamType.audioOnly.rawValue
        var out = Members()
        for r in records where r !== rec {
            guard !r.isPurged, !r.isSetAside else { continue }
            let inFootage = foot != nil && r.footage?.groupID == foot
            if r.streamTypeRaw == audioOnly {
                let inFolder = !folder.isEmpty && r.directory == folder
                if inFolder || inFootage { out.soundFiles.append((r, inFolder, inFootage)) }
            } else if hasSound(r) {
                if dup != nil, r.duplicateGroupID == dup {
                    out.sameContent.append((r, "exact copy"))
                } else if inFootage {
                    out.sameContent.append((r, "same footage"))
                }
            }
        }
        return out
    }

    /// A picture WITH a sound track (an audio-only file is not a copy to watch).
    nonisolated static func hasSound(_ r: VideoRecord) -> Bool {
        r.streamTypeRaw == StreamType.videoAndAudio.rawValue
    }

    /// The catalog's length, else the full Verify's measured length while
    /// its card still describes the file on disk.
    @MainActor
    static func pictureSeconds(_ rec: VideoRecord) -> Double? {
        if rec.durationSeconds > 0, rec.durationSeconds.isFinite { return rec.durationSeconds }
        guard let card = rec.mediaReportCard, card.isCurrent(forSizeBytes: rec.sizeBytes) else { return nil }
        return card.measuredPictureSeconds
    }

    // MARK: Load (gather on main, decide off main)

    /// The advice for a flagged record; `.none` when the policy does not
    /// flag it (the pass is skipped for every file that has sound).
    /// `flagged` = the caller's own verdict (Get Info's comes from the live
    /// probe); nil = the catalog's stream type decides.
    @MainActor
    static func load(recordID: UUID, model: VideoScanModel, flagged: Bool? = nil) async -> SoundCopyAdvice {
        guard let rec = model.record(forID: recordID),
              flagged ?? rec.catalogSoundPresence.isWarning else { return .none }
        let input = gather(for: rec, model: model)
        return await decideOffMain(input)
    }

    /// Off the main actor: one directory stat per candidate drive, then
    /// decide. (`@concurrent` ≈ "really run on a worker thread"; under
    /// approachable concurrency a plain nonisolated async func would run
    /// on the caller's actor.)
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func decideOffMain(_ input: SoundCopyInput) async -> SoundCopyAdvice {
        decide(input, isConnected: CopiesAdviceDisk.driveIsConnected(forPath:))
    }

    // MARK: For the "no pair found" alerts

    /// Ranked sound files for a video-only record, for a user action (Find
    /// A/V Pair, Find Matching Audio) after Correlate found nothing. One
    /// pass on the main actor; an action handler, never a view body.
    @MainActor
    static func pairCandidates(for rec: VideoRecord, model: VideoScanModel) -> [SoundPairCandidate] {
        guard rec.streamType == .videoOnly else { return [] }
        let input = gather(for: rec, model: model)
        return SoundPairRanker.rank(pictureName: input.filename, pictureSeconds: input.pictureSeconds,
                                    sources: input.soundFiles)
    }

    /// The alert text listing up to three candidates with their reasons.
    nonisolated static func alertText(_ candidates: [SoundPairCandidate]) -> String {
        let lines = candidates.prefix(3).map { "• \($0.audio.filename) (\($0.audio.volume)) — \($0.reason)" }
        return "Sound files that may belong to it (not paired — you choose):\n\n" + lines.joined(separator: "\n")
    }
}
