// DuplicateLikeness.swift
// The duplicate check's LIKENESS rule, as pure values (Rick 2026-10-19:
// "I have a 2 hour video FFV1 then re-encode to H264 … I don't want to lose
// the 'same event different codec' feature").
//
// Since 2026-10-19 a duplicate group holds COPIES only — files whose whole-
// file SHA-256s agree (DuplicateGroupDigestSplit). The old detector's other
// knowledge — "these two files are alike: same name, same length, same
// timecode, same sampled hash" — is not wrong, it just is not "copy". This
// file is that knowledge, in ONE place, used twice:
//
//   * DuplicateDetector builds its candidate pairs and star groups here
//     (scoring rules, bucket keys, hub election — moved here unchanged), then
//     partitions each star by digest into groups of copies;
//   * Find Similar Footage (FootageGrouping's `copyCheckLikeness` evidence)
//     asks `sameFootageLinks` for the scored pairs whose digests DIFFER — the
//     "same footage, different file" relationship (re-encode, rewrap, other
//     codec or container) — and records them as footage links with these
//     reasons, verbatim. Never delete-eligible: footage membership feeds no
//     delete path (pinned by SameFootageSensorTests).
//
// WHAT A FOOTAGE GROUP CAN HOLD. Anchored likeness (the sampled hash, a
// timecode no camera starts at by default, a specific name — each with the
// length agreeing) becomes a Likely footage link. Weak likeness (a default
// timecode, a camera-counter name, format + length) becomes a Possible link,
// which may only attach a lone file: a footage group has one confidence (its
// weakest link), so a weak link between two groups would demote byte copies.
// The split HOLDS any old group whose files only weak likeness would keep
// together (DuplicateGroupDigestSplit, "HELD, NOT SPLIT").
//
// THE THREE RELATIONSHIPS a scored pair can have (`relationship`):
//   copies         both whole-file digests known and equal → the duplicate group
//   sameFootage    both known and different, and the lengths agree (the
//                  pair's reasons include "duration": within 1 s) → a footage link
//   differentLength both known and different, and the lengths DISAGREE — only a
//                  sampled-hash bucket can pair such files (the name and timecode
//                  buckets are keyed by length), so this is the sampled-hash
//                  collision class: evidence says NOT the same; no link
//   unknown        a digest is missing: not known to differ (the detector keeps
//                  it with the keeper's copies, as before); no footage link
//
// MEMORY. One Facts value per record (~300 B with its strings), the bucket
// dictionary (a few keys per record) and the scored pairs. Bucket pairs are
// all-pairs WITHIN a bucket, exactly as the detector always did; buckets are
// keyed by stream type + length (or size + sampled hash), so they are small.
// Lookups are by array index — no O(n) search per pair.
//
// (For Rick: `Facts` is a plain value struct ≈ a C++ POD snapshot of the
// record fields the rule reads, so the rule can run on any thread.)

import Foundation
import VideoScanCore

enum DuplicateLikeness {

    // MARK: - Thresholds (the detector's, unchanged)

    static let scoreThreshold = 7
    static let mediumConfidenceScore = 9
    static let highConfidenceScore = 12
    static let durationToleranceExact = 0.25
    static let durationToleranceLoose = 1.0
    static let creationTolerance: TimeInterval = 5 * 60

    // MARK: - Facts

    /// The record fields the rule reads, by value.
    struct Facts: Sendable, Equatable {
        var id: UUID
        var filename: String
        var fullPath: String
        var streamTypeRaw: String
        var partialMD5: String
        var sizeBytes: Int64
        var timecode: String
        var durationSeconds: Double
        var resolution: String
        var videoCodec: String
        var audioCodec: String
        var audioChannels: String
        var audioSampleRate: String
        var tapeName: String
        var dateCreatedRaw: Date?
        var isPlayable: String
        /// The stored whole-file SHA-256, lowercase (`VideoScanModel.storedFullDigest`).
        var digest: String?
        /// `DuplicateLikeness.normalizedStem(filename)`, computed once — or
        /// `Facts.deferredStem` when the main-actor snapshot left it for the
        /// off-main pairing pass (`withStem()`; four regexes per name).
        var stem: String

