// ArchiveReadiness.swift
// Archival readiness assessment for Promote to Archive (Rick 2026-08-16):
// PRESERVE – ASSESS – RECORD, never alter bytes. Computed from fields the
// catalog already holds; nothing here re-probes a file. Principles:
//   • warn / observe helpfully, never block — EXCEPT an un-probeable file
//     (no streams / ffprobe failed), and even that the user can override
//     ("Archive anyway (I know this file)");
//   • AUDIO first: "a person can handle wiggly lines in a video, but bad,
//     out-of-sync or missing audio is torture" — audio findings lead the
//     warning list, then format, then date.
// Pure + nonisolated: table-testable without a model.

import Foundation

struct ArchiveReadiness: Equatable, Sendable {

    enum Audio: Equatable, Sendable {
        case verifiedOK
        case verifiedProblem(String)
        case notVerified
        case noAudioTrack
    }
    enum Format: Equatable, Sendable {
        case archivalSafe
        case atRisk(String)
        case unknown
    }
    enum DateState: Equatable, Sendable {
        case known
        case lowConfidence
        case undated
    }

    let playable: Bool
    let audio: Audio
    let format: Format
    let date: DateState
    /// Human sentences, audio first, then format, then date, then other.
    let warnings: [String]
    /// True ONLY for an un-probeable file (no streams / ffprobe failed).
    let blocking: Bool

    // MARK: Inputs (a Sendable slice of VideoRecord)

    struct Inputs: Sendable, Equatable {
        var isPlayable: String = ""
        var streamTypeRaw: String = ""
        var videoCodec: String = ""
        var audioCodec: String = ""
        var container: String = ""
        var audioVerifyStatus: String = ""
        var audioVerifyDate: Date?
        var audioVerifyNote: String = ""
        var audioChannels: String = ""
        var audioSampleRate: String = ""
        var durationSeconds: Double = 0
        var inferredRecordDate: Date?
        var inferredDateConfidence: Float?
        var userDate: String?
        var userDateConfidence: String?
        // Embedded creation date + origin (2026-08-16) and the filename,
        // so the readiness date state reads the SAME resolver as placement.
        var embeddedCreationDate: Date?
        var originMake: String?
        var originModel: String?
        var originEncoder: String?
        var filename: String = ""
        init() {}
    }

