import Combine
import CryptoKit
import Foundation
import os

// MARK: - MediaPairComparator
//
// "Compare These Two Files…" — the quick two-file check from the
// Catalog tab. Rick browses the catalog, spots two rows with the same
// size that look suspiciously similar, and wants a direct answer:
// are these the same file, the same media content, or actually
// different? Distinct from the volume-level "Compare & Rescue"
// feature — this is a targeted pair check, not a fleet audit.
//
// Three-tier comparison (cheapest evidence first):
//   Tier 0 — file sizes (stat only). Different sizes can't be
//            byte-identical, so Tier 1 is skipped.
//   Tier 1 — chunked full-file SHA-256 of both files. Equal digests
//            ⇒ "Exact duplicates" (same bytes; only filesystem
//            names/dates differ).
//   Tier 2 — per-stream packet hashes via ffmpeg's streamhash muxer
//            (`-c copy`, no decode — demux cost only). Matching
//            stream-hash sets ⇒ "Same content, different wrapper"
//            (e.g. the same DV essence rewrapped from .mov to .mxf).
//   Tier 3 — PERCEPTUAL (escalation only): when Tiers 0–2 conclude
//            "different" and both files carry video, sample 32 frames
//            per file as 64-bit dHashes and compare them statistically
//            (model documented in PerceptualHash.swift). A strong
//            frame-level match ⇒ "Same content (re-encoded)" — the DV
//            original vs its H.264 re-encode case, which shares zero
//            bytes and zero packet hashes. A fingerprint failure here
//            (undecodable video, e.g. Avid RGBA MXF) deliberately
//            falls BACK to "Genuinely different files" instead of
//            erroring — Tiers 0–2 already proved both files readable,
//            and this tier must never make the feature less robust
//            than it was before the tier existed.
//   Otherwise ⇒ "Genuinely different files".
//
// Layering (deliberate, for the testing agent):
//   - `PairCompareVerdict` + `PairCompareLogic` are PURE — verdict
//     computation, ffmpeg streamhash output parsing, and metadata
//     diffing take values in and return values out. No file I/O, no
//     subprocesses, no actors. Unit-testable without fixtures.
//   - `MediaPairComparator` is the I/O orchestrator — an
//     ObservableObject the sheet observes, mirroring FrameRipper's
//     shape. All disk reads and ffmpeg invocations live here.
//
// Memory footprint (worst case): one read chunk in flight at a time —
// chunkSize (8 MB) plus Foundation's transient Data copy ≈ 16 MB,
// drained per-iteration by autoreleasepool. Stream-hash output from
// ffmpeg is a handful of short lines. We never mmap or buffer a whole
// media file (multi-GB sources; project has been burned before).

private let pairCompareLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                    category: "pairCompare")

// MARK: - Verdict

/// The answer to "are these two files the same?", strongest claim first.
enum PairCompareVerdict: Equatable {
    /// Byte-for-byte identical files. Only names / filesystem dates differ.
    case exactDuplicates
    /// Audio/video packet content is identical; only the container
    /// wrapper or its metadata differs (rewrap, remux, retagged copy).
    case sameContentDifferentContainer
    /// The frames LOOK the same but the encodings differ — one file is
    /// a re-encode of the other (different codec / resolution /
    /// bitrate / container). Established statistically by the
    /// perceptual tier; the supporting numbers live in
    /// `MediaPairComparator.perceptualStats`.
    case samePerceptualContent
    /// The media content itself doesn't match.
    case differentMedia
    /// Both catalog rows resolve to the same path on disk — there is
    /// only one file, so there's nothing to compare.
    case sameFile

    /// Short, family-friendly headline for the verdict banner.
    var title: String {
        switch self {
        case .exactDuplicates:
            return "Exact duplicates"
        case .sameContentDifferentContainer:
            return "Same movie, different wrapper"
        case .samePerceptualContent:
            return "Same content (re-encoded)"
        case .differentMedia:
            return "Genuinely different files"
        case .sameFile:
            return "These are the same file"
        }
    }

    /// One-sentence explanation under the headline.
    var detail: String {
        switch self {
        case .exactDuplicates:
            return "These two files are byte-for-byte identical — the same data on disk. Only the names or folder dates differ."
        case .sameContentDifferentContainer:
            return "The picture and sound inside are identical — only the file container or its metadata differs."
        case .samePerceptualContent:
            return "The pictures match frame for frame, but the files use different encodings — one is a converted copy of the other."
        case .differentMedia:
            return "The picture or sound content doesn't match — these are two different recordings."
        case .sameFile:
            return "Both selected rows point at the very same file on disk — one file, two catalog entries."
        }
    }
}