        static let deferredStem = "\u{0}deferred"

        init(id: UUID = UUID(), filename: String, fullPath: String = "", streamTypeRaw: String = StreamType.videoAndAudio.rawValue,
             partialMD5: String = "", sizeBytes: Int64 = 0, timecode: String = "", durationSeconds: Double = 0,
             resolution: String = "", videoCodec: String = "", audioCodec: String = "", audioChannels: String = "",
             audioSampleRate: String = "", tapeName: String = "", dateCreatedRaw: Date? = nil, isPlayable: String = "",
             digest: String? = nil, deferStem: Bool = false) {
            self.id = id; self.filename = filename; self.fullPath = fullPath; self.streamTypeRaw = streamTypeRaw
            self.partialMD5 = partialMD5; self.sizeBytes = sizeBytes; self.timecode = timecode
            self.durationSeconds = durationSeconds; self.resolution = resolution; self.videoCodec = videoCodec
            self.audioCodec = audioCodec; self.audioChannels = audioChannels; self.audioSampleRate = audioSampleRate
            self.tapeName = tapeName; self.dateCreatedRaw = dateCreatedRaw; self.isPlayable = isPlayable
            self.digest = digest.flatMap { $0.isEmpty ? nil : $0.lowercased() }
            self.stem = deferStem ? Self.deferredStem : DuplicateLikeness.normalizedStem(filename)
        }

        /// The same facts with the stem computed (a no-op when it already is).
        func withStem() -> Facts {
            guard stem == Self.deferredStem else { return self }
            var f = self
            f.stem = DuplicateLikeness.normalizedStem(filename)
            return f
        }

