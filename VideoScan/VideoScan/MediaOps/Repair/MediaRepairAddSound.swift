import Foundation

// MARK: - Repair… ▸ Add its sound from another file (Rick 2026-10-10)
//
// "A picture with no sound" (SoundPresencePolicy) is fixed behind the ONE
// repair door (Rick's 10/8 ruling: all A/V repair goes through Repair…;
// there is no separate "Find Audio" verb). This file holds the add-sound
// step's pure parts:
//
//   MediaRepairSoundSource  which sound file the step would use, and why
//                           it can or can't run. Only a MEASURED length
//                           match (SoundPairRanker) can run and is ticked;
//                           a "may be" (the picture's length never
//                           measured) is shown unticked with "run a full
//                           Verify first".
//   MediaRepairPrefill      what a "Repair…" button elsewhere (the Verify
//                           job's row, its detail, Get Info) hands the
//                           Repair sheet: the file and that candidate.
//   compareAddedSound       the proof the copy is the picture, untouched,
//                           plus that sound, untouched.
//
// The write itself is the Combine engine's stream-copy mux, run by Repair's
// engine (reserved partial → prove → no-clobber publish; the original and
// the sound file are only read). Never auto-run: a person presses Repair
// Now in the sheet.

/// The sound file Repair would add to a picture with none.
/// (An enum with associated values ≈ a C++ std::variant.)
enum MediaRepairSoundSource: Equatable, Sendable {
    /// Nothing in the same folder or footage group matches.
    case notFound
    /// Same folder / footage and name start, but this picture's length was
    /// never measured — can't be compared yet.
    case maybe(SoundPairCandidate)
    /// The lengths were measured on both sides and agree.
    case measured(SoundPairCandidate)

    /// From the lookup's answer. A copy WITH sound to watch instead is not
    /// a sound file to add, so it reads as nothing found here.
    init(advice: SoundCopyAdvice) {
        switch advice {
        case .combine(let p): self = .measured(p)
        case .maybeCombine(let p): self = .maybe(p)
        case .watch, .connect, .none: self = .notFound
        }
    }

    var candidate: SoundPairCandidate? {
        switch self {
        case .measured(let p), .maybe(let p): return p
        case .notFound: return nil
        }
    }

    /// The sound file the add-sound pass may read: a measured match only.
    var measured: SoundPairCandidate? {
        if case .measured(let p) = self { return p }
        return nil
    }

    static let notLookedForReason = "Looking for its sound file\u{2026}"
    static let notFoundReason =
        "No sound file in the same folder or footage group matches this picture's length."

    /// Why the add-sound step can't run; nil = it can (a measured match).
    /// `source` nil = not looked for yet.
    static func unavailableReason(_ source: MediaRepairSoundSource?) -> String? {
        switch source {
        case nil: return notLookedForReason
        case .notFound?: return notFoundReason
        case .maybe(let p)?:
            return "Its sound may be \(p.audio.filename) (\(p.shortReason)) \u{2014} run a full Verify first, so this picture's length can be measured."
        case .measured?: return nil
        }
    }

    /// "More repairs": a file that has sound, or no picture, never gets it.
    static func moreRepairsReason(_ source: MediaRepairSoundSource?, hasPicture: Bool, hasSound: Bool) -> String? {
        guard hasPicture else { return "This file has no picture." }
        guard !hasSound else { return "This file already has sound." }
        return unavailableReason(source)
    }
}

/// What a "Repair…" button outside the catalog hands the Repair sheet.
struct MediaRepairPrefill: Equatable, Sendable {
    let recordID: UUID
    /// nil = the sheet looks for the sound file itself.
    let soundSource: MediaRepairSoundSource?

    init(recordID: UUID, soundSource: MediaRepairSoundSource?) {
        self.recordID = recordID
        self.soundSource = soundSource
    }

    /// From the lookup the banner already has: carry a candidate when there
    /// is one, else let the sheet look.
    init(recordID: UUID, advice: SoundCopyAdvice?) {
        let source = advice.map(MediaRepairSoundSource.init(advice:))
        self.init(recordID: recordID, soundSource: source?.candidate == nil ? nil : source)
    }
}

// MARK: - The proof

extension MediaRepairParity {

    /// The add-sound copy must be the picture's video streams, packet for
    /// packet (MediaRepairParity.difference: codec, bytes, packets, length),
    /// plus exactly one sound track with the sound file's codec, its bytes
    /// and — except raw PCM, which a muxer may re-cut — its packet count.
    /// (Lengths are compared in seconds: an .ac3 counts in 1/90000 s, the
    /// .mov the same sound in 1/44100 s.)
    static func compareAddedSound(picture: [MediaStreamTally], sound: [MediaStreamTally],
                                  output: [MediaStreamTally]) -> MediaRepairParity {
        let srcVideo = picture.filter { $0.codecType == "video" }
        let outVideo = output.filter { $0.codecType == "video" }
        guard !srcVideo.isEmpty, srcVideo.count == outVideo.count else {
            return .different(reason: "the copy has \(outVideo.count) picture stream(s), the original \(srcVideo.count)")
        }
        for (s, o) in zip(srcVideo, outVideo) {
            if let why = difference(s, o) { return .different(reason: "picture stream \(s.index): \(why)") }
        }
        guard let added = sound.first(where: { $0.codecType == "audio" }) else {
            return .different(reason: "the sound file has no sound track")
        }
        let outSound = output.filter { $0.codecType == "audio" }
        guard outSound.count == 1, let got = outSound.first else {
            return .different(reason: "the copy has \(outSound.count) sound tracks, expected 1")
        }
        if let why = addedSoundDifference(added, got) { return .different(reason: "the added sound: \(why)") }
        return .identical(detail: (srcVideo + [got]).map(describe).joined(separator: " · ") + " (sound added, nothing re-encoded)")
    }

    private static func addedSoundDifference(_ s: MediaStreamTally, _ o: MediaStreamTally) -> String? {
        if s.codec != o.codec { return "\(s.codec) became \(o.codec)" }
        if s.bytes != o.bytes { return "\(s.bytes) bytes became \(o.bytes)" }
        if !s.codec.hasPrefix("pcm_"), s.packets != o.packets { return "\(s.packets) packets became \(o.packets)" }
        return nil
    }
}