// MARK: - Pure logic (no I/O — unit-testable without fixtures)

enum PairCompareLogic {

    // MARK: Stream hashes

    /// One line of ffmpeg streamhash output: which stream, what kind,
    /// and the digest of every packet in it.
    struct StreamHash: Hashable, Sendable {
        let index: Int
        /// Stream type letter as ffmpeg emits it: "v" video, "a" audio,
        /// "s" subtitle, "d" data. Lowercased by the parser.
        let type: String
        /// Hex digest, lowercased by the parser.
        let digest: String
    }

    /// Parse the stdout of
    /// `ffmpeg -nostdin -i <path> -map 0 -c copy -f streamhash -hash sha256 -`.
    /// Lines look like `0,v,SHA256=58f8c2f...`. Malformed or empty lines
    /// are skipped — ffmpeg occasionally prepends nothing, but be defensive.
    static func parseStreamHashes(_ output: String) -> [StreamHash] {
        var result: [StreamHash] = []
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // maxSplits keeps any "=" padding inside the digest segment intact.
            let parts = line.split(separator: ",", maxSplits: 2,
                                   omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let index = Int(parts[0].trimmingCharacters(in: .whitespaces))
            else { continue }
            let type = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !type.isEmpty else { continue }
            let algoAndDigest = parts[2]
            guard let eq = algoAndDigest.firstIndex(of: "=") else { continue }
            let digest = algoAndDigest[algoAndDigest.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !digest.isEmpty else { continue }
            result.append(StreamHash(index: index, type: type, digest: digest))
        }
        return result
    }

    /// True when both files carry the same media content per stream type.
    /// Order-independent: a rewrap that reorders streams (audio before
    /// video) still matches, because we compare the multiset of digests
    /// per type rather than position-by-position. Empty sets never match
    /// — "we couldn't hash anything" must not read as "identical".
    static func streamContentMatches(_ a: [StreamHash], _ b: [StreamHash]) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return digestsByType(a) == digestsByType(b)
    }

    /// Group digests by stream type, sorted so comparison is a plain
    /// dictionary equality. (≈ C++ std::map<string, std::multiset<string>>.)
    private static func digestsByType(_ hashes: [StreamHash]) -> [String: [String]] {
        var grouped: [String: [String]] = [:]
        for h in hashes {
            grouped[h.type, default: []].append(h.digest)
        }
        for key in grouped.keys {
            grouped[key]?.sort()
        }
        return grouped
    }

    // MARK: Verdict

    /// Fold the tier evidence into a verdict. `nil` means "that tier
    /// didn't run" (Tier 1 skipped on size mismatch; Tier 2 skipped
    /// when Tier 1 already proved byte equality; Tier 3 — perceptual —
    /// skipped unless Tiers 0–2 said "different" AND both files have
    /// video). Strongest claim wins: byte identity > packet identity >
    /// perceptual identity.
    static func verdict(sizesMatch: Bool,
                        bytesMatch: Bool?,
                        streamsMatch: Bool?,
                        perceptualMatch: Bool? = nil) -> PairCompareVerdict {
        if sizesMatch && bytesMatch == true {
            return .exactDuplicates
        }
        if streamsMatch == true {
            return .sameContentDifferentContainer
        }
        if perceptualMatch == true {
            return .samePerceptualContent
        }
        return .differentMedia
    }

    // MARK: Metadata diff

    /// One side-by-side row for the sheet's metadata table.
    struct MetadataDiffRow: Identifiable, Equatable {
        let label: String
        let valueA: String
        let valueB: String
        /// True when the two values genuinely differ (the UI highlights
        /// these). Empty-vs-empty counts as "same".
        let differs: Bool

        var id: String { label }
    }