    // MARK: Format risk table (LoC Recommended Formats / Sustainability spirit)
    //
    // Keyed by lower-cased ffprobe codec_name (and common aliases). ONE
    // table; a codec that is in neither set is `.unknown` (warn, not
    // at-risk). Container is informational: MOV/MP4/MKV/MXF are fine;
    // AVI/WMV/RM/FLV/VOB wrappers ride with their codecs.
    static let archivalSafeVideoCodecs: Set<String> = [
        // Apple ProRes family
        "prores", "prores_ks", "prores_aw", "prores_videotoolbox", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x",
        // Avid DNxHD / DNxHR
        "dnxhd", "dnxhr", "avdn", "avdh",
        // H.264 / AVC, HEVC / H.265, AV1
        "h264", "avc", "avc1", "x264", "libx264", "h264_videotoolbox",
        "hevc", "h265", "hvc1", "hev1", "x265", "libx265", "hevc_videotoolbox",
        "av1", "libaom-av1", "libsvtav1", "av01",
        // Lossless / uncompressed
        "ffv1", "rawvideo", "v210", "v410", "uyvy", "yuv2", "2vuy", "huffyuv", "ffvhuff", "utvideo",
        // Motion JPEG (fine inside MOV/AVI)
        "mjpeg", "mjpega", "mjpegb", "jpeg", "photo-jpeg",
    ]
    /// codec → short reason shown in the warning ("plan an access copy").
    static let atRiskVideoCodecs: [String: String] = [
        // DV family, HDV, MPEG-1/2 (incl. VOB)
        "dvvideo": "DV", "dv": "DV", "dvcpro": "DVCPRO", "dvcpro50": "DVCPRO50", "dvcprohd": "DVCPRO HD", "dvh1": "DVCPRO HD", "dvhd": "DVCPRO HD", "hdv": "HDV",
        "mpeg1video": "MPEG-1", "mpeg1": "MPEG-1", "mpeg2video": "MPEG-2", "mpeg2": "MPEG-2", "mpegvideo": "MPEG-2", "vob": "MPEG-2 (VOB)",
        // Legacy QuickTime / early codecs
        "svq1": "Sorenson Video 1", "svq3": "Sorenson Video 3", "sorenson": "Sorenson", "cinepak": "Cinepak", "cvid": "Cinepak",
        "indeo3": "Indeo 3", "indeo4": "Indeo 4", "indeo5": "Indeo 5", "iv31": "Indeo", "iv32": "Indeo", "iv41": "Indeo", "iv50": "Indeo",
        "rv10": "RealVideo", "rv20": "RealVideo", "rv30": "RealVideo", "rv40": "RealVideo", "realvideo": "RealVideo",
        // Windows Media / VC-1
        "wmv1": "WMV 7", "wmv2": "WMV 8", "wmv3": "WMV 9", "vc1": "VC-1", "vc-1": "VC-1", "wvc1": "VC-1", "msmpeg4v1": "MS MPEG-4 v1", "msmpeg4v2": "MS MPEG-4 v2", "msmpeg4v3": "MS MPEG-4 v3", "msmpeg4": "MS MPEG-4",
        // MPEG-4 Part 2, H.263, Flash
        "mpeg4": "MPEG-4 Part 2", "divx": "DivX (MPEG-4 Part 2)", "xvid": "Xvid (MPEG-4 Part 2)", "dx50": "DivX (MPEG-4 Part 2)",
        "h263": "H.263", "h263p": "H.263+", "flv1": "Flash Video", "flv": "Flash Video", "vp6": "Flash Video (VP6)", "vp6f": "Flash Video (VP6)",
    ]
    static let acceptableAudioCodecs: Set<String> = [
        "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be", "pcm_f32le", "pcm_f32be",
        "pcm_u8", "pcm_s8", "pcm_mulaw", "pcm_alaw", "pcm", "lpcm", "sowt", "twos", "in24", "in32", "fl32",
        "aac", "mp4a", "aac_at", "flac", "alac", "mp3", "mp3float", "mp2", "opus", "vorbis", "ac3", "eac3", "dts",
    ]
    static let atRiskAudioCodecs: [String: String] = [
        "wmav1": "WMA", "wmav2": "WMA", "wmapro": "WMA Pro", "wmalossless": "WMA Lossless", "wma": "WMA",
        "ra_144": "RealAudio", "ra_288": "RealAudio", "cook": "RealAudio (Cook)", "sipr": "RealAudio (Sipro)", "atrac3": "ATRAC3", "realaudio": "RealAudio",
        "qdm2": "QDesign Music 2", "qdmc": "QDesign Music", "mace3": "MACE 3:1", "mace6": "MACE 6:1", "ima4": "IMA ADPCM (QuickTime)",
        "adpcm_ima_qt": "IMA ADPCM (QuickTime)", "adpcm_ms": "MS ADPCM", "gsm": "GSM", "truespeech": "TrueSpeech",
    ]

    // MARK: Assess (pure)

    static func assess(_ i: Inputs) -> ArchiveReadiness {
        // ---- Playable / blocking
        let stream = StreamType(rawValue: i.streamTypeRaw) ?? .ffprobeFailed
        let hasMedia = stream == .videoAndAudio || stream == .videoOnly || stream == .audioOnly
        let playable = hasMedia && i.isPlayable != "No streams"
        let blocking = !playable

        // ---- Audio
        let hasAudio = stream == .videoAndAudio || stream == .audioOnly
        let audio: Audio
        if !hasAudio {
            audio = .noAudioTrack
        } else if i.audioVerifyStatus == "damaged" {
            audio = .verifiedProblem(i.audioVerifyNote.isEmpty ? "damaged audio" : i.audioVerifyNote)
        } else if i.audioVerifyStatus == "ok" || i.audioVerifyDate != nil {
            audio = i.audioVerifyNote.isEmpty ? .verifiedOK : .verifiedProblem(i.audioVerifyNote)
        } else {
            audio = .notVerified
        }

        // ---- Format
        let format = formatRisk(videoCodec: i.videoCodec, audioCodec: i.audioCodec, stream: stream)

        // ---- Date — the ONE shared ranking (RecordDateResolver), same as
        // ArchivePathResolver.facts(for:) uses for placement.
        let resolution = RecordDateResolver.resolve(userDate: i.userDate,
                                                    userDateConfidence: i.userDateConfidence,
                                                    embeddedCreationDate: i.embeddedCreationDate,
                                                    originMake: i.originMake,
                                                    originModel: i.originModel,
                                                    originEncoder: i.originEncoder,
                                                    inferredRecordDate: i.inferredRecordDate,
                                                    inferredDateConfidence: i.inferredDateConfidence,
                                                    filename: i.filename.isEmpty ? nil : i.filename)
        let date = dateState(resolution)

        let warnings = composeWarnings(i, stream: stream, hasMedia: hasMedia, hasAudio: hasAudio,
                                       blocking: blocking, audio: audio, format: format, date: date,
                                       resolution: resolution)
        return ArchiveReadiness(playable: playable, audio: audio, format: format, date: date,
                                warnings: warnings, blocking: blocking)
    }

