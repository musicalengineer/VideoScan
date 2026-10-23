// VideoScanModel+RelatedEvidence.swift
// Compare Media's catalog half (docs/design/event_analyzer_compare_media_2026_10_15.md):
// two records → `RelatedEvidence` (values, on the main actor) → the audio
// match off the main actor → `RelatedLadder.judge` and
// `EventRecommendation.recommend` (pure, VideoScanCore).
//
// What each side is made of, and where it comes from:
//   digest           the stored whole-file SHA-256 (Cleanup's `storedFullDigest`)
//   audible seconds  the fingerprint's active-seconds bitmap (loaded from the
//                    sidecar for the match); a no-sound stamp = 0
//   day              EventsDate.resolve (you › camera › inferred › file name);
//                    reliable = your date, or a trusted camera date, to the day
//   people           confirmedByUserPeople; names said = transcript words that
//                    are people's names on either side
//   occasion words   the event categories the words support (EventCategoryRules)
//   folder label     the parent folder's name, unless it is a generic one
//   archive          isArchiveFile (a file OF the archive) / isArchived (content held)
//   codec generation an original-quality capture vs a delivery re-encode
//
// Memory: two value structs and two fingerprints (~13 KB a minute of audio).

import Foundation
import VideoScanCore

/// The ladder's answer for one pair, with the evidence it judged and the
/// per-second sound maps the spools draw.
struct RelatedAnswer: Sendable, Equatable {
    let evidence: RelatedEvidence
    let verdict: RelatedVerdict
    let recommendation: EventRecommendation
    let strips: RelatedStrips
}

/// One flag per second of each file (true = audible), and the matched
/// stretch in each file's own seconds, when the sound matched.
struct RelatedStrips: Sendable, Equatable {
    /// One flag per second; nil = not measured (no fingerprint, or a print
    /// with no landmark and no measurement) — drawn as "not measured",
    /// never as silence.
    var a: [Bool]?
    var b: [Bool]?
    /// Why a side's strip is quiet when it came from the STAMP, not a print:
    /// "Measured silent" / "No sound track". nil with a nil strip = unknown.
    var wordsA: String?
    var wordsB: String?
    /// Where `a`'s second 0 sits in `b` (negative: `b` starts inside `a`).
    var offsetSeconds: Double = 0
    var matchedA: Range<Int>?
    var matchedB: Range<Int>?
}

extension VideoScanModel {

    /// The pair's answer: the projection here, the fingerprints and the
    /// match off the main actor. Never called from a view body.
    func relatedAnswer(a: VideoRecord, b: VideoRecord) async -> RelatedAnswer {
        let now = Date()
        // Archived = PROVEN (GH #327); a sampled-only match is its own words.
        var sideA = Self.relatedSide(a, isArchiveFile: isArchiveCopy(a) || isInsideMasterArchive(path: a.fullPath), isArchived: isProvenArchived(a), now: now)
        var sideB = Self.relatedSide(b, isArchiveFile: isArchiveCopy(b) || isInsideMasterArchive(path: b.fullPath), isArchived: isProvenArchived(b), now: now)
        sideA.isPossiblyArchivedSampled = isPossiblyArchivedSampled(a)
        sideB.isPossiblyArchivedSampled = isPossiblyArchivedSampled(b)
        let known = Set(a.confirmedByUserPeople.map(\.name) + b.confirmedByUserPeople.map(\.name) + a.detectedPeople + b.detectedPeople)
        sideA.namesSaid = Self.namesSaid(in: a.audioTranscript, known: known)
        sideB.namesSaid = Self.namesSaid(in: b.audioTranscript, known: known)
        let keyA = Self.fingerprintKey(a), keyB = Self.fingerprintKey(b)
        let directory = audioFingerprintSidecarDirectory
        let pathA = a.fullPath, pathB = b.fullPath
        let (sound, onDiskA, onDiskB) = await Task.detached(priority: .userInitiated) {
            (Self.soundEvidence(keyA: keyA, keyB: keyB, directory: directory),
             Self.isOnDisk(pathA), Self.isOnDisk(pathB))
        }.value
        sideA.isOnDisk = onDiskA
        sideB.isOnDisk = onDiskB
        if let s = sound.audibleA { sideA.audibleSeconds = s }
        if let s = sound.audibleB { sideB.audibleSeconds = s }
        let evidence = RelatedEvidence(a: sideA, b: sideB, audio: sound.verdict, audioCoverage: sound.coverage, video: nil)
        let verdict = RelatedLadder.judge(evidence)
        return RelatedAnswer(evidence: evidence, verdict: verdict,
                             recommendation: EventRecommendation.recommend(verdict, evidence: evidence),
                             strips: Self.completedStrips(sound.strips, a: a, b: b))
    }