    /// Side-by-side field diff sourced entirely from the already-
    /// cataloged VideoRecord metadata — no ffprobe re-run. Labels are
    /// family-facing ("Picture codec", not "vcodec").
    static func metadataDiff(_ a: VideoRecord, _ b: VideoRecord) -> [MetadataDiffRow] {
        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        func row(_ label: String, _ va: String, _ vb: String,
                 differs: Bool? = nil) -> MetadataDiffRow {
            MetadataDiffRow(label: label,
                            valueA: va.isEmpty ? "—" : va,
                            valueB: vb.isEmpty ? "—" : vb,
                            differs: differs ?? (norm(va) != norm(vb)))
        }
        func containerLabel(_ r: VideoRecord) -> String {
            r.container.isEmpty ? r.ext.uppercased() : r.container
        }
        return [
            row("Length", a.duration, b.duration),
            row("Picture codec", a.videoCodec, b.videoCodec),
            row("Sound codec", a.audioCodec, b.audioCodec),
            row("Resolution", a.resolution, b.resolution),
            row("Frame rate", a.frameRate, b.frameRate),
            row("Bitrate", a.totalBitrate, b.totalBitrate),
            row("Created", a.dateCreated, b.dateCreated),
            row("File type", containerLabel(a), containerLabel(b)),
            // Size compares the exact byte counts; the display strings
            // are rounded ("1.2 GB") and could collide while differing.
            row("File size", a.size, b.size, differs: a.sizeBytes != b.sizeBytes)
        ]
    }
}

// MARK: - Errors

enum PairCompareError: LocalizedError {
    case cantReadFile(String)
    case ffmpegFailed(file: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .cantReadFile(let path):
            let name = (path as NSString).lastPathComponent
            return "Couldn't read \"\(name)\" — the file may be offline or moved."
        case .ffmpegFailed(let file, let detail):
            let name = (file as NSString).lastPathComponent
            return "Couldn't read the media streams in \"\(name)\"."
                + (detail.isEmpty ? "" : " (\(detail))")
        }
    }
}

// MARK: - Comparator (I/O orchestration)

/// Runs the tiered comparison off the main thread and publishes
/// progress for the UI. Owned one-per-job by `PairCompareJob` (Media
/// File Operations window); the job's run Task drives `run(...)`, so
/// cancelling that task propagates into the hash loop (per-chunk
/// check) and into ffmpeg (ProcessRunner's cancellation handler
/// terminates the child process).
///
/// `@MainActor` ≈ "all members touched only on the UI thread" — the
/// heavy lifting happens in `nonisolated static` helpers below, which
/// run on the cooperative background pool.
@MainActor
final class MediaPairComparator: ObservableObject {

    // MARK: Published state (drives the sheet)

    /// True while a comparison is in flight.
    @Published var isRunning = false

    /// Human-readable phase ("Reading both files…", "Comparing streams…").
    @Published var statusText = ""

    /// 0…1 overall progress. Tier 1 (full byte read of both files) is
    /// the heavy phase, so it owns 0…0.7 of the bar when it runs;
    /// Tier 2 fills the remainder. When Tier 1 is skipped (sizes
    /// differ), Tier 2 spans the whole bar.
    @Published var fraction: Double = 0

    /// Final answer. Non-nil ⇒ comparison finished successfully.
    @Published var verdict: PairCompareVerdict?

    /// Non-recoverable failure message (offline file, ffmpeg error).
    @Published var lastError: String?

    /// True while Tier 2 runs without a usable duration hint — the
    /// sheet shows an indeterminate bar instead of a frozen one.
    @Published var isIndeterminate = false

    /// Tier-3 statistics. Non-nil whenever the perceptual tier ran to
    /// completion — INCLUDING when it did NOT find a match (the
    /// "inconclusive zone" stats stay visible under a differentMedia
    /// verdict so Rick can see how close the call was).
    @Published var perceptualStats: PerceptualMatchResult?

    /// What the finished row's subtitle should say. For the perceptual
    /// verdict the stats line IS the story ("31/32 frames agree …");
    /// every other verdict keeps its plain-language detail.
    var finishedSubtitle: String? {
        guard let verdict else { return nil }
        if verdict == .samePerceptualContent, let stats = perceptualStats {
            return stats.summary
        }
        return verdict.detail
    }

    /// Bar span owned by Tier 1 when it runs.
    private static let tier1Span = 0.7
    /// Read chunk for full-file hashing. 8 MB balances syscall overhead
    /// against memory; never larger — see memory-footprint note above.
    private static let hashChunkSize = 8 * 1024 * 1024
    /// Only publish hash progress every 32 MB so a fast SSD doesn't
    /// flood the main actor with per-chunk hops.
    private static let progressGranularity: Int64 = 32 * 1024 * 1024

    // MARK: Entry point

