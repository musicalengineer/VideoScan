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
// Memory: PacketCensus's bound (≤ 8 MB worst case, ≈ 0.3 MB for a 2 h
// tape) + one pipe chunk.

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
        let total = facts.durationSeconds ?? facts.video?.durationSeconds ?? 0
        // Picture = first 85 % of this pass's bar (it is most of the bytes).
        if facts.video != nil {
            let meter = ProgressMeter(totalSeconds: total, report: { progress?(0.85 * $0) })
            let r = await ProcessRunner.runProcess(
                executable: ffprobe, arguments: censusArgs(input: path, stream: "v:0"),
                stdoutLine: { if let t = tally.notePicture($0) { meter.note(t) } },
                stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
            try Task.checkCancellation()
            guard r.exitCode == 0 else {
                return .failure(CheckMediaSkip(reason: "ffprobe could not list the picture packets (exit \(r.exitCode))"))
            }
        }
        if facts.audio != nil {
            let meter = ProgressMeter(totalSeconds: total, report: { progress?(0.85 + 0.15 * $0) })
            let r = await ProcessRunner.runProcess(
                executable: ffprobe, arguments: censusArgs(input: path, stream: "a:0"),
                stdoutLine: { if let t = tally.noteSound($0) { meter.note(t) } },
                stdoutLimitBytes: 0, stderrLimitBytes: 16 * 1024, control: control)
            try Task.checkCancellation()
            guard r.exitCode == 0 else {
                return .failure(CheckMediaSkip(reason: "ffprobe could not list the sound packets (exit \(r.exitCode))"))
            }
        }
        return .success(tally.report)
    }
}