    /// A side the sidecar gave no strip (no print to load) takes one from its
    /// STAMP: quiet, with the reason, for measured silence or no sound track;
    /// still nil — "Sound not measured" — when nothing is known (QA round 2).
    static func completedStrips(_ strips: RelatedStrips, a: VideoRecord, b: VideoRecord) -> RelatedStrips {
        var out = strips
        if out.a == nil { (out.a, out.wordsA) = stampStrip(a) }
        if out.b == nil { (out.b, out.wordsB) = stampStrip(b) }
        return out
    }

    /// The strip a record's stamp (or header) can stand behind with no print
    /// loaded: measured silence → all quiet, "Measured silent"; a real
    /// no-sound track (the stamp, or a header with no audio codec and no
    /// stamp) → all quiet, "No sound track"; anything else → (nil, nil).
    static func stampStrip(_ r: VideoRecord) -> (active: [Bool]?, words: String?) {
        let quiet = Array(repeating: false, count: max(0, Int(r.durationSeconds)))
        let headerHasAudio = !r.audioCodec.isEmpty
        guard let stamp = r.audioFingerprint, stamp.sizeBytes == r.sizeBytes else {
            // Only a header that SAYS video-only is a no-sound fact; an
            // ffprobe failure (no codec either) stays unknown.
            return r.streamType == .videoOnly && !headerHasAudio ? (quiet, "No sound track") : (nil, nil)
        }
        switch stamp.hearing(headerHasAudio: headerHasAudio) {
        case .measuredSilence: return (quiet, "Measured silent")
        case .noAudioTrack: return (quiet, "No sound track")
        case .heardSound, .notEvidence: return (nil, nil)
        }
    }

    // MARK: One side (pure)

    nonisolated static func relatedSide(_ r: VideoRecord, isArchiveFile: Bool, isArchived: Bool, now: Date) -> RelatedEvidence.Side {
        let date = EventsDate.resolve(
            EventsDateFacts(userDate: r.userDate, userDateConfidence: r.userDateConfidence,
                            embeddedCreationDate: r.embeddedCreationDate, originMake: r.originMake, originModel: r.originModel,
                            originEncoder: r.originEncoder, inferredRecordDate: r.inferredRecordDate,
                            inferredDateConfidence: r.inferredDateConfidence, inferredDateRange: r.inferredDateRange,
                            inferredDateSource: r.inferredDateSource),
            filename: r.filename, path: r.fullPath, now: now)
        var day: EventDay?
        if let y = date.year, let m = date.month, let d = date.day { day = EventDay(year: y, month: m, day: d) }
        let reliable = day != nil && (date.source == .you || (date.source == .camera && date.trusted))
        let audible: Double? = r.audioFingerprint.flatMap { Self.stampAudibleSeconds($0, headerHasAudio: !r.audioCodec.isEmpty) }
        return RelatedEvidence.Side(
            digest: storedFullDigest(r), sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds,
            audibleSeconds: audible, day: day, dayIsReliable: reliable,
            people: Set(r.confirmedByUserPeople.map(\.name)), namesSaid: [],
            occasionWords: occasionWords(captions: r.sceneCaptions, transcript: r.audioTranscript),
            folderLabel: folderLabel(forPath: r.fullPath), isArchiveFile: isArchiveFile, isArchived: isArchived,
            codec: codecGeneration(video: r.videoCodec, audio: r.audioCodec),
            frameHeight: frameHeight(fromResolution: r.resolution), bitRate: bitRate(from: r.totalBitrate),
            year: date.year)
    }