    /// Run the full tiered comparison. Call from the sheet's `.task`
    /// so dismissal cancels everything. Reads only value-type fields
    /// off the records up front (VideoRecord is a main-actor-bound
    /// class; the background helpers see plain Strings/Ints).
    func run(recordA: VideoRecord, recordB: VideoRecord) async {
        guard !isRunning else { return }
        isRunning = true
        verdict = nil
        lastError = nil
        fraction = 0
        isIndeterminate = false
        perceptualStats = nil
        statusText = "Checking file sizes…"

        let pathA = recordA.fullPath
        let pathB = recordB.fullPath
        // Tier-3 gate inputs, read off the records up front like the
        // paths (catalog metadata only — never re-probed here). The
        // perceptual tier needs per-file durations for its sampling
        // rate and only makes sense when both files carry a picture.
        let durationA = recordA.durationSeconds
        let durationB = recordB.durationSeconds
        let aHasVideo = recordA.streamType == .videoAndAudio
            || recordA.streamType == .videoOnly
        let bHasVideo = recordB.streamType == .videoAndAudio
            || recordB.streamType == .videoOnly

        // Two catalog rows can point at one file on disk (duplicate
        // entries). Comparing a file with itself would read it twice
        // and claim "exact duplicates" — misleading. Answer directly.
        if (pathA as NSString).standardizingPath == (pathB as NSString).standardizingPath {
            pairCompareLog.info("pair compare: both rows resolve to the same path")
            finish(with: .sameFile)
            return
        }
        // Duration hint feeds Tier 2's progress fraction (ffmpeg reports
        // out_time, we know roughly how long the media runs). Catalog
        // metadata only — never re-probed.
        let durationHint = max(recordA.durationSeconds, recordB.durationSeconds)

        pairCompareLog.info("pair compare start: \(pathA, privacy: .public) vs \(pathB, privacy: .public)")

        do {
            // MARK: Tier 0 — sizes (stat the real files; catalog could be stale)
            let sizeA = try await Self.fileSize(atPath: pathA)
            let sizeB = try await Self.fileSize(atPath: pathB)
            let sizesMatch = sizeA == sizeB
            pairCompareLog.info("tier 0: sizeA=\(sizeA) sizeB=\(sizeB) match=\(sizesMatch)")

            // MARK: Tier 1 — chunked full-file SHA-256 (only when sizes match)
            var bytesMatch: Bool?
            if sizesMatch {
                statusText = "Reading both files byte-by-byte…"
                let totalBytes = sizeA + sizeB
                let digestA = try await Self.sha256OfFile(
                    atPath: pathA,
                    chunkSize: Self.hashChunkSize,
                    progressGranularity: Self.progressGranularity,
                    onBytesHashed: progressSink(base: 0,
                                                span: Self.tier1Span,
                                                offsetBytes: 0,
                                                totalBytes: totalBytes)
                )
                let digestB = try await Self.sha256OfFile(
                    atPath: pathB,
                    chunkSize: Self.hashChunkSize,
                    progressGranularity: Self.progressGranularity,
                    onBytesHashed: progressSink(base: 0,
                                                span: Self.tier1Span,
                                                offsetBytes: sizeA,
                                                totalBytes: totalBytes)
                )
                bytesMatch = (digestA == digestB)
                pairCompareLog.info("tier 1: byte-identical=\(bytesMatch == true)")

                if bytesMatch == true {
                    finish(with: .exactDuplicates)
                    return
                }
            } else {
                pairCompareLog.info("tier 1 skipped: sizes differ")
            }

            // MARK: Tier 2 — per-stream packet hashes (no decode)
            statusText = "Comparing the picture and sound streams…"
            // No cataloged duration → ffmpeg progress can't be turned
            // into a fraction; switch the sheet to an indeterminate bar
            // rather than freezing a determinate one.
            isIndeterminate = durationHint <= 0
            let tier2Base = sizesMatch ? Self.tier1Span : 0.0
            let tier2Span = 1.0 - tier2Base
            let ffmpeg = ToolLocator.ffmpegPath

            let hashesA = try await Self.streamHashes(
                ffmpegPath: ffmpeg,
                path: pathA,
                durationHint: durationHint,
                onFraction: fractionSink(base: tier2Base, span: tier2Span / 2)
            )
            let hashesB = try await Self.streamHashes(
                ffmpegPath: ffmpeg,
                path: pathB,
                durationHint: durationHint,
                onFraction: fractionSink(base: tier2Base + tier2Span / 2,
                                         span: tier2Span / 2)
            )
            let streamsMatch = PairCompareLogic.streamContentMatches(hashesA, hashesB)
            pairCompareLog.info("tier 2: streamsA=\(hashesA.count) streamsB=\(hashesB.count) match=\(streamsMatch)")

            // MARK: Tier 3 — perceptual frame comparison (escalation only)
            //
            // Runs only when the packet tier said "different" and both
            // files actually carry video with a known duration. The
            // sequential ffmpeg reads happen under the same volume
            // gates the job already holds for Tiers 1–2 — this is just
            // more of the same one-reader-at-a-time disk traffic.
            var perceptualMatch: Bool?
            if !streamsMatch, aHasVideo, bHasVideo,
               durationA > 0, durationB > 0 {
                statusText = "Comparing visual content…"
                // The earlier tiers already walked the bar to ~1.0; the
                // perceptual pass owns a fresh 0…1 sweep (file A then B).
                fraction = 0
                isIndeterminate = false
                do {
                    let fpA = try await PerceptualFingerprinter.fingerprint(
                        ffmpegPath: ffmpeg,
                        path: pathA,
                        durationSeconds: durationA,
                        onFraction: fractionSink(base: 0, span: 0.5)
                    )
                    let fpB = try await PerceptualFingerprinter.fingerprint(
                        ffmpegPath: ffmpeg,
                        path: pathB,
                        durationSeconds: durationB,
                        onFraction: fractionSink(base: 0.5, span: 0.5)
                    )
                    let stats = PerceptualHash.compare(fpA, fpB)
                    perceptualStats = stats
                    perceptualMatch = stats.isMatch
                    pairCompareLog.info("tier 3: \(stats.matchedFrames)/\(stats.framesCompared) frames ≤ \(PerceptualHash.perFrameBitThreshold) bits, median=\(stats.medianDistance) offset=\(stats.bestOffset) log10P=\(stats.log10CoincidenceProbability) match=\(stats.isMatch)")
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Robustness contract (see header): a Tier-3 failure
                    // must not be louder than not having Tier 3 at all.
                    // The earlier tiers already read both files, so this
                    // is "couldn't decode", not "couldn't reach" — keep
                    // the differentMedia verdict and log the why.
                    pairCompareLog.error("tier 3 skipped after error: \(error.localizedDescription, privacy: .public)")
                }
            } else if !streamsMatch {
                pairCompareLog.info("tier 3 skipped: video A=\(aHasVideo) B=\(bHasVideo) durations \(durationA)/\(durationB)")
            }

            finish(with: PairCompareLogic.verdict(sizesMatch: sizesMatch,
                                                  bytesMatch: bytesMatch,
                                                  streamsMatch: streamsMatch,
                                                  perceptualMatch: perceptualMatch))
        } catch is CancellationError {
            pairCompareLog.info("pair compare cancelled")
            statusText = "Cancelled"
            isRunning = false
        } catch {
            pairCompareLog.error("pair compare failed: \(error.localizedDescription, privacy: .public)")
            statusText = "Error"
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    private func finish(with verdict: PairCompareVerdict) {
        pairCompareLog.info("verdict: \(verdict.title, privacy: .public)")
        self.fraction = 1.0
        self.isIndeterminate = false
        self.verdict = verdict
        self.statusText = "Done"
        self.isRunning = false
    }

    // MARK: Progress plumbing

    /// Bytes-hashed → published fraction, hopping back to the main
    /// actor. `[weak self]` so a dismissed sheet doesn't retain us.
    private func progressSink(base: Double, span: Double,
                              offsetBytes: Int64,
                              totalBytes: Int64) -> @Sendable (Int64) -> Void {
        { [weak self] bytes in
            guard totalBytes > 0 else { return }
            let f = base + span * (Double(offsetBytes + bytes) / Double(totalBytes))
            Task { @MainActor in
                self?.fraction = min(1.0, f)
            }
        }
    }

    /// Tier-2 (0…1 per file) fraction → published overall fraction.
    private func fractionSink(base: Double, span: Double) -> @Sendable (Double) -> Void {
        { [weak self] f in
            let overall = base + span * min(1.0, max(0, f))
            Task { @MainActor in
                self?.fraction = min(1.0, overall)
            }
        }
    }

    // MARK: - Background I/O helpers (off the main actor)

    /// File size via FileManager. Throws `.cantReadFile` for offline /
    /// moved files so the user sees a friendly message, not a crash.
    ///
    /// `@concurrent` matters here and on the two helpers below: this
    /// project builds with Approachable Concurrency
    /// (NonisolatedNonsendingByDefault), under which a plain
    /// `nonisolated async` function runs on its CALLER's actor — i.e.
    /// the main thread, since `run()` is @MainActor. `@concurrent`
    /// pins execution to the global pool, so a stat against a sleeping
    /// HDD (or an 8 MB read loop over a multi-GB file) never blocks
    /// the UI. (C++ analogy: without it, the "worker" is inlined into
    /// the UI thread's event loop.)
    @concurrent
    nonisolated static func fileSize(atPath path: String) async throws -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            throw PairCompareError.cantReadFile(path)
        }
        return size
    }