    /// Date state from a resolution:
    ///   • `.known` — Rick's own date (any precision: "1992" + I'm-sure means
    ///     the YEAR is certain, and nagging him about his own entry helps
    ///     nobody), or a machine date at day/month precision with
    ///     confidence ≥ 0.6 (embedded camera stamp, trusted dossier date).
    ///   • `.lowConfidence` — placed on a weak signal (filename pattern at
    ///     0.5), or undated because the only signal was a rejected
    ///     inferred date.
    ///   • `.undated` — nothing at all.
    static func dateState(_ r: RecordDateResolution) -> DateState {
        if r.precision == .unknown { return r.hadRejectedSignal ? .lowConfidence : .undated }
        if r.source == .userDate { return .known }
        if r.precision <= .month && r.confidence >= RecordDateResolver.inferredConfidenceFloor { return .known }
        return .lowConfidence
    }

    /// Warning sentences — AUDIO FIRST, then format, then date, then other.
    private static func composeWarnings(_ i: Inputs, stream: StreamType, hasMedia: Bool, hasAudio: Bool,
                                        blocking: Bool, audio: Audio, format: Format, date: DateState,
                                        resolution: RecordDateResolution) -> [String] {
        var warnings: [String] = []
        if blocking {
            warnings.append(stream == .ffprobeFailed
                            ? "Un-probeable — ffprobe could not read this file; the archive would hold bytes nobody has decoded"
                            : "No audio or video streams found — nothing decodable to preserve")
        }
        switch audio {
        case .verifiedProblem(let note): warnings.append("Audio problem — \(note)")
        case .notVerified where hasAudio: warnings.append("Audio not verified — run Verify Audio first if you can (bad or out-of-sync audio is the one thing that ruins a keeper)")
        case .noAudioTrack where stream == .videoOnly: warnings.append("No audio track (video-only) — pair its audio before or after promoting")
        default: break
        }
        if hasAudio, !i.audioCodec.isEmpty, let risk = atRiskAudioCodecs[i.audioCodec.lowercased()] {
            warnings.append("Audio codec \(risk) is legacy/lossy — plan a PCM access copy")
        }
        switch format {
        case .atRisk(let reason): warnings.append("Codec \(reason) is at-risk for long-term access — the original is preserved as-is; plan an access copy (ProRes/H.264)")
        case .unknown where hasMedia && stream != .audioOnly && !i.videoCodec.isEmpty:
            warnings.append("Codec \(i.videoCodec) is not in the archival table — unknown risk, kept as-is")
        default: break
        }
        if i.isPlayable == "Codec unsupported" {
            warnings.append("Playable elsewhere but this Mac's decoders don't support it — archived as-is")
        }
        switch date {
        case .lowConfidence where resolution.precision != .unknown:
            // Placed on a weak signal (a year in the filename): say WHERE
            // it will land so a wrong guess is a visible refile, not a surprise.
            let from = resolution.source == .filename ? "from the filename" : "from a weak signal"
            warnings.append("Date \(resolution.isoString) is a low-confidence guess \(from) — filed under it; confirm or correct it in the inspector")
        case .lowConfidence:
            warnings.append("Date is a low-confidence guess — filed as undated until you confirm it")
        case .undated: warnings.append("Undated — will land in Undated/ (refile later once the date is known)")
        case .known: break
        }
        return warnings
    }

