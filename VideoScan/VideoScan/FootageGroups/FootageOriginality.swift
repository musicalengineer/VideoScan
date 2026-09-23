// FootageOriginality.swift
// Find Similar Footage, Phase 1 — "which member of a footage group is most
// likely the original?" and "what is each other member?" (the v1 scorer of
// docs/find_original_design.md §2, metadata only).
//
// A reason-printing points table, in the style of DuplicateDetector's
// keeperScore. FOR the original:
//   +40 a device model in the tags ("iPhone 12", "P5100") — a camera/phone
//       wrote it. "Apple" as MAKE alone is QuickTime's vendor stamp on
//       1,406 catalog files (DV captures, Photo-JPEG movies), not a camera,
//       so it earns nothing; another make alone earns +20.
//   +15 a camera-native format (DV video; .mts/.m2ts/.mod/.tod/.dv/.m2t/.3gp)
//   +10 a camera filename (MVI_1234, IMG_0001, GX010123, MA5A3201, 00012…)
//   +10 a capture codec named in the encoder tag (DV/DVCPRO, Avid DV25)
//    +5 a capture date in the container
// AGAINST:
//   −40 inside an editor's generated media (FCP "Transcoded Media",
//       "Proxy Media", "Render Files")
//   −25 recorded as made FROM another catalog record (derivedFrom), except
//       a Promote copy (same bytes, it is a copy — not a derivative)
//   −20 a transcoder/export encoder tag (ffmpeg "Lavf…", HandBrake, VLC,
//       CoreMediaAuthoring, "Apple ProRes …", "H.264", "AVC Coding", HEVC…)
//   −20 a version token in the name (_balanced, .vs.archive, _converted…)
//   −15 FCP's media identifier (FCP stamps it on media it transcodes)
//   −10 an audio-only half (the picture half is the one to show)
//    −1 a Promote copy (same bytes; the file it was copied from ranks first)
// Ties: earlier capture date, then path (stable).
//
// `cameraEvidence` = device model, non-Apple make, camera format or camera
// filename. When the likely original has none AND looks like an export
// (`looksLikeExport`), the group's original is probably NOT in the catalog
// ("best available: an export") — the guitar case, whose camera clips were
// never cataloged.
//
// Pure; O(1) per member. (For Rick: a table-driven scorer ≈ a C++
// function returning a struct {int score; std::vector<std::string> why;}.)

import Foundation
import VideoScanCore

enum FootageOriginality {

    struct Verdict: Sendable, Equatable {
        var score: Int
        var reasons: [String]
        var cameraEvidence: Bool
    }

    static func assess(_ x: FootageInput, analysis a: FootageStem.Analysis) -> Verdict {
        var score = 0
        var reasons: [String] = []
        var camera = false
        let lowerPath = x.fullPath.lowercased()
        let ext = (x.filename as NSString).pathExtension.lowercased()
        let codec = x.videoCodec.lowercased()

        if let model = x.originModel, !model.isEmpty, !isComputerModel(model) {
            score += 40; camera = true
            reasons.append("camera/phone: \(model)")
        } else if let make = x.originMake, !make.isEmpty, make.lowercased() != "apple" {
            score += 20; camera = true
            reasons.append("device make: \(make)")
        }
        if codec == "dvvideo" || cameraExtensions.contains(ext) {
            score += 15; camera = true
            reasons.append("camera format (\(codec == "dvvideo" ? "DV" : ext.uppercased()))")
        }
        if isCameraFilename(a.strippedStem) {
            score += 10; camera = true
            reasons.append("camera filename")
        }
        if let enc = x.originEncoder, isCaptureEncoder(enc) {
            score += 10
            reasons.append("capture codec: \(enc)")
        }
        if x.embeddedCreationDate != nil {
            score += 5
            reasons.append("capture date in the file")
        }

        if isEditorGeneratedPath(lowerPath) {
            score -= 40
            reasons.append("inside an editor's generated media")
        }
        if x.derivedFrom != nil, x.derivationKind != promoteDerivationKind {
            score -= 25
            reasons.append("made from another catalog file (\(x.derivationKind ?? "derived"))")
        } else if x.derivationKind == promoteDerivationKind {
            score -= 1   // a tie-break: the file the archive copy was made from ranks first
            reasons.append("the archive's copy")
        }
        if let enc = x.originEncoder, isTranscoderEncoder(enc) {
            score -= 20
            reasons.append("written by \(EmbeddedOriginTags.encoderFamily(enc))")
        }
        if a.hasDerivativeToken {
            score -= 20
            reasons.append("name says it is a version")
        }
        if x.mediaIdentifier != nil {
            score -= 15
            reasons.append("Final Cut media identifier")
        }
        if x.streamTypeRaw == StreamType.audioOnly.rawValue {
            score -= 10
            reasons.append("audio-only half")
        }
        return Verdict(score: score, reasons: reasons, cameraEvidence: camera)
    }

