// AudioFingerprintStamp.swift (VideoScanCore)
// ONE SENTENCE: the small note a catalog record carries saying "the sound of
// THIS content has been fingerprinted (or has no sound), by this engine, and
// the bytes live in the sidecar under this digest" — Rick's 2026-10-14
// decision: "the catalog points to the file and the fingerprint".
//
// The fingerprint itself (hundreds of KB for a long tape) never enters
// catalog.json; it lives in `AudioFingerprintStore` (audio-fingerprints.sqlite)
// keyed by (contentDigest, sizeBytes, engineVersion). Two copies of the same
// bytes share one sidecar row and each carries its own stamp.
//
// `contentDigest` is self-describing, so a sampled hash can never be mistaken
// for a full one:
//   "sha256:<hex>"   the stored full SHA-256 (ContentFixity.digest)
//   "v1:<hex>"       the catalog's sampled contentHash, already prefixed by
//                    the scan (head ‖ middle ‖ tail ‖ size)
// A stamp describes a record while the record's size is unchanged AND the
// record still carries that digest (either kind). A record that gains a full
// hash later keeps its sampled-keyed stamp — the bytes did not change.
//
// `outcome` + `complete` make the stamp HONEST about what was analysed
// (codex P1 on the engine, 2026-10-14): a file with no audio stream gets a
// `.noAudio` stamp so the plan never retries it nightly; a file longer than
// the decoder's cap gets `complete == false` ("partial") — listed, not
// retried, and never treated as a whole-recording fingerprint.
//
// ADDITIVE optional on VideoRecord (`audioFingerprint`): legacy catalogs
// decode nil; the DTO writes the key only when present, so every record
// without one round-trips byte-identical. No catalog version bump (same
// rule as `perceptualFingerprint`, `contentFixity`).
//
// (For Rick: a POD struct with a compiler-written serializer; `Outcome` is a
// string-backed enum so the JSON stays readable in catalog.json.)

import Foundation

public struct AudioFingerprintStamp: Codable, Equatable, Hashable, Sendable {

    public enum Outcome: String, Codable, Sendable {
        /// Landmarks were computed and stored in the sidecar.
        case fingerprinted
        /// No sound to store — and, from stamp version 3 on, the file's
        /// HEADER agrees (the row's probe reports no audio codec). Version
        /// 2 also wrote this on a decode failure (zero samples from a file
        /// whose header has sound — 98 real files + 33 reference movies on
        /// 2026-10-17); those stamps are redone, see `describes`.
        case noAudio
    }

    /// The STAMP's rule version — separate from `AudioFingerprint
    /// .currentVersion` (the sidecar blob's on-disk format, still 2).
    ///   2: fingerprint format 2; `.noAudio` written on any decoder
    ///      "no audio stream", decode failures included.
    ///   3: `.noAudio` only when the header agrees (no audio codec on the
    ///      row); zero samples from a file whose header has sound is a
    ///      failed decode, retried next run (design: integrity_first §2 —
    ///      no verdict from unverified evidence).
    ///   4: a `.fingerprinted` stamp with ZERO landmarks is written only
    ///      when the engine MEASURED silence — every second of its
    ///      audible-seconds bitmap below the floor (`Reading.silence`).
    ///      A print that heard sound but found too few spectral peaks to
    ///      pair into one landmark (8 AVCHD clips of 1–10 s on 2026-10-20,
    ///      up to −0.1 dB peak) is NOT stamped: it is "heard too little to
    ///      print", retried next run, never "silent". Before 4, zero
    ///      landmarks meant either, so such stamps are redone (`describes`)
    ///      and read as `Hearing.notEvidence` until they are.
    public static let currentEngineVersion = 4
    /// The version whose `.noAudio` stamps may be decode failures.
    public static let noAudioOnDecodeFailureVersion = 2
    /// The first version whose zero-landmark stamp means measured silence.
    public static let silenceMeasuredVersion = 4
    /// The oldest stamp version this build still reads (selectively — see
    /// `describes`).
    public static let oldestTrustedVersion = 2