    /// Format risk from the codec table (case-insensitive; aliases welcome).
    static func formatRisk(videoCodec: String, audioCodec: String, stream: StreamType) -> Format {
        if stream == .audioOnly {
            let a = audioCodec.lowercased()
            if let r = atRiskAudioCodecs[a] { return .atRisk(r) }
            if a.isEmpty { return .unknown }
            return acceptableAudioCodecs.contains(a) || a.hasPrefix("pcm_") ? .archivalSafe : .unknown
        }
        let v = videoCodec.lowercased().trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return .unknown }
        if let r = atRiskVideoCodecs[v] { return .atRisk(r) }
        if archivalSafeVideoCodecs.contains(v) { return .archivalSafe }
        // Loose aliases: "ProRes 422 HQ", "H.264", "HEVC (h265)", "DV/DVCPRO", "MPEG-2 Video"…
        let compact = v.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
        for (key, reason) in atRiskVideoCodecs where key.count >= 3 && compact.contains(key) { return .atRisk(reason) }
        for key in ["prores", "dnxh", "h264", "avc1", "hevc", "h265", "ffv1", "av1", "mjpeg", "rawvideo"] where compact.contains(key) {
            return .archivalSafe
        }
        return .unknown
    }

    // MARK: Tokens (manifest column) + summary

    /// Compact machine token: "playable;audio=verified;format=at-risk:DV;date=low".
    var token: String {
        var parts: [String] = [playable ? "playable" : "unprobeable"]
        switch audio {
        case .verifiedOK: parts.append("audio=verified")
        case .verifiedProblem: parts.append("audio=problem")
        case .notVerified: parts.append("audio=unverified")
        case .noAudioTrack: parts.append("audio=none")
        }
        switch format {
        case .archivalSafe: parts.append("format=safe")
        case .atRisk(let r): parts.append("format=at-risk:" + r.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: " ", with: "_"))
        case .unknown: parts.append("format=unknown")
        }
        switch date {
        case .known: parts.append("date=known")
        case .lowConfidence: parts.append("date=low")
        case .undated: parts.append("date=undated")
        }
        return parts.joined(separator: ";")
    }

    /// Short human summary for journey notes: "audio verified, codec DV at-risk, undated".
    var summary: String {
        var parts: [String] = []
        if !playable { parts.append("un-probeable (archived on your say-so)") }
        switch audio {
        case .verifiedOK: parts.append("audio verified")
        case .verifiedProblem(let n): parts.append("audio problem (\(n))")
        case .notVerified: parts.append("audio not verified")
        case .noAudioTrack: parts.append("no audio track")
        }
        switch format {
        case .archivalSafe: parts.append("codec archival-safe")
        case .atRisk(let r): parts.append("codec \(r) at-risk")
        case .unknown: parts.append("codec unknown")
        }
        switch date {
        case .known: break
        case .lowConfidence: parts.append("date low-confidence")
        case .undated: parts.append("undated")
        }
        return parts.joined(separator: ", ")
    }

    /// One-line sheet text: "Playable ✓ · Audio ✓ · Codec: DV (at-risk: plan an access copy) · Date: 1994 (low confidence)".
    func sheetLine(dateLabel: String) -> String {
        var parts: [String] = [playable ? "Playable ✓" : "Un-probeable ✗"]
        switch audio {
        case .verifiedOK: parts.append("Audio ✓")
        case .verifiedProblem(let n): parts.append("Audio ✗ \(n)")
        case .notVerified: parts.append("Audio — not verified")
        case .noAudioTrack: parts.append("Audio —")
        }
        switch format {
        case .archivalSafe: parts.append("Codec: safe")
        case .atRisk(let r): parts.append("Codec: \(r) (at-risk: plan an access copy)")
        case .unknown: parts.append("Codec: unknown")
        }
        switch date {
        case .known: parts.append("Date: \(dateLabel)")
        case .lowConfidence: parts.append("Date: \(dateLabel) (low confidence)")
        case .undated: parts.append("Date: undated")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Main-actor bridge

extension ArchiveReadiness {
    /// Snapshot the fields from a live record (main actor) and assess.
    @MainActor
    static func assess(record r: VideoRecord) -> ArchiveReadiness {
        var i = Inputs()
        i.isPlayable = r.isPlayable
        i.streamTypeRaw = r.streamTypeRaw
        i.videoCodec = r.videoCodec
        i.audioCodec = r.audioCodec
        i.container = r.container
        i.audioVerifyStatus = r.audioVerifyStatus
        i.audioVerifyDate = r.audioVerifyDate
        i.audioVerifyNote = r.audioVerifyNote
        i.audioChannels = r.audioChannels
        i.audioSampleRate = r.audioSampleRate
        i.durationSeconds = r.durationSeconds
        i.inferredRecordDate = r.inferredRecordDate
        i.inferredDateConfidence = r.inferredDateConfidence
        i.userDate = r.userDate
        i.userDateConfidence = r.userDateConfidence
        i.embeddedCreationDate = r.embeddedCreationDate
        i.originMake = r.originMake
        i.originModel = r.originModel
        i.originEncoder = r.originEncoder
        i.filename = r.filename
        return assess(i)
    }
}
