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
        /// ffmpeg found no audio stream (or an empty one): nothing to store.
        case noAudio
    }

    /// Decoder cap the engine applies (AudioPCMDecoder.defaultMaxSeconds):
    /// a recording longer than this is analysed as a prefix only.
    public static let decoderCapSeconds = AudioPCMDecoder.defaultMaxSeconds

    public var computedAt: Date
    /// `AudioFingerprint.currentVersion` when the stamp was written.
    public var engineVersion: Int
    /// Sidecar key, self-describing ("sha256:…" or "v1:…", see header).
    public var contentDigest: String
    public var sizeBytes: Int64
    public var outcome: Outcome
    /// Seconds of audio actually analysed (PCM samples ÷ sample rate).
    public var analyzedSeconds: Double
    /// True when the analysed span covers the whole recording (within 1 s
    /// of the catalog duration, or the duration is unknown).
    public var complete: Bool
    public var landmarks: Int
    /// Encoded size of the sidecar blob (0 for `.noAudio`).
    public var bytes: Int

    public init(computedAt: Date = Date(), engineVersion: Int = Int(AudioFingerprint.currentVersion),
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

    /// Stamp for a stored fingerprint of `fingerprint` covering
    /// `analyzedSeconds` of a recording the catalog says lasts
    /// `durationSeconds` (0 = unknown).
    public static func fingerprinted(_ fingerprint: AudioFingerprint, contentDigest: String, sizeBytes: Int64,
                                     durationSeconds: Double, computedAt: Date = Date()) -> AudioFingerprintStamp {
        let analysed = fingerprint.durationSeconds
        return AudioFingerprintStamp(computedAt: computedAt, contentDigest: contentDigest, sizeBytes: sizeBytes,
                                     outcome: .fingerprinted, analyzedSeconds: analysed,
                                     complete: isComplete(analyzedSeconds: analysed, durationSeconds: durationSeconds),
                                     landmarks: fingerprint.landmarkCount, bytes: fingerprint.estimatedBytes)
    }

    /// Stamp for a file ffmpeg found no audio in.
    public static func noAudio(contentDigest: String, sizeBytes: Int64, computedAt: Date = Date()) -> AudioFingerprintStamp {
        AudioFingerprintStamp(computedAt: computedAt, contentDigest: contentDigest, sizeBytes: sizeBytes,
                              outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
    }

    /// The whole recording was analysed: within `tolerance` of the catalog
    /// duration, or the duration is unknown (≤ 0).
    public static func isComplete(analyzedSeconds: Double, durationSeconds: Double, tolerance: Double = 1.0) -> Bool {
        durationSeconds <= 0 || analyzedSeconds >= durationSeconds - tolerance
    }

    /// Does this stamp describe a file of `sizeBytes` whose digests (any
    /// kind the record carries) include the one it was keyed on, at the
    /// engine version this build writes? False → the file is (re)done.
    public func describes(sizeBytes: Int64, digests: [String],
                          engineVersion: Int = Int(AudioFingerprint.currentVersion)) -> Bool {
        self.engineVersion == engineVersion && self.sizeBytes == sizeBytes && sizeBytes > 0
            && digests.contains(contentDigest)
    }

    // MARK: Digest spelling

    /// "sha256:<hex>" for a stored full digest.
    public static func fullDigest(_ hex: String) -> String { "sha256:" + hex.lowercased() }

    /// The sampled contentHash is its own key (the scan writes "v1:<hex>");
    /// nil when the record has none.
    public static func sampledDigest(_ contentHash: String) -> String? {
        contentHash.isEmpty ? nil : contentHash
    }
}