    /// What a sound-print STAMP says was audible (GH #327 case 5), read
    /// through `AudioFingerprintStamp.hearing`: no sound track, or measured
    /// silence = 0 — never "analysed seconds of sound"; a print with
    /// landmarks = the analysed seconds (an upper bound; the sidecar's
    /// active-seconds bitmap refines it in `relatedAnswer`). A stamp that
    /// is not evidence (a failed decode, a pre-rule-4 zero-landmark print
    /// that may have heard real sound) = nil: "no fingerprint yet", never
    /// "no sound".
    nonisolated static func stampAudibleSeconds(_ stamp: AudioFingerprintStamp, headerHasAudio: Bool) -> Double? {
        switch stamp.hearing(headerHasAudio: headerHasAudio) {
        case .noAudioTrack, .measuredSilence: return 0
        case .heardSound: return stamp.analyzedSeconds
        case .notEvidence: return nil
        }
    }

    /// The audible seconds a loaded print stands behind: its active-seconds
    /// count when it has the bitmap, else its duration (prints made before
    /// the bitmap). With NO landmark: nil — a sidecar blob carries no
    /// absolute measurement, so it cannot tell silence from "too little to
    /// print"; measured silence comes from the stamp (`stampAudibleSeconds`).
    nonisolated static func printAudibleSeconds(_ print: AudioFingerprint) -> Double? {
        guard print.landmarkCount > 0 else { return nil }
        return Double(print.activeSeconds.isEmpty ? Int(print.durationSeconds) : print.activeSecondCount)
    }

    /// Transcript words that are a person's name on either side (case-insensitive, whole words).
    nonisolated static func namesSaid(in transcript: String?, known: Set<String>) -> Set<String> {
        guard let t = transcript?.lowercased(), !t.isEmpty, !known.isEmpty else { return [] }
        let words = Set(t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map { String($0) })
        return Set(known.filter { name in
            let first = name.lowercased().split(separator: " ").first.map(String.init) ?? name.lowercased()
            return !first.isEmpty && words.contains(first)
        })
    }

    /// The kinds of occasion the recording's words support ("birthday",
    /// "christmas"): a non-clue when both sides share one.
    nonisolated static func occasionWords(captions: [SceneCaption], transcript: String?) -> Set<String> {
        Set(EventCategoryRules.evidence(captions: captions, transcript: transcript, labels: []).map { $0.category.lowercased() })
    }

    /// The parent folder's name, unless it is one every drive has.
    nonisolated static func folderLabel(forPath path: String) -> String? {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.lowercased()
        let generic: Set<String> = ["", "movies", "video_ts", "media", "clips", "videos", "export", "exports", "originals",
                                    "masters", "mxf", "1", "2", "3", "4", "avid mediafiles", "omfi mediafiles", "desktop", "downloads"]
        return generic.contains(parent) ? nil : parent
    }

    nonisolated static func codecGeneration(video: String, audio: String) -> CodecGeneration {
        let v = video.lowercased(), a = audio.lowercased()
        let original = ["dvvideo", "dv", "ffv1", "prores", "rawvideo", "v210", "huffyuv", "utvideo", "mjpeg", "hap"]
        let delivery = ["h264", "avc", "hevc", "h265", "mpeg2", "mpeg4", "mpeg1", "wmv", "vp8", "vp9", "av1", "svq", "sorenson", "cinepak"]
        if original.contains(where: { v.contains($0) }) { return .original }
        if delivery.contains(where: { v.contains($0) }) { return .delivery }
        if v.isEmpty {
            if a.contains("pcm") || a.contains("flac") || a.contains("alac") { return .original }
            if a.contains("aac") || a.contains("mp3") || a.contains("ac3") || a.contains("ac-3") { return .delivery }
        }
        return .unknown
    }

    /// "720x480" → 480; "1920×1080" → 1080.
    nonisolated static func frameHeight(fromResolution r: String) -> Int? {
        let parts = r.lowercased().split(whereSeparator: { $0 == "x" || $0 == "×" })
        guard parts.count == 2, let h = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return h > 0 ? h : nil
    }

