// ArchiveReadiness.swift
// Archival readiness assessment for Promote to Archive (Rick 2026-08-16):
// PRESERVE – ASSESS – RECORD, never alter bytes. Computed from fields the
// catalog already holds; nothing here re-probes a file. Principles:
//   • warn / observe helpfully, never block — EXCEPT an un-probeable file
//     (no streams / ffprobe failed), and even that the user can override
//     ("Archive anyway (I know this file)"). Since 2026-11-10 the Promote
//     JOB also refuses missing, silent or damaged sound (PromoteSoundGate):
//     a measurement taken in the job, not a field read here, and that tick
//     does not waive it (the sound override is the “Silent — checked” tag);
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
    /// What the stored sound check MEANS for Promote (Rick 2026-11-16: the
    /// sheet showed a mono file as a red "audio problem" while the gate
    /// passes mono). `Audio` says whether a check ran and left a note; this
    /// says what kind of note, in the Promote gate's own terms (DECISIONS
    /// 2026-11-10: mono and one-sided pass; missing, silent or damaged
    /// sound is refused). Read from the stored verdict — the sheet's
    /// forecast; the gate still measures the bytes itself at Promote.
    /// (For Rick: an enum with payloads ≈ std::variant.)
    ///
    /// Codex #300 (2026-11-16): each case is one answer of the gate, so the
    /// sheet can not be green where the gate refuses nor red where it
    /// accepts (SoundStandingFollowsGateTests walks every class).
    enum SoundStanding: Equatable, Sendable {
        /// Checked, nothing to say. Green.
        case fine
        /// Checked; mono — ONE channel in the file, and the record agrees it
        /// has one channel. Not a problem, nothing to do. Green.
        case note(String)
        /// Checked, and the stored note is about the LAYOUT (surround, two
        /// or more live tracks) or is one this code does not recognise. The
        /// check then measured that there is sound, not whether each track
        /// or channel is balanced. Promote accepts it; never green.
        case unmeasured(String)
        /// Checked; sound on one side only, or lopsided. Promote accepts
        /// it; a balanced copy is the better thing to archive.
        case unbalanced(String)
        /// Checked; damaged, silent or no stream — Promote refuses it. Red.
        case refusable(String)
        /// Silent, or no audio track, and the owner's “Silent — checked” tag
        /// speaks for this file AS CATALOGUED: Promote accepts it if the
        /// file is still that one. The payload is the sentence shown.
        /// Neutral — said, not counted as a problem, never a promise.
        case accepted(String)
        /// No stored check describes this file's sound: never checked, a
        /// stored "mono" on a record that is not one channel, or a file
        /// that could not be probed. Promote measures it.
        case notChecked
        /// A video with no audio track and no accepting tag — Promote
        /// refuses it. Red.
        case noTrack

        /// The sound part of the sheet's one-line summary. ✓ only for the
        /// green cases, ✗ only for what Promote refuses.
        var sheetWords: String {
            switch self {
            case .fine: return "Audio ✓"
            case .note(let n): return "Audio ✓ \(n)"
            case .unmeasured(let n): return "Audio: \(n) (balance not measured)"
            case .unbalanced(let n): return "Audio ⚠ \(n)"
            case .refusable(let n): return "Audio ✗ \(n)"
            case .accepted(let words): return "Audio: \(words)"
            case .notChecked: return "Audio — checked when you promote"
            case .noTrack: return "Audio ✗ no audio track"
            }
        }

        /// The ONE audio counter this row is counted under.
        var bucket: SoundBucket {
            switch self {
            case .fine, .note: return .fine
            case .unmeasured, .accepted: return .noted
            case .unbalanced: return .unbalanced
            case .refusable, .noTrack: return .refused
            case .notChecked: return .notChecked
            }
        }
    }
    /// The Promote sheet's audio counters: an exclusive partition — every
    /// selected row is in exactly one (Codex #300 F5).
    enum SoundBucket: Sendable, Equatable, CaseIterable {
        /// Checked and fine (plain, or mono).
        case fine
        /// Something is said about the sound that is not a problem: a
        /// layout note, or silence the owner's tag accepts.
        case noted
        /// One side only / lopsided: accepted, better balanced.
        case unbalanced
        /// Promote will refuse it: damaged, silent, no stream, no track.
        case refused
        /// Promote measures it first.
        case notChecked
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
    /// What `audio` means for Promote — the sheet's colours and counters
    /// read THIS, never "is there a note".
    let sound: SoundStanding
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
        /// The scan's channel count for the first audio stream ("1", "2").
        var audioChannels: String = ""
        /// Does the owner's “Silent — checked” tag speak for this file?
        /// The gate's own answer (PromoteSoundGate.mark), forecast from the
        /// record — see `forecastSoundMark`. In memory only, never stored.
        var soundMark: PromoteSoundGate.Mark = .absent
        var audioSampleRate: String = ""
        var durationSeconds: Double = 0
        var inferredRecordDate: Date?
        var inferredDateConfidence: Float?
        /// GH #201: a year-precise inference files at year precision.
        var inferredDateRange: InferredDateRange?
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
        // A stored "damaged" comes first, track or no track (Codex #302): a
        // reference movie has no audio stream of its own AND is damaged, and
        // Promote's gate puts damage ahead of "no track".
        let audio: Audio
        if i.audioVerifyStatus == "damaged" {
            audio = .verifiedProblem(i.audioVerifyNote.isEmpty ? "damaged audio" : i.audioVerifyNote)
        } else if !hasAudio {
            audio = .noAudioTrack
        } else if i.audioVerifyStatus == "ok" || i.audioVerifyDate != nil {
            audio = i.audioVerifyNote.isEmpty ? .verifiedOK : .verifiedProblem(i.audioVerifyNote)
        } else {
            audio = .notVerified
        }

        // An un-probeable file has no sound fact at all: Promote's gate
        // answers "could not check" for it, so it is not "no track" — unless
        // damage is stored, which nothing outranks.
        let sound: SoundStanding = blocking && i.audioVerifyStatus != "damaged"
            ? .notChecked
            : soundStanding(audio: audio, audioVerifyStatus: i.audioVerifyStatus,
                            channelCount: channelCount(i.audioChannels), mark: i.soundMark)

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
                                                    inferredDateRange: i.inferredDateRange,
                                                    filename: i.filename.isEmpty ? nil : i.filename)
        let date = dateState(resolution)

        let warnings = composeWarnings(i, stream: stream, hasMedia: hasMedia, hasAudio: hasAudio,
                                       blocking: blocking, sound: sound, format: format, date: date,
                                       resolution: resolution)
        return ArchiveReadiness(playable: playable, audio: audio, sound: sound, format: format, date: date,
                                warnings: warnings, blocking: blocking)
    }

    /// The ONE "no usable sound" rule (Rick 2026-10-06 — the Archive
    /// Angel's `noSound` floor): true for anything but a picture WITH a
    /// sound track (video-only, audio-only, un-probed), for damaged audio
    /// (Verify Audio's "damaged"), and for a track Verify Audio found
    /// silent or missing (status "ok" + that note fragment — honest states,
    /// not damage, so the status alone cannot say it). A track never
    /// checked is NOT refused here: Prepare checks it, and it is never
    /// "Ready" until it has been (ArchiveAngelStatusWords.needs).
    /// Informational notes (surround, two live tracks, mono) pass. The
    /// owner's “Silent — checked” tag does not change this floor. Pure.
    static func lacksUsableSound(streamTypeRaw: String, audioVerifyStatus: String,
                                 audioVerifyNote: String) -> Bool {
        guard streamTypeRaw == StreamType.videoAndAudio.rawValue else { return true }
        if audioVerifyStatus == "damaged" { return true }
        guard !audioVerifyNote.isEmpty else { return false }
        let fragments = audioVerifyNote.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        return fragments.contains(silentNoteFragment) || fragments.contains(noStreamNoteFragment)
    }
    private static let silentNoteFragment = VerifyAudioRules.noteFragment(for: .silentAudio)
    private static let noStreamNoteFragment = VerifyAudioRules.noteFragment(for: .noAudioStream)
    /// The note fragments Balance Audio exists for: sound on one side, or
    /// lopsided. Mono (a single-channel track) is NOT one of them — it is
    /// how the recording was made.
    private static let unbalancedNoteFragments: Set<String> = [
        VerifyAudioRules.noteFragment(for: .channelImbalance(.leftOnly)),
        VerifyAudioRules.noteFragment(for: .channelImbalance(.rightOnly)),
        VerifyAudioRules.noteFragment(for: .channelImbalance(.trueStereo)),   // the generic "channel imbalance"
    ]

    private static let monoNoteFragment = VerifyAudioRules.noteFragment(for: .channelImbalance(.mono))

    /// "2" → 2. nil when the record states no count: unknown, not zero.
    static func channelCount(_ stored: String) -> Int? {
        let digits = stored.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        guard let n = Int(digits), n > 0 else { return nil }
        return n
    }

    /// Would Promote's gate refuse this sound, given the owner's mark? The
    /// gate's own decision (one engine): only whether it refuses is read,
    /// never its words. Pure.
    private static func gateRefuses(_ finding: PromoteSoundGate.Finding, mark: PromoteSoundGate.Mark) -> Bool {
        PromoteSoundGate.decide(finding: finding, mark: mark, soundPartnerName: nil, recordedYear: nil,
                                digestPrefix: "").isRefusal
    }
    // A FORECAST, so conditional words (Codex #302): the tag is read against
    // the file as catalogued; the Promote job reads it again against the
    // bytes it proves, and refuses if the file is no longer that one.
    static let acceptedSilentWords = "Silent — your “\(PromoteSoundGate.ownerTag)” tag covers this file as catalogued"
    static let acceptedNoTrackWords = "No audio track — your “\(PromoteSoundGate.ownerTag)” tag covers this file as catalogued"
    /// What every "accepted" sentence ends with: the condition.
    static let acceptedConditionWords = "Promote checks the file is still that one before archiving it without sound"

    /// THE reading of a stored sound verdict for the Promote sheet. The
    /// worst fragment wins: refusable, then a stored "mono" that does not
    /// describe the file, then unbalanced; green is only "nothing found" or
    /// mono alone; anything else is a layout note (never green). "Refusable"
    /// is the same rule as `lacksUsableSound` (a test pins the two together)
    /// minus what the owner's tag accepts.
    ///
    /// `channelCount`: the record's own (nil = it states none). Mono means
    /// ONE channel in the file, so a stored "mono audio" on a record that is
    /// not one channel was measured on something else (Codex #300 F2).
    /// `mark`: the gate's reading of the “Silent — checked” tag (F4).
    /// The defaults are the cautious side: mono not confirmed, no tag. Pure.
    static func soundStanding(audio: Audio, audioVerifyStatus: String,
                              channelCount: Int? = nil,
                              mark: PromoteSoundGate.Mark = .absent) -> SoundStanding {
        // Damage first, whatever `audio` says: the owner's tag accepts
        // silence and a missing track, never damage (Codex #302).
        if audioVerifyStatus == "damaged" {
            if case .verifiedProblem(let note) = audio { return .refusable(note) }
            return .refusable("damaged audio")
        }
        switch audio {
        case .verifiedOK: return .fine
        case .notVerified: return .notChecked
        case .noAudioTrack:
            return gateRefuses(.noTrack, mark: mark) ? .noTrack : .accepted(acceptedNoTrackWords)
        case .verifiedProblem(let note):
            return standing(ofStoredNote: note, channelCount: channelCount, mark: mark)
        }
    }

    /// The reading of a NOTE stored beside an "ok" verdict (never a damaged
    /// one — `soundStanding` has answered that). Fragment by fragment, worst
    /// first. Pure.
    private static func standing(ofStoredNote note: String, channelCount: Int?,
                                 mark: PromoteSoundGate.Mark) -> SoundStanding {
        let fragments = note.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        if fragments.contains(noStreamNoteFragment) {
            return gateRefuses(.noTrack, mark: mark) ? .refusable(note) : .accepted(acceptedNoTrackWords)
        }
        if fragments.contains(silentNoteFragment) {
            let silent = PromoteSoundGate.Finding.silent(levels: "", loudestDBFS: -.infinity)
            return gateRefuses(silent, mark: mark) ? .refusable(note) : .accepted(acceptedSilentWords)
        }
        if fragments.contains(monoNoteFragment), channelCount != 1 { return .notChecked }
        if fragments.contains(where: unbalancedNoteFragments.contains) { return .unbalanced(note) }
        if fragments == [monoNoteFragment] { return .note(note) }
        return .unmeasured(note)
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

    /// The one sentence about the sound, or nil when there is nothing to
    /// say (checked and fine, or mono). Pure.
    static func soundWarning(_ sound: SoundStanding, hasAudio: Bool) -> String? {
        switch sound {
        case .refusable(let note):
            return "Audio problem — \(note) — Promote refuses it (it measures the sound again first)"
        case .unbalanced(let note):
            return "Sound is not balanced — \(note) — it can be archived as it is; a balanced copy plays on both sides (Repair… ▸ Balance Audio, or Prepare with Archive Angel)"
        case .unmeasured(let note):
            return "Sound checked: \(note) — \(notMeasuredWords); listen before you archive it"
        case .accepted(let words):
            return "\(words); \(acceptedConditionWords)"
        case .notChecked where hasAudio:
            return "Sound not checked yet — Promote checks it before copying (missing, silent or damaged sound is refused)"
        case .noTrack:
            return "No audio track (video-only) — Promote refuses it unless it is tagged “\(WorkflowTags.silentChecked)”; combine it with its sound first"
        case .fine, .note, .notChecked:
            return nil
        }
    }
    /// What a layout note leaves unsaid.
    static let notMeasuredWords = "the balance of each track and channel was not measured"

    /// Warning sentences — AUDIO FIRST, then format, then date, then other.
    private static func composeWarnings(_ i: Inputs, stream: StreamType, hasMedia: Bool, hasAudio: Bool,
                                        blocking: Bool, sound: SoundStanding, format: Format, date: DateState,
                                        resolution: RecordDateResolution) -> [String] {
        var warnings: [String] = []
        if blocking {
            warnings.append(stream == .ffprobeFailed
                            ? "Un-probeable — ffprobe could not read this file; the archive would hold bytes nobody has decoded"
                            : "No audio or video streams found — nothing decodable to preserve")
        }
        if let sentence = soundWarning(sound, hasAudio: hasAudio) {
            warnings.append(sentence)
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
            warnings.append("Date \(UserDateEntry.friendlyDisplay(resolution.isoString)) is a low-confidence guess \(from) — filed under it; confirm or correct it in the inspector")
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
        parts.append(sound.sheetWords)
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
    /// `familyUserDate`: the copy family's best hand-entered date — a
    /// user date is a fact about the RECORDING, not the one file it was
    /// typed on, so when THIS record has none the family's stands in
    /// (Mark_Bday 2026-08-20: date on the MediaExpansion copy, election
    /// recommended the staging twin, readiness nagged low-confidence).
    @MainActor
    static func assess(record r: VideoRecord,
                       familyUserDate: (date: String, confidence: String)? = nil) -> ArchiveReadiness {
        assess(inputs(record: r, familyUserDate: familyUserDate))
    }

    /// The gate's reading of the owner's “Silent — checked” tag, BEFORE the
    /// bytes are proven: PromoteSoundGate.mark itself, asked "if this file is
    /// still the one the record describes" (its stored fingerprint, or its
    /// catalogued size when it was never fingerprinted). The Promote job asks
    /// the same function again with the digest it has just read, so a file
    /// that changed since is refused there whatever the sheet forecast.
    @MainActor
    static func forecastSoundMark(record r: VideoRecord) -> PromoteSoundGate.Mark {
        PromoteSoundGate.mark(tags: r.tags, storedFixity: r.contentFixity,
                              provenDigest: r.contentFixity?.digest ?? "",
                              recordSizeBytes: r.sizeBytes, provenSizeBytes: r.sizeBytes)
    }

    /// The Sendable snapshot `assess(record:)` reads — for a caller that
    /// assesses OFF the main actor (the Catalog's "Ready for archive" hints).
    @MainActor
    static func inputs(record r: VideoRecord,
                       familyUserDate: (date: String, confidence: String)? = nil) -> Inputs {
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
        i.soundMark = forecastSoundMark(record: r)
        i.audioSampleRate = r.audioSampleRate
        i.durationSeconds = r.durationSeconds
        i.inferredRecordDate = r.inferredRecordDate
        i.inferredDateConfidence = r.inferredDateConfidence
        i.inferredDateRange = r.inferredDateRange
        i.userDate = r.userDate ?? familyUserDate?.date
        i.userDateConfidence = r.userDate == nil
            ? (familyUserDate?.confidence ?? r.userDateConfidence)
            : r.userDateConfidence
        i.embeddedCreationDate = r.embeddedCreationDate
        i.originMake = r.originMake
        i.originModel = r.originModel
        i.originEncoder = r.originEncoder
        i.filename = r.filename
        return i
    }
}
