// AudioFingerprintAttempt.swift (VideoScanCore)
// ONE SENTENCE: the note a record carries saying "the sound of THIS content
// was tried N times by engine version V and gave no print" — so Fingerprint
// Sound stops re-reading a file that hears too little or will not decode
// (GH #416 part 2; Rick approved option B, 2026-11-03).
//
// Stored in catalog.sqlite's `sound_attempts` (schema v15, one row per
// content digest, like `sound_prints`), written only through the commit
// door, loaded back onto every copy of the content.
//
// Rules:
//   * keyed on a FULL SHA-256 only ("sha256:<hex>", the digest the commit
//     binds — `CatalogRecordDTO.resolveDigest`); a record with only a
//     sampled "v1:" hash never gets one (it is tried every run, as before);
//   * only two outcomes count: the print HEARD sound but too little to make
//     one landmark, and ffmpeg could not decode the file. A drive that was
//     not connected, a file missing at its path, a record that changed, a
//     run cut off, a timeout or a missing ffmpeg are the world's state, not
//     the file's, and are never an attempt;
//   * `cap` (3) tries per engine version; a row written by an OLDER engine
//     counts as 0, so a new engine retries every capped file;
//   * a later print or "no sound" stamp ends it: the commit door deletes the
//     row when it writes the content's sound print.
//
// (For Rick: a POD with a "retry counter + version" — like a per-key
// failure counter in a C++ work queue, reset when the worker is upgraded.)

import Foundation

public struct AudioFingerprintAttempt: Codable, Equatable, Hashable, Sendable {

    public enum Outcome: String, Codable, Sendable, CaseIterable {
        /// Decoded, heard sound, no landmark (stamp rule 4's "too little").
        case heardTooLittle
        /// ffmpeg could not decode it (a non-zero exit, or zero samples from
        /// a file whose header names a sound codec).
        case failed
    }

    /// Tries per engine version before the plan stops asking.
    public static let cap = 3

    /// "sha256:<64 lowercase hex>" — never a sampled key.
    public var contentDigest: String
    /// `AudioFingerprintStamp.currentEngineVersion` when last tried.
    public var engineVersion: Int
    /// The outcome of the LAST try.
    public var outcome: Outcome
    /// Tries at `engineVersion` (≥ 1).
    public var attempts: Int
    public var lastAt: Date
    /// The last try's words (ffmpeg's stderr tail, "2 audible seconds").
    public var detail: String?

    public init(contentDigest: String, engineVersion: Int = AudioFingerprintStamp.currentEngineVersion,
                outcome: Outcome, attempts: Int, lastAt: Date = Date(), detail: String? = nil) {
        self.contentDigest = contentDigest
        self.engineVersion = engineVersion
        self.outcome = outcome
        self.attempts = attempts
        self.lastAt = lastAt
        self.detail = detail
    }

    /// Tries that count for `engineVersion` (an older engine's count is 0).
    public func tries(at engineVersion: Int = AudioFingerprintStamp.currentEngineVersion) -> Int {
        self.engineVersion == engineVersion ? attempts : 0
    }

    /// The plan skips the record: this note is for the record's preferred
    /// digest (`digests.first`, a full SHA-256) and the current engine has
    /// tried `cap` times.
    public func gaveUp(digests: [String], engineVersion: Int = AudioFingerprintStamp.currentEngineVersion) -> Bool {
        guard let first = digests.first, AudioFingerprintStamp.isFullDigest(first), first == contentDigest else { return false }
        return tries(at: engineVersion) >= Self.cap
    }

    /// The note after one more try on `contentDigest` (a full SHA-256):
    /// the count goes on at the same engine and digest, else starts at 1.
    /// nil for a sampled key — never recorded.
    public static func after(_ previous: AudioFingerprintAttempt?, contentDigest: String, outcome: Outcome,
                             detail: String?, at: Date = Date(),
                             engineVersion: Int = AudioFingerprintStamp.currentEngineVersion) -> AudioFingerprintAttempt? {
        guard AudioFingerprintStamp.isFullDigest(contentDigest) else { return nil }
        let before = previous.flatMap { $0.contentDigest == contentDigest ? $0.tries(at: engineVersion) : nil } ?? 0
        return AudioFingerprintAttempt(contentDigest: contentDigest, engineVersion: engineVersion, outcome: outcome,
                                       attempts: before + 1, lastAt: at, detail: detail.map { String($0.prefix(Self.detailCap)) })
    }

    /// The stored detail is a short tail, never a log (bytes per row bounded).
    public static let detailCap = 300
}