    /// Ranking comparator: a ranks before b (more original).
    static func ranksBefore(_ a: (Verdict, FootageInput), _ b: (Verdict, FootageInput)) -> Bool {
        if a.0.score != b.0.score { return a.0.score > b.0.score }
        switch (a.1.embeddedCreationDate, b.1.embeddedCreationDate) {
        case let (da?, db?) where da != db: return da < db
        case (.some, nil): return true
        case (nil, .some): return false
        default: break
        }
        if a.1.fullPath != b.1.fullPath { return a.1.fullPath < b.1.fullPath }
        return a.1.id.uuidString < b.1.id.uuidString
    }

    // MARK: Roles

    /// What `x` is relative to the likely original `o`. `identicalToOriginal`
    /// = same full content hash / fixity / sampled signature as `o`.
    /// Order matters: the most specific evidence wins.
    static func role(of x: FootageInput, analysis a: FootageStem.Analysis, verdict: Verdict,
                     original o: FootageInput, originalVerdict: Verdict,
                     identicalToOriginal: Bool) -> FootageRole {
        if identicalToOriginal { return .copy }
        let audioOnly = StreamType.audioOnly.rawValue
        if (x.streamTypeRaw == audioOnly) != (o.streamTypeRaw == audioOnly) { return .avHalf }
        switch x.derivationKind ?? "" {
        case "trim": return .trim
        case "balanceAudio", "rebuildAudio", "externalRepair", "cleanup": return .restored
        case "transcode", "reformat": return .reEncode
        default: break
        }
        if x.cleanupRecipeID != nil { return .restored }
        if isEditorGeneratedPath(x.fullPath.lowercased()) || x.mediaIdentifier != nil { return .transcode }
        if let named = a.nameRole, named != .copy { return named }
        let enc = x.originEncoder ?? ""
        if enc.lowercased().contains("prores") { return .transcode }
        if isTranscoderEncoder(enc) { return .reEncode }
        let delivery = deliveryCodecs.contains(x.videoCodec.lowercased())
        if originalVerdict.cameraEvidence, !verdict.cameraEvidence, delivery { return .export }
        if !x.videoCodec.isEmpty, !o.videoCodec.isEmpty, x.videoCodec.lowercased() != o.videoCodec.lowercased() {
            return .reEncode
        }
        if a.nameRole == .copy { return .copy }
        return .related
    }

    /// The likely original is really an export: no camera evidence, and a
    /// delivery codec, a transcoder/export encoder tag or an editor's
    /// generated-media folder. Then "the camera original is probably not in
    /// the catalog" (the guitar case).
    static func looksLikeExport(_ x: FootageInput, verdict: Verdict) -> Bool {
        guard !verdict.cameraEvidence else { return false }
        if deliveryCodecs.contains(x.videoCodec.lowercased()) { return true }
        if let enc = x.originEncoder, isTranscoderEncoder(enc) { return true }
        return isEditorGeneratedPath(x.fullPath.lowercased())
    }

    // MARK: Tables (pure predicates, table-tested)

    static let promoteDerivationKind = "archivePromotion"
    static let cameraExtensions: Set<String> = ["mts", "m2ts", "mod", "tod", "dv", "m2t", "3gp", "3g2"]
    static let deliveryCodecs: Set<String> = ["h264", "hevc", "mpeg4", "vp9", "av1"]

    /// Paths under an editor's generated-media folders.
    static func isEditorGeneratedPath(_ lowerPath: String) -> Bool {
        lowerPath.contains("/transcoded media/") || lowerPath.contains("/proxy media/")
            || lowerPath.contains("/render files/")
    }

    /// A program that re-encodes or exports (never a camera).
    static func isTranscoderEncoder(_ encoder: String) -> Bool {
        let e = encoder.lowercased().trimmingCharacters(in: .whitespaces)
        if e.hasPrefix("lavf") || e.hasPrefix("lavc") { return true }
        for token in ["handbrake", "vlc", "ffmpeg", "cleaner", "coremediaauthoring", "compressor",
                      "prores", "h.264", "avc coding", "'avc1'", "hevc", "mpeg-4 video", "sorenson",
                      "virtualdub"] where e.contains(token) {
            return true
        }
        return false
    }

    /// A capture codec's own name (DV capture, Avid DV ingest).
    static func isCaptureEncoder(_ encoder: String) -> Bool {
        let e = encoder.lowercased()
        return e.hasPrefix("dv/dvcpro") || e.hasPrefix("dv -") || e.hasPrefix("avid dv") || e.hasPrefix("dv411")
    }

    /// Mac model names in the `model` tag (screen recordings) — not a camera.
    static func isComputerModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("macbook") || m.hasPrefix("imac") || m.hasPrefix("mac")
    }

    static func isCameraFilename(_ stem: String) -> Bool {
        let s = stem.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 24 else { return false }
        return cameraFilenameRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static let cameraFilenameRegex = try! NSRegularExpression(
        pattern: #"^((mvi|img|vid|gx|gh|gopr|gp|dji|dsc|dscn|dscf|ma5a|mah|sany|hdv|pxl)[_ -]?\d{3,}[a-z]?|[cp]\d{4,7}|\d{5}|\d{8}_\d{6})$"#,
        options: [.caseInsensitive])
}