    /// Decoder cap the engine applies (AudioPCMDecoder.defaultMaxSeconds):
    /// a recording longer than this is analysed as a prefix only.
    public static let decoderCapSeconds = AudioPCMDecoder.defaultMaxSeconds

    public var computedAt: Date
    /// `currentEngineVersion` when the stamp was written.
    public var engineVersion: Int
    /// Sidecar key, self-describing ("sha256:…" or "v1:…", see header).
    public var contentDigest: String
    public var sizeBytes: Int64
    public var outcome: Outcome
    /// Seconds of audio actually analysed (PCM samples ÷ sample rate).
    public var analyzedSeconds: Double
    /// True when the engine analysed the whole recording (the decoder did
    /// not hit its cap) — `AudioFingerprint.complete`.
    public var complete: Bool
    public var landmarks: Int
    /// Encoded size of the sidecar blob (0 for `.noAudio`).
    public var bytes: Int

    public init(computedAt: Date = Date(), engineVersion: Int = AudioFingerprintStamp.currentEngineVersion,
                contentDigest: String, sizeBytes: Int64, outcome: Outcome, analyzedSeconds: Double,
                complete: Bool, landmarks: Int, bytes: Int) {
        self.computedAt = computedAt
        self.engineVersion = engineVersion
        self.contentDigest = contentDigest
        self.sizeBytes = sizeBytes
        self.outcome = outcome
        self.analyzedSeconds = analyzedSeconds
        self.complete = complete
        self.landmarks = landmarks
        self.bytes = bytes
    }

    // MARK: What a print heard (the one classification)

    /// What a freshly computed print says about the sound — decided from
    /// the engine's OWN measurements, never from the landmark count alone.
    /// (For Rick: a three-way tagged result, like an enum class in C++.)
    public enum Reading: Equatable, Sendable {
        /// At least one landmark: a usable fingerprint.
        case printable
        /// No landmark AND every analysed second measured below the
        /// audible floor (`AudioFingerprintParameters.activeFloorDB`):
        /// decoded, measured digital silence (or near it).
        case silence
        /// No landmark, yet the audio was heard — at least one audible
        /// second (or no bitmap to say otherwise): too short or too sparse
        /// for the peak picker (it needs two peaks, each the loudest of a
        /// ±3-frame × ±15-bin patch, ≥ 1 frame apart; the first and last
        /// 3 frames are never centres). Never "silent".
        case heardTooLittle(audibleSeconds: Int)
    }

    public static func reading(of fingerprint: AudioFingerprint) -> Reading {
        if fingerprint.landmarkCount > 0 { return .printable }
        // An empty bitmap is "unknown" (AudioFingerprint.activeSeconds):
        // the conservative side is "heard", never "silent".
        guard fingerprint.analyzedSeconds > 0, !fingerprint.activeSeconds.isEmpty else {
            return .heardTooLittle(audibleSeconds: fingerprint.activeSeconds.isEmpty ? 0 : fingerprint.activeSecondCount)
        }
        let audible = fingerprint.activeSecondCount
        return audible == 0 ? .silence : .heardTooLittle(audibleSeconds: audible)
    }

    /// What a STAMP says about the sound, judged against the row's header
    /// (`headerHasAudio`: its probe names an audio codec). Every surface
    /// that turns a stamp into words — Verify Catalog tier 3, the Stream
    /// column, Compare's sound line — reads THIS, so "silent" has one
    /// meaning: decoded and measured.
    public enum Hearing: Equatable, Sendable {
        /// The print holds landmarks: sound was heard and printed.
        case heardSound
        /// Decoded and measured silent (stamp version ≥ 4, zero landmarks).
        case measuredSilence
        /// The file has no sound track, and the header agrees (or the stamp
        /// rule never wrote this on a decode failure).
        case noAudioTrack
        /// Not evidence either way: a version-2 "no sound" stamp on a row
        /// whose header has sound (written on decode failures — 0 samples),
        /// or a pre-4 zero-landmark print (silence and "too little to print"
        /// were not told apart). Could not check; the backfill redoes it.
        case notEvidence
    }