    /// Chunked SHA-256 of an entire file. Streams `chunkSize` bytes at
    /// a time through CryptoKit inside an autoreleasepool — never mmap,
    /// never whole-file reads (multi-GB sources; memory-pressure
    /// history). Checks for task cancellation between chunks and
    /// yields so a long HDD read doesn't monopolize a cooperative
    /// thread. Worst-case resident memory ≈ 2 × chunkSize.
    /// `@concurrent`: see `fileSize` — without it this loop runs on
    /// the main actor under Approachable Concurrency.
    @concurrent
    nonisolated static func sha256OfFile(
        atPath path: String,
        chunkSize: Int,
        progressGranularity: Int64,
        onBytesHashed: @escaping @Sendable (Int64) -> Void
    ) async throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw PairCompareError.cantReadFile(path)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var totalBytes: Int64 = 0
        var bytesSinceCallback: Int64 = 0

        while true {
            try Task.checkCancellation()
            // autoreleasepool drains the transient Data each iteration
            // (≈ a C++ scoped arena freed per loop pass). It can't wrap
            // an `await`, so the yield happens outside.
            let chunkLength: Int = try autoreleasepool {
                guard let data = try handle.read(upToCount: chunkSize),
                      !data.isEmpty else { return 0 }
                hasher.update(data: data)
                return data.count
            }
            if chunkLength == 0 { break }
            totalBytes += Int64(chunkLength)
            bytesSinceCallback += Int64(chunkLength)
            if bytesSinceCallback >= progressGranularity {
                onBytesHashed(totalBytes)
                bytesSinceCallback = 0
            }
            await Task.yield()
        }
        onBytesHashed(totalBytes)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run ffmpeg's streamhash muxer over one file and parse the
    /// per-stream digests. `-c copy` means demux-only — no decode, so
    /// the cost is one sequential read of the file. `-progress pipe:2`
    /// emits newline-delimited `out_time_us=` keys on stderr, which we
    /// turn into a 0…1 fraction against the cataloged duration.
    /// ProcessRunner terminates the child on task cancellation.
    /// `@concurrent`: see `fileSize` — without it the demux wait and
    /// output parsing run on the main actor under Approachable
    /// Concurrency.
    @concurrent
    nonisolated static func streamHashes(
        ffmpegPath: String,
        path: String,
        durationHint: Double,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws -> [PairCompareLogic.StreamHash] {
        let args = [
            "-nostdin", "-nostats",
            "-progress", "pipe:2",
            "-i", path,
            "-map", "0",
            "-c", "copy",
            "-f", "streamhash",
            "-hash", "sha256",
            "-"
        ]
        let result = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: args,
            stderrLine: { line in
                guard durationHint > 0,
                      line.hasPrefix("out_time_us="),
                      let micros = Double(line.dropFirst("out_time_us=".count))
                else { return }
                onFraction((micros / 1_000_000) / durationHint)
            }
        )
        try Task.checkCancellation()
        guard result.exitCode == 0, let stdout = result.stdout else {
            // Last stderr line is usually ffmpeg's actual complaint.
            let tail = result.stderr
                .split(separator: "\n")
                .last(where: { !$0.hasPrefix("out_time") && !$0.contains("=") })
                .map(String.init) ?? ""
            throw PairCompareError.ffmpegFailed(file: path, detail: tail)
        }
        let hashes = PairCompareLogic.parseStreamHashes(stdout)
        guard !hashes.isEmpty else {
            throw PairCompareError.ffmpegFailed(file: path,
                                                detail: "no stream hashes produced")
        }
        return hashes
    }
}
