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
    var a: [Bool] = []
    var b: [Bool] = []
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
        var sideA = Self.relatedSide(a, isArchiveFile: isArchiveCopy(a) || isInsideMasterArchive(path: a.fullPath), isArchived: isArchived(a), now: now)
        var sideB = Self.relatedSide(b, isArchiveFile: isArchiveCopy(b) || isInsideMasterArchive(path: b.fullPath), isArchived: isArchived(b), now: now)
        let known = Set(a.confirmedByUserPeople.map(\.name) + b.confirmedByUserPeople.map(\.name) + a.detectedPeople + b.detectedPeople)
        sideA.namesSaid = Self.namesSaid(in: a.audioTranscript, known: known)
        sideB.namesSaid = Self.namesSaid(in: b.audioTranscript, known: known)
        let keyA = Self.fingerprintKey(a), keyB = Self.fingerprintKey(b)
        let directory = audioFingerprintSidecarDirectory
        let sound = await Task.detached(priority: .userInitiated) {
            Self.soundEvidence(keyA: keyA, keyB: keyB, directory: directory)
        }.value
        if let s = sound.audibleA { sideA.audibleSeconds = s }
        if let s = sound.audibleB { sideB.audibleSeconds = s }
        let evidence = RelatedEvidence(a: sideA, b: sideB, audio: sound.verdict, audioCoverage: sound.coverage, video: nil)
        let verdict = RelatedLadder.judge(evidence)
        return RelatedAnswer(evidence: evidence, verdict: verdict,
                             recommendation: EventRecommendation.recommend(verdict, evidence: evidence),
                             strips: sound.strips)
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
        let audible: Double? = r.audioFingerprint.map { $0.outcome == .noAudio ? 0 : $0.analyzedSeconds }
        return RelatedEvidence.Side(
            digest: storedFullDigest(r), sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds,
            audibleSeconds: audible, day: day, dayIsReliable: reliable,
            people: Set(r.confirmedByUserPeople.map(\.name)), namesSaid: [],
            occasionWords: occasionWords(captions: r.sceneCaptions, transcript: r.audioTranscript),
            folderLabel: folderLabel(forPath: r.fullPath), isArchiveFile: isArchiveFile, isArchived: isArchived,
            codec: codecGeneration(video: r.videoCodec, audio: r.audioCodec),
            frameHeight: frameHeight(fromResolution: r.resolution), bitRate: bitRate(from: r.totalBitrate))
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

    nonisolated static func fingerprintKey(_ r: VideoRecord) -> AudioFingerprintStore.Key? {
        guard let s = r.audioFingerprint, s.outcome == .fingerprinted else { return nil }
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

    /// Load both fingerprints from the sidecar and match `a` against `b`.
    /// A side with no fingerprint leaves the verdict nil (the ladder says
    /// what is missing); a store that cannot open does the same.
    nonisolated static func soundEvidence(keyA: AudioFingerprintStore.Key?, keyB: AudioFingerprintStore.Key?,
                                          directory: URL) -> SoundEvidence {
        var out = SoundEvidence()
        guard let keyA, let keyB, let store = try? AudioFingerprintStore(directory: directory),
              let fa = try? store.fingerprint(for: keyA), let fb = try? store.fingerprint(for: keyB) else { return out }
        out.audibleA = Double(fa.activeSeconds.isEmpty ? Int(fa.durationSeconds) : fa.activeSecondCount)
        out.audibleB = Double(fb.activeSeconds.isEmpty ? Int(fb.durationSeconds) : fb.activeSecondCount)
        out.strips.a = fa.activeSeconds.isEmpty ? Array(repeating: true, count: Int(fa.durationSeconds)) : fa.activeSeconds
        out.strips.b = fb.activeSeconds.isEmpty ? Array(repeating: true, count: Int(fb.durationSeconds)) : fb.activeSeconds
        let match = AudioFingerprintMatcher.match(query: fa, master: fb)
        out.verdict = match.verdict
        out.coverage = match.evidence.coverage
        switch match.verdict {
        case .sameRecording, .containedInMaster, .masterContainedInQuery, .overlap:
            let offset = match.evidence.offsetSeconds
            out.strips.offsetSeconds = offset
            let startB = max(0, Int(match.spanStartInMasterSeconds.rounded(.down)))
            let endB = min(out.strips.b.count, Int(match.spanEndInMasterSeconds.rounded(.up)))
            if endB > startB {
                out.strips.matchedB = startB..<endB
                let startA = max(0, Int((Double(startB) - offset).rounded(.down)))
                let endA = min(out.strips.a.count, Int((Double(endB) - offset).rounded(.up)))
                if endA > startA { out.strips.matchedA = startA..<endA }
            }
        case .different, .inconclusive:
            break
        }
        return out
    }
}
