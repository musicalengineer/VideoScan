import Foundation

// MARK: - The picture when Repair re-encodes it (codex design consult,
// 2026-10-08, docs/reviews/codex/codex-design-repair-center-perf-2026-10-08.md)
//
// Removing repeated frames is the one fix that re-encodes the picture.
// Two rules from the consult, pinned here as pure functions:
//
//   • The output rate F must be JUSTIFIED, never inferred from the very
//     timestamps that are corrupt: it is the file's own stated frame rate
//     (r_frame_rate, else avg_frame_rate), accepted only when it is a camera
//     rate (within 1 %). No justified rate → refuse, with the reason. The
//     filter is `mpdecimate,setpts=N/(F*TB)`: one picture per real frame,
//     played at F. The copy is SHORTER than the original by design.
//   • Preserve the representation explicitly — colour matrix, transfer,
//     primaries, range, sample aspect, chroma format — and then CHECK the
//     copy carries them (`mismatch(output:)`). "The encoder accepted the
//     flag" is not preservation. Interlaced sources are refused for now:
//     a progressive re-encode would lose the field order.
//
// The encoder arguments live here and in MediaRepairRecipe ONLY — the seam
// a hardware (VideoToolbox) variant slots into later without touching the
// job or the UI.

/// The original's picture, from its header (no decode).
struct MediaRepairPictureFacts: Equatable, Sendable {
    var codec = ""
    var pixelFormat = ""
    var rFrameRate = ""
    var avgFrameRate = ""
    var colorPrimaries = ""
    var colorTransfer = ""
    var colorSpace = ""
    var colorRange = ""
    var sampleAspectRatio = ""
    var fieldOrder = ""

    /// "tt", "bb", "tb", "bt" = interlaced; "progressive" / "unknown" / "" = not known to be.
    var isInterlaced: Bool { ["tt", "bb", "tb", "bt"].contains(fieldOrder) }
}

/// How the re-encoded picture is written, decided before the first write.
struct MediaRepairPicturePlan: Equatable, Sendable {
    /// The justified output rate F, as ffmpeg spells it ("30000/1001").
    let rateText: String
    let rate: Double
    /// Where F came from, for the plan the person sees.
    let rateSource: String
    let pixelFormat: String
    /// The source's chroma format can't be kept by the encoder (4:2:0 used).
    let reducesColourDetail: Bool
    /// `-color_primaries …` etc.: only tags the source actually states.
    let tagArgs: [String]
    /// "10:11" when the source states a non-square sample aspect.
    let sampleAspectRatio: String?

    /// x264's chroma formats, by the name ffprobe reports.
    static let encoderPixelFormats: Set<String> = ["yuv420p", "yuv422p", "yuv444p",
                                                    "yuv420p10le", "yuv422p10le", "yuv444p10le"]
    /// Full-range "j" formats map to their plain twin plus range=pc.
    static let fullRangeTwins = ["yuvj420p": "yuv420p", "yuvj422p": "yuv422p", "yuvj444p": "yuv444p"]
    static let cameraRates: [(text: String, value: Double)] = [
        ("24000/1001", 24000.0 / 1001), ("24", 24), ("25", 25), ("30000/1001", 30000.0 / 1001), ("30", 30),
        ("48", 48), ("50", 50), ("60000/1001", 60000.0 / 1001), ("60", 60)]

    /// The camera rate a stated rate stands for, within 1 %; nil otherwise.
    static func cameraRate(_ stated: String) -> (text: String, value: Double)? {
        guard let v = rational(stated), v > 0 else { return nil }
        return cameraRates.first { abs($0.value - v) / $0.value <= 0.01 }
    }

    /// "30000/1001" → 29.97; "25" → 25; malformed / x/0 → nil.
    static func rational(_ s: String) -> Double? {
        let p = s.split(separator: "/")
        if p.count == 1 { return Double(p[0]) }
        guard p.count == 2, let n = Double(p[0]), let d = Double(p[1]), d != 0 else { return nil }
        return n / d
    }

    /// The plan, or why the repeated frames can't be removed safely.
    static func justify(_ f: MediaRepairPictureFacts) -> Result<MediaRepairPicturePlan, MediaRepairRefusal> {
        if f.isInterlaced {
            return .failure(MediaRepairRefusal("The picture is interlaced (field order \(f.fieldOrder)); removing repeated frames would lose the field order, so it isn't offered for this file yet. Nothing was written."))
        }
        let stated: (String, (text: String, value: Double))?
        if let r = cameraRate(f.rFrameRate) {
            stated = ("the file's own frame rate (\(f.rFrameRate))", r)
        } else if let a = cameraRate(f.avgFrameRate) {
            stated = ("the file's average frame rate (\(f.avgFrameRate))", a)
        } else {
            stated = nil
        }
        guard let (source, rate) = stated else {
            return .failure(MediaRepairRefusal("The file doesn't state a believable frame rate (it says \(f.rFrameRate.isEmpty ? "nothing" : f.rFrameRate)), so VideoScan can't tell how fast the real pictures should play. Nothing was written."))
        }
        let (pix, reduces, fullRange) = pixelFormat(for: f.pixelFormat)
        return .success(MediaRepairPicturePlan(
            rateText: rate.text, rate: rate.value, rateSource: source,
            pixelFormat: pix, reducesColourDetail: reduces,
            tagArgs: tagArgs(f, fullRangeFromFormat: fullRange),
            sampleAspectRatio: sampleAspect(f.sampleAspectRatio)))
    }