    public func hearing(headerHasAudio: Bool) -> Hearing {
        switch outcome {
        case .noAudio:
            return headerHasAudio && engineVersion <= Self.noAudioOnDecodeFailureVersion ? .notEvidence : .noAudioTrack
        case .fingerprinted:
            if landmarks > 0 { return .heardSound }
            return engineVersion >= Self.silenceMeasuredVersion && analyzedSeconds > 0 ? .measuredSilence : .notEvidence
        }
    }

    /// Stamp for a stored fingerprint. `analyzedSeconds` and `complete`
    /// come FROM the engine (`AudioFingerprint.analyzedSeconds` /
    /// `.complete` — false when the decoder hit its cap), never recomputed.
    /// From version 4 the job asks only for a `.printable` or `.silence`
    /// reading (`reading(of:)`); a print that heard too little is not stamped.
    public static func fingerprinted(_ fingerprint: AudioFingerprint, contentDigest: String, sizeBytes: Int64,
                                     computedAt: Date = Date()) -> AudioFingerprintStamp {
        AudioFingerprintStamp(computedAt: computedAt, engineVersion: Self.currentEngineVersion,
                              contentDigest: contentDigest, sizeBytes: sizeBytes, outcome: .fingerprinted,
                              analyzedSeconds: fingerprint.analyzedSeconds, complete: fingerprint.complete,
                              landmarks: fingerprint.landmarkCount, bytes: fingerprint.estimatedBytes)
    }

    /// Stamp for a file with no sound — written only when the header agrees
    /// (the job checks the row's audio codec before asking for this).
    public static func noAudio(contentDigest: String, sizeBytes: Int64, computedAt: Date = Date()) -> AudioFingerprintStamp {
        AudioFingerprintStamp(computedAt: computedAt, contentDigest: contentDigest, sizeBytes: sizeBytes,
                              outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
    }

    /// Does this stamp describe a file of `sizeBytes` whose PREFERRED
    /// digest (`digests.first`: the full hash when the record has one, else
    /// the sampled one) is the key it was written under, at a stamp version
    /// this build still trusts? False → the file is (re)done. A stamp
    /// keyed on a sampled "v1:" hash is redone once the record gains a full
    /// hash — one extra decode, and from then on a real identity (QA P1-a).
    ///
    /// `headerHasAudio` is the row's own evidence (its probe reports an
    /// audio codec). An OLDER stamp (versions 2–3) stands when this build
    /// would read it as evidence (`hearing` is not `.notEvidence`): a
    /// fingerprint with landmarks (same engine, same bytes), or a "no
    /// sound" stamp the header agrees with. It is REDONE when it is not
    /// evidence: a version-2 "no sound" stamp on a row whose header has
    /// sound (decode failures), and any pre-4 zero-landmark print (it may
    /// be "too little to print", 8 AVCHD clips with real sound on
    /// 2026-10-20) — re-decided from the sidecar's audible bitmap, or by a
    /// fresh decode.
    public func describes(sizeBytes: Int64, digests: [String], headerHasAudio: Bool,
                          engineVersion: Int = AudioFingerprintStamp.currentEngineVersion) -> Bool {
        guard self.sizeBytes == sizeBytes, sizeBytes > 0, digests.first == contentDigest else { return false }
        if self.engineVersion == engineVersion { return true }
        guard engineVersion == Self.currentEngineVersion,
              (Self.oldestTrustedVersion..<Self.currentEngineVersion).contains(self.engineVersion) else { return false }
        return hearing(headerHasAudio: headerHasAudio) != .notEvidence
    }

    // MARK: Digest spelling

    /// "sha256:<hex>" for a stored full digest.
    public static func fullDigest(_ hex: String) -> String { "sha256:" + hex.lowercased() }

    /// Only a full digest is an identity: the sampled "v1:" hash can agree
    /// between two different recordings (10 of 836 v1-equal pairs had
    /// different bytes on 10/11), so only "sha256:" keys may be SHARED.
    public static func isFullDigest(_ digest: String) -> Bool { digest.hasPrefix("sha256:") }

    /// The sampled contentHash is its own key (the scan writes "v1:<hex>");
    /// nil when the record has none.
    public static func sampledDigest(_ contentHash: String) -> String? {
        contentHash.isEmpty ? nil : contentHash
    }
}