        /// `VideoRecord.streamType`'s rule: an unknown raw value is "ffprobe failed".
        var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }
    }

    // MARK: - Candidates and buckets

    static func isCandidate(_ f: Facts) -> Bool {
        switch f.streamType {
        case .ffprobeFailed, .noStreams: return false
        default: break
        }
        return !isStockMedia(f.fullPath)
    }

    private static let stockPathPatterns: [String] = [
        "/iMovie", "/Final Cut", "/FxPlug", "/Motion", "/Compressor", "/Pro Video Formats", "/Avid/AVX",
        "/Media Composer", "/Transitions/", "/Titles/", "/Generators/", "/Effects/", ".app/Contents/",
    ]

    static func isStockMedia(_ path: String) -> Bool {
        stockPathPatterns.contains { path.contains($0) }
    }

    /// One bucket a record can pair under — hash (size + sampled hash),
    /// timecode (+ length) or normalized stem (+ length), namespaced by
    /// `kind` so families never collide. A struct, so the grouping pass
    /// hashes the fields without building a string per key.
    struct BucketKey: Hashable, Sendable {
        enum Kind: UInt8, Sendable { case hash, timecode, stem }
        var kind: Kind
        var stream: String
        var text: String
        var number: Int64

        /// The legacy string form ("h|<stream>|<size>|<md5>", "t|…", "s|…").
        var string: String {
            switch kind {
            case .hash: return "h|\(stream)|\(number)|\(text)"
            case .timecode: return "t|\(stream)|\(text)|\(number)"
            case .stem: return "s|\(stream)|\(text)|\(number)"
            }
        }
    }

    static func bucketKeyValues(_ input: Facts) -> [BucketKey] {
        let f = input.withStem()
        var keys: [BucketKey] = []
        if !f.partialMD5.isEmpty && f.sizeBytes > 0 {
            keys.append(BucketKey(kind: .hash, stream: f.streamTypeRaw, text: f.partialMD5, number: f.sizeBytes))
        }
        let length = Int64(durationBucket(f.durationSeconds))
        if !f.timecode.isEmpty {
            keys.append(BucketKey(kind: .timecode, stream: f.streamTypeRaw, text: f.timecode, number: length))
        }
        if !f.stem.isEmpty {
            keys.append(BucketKey(kind: .stem, stream: f.streamTypeRaw, text: f.stem, number: length))
        }
        return keys
    }

    /// The same keys as strings (the analysis ledger's `affectedSubset`
    /// indexes these) — derived from `bucketKeyValues`, so they never drift.
    static func bucketKeys(_ f: Facts) -> [String] { bucketKeyValues(f).map(\.string) }

    static func durationBucket(_ duration: Double) -> Int { Int((duration * 2).rounded()) }

    static func normalizedStem(_ filename: String) -> String {
        var stem = (filename as NSString).deletingPathExtension.lowercased()
        for pattern in stemPatterns {
            stem = stem.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return stem.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static let stemPatterns = [
        #"\s*\(\d+\)$"#,
        #"\s+copy(?:\s+\d+)?$"#,
        #"[-_ ]copy(?:[-_ ]\d+)?$"#,
        #"[-_ ]duplicate(?:[-_ ]\d+)?$"#,
    ]

    // MARK: - Scoring (the detector's rule table, unchanged)

    struct Score: Sendable, Equatable {
        var points: Int
        var confidence: DuplicateConfidence
        /// The rule names that fired, in table order ("hash", "timecode",
        /// "filename", "duration", "resolution", "vcodec", "audio", "tape",
        /// "created") — the words the detector records, verbatim.
        var reasons: [String]
    }

    private struct Rule {
        let reason: String
        let evaluate: @Sendable (Facts, Facts) -> Int?
    }

    private static let rules: [Rule] = [
        // Strongest SIGNAL, never proof: partialMD5 hashes the first and
        // last 64 KB only (codex #333). Enough to PROPOSE; never to delete.
        Rule(reason: "hash") { l, r in
            guard !l.partialMD5.isEmpty, l.partialMD5 == r.partialMD5, l.sizeBytes == r.sizeBytes else { return nil }
            return 8
        },
        Rule(reason: "timecode") { l, r in (!l.timecode.isEmpty && l.timecode == r.timecode) ? 4 : nil },
        Rule(reason: "filename") { l, r in l.stem == r.stem ? 3 : nil },
        Rule(reason: "duration") { l, r in
            guard l.durationSeconds > 0, r.durationSeconds > 0 else { return nil }
            let delta = abs(l.durationSeconds - r.durationSeconds)
            if delta <= durationToleranceExact { return 3 }
            if delta <= durationToleranceLoose { return 2 }
            return nil
        },
        Rule(reason: "resolution") { l, r in (!l.resolution.isEmpty && l.resolution == r.resolution) ? 2 : nil },
        Rule(reason: "vcodec") { l, r in (!l.videoCodec.isEmpty && l.videoCodec == r.videoCodec) ? 2 : nil },
        Rule(reason: "audio") { l, r in audioSignature(l) == audioSignature(r) ? 2 : nil },
        Rule(reason: "tape") { l, r in (!l.tapeName.isEmpty && l.tapeName == r.tapeName) ? 1 : nil },
        Rule(reason: "created") { l, r in
            guard let a = l.dateCreatedRaw, let b = r.dateCreatedRaw,
                  abs(a.timeIntervalSince(b)) <= creationTolerance else { return nil }
            return 1
        },
    ]

    private static func audioSignature(_ f: Facts) -> String { "\(f.audioCodec)|\(f.audioChannels)|\(f.audioSampleRate)" }

    /// nil = not alike enough (different stream type, or under the threshold).
    static func score(_ left: Facts, _ right: Facts) -> Score? {
        guard left.streamType == right.streamType else { return nil }
        let l = left.withStem(), r = right.withStem()   // a no-op unless the stem was deferred
        var total = 0
        var reasons: [String] = []
        for rule in rules {
            if let points = rule.evaluate(l, r) {
                total += points
                reasons.append(rule.reason)
            }
        }
        guard total >= scoreThreshold else { return nil }
        let confidence: DuplicateConfidence
        switch total {
        case highConfidenceScore...: confidence = .high
        case mediumConfidenceScore...: confidence = .medium
        default: confidence = .low
        }
        return Score(points: total, confidence: confidence, reasons: reasons)
    }

    /// TECHNICAL merit (the detector's `keeperScore`): playability,
    /// streams, codecs, size, resolution, date.
    static func technicalScore(_ f: Facts) -> Int {
        technicalScore(isPlayable: f.isPlayable, streamType: f.streamType, audioCodec: f.audioCodec,
                       videoCodec: f.videoCodec, sizeBytes: f.sizeBytes, resolution: f.resolution,
                       dateCreatedRaw: f.dateCreatedRaw)
    }

    /// The same, from loose fields (DuplicateDetector.keeperScore passes a
    /// record's without building Facts — no stem regex per call).
    static func technicalScore(isPlayable: String, streamType: StreamType, audioCodec: String, videoCodec: String,
                               sizeBytes: Int64, resolution: String, dateCreatedRaw: Date?) -> Int {
        var score = 0
        if isPlayable == "Yes" { score += 40 }
        switch streamType {
        case .videoAndAudio: score += 30
        case .videoOnly: score += 20
        case .audioOnly: score += 10
        case .noStreams: score -= 20
        case .ffprobeFailed: score -= 40
        }
        if !audioCodec.isEmpty { score += 8 }
        if !videoCodec.isEmpty { score += 6 }
        score += min(20, Int(sizeBytes / 50_000_000))
        let parts = resolution.split(separator: "x")
        if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) { score += min(12, w * h / 500_000) }
        if let date = dateCreatedRaw { score += max(0, 5 - Int(date.timeIntervalSince1970 / 86_400_000)) }
        return score
    }

    // MARK: - Pairs and stars

    /// An unordered pair of indices (a < b).
    struct PairKey: Hashable, Sendable {
        let a: Int
        let b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    /// Every bucket pair that scores, keyed by index pair. `facts` is the
    /// whole input; non-candidates are skipped.
    static func pairs(_ input: [Facts]) -> [PairKey: Score] {
        let facts = input.map { $0.withStem() }
        var buckets: [BucketKey: [Int]] = [:]
        buckets.reserveCapacity(facts.count * 2)
        for i in facts.indices where isCandidate(facts[i]) {
            for key in bucketKeyValues(facts[i]) { buckets[key, default: []].append(i) }
        }
        var tried = Set<PairKey>()
        var out: [PairKey: Score] = [:]
        for bucket in buckets.values where bucket.count > 1 {
            for x in 0..<(bucket.count - 1) {
                for y in (x + 1)..<bucket.count {
                    let key = PairKey(bucket[x], bucket[y])
                    guard tried.insert(key).inserted else { continue }
                    if let s = score(facts[key.a], facts[key.b]) { out[key] = s }
                }
            }
        }
        return out
    }

    /// One star: the hub and the members that score against it directly
    /// (`members[0] == hub`). Star topology keeps A↔B↔C chains from
    /// inflating a group with unrelated files (the detector's rule).
    struct Star: Sendable, Equatable {
        var hub: Int
        var members: [Int]
    }

    /// The detector's stars over `pairs`: connected components, the best-
    /// connected hub (most direct matches, then technical merit, then the
    /// smallest path), then the hub's direct matches. Components are
    /// visited in input order.
    static func stars(_ facts: [Facts], pairs: [PairKey: Score]) -> [Star] {
        var adjacency: [Int: [Int]] = [:]
        for key in pairs.keys {
            adjacency[key.a, default: []].append(key.b)
            adjacency[key.b, default: []].append(key.a)
        }
        var visited = Set<Int>()
        var out: [Star] = []
        for start in facts.indices where adjacency[start] != nil && !visited.contains(start) {
            var stack = [start]
            var component: [Int] = []
            while let i = stack.popLast() {
                guard visited.insert(i).inserted else { continue }
                component.append(i)
                for j in adjacency[i] ?? [] where !visited.contains(j) { stack.append(j) }
            }
            guard component.count > 1, let hub = electHub(component, facts: facts, adjacency: adjacency) else { continue }
            var members = [hub]
            for i in component where i != hub {
                if let s = pairs[PairKey(hub, i)], s.points >= scoreThreshold { members.append(i) }
            }
            if members.count > 1 { out.append(Star(hub: hub, members: members)) }
        }
        return out
    }

    static func electHub(_ component: [Int], facts: [Facts], adjacency: [Int: [Int]]) -> Int? {
        var best: Int?
        var bestKey: (Int, Int, String)?
        for i in component {
            let key = (adjacency[i]?.count ?? 0, technicalScore(facts[i]), facts[i].fullPath)
            if let current = bestKey {
                let better = key.0 != current.0 ? key.0 > current.0
                    : key.1 != current.1 ? key.1 > current.1
                    : key.2 < current.2
                if !better { continue }
            }
            best = i
            bestKey = key
        }
        return best
    }

    // MARK: - The three relationships

    enum Relationship: Sendable, Equatable {
        case copies
        case sameFootage
        case differentLength
        case unknown
    }

    /// What a scored pair IS, by its whole-file digests and its reasons.
    static func relationship(_ a: Facts, _ b: Facts, reasons: [String]) -> Relationship {
        guard let x = a.digest, let y = b.digest else { return .unknown }
        if x == y { return .copies }
        return reasons.contains("duration") ? .sameFootage : .differentLength
    }

    /// One "same footage, different file" link: a scored pair (`b` the
    /// lower index) whose digests differ and whose lengths agree.
    struct Link: Sendable, Equatable {
        var a: Int
        var b: Int
        var score: Score
        /// The pair is a hub–member edge of the detector's star — the only
        /// kind FootageGrouping takes for a WEAK (unanchored) likeness.
        var inStar: Bool
    }

    struct LinkRun: Sendable, Equatable {
        var links: [Link] = []
        /// Pairs whose digests differ AND whose lengths disagree — the
        /// sampled-hash collision class; never linked.
        var differentLength = 0
    }

    /// The duplicate check's likeness, kept: every SCORED pair whose whole-
    /// file digests are known and differ, lengths agreeing → a link.
    ///
    /// Every pair, not only the hub's star: the star is a COPIES rule (it
    /// keeps an A↔B↔C chain out of one delete-eligible group), and the stars
    /// a whole-catalog pass picks are not the ones the incremental detector
    /// picked over the years — on Rick's catalog the direct A1↔A2 pair of an
    /// Avid clip (same sampled hash, timecode and length) was never a star
    /// edge once a busier hub shared its timecode (2026-10-19 evidence run).
    /// Chains are FootageGrouping's to bound (cap 64; Possible never chains;
    /// name links obey dates; the person's "not the same" wins). Pairs come
    /// out in a stable order (by index) so a re-run gives the same answer.
    static func sameFootageLinks(_ facts: [Facts]) -> LinkRun {
        let scored = pairs(facts)
        var starPairs = Set<PairKey>()
        for star in stars(facts, pairs: scored) {
            for m in star.members.dropFirst() { starPairs.insert(PairKey(star.hub, m)) }
        }
        var run = LinkRun()
        for key in scored.keys.sorted(by: { $0.a != $1.a ? $0.a < $1.a : $0.b < $1.b }) {
            guard let s = scored[key] else { continue }
            switch relationship(facts[key.b], facts[key.a], reasons: s.reasons) {
            case .sameFootage: run.links.append(Link(a: key.b, b: key.a, score: s, inStar: starPairs.contains(key)))
            case .differentLength: run.differentLength += 1
            case .copies, .unknown: break
            }
        }
        return run
    }

    /// Does the likeness name WHICH recording it is? The sampled hash (same
    /// size, head and tail), a timecode no camera starts at by default, or a
    /// name that is not a camera counter — each with the length agreeing.
    /// Unanchored likeness (a default timecode, a counter name, format and
    /// length alone) is weak: FootageGrouping takes it only as Possible.
    /// `isGenericName` is FootageGrouping's camera-counter test.
    static func isAnchored(_ reasons: [String], timecode: String, isGenericName: () -> Bool) -> Bool {
        if reasons.contains("hash") { return true }
        if reasons.contains("timecode") && !isDefaultTimecode(timecode) { return true }
        return reasons.contains("filename") && !isGenericName()
    }

    // MARK: - Words

    /// "FFV1 MKV", "H.264 MOV", "DV MOV", "AAC M4A" — the codec as families
    /// know it, then the container (the file's extension).
    static func formatWords(videoCodec: String, audioCodec: String, filename: String) -> String {
        let codec = codecWords(videoCodec.isEmpty ? audioCodec : videoCodec)
        let container = (filename as NSString).pathExtension.uppercased()
        return [codec, container].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func codecWords(_ raw: String) -> String {
        let key = raw.lowercased()
        if let known = codecNames[key] { return known }
        return raw.uppercased()
    }

    private static let codecNames: [String: String] = [
        "h264": "H.264", "avc1": "H.264", "hevc": "HEVC", "h265": "HEVC", "ffv1": "FFV1", "dvvideo": "DV",
        "prores": "ProRes", "dnxhd": "DNxHD", "mpeg2video": "MPEG-2", "mpeg4": "MPEG-4", "mjpeg": "Motion JPEG",
        "rawvideo": "uncompressed", "vp9": "VP9", "av1": "AV1", "aac": "AAC", "pcm_s16le": "PCM", "pcm_s24le": "PCM",
    ]

    /// "same footage as X — different codec: FFV1 MKV · H.264 MOV (the
    /// duplicate check matched timecode+duration)" — the evidence line a
    /// footage member shows for this link, `mine` being its own format.
    static func sameFootageWords(other: String, mine: String, theirs: String, reasons: String) -> String {
        "same footage as \(other) — \(differenceWords(mine, theirs)) (the duplicate check matched \(reasons))"
    }

    /// "different codec: FFV1 MKV · H.264 MOV" / "different bytes, same format: DV MOV".
    static func differenceWords(_ a: String, _ b: String) -> String {
        a == b ? "different bytes, same format: \(a.isEmpty ? "unknown" : a)" : "different codec: \(a) · \(b)"
    }

    /// A timecode every camera starts at — it identifies nothing.
    static func isDefaultTimecode(_ tc: String) -> Bool {
        let digits = tc.filter(\.isNumber)
        return digits.isEmpty || digits == "00000000" || digits == "01000000"
    }
}

extension DuplicateLikeness.Facts {
    /// Capture one record by value. Called on the main actor for live
    /// records (Find Similar Footage's snapshot pass) and off it only for
    /// the detector's exclusively-owned `snapshotClone`s — the same
    /// contract `DuplicateDetector.analyzeDetached` has always had.
    init(record r: VideoRecord, deferStem: Bool = false) {
        self.init(id: r.id, filename: r.filename, fullPath: r.fullPath, streamTypeRaw: r.streamTypeRaw,
                  partialMD5: r.partialMD5, sizeBytes: r.sizeBytes, timecode: r.timecode,
                  durationSeconds: r.durationSeconds, resolution: r.resolution, videoCodec: r.videoCodec,
                  audioCodec: r.audioCodec, audioChannels: r.audioChannels, audioSampleRate: r.audioSampleRate,
                  tapeName: r.tapeName, dateCreatedRaw: r.dateCreatedRaw, isPlayable: r.isPlayable,
                  digest: VideoScanModel.storedFullDigest(r), deferStem: deferStem)
    }
}
