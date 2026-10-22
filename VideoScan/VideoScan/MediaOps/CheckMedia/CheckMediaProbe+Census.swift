import Foundation

// MARK: - Check Media — the packet census pass (I/O half, 2026-10-07)
//
// Two ffprobe runs through ProcessRunner (never a bare Process()):
//   ffprobe -select_streams v:0 -show_entries packet=pts_time,dts_time,
//           duration_time,size,pos,flags -of compact=p=0 <file>
// then the same for a:0. Every line streams into PacketCensus; nothing is
// collected (`stdoutLimitBytes: 0`). Read-only on the media.
//
// Cost: ffprobe reads each packet's data, so the picture run reads the
// picture once more (the full tier now reads the picture twice: decode +
// census; the sound once more, cheaply). One stream per run keeps the
// reads sequential on a non-interleaved file.
//
// The census also counts every packet, which is how a file with no
// recorded duration (a raw .m2v) gets its length estimated — no extra read
// (DurationEstimate, 2026-10-21). Such a file has no seconds to measure
// progress against, so the bar follows each packet's byte position over
// the file's size instead (CensusProgressBasis).
//
// Memory: PacketCensus's bound (≤ 8 MB worst case, ≈ 0.3 MB for a 2 h
// tape) + one pipe chunk.

/// What the census bar measures against: the header's duration in
/// seconds, or — for a file that records none — its size in bytes, by
/// each packet's byte position. nil = nothing to measure (no progress).
enum CensusProgressBasis: Sendable, Equatable {
    case seconds(Double)
    case bytes(Int64)

    static func basis(for facts: MediaFacts) -> CensusProgressBasis? {
        let total = facts.durationSeconds ?? facts.video?.durationSeconds ?? 0
        if total > 0 { return .seconds(total) }
        if let size = facts.sizeBytes, size > 0 { return .bytes(size) }
        return nil
    }

    /// 0…1 for this packet; nil when the packet lacks the coordinate.
    func fraction(of p: CensusPacket) -> Double? {
        switch self {
        case .seconds(let total):
            return p.time.map { min(1, max(0, $0 / total)) }
        case .bytes(let total):
            return p.pos.map { min(1, max(0, Double($0) / Double(total))) }
        }
    }
}

extension CheckMediaProbe {

    static func censusArgs(input: String, stream: String) -> [String] {
        ["-hide_banner", "-v", "error", "-select_streams", stream,
         "-show_entries", "packet=pts_time,dts_time,duration_time,size,pos,flags",
         "-of", "compact=p=0", input]
    }

    /// Every packet of the picture, then of the sound. A failure is the
    /// rows' "not run" reason; only cancellation throws.
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func census(path: String, facts: MediaFacts, control: ProcessControl? = nil,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws
        -> Result<PacketCensusReport, CheckMediaSkip> {
        let ffprobe = ToolLocator.ffprobePath
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else {
            return .failure(CheckMediaSkip(reason: "ffprobe not found"))
        }
        let tally = PacketCensusTally()
        let basis = CensusProgressBasis.basis(for: facts)
        // The meters take a 0…1 fraction here (total 1), whichever basis.
        // Picture = first 85 % of this pass's bar (it is most of the bytes).
        if facts.video != nil {
            let meter = ProgressMeter(totalSeconds: 1, report: { progress?(0.85 * $0) })
            let r = await ProcessRunner.runProcess(
                executable: ffprobe, arguments: censusArgs(input: path, stream: "v:0"),
                stdoutLine: { if let p = tally.notePicture($0), let f = basis?.fraction(of: p) { meter.note(f) } },
                stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
            try Task.checkCancellation()
            guard r.exitCode == 0 else {
                return .failure(CheckMediaSkip(reason: "ffprobe could not list the picture packets (exit \(r.exitCode))"))
            }
        }
        if facts.audio != nil {
            let meter = ProgressMeter(totalSeconds: 1, report: { progress?(0.85 + 0.15 * $0) })
            let r = await ProcessRunner.runProcess(
                executable: ffprobe, arguments: censusArgs(input: path, stream: "a:0"),
                stdoutLine: { if let p = tally.noteSound($0), let f = basis?.fraction(of: p) { meter.note(f) } },
                stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
            try Task.checkCancellation()
            guard r.exitCode == 0 else {
                return .failure(CheckMediaSkip(reason: "ffprobe could not list the sound packets (exit \(r.exitCode))"))
            }
        }
        return .success(tally.report)
    }
}