    private static func pixelFormat(for source: String) -> (String, reduces: Bool, fullRange: Bool) {
        if let twin = fullRangeTwins[source] { return (twin, false, true) }
        if encoderPixelFormats.contains(source) { return (source, false, false) }
        return ("yuv420p", !source.isEmpty && !source.hasPrefix("yuv420p"), false)
    }

    private static func tagArgs(_ f: MediaRepairPictureFacts, fullRangeFromFormat: Bool) -> [String] {
        func known(_ v: String) -> Bool { !v.isEmpty && v != "unknown" && v != "reserved" }
        var args: [String] = []
        if known(f.colorPrimaries) { args += ["-color_primaries", f.colorPrimaries] }
        if known(f.colorTransfer) { args += ["-color_trc", f.colorTransfer] }
        if known(f.colorSpace) { args += ["-colorspace", f.colorSpace] }
        if known(f.colorRange) { args += ["-color_range", f.colorRange] } else if fullRangeFromFormat { args += ["-color_range", "pc"] }
        return args
    }

    private static func sampleAspect(_ sar: String) -> String? {
        guard !sar.isEmpty, sar != "1:1", sar != "0:1", sar != "N/A" else { return nil }
        return sar
    }

    /// The video filter: drop stored repeats, then lay the kept pictures on
    /// an even grid at F (`N` = kept-frame index, `TB` = time base).
    var filter: String {
        "mpdecimate,setpts=N/((\(rateText))*TB)" + (sampleAspectRatio.map { ",setsar=\($0.replacingOccurrences(of: ":", with: "/"))" } ?? "")
    }

    /// The encoder half of the command (the hardware seam).
    var encodeArgs: [String] {
        ["-vf", filter, "-fps_mode", "passthrough",
         "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", pixelFormat] + tagArgs
    }

    /// What the copy must carry; nil = preserved. Checked on the WRITTEN
    /// file's header, never assumed from the command.
    func mismatch(output o: MediaRepairPictureFacts) -> String? {
        if o.codec != "h264" { return "the picture is \(o.codec), expected h264" }
        // A decoder reports full-range H.264 as the "j" twin (yuvj444p):
        // the same picture as yuv444p + range pc, which is what we wrote.
        let written = Self.fullRangeTwins[o.pixelFormat] ?? o.pixelFormat
        if written != pixelFormat { return "the colour format is \(o.pixelFormat), expected \(pixelFormat)" }
        if let rate = Self.rational(o.rFrameRate), abs(rate - self.rate) / self.rate > 0.01 {
            return "the copy plays at \(o.rFrameRate), expected \(rateText)"
        }
        let expected = Dictionary(uniqueKeysWithValues: stride(from: 0, to: tagArgs.count - 1, by: 2).map { (tagArgs[$0], tagArgs[$0 + 1]) })
        let actual = ["-color_primaries": o.colorPrimaries, "-color_trc": o.colorTransfer,
                      "-colorspace": o.colorSpace, "-color_range": o.colorRange]
        for (flag, value) in expected where actual[flag] != value {
            return "the colour tag \(flag.dropFirst()) is \(actual[flag] ?? "missing"), expected \(value)"
        }
        if let sar = sampleAspectRatio, o.sampleAspectRatio != sar {
            return "the picture shape (sample aspect) is \(o.sampleAspectRatio), expected \(sar)"
        }
        return nil
    }

    /// The plan, in plain words.
    var summary: String {
        var s = "One picture per real frame at \(String(format: "%.3g", rate)) fps — \(rateSource). The copy is shorter than the original; the picture is re-encoded (H.264, high quality)."
        if reducesColourDetail { s += " This file's colour detail can't be kept exactly by the encoder (it becomes 4:2:0)." }
        return s
    }
}

/// A reason Repair says no, before anything is written.
struct MediaRepairRefusal: Error, Equatable, Sendable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}

// MARK: - Does the sound line up with the cleaned-up picture?
//
// Removing repeated frames makes the PICTURE shorter (kept pictures ÷ the
// justified rate) while the sound is copied as it is. If they no longer
// agree (within 1 %), the copy would play sound past the picture — so the
// fix is unavailable, refused before any write (Rick 2026-10-08). A file
// with no sound is unaffected.
enum MediaRepairSoundAlignment {

    static let tolerance = 0.01

    /// The planned picture length.
    static func pictureSeconds(keptFrames: Int, rate: Double) -> Double {
        rate > 0 ? Double(keptFrames) / rate : 0
    }

    /// nil = every sound stream lines up (or there is no sound); else why not.
    static func refusal(soundDurations: [Double?], keptFrames: Int, rate: Double) -> String? {
        guard !soundDurations.isEmpty else { return nil }
        let picture = pictureSeconds(keptFrames: keptFrames, rate: rate)
        for d in soundDurations {
            guard let sound = d, sound > 0 else {
                return "the sound's length can't be read, so VideoScan can't tell whether it lines up with the cleaned-up picture"
            }
            if picture <= 0 || abs(sound - picture) / max(sound, picture) > tolerance {
                return String(format: "the sound doesn't line up with the cleaned-up picture (sound %.1f s, picture %.1f s)",
                              sound, picture)
            }
        }
        return nil
    }
}