    /// "8 Mb/s" → 8_000_000; "1500 kb/s" → 1_500_000; a bare number is bits per second.
    nonisolated static func bitRate(from s: String) -> Int64? {
        let lower = s.lowercased().replacingOccurrences(of: ",", with: "")
        guard let number = Double(lower.prefix(while: { $0.isNumber || $0 == "." })), number > 0 else { return nil }
        if lower.contains("mb") { return Int64(number * 1_000_000) }
        if lower.contains("kb") { return Int64(number * 1_000) }
        return Int64(number)
    }

    /// The file is at its path (a plain file; a drive that is not mounted
    /// answers nil, not false — "not asked", never "gone").
    nonisolated static func isOnDisk(_ path: String) -> Bool? {
        guard !path.isEmpty else { return false }
        if Self.isExternalVolumePath(path), !VolumeReachability.isReachable(path: path) { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// One flag per second for a loaded print: the bitmap (all audible for a
    /// pre-bitmap print). With NO landmark: nil — unknown, never drawn as
    /// silence (QA P3a); a side's quiet strip comes from its stamp
    /// (`stampStrip`), the only place silence is measured.
    nonisolated static func soundStrip(_ print: AudioFingerprint) -> [Bool]? {
        guard print.landmarkCount > 0 else { return nil }
        let seconds = max(0, Int(print.durationSeconds))
        return print.activeSeconds.isEmpty ? Array(repeating: true, count: seconds) : print.activeSeconds
    }

    /// The sidecar key of a stamp that is EVIDENCE of sound to match
    /// (`hearing == .heardSound`). A measured-silent print has nothing to
    /// match, and a not-evidence stamp (a pre-rule-4 zero-landmark print)
    /// must not be offered as if it were (QA P3a).
    nonisolated static func fingerprintKey(_ r: VideoRecord) -> AudioFingerprintStore.Key? {
        guard let s = r.audioFingerprint, s.hearing(headerHasAudio: !r.audioCodec.isEmpty) == .heardSound else { return nil }
        return AudioFingerprintStore.Key(contentDigest: s.contentDigest, sizeBytes: s.sizeBytes)
    }

    // MARK: The sound (off the main actor)

    struct SoundEvidence: Sendable {
        var verdict: AudioMatchVerdict?
        var coverage: Double?
        var audibleA: Double?
        var audibleB: Double?
        var strips = RelatedStrips()
    }

    /// Load each side's fingerprint from the sidecar ON ITS OWN — a side
    /// with a print gets its audible seconds and strip whatever the other
    /// side has (QA round 2) — and match `a` against `b` only when both
    /// loaded. A side with no fingerprint leaves the verdict nil (the ladder
    /// says what is missing); a store that cannot open does the same.
    nonisolated static func soundEvidence(keyA: AudioFingerprintStore.Key?, keyB: AudioFingerprintStore.Key?,
                                          directory: URL) -> SoundEvidence {
        var out = SoundEvidence()
        guard keyA != nil || keyB != nil, let store = try? AudioFingerprintStore(directory: directory) else { return out }
        let fa = keyA.flatMap { try? store.fingerprint(for: $0) }
        let fb = keyB.flatMap { try? store.fingerprint(for: $0) }
        if let fa { out.audibleA = printAudibleSeconds(fa); out.strips.a = Self.soundStrip(fa) }
        if let fb { out.audibleB = printAudibleSeconds(fb); out.strips.b = Self.soundStrip(fb) }
        guard let fa, let fb else { return out }
        let match = AudioFingerprintMatcher.match(query: fa, master: fb)
        out.verdict = match.verdict
        out.coverage = match.evidence.coverage
        switch match.verdict {
        case .sameRecording, .containedInMaster, .masterContainedInQuery, .overlap:
            let offset = match.evidence.offsetSeconds
            out.strips.offsetSeconds = offset
            let startB = max(0, Int(match.spanStartInMasterSeconds.rounded(.down)))
            let endB = min(out.strips.b?.count ?? 0, Int(match.spanEndInMasterSeconds.rounded(.up)))
            if endB > startB {
                out.strips.matchedB = startB..<endB
                let startA = max(0, Int((Double(startB) - offset).rounded(.down)))
                let endA = min(out.strips.a?.count ?? 0, Int((Double(endB) - offset).rounded(.up)))
                if endA > startA { out.strips.matchedA = startA..<endA }
            }
        case .different, .inconclusive:
            break
        }
        return out
    }
}
