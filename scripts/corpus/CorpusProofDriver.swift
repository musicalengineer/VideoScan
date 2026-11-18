// CorpusProofDriver.swift — lane `proof` of the real-data corpus harness.
// (How this file reaches a build, the seal and the privacy rule:
// CorpusDriverSupport.swift.)
//
// Laid over the testbed ONLY when the ref under test contains the
// balanced-copy proof engine (MediaOps/BalancedCopyProof*.swift); the Python
// side says "this ref has no proof engine" otherwise and builds nothing.
//
// Per "one-sided sound" corpus file:
//   balance  AudioBalanceProbe.analyze, then the app's own BalanceAudioJob
//            with `plannedOutput` under ~/corpus/work/<run>/ (the job's seam
//            for a chosen folder) — the corpus source is only read. The model
//            is a bare in-memory one in a test host: nothing is catalogued.
//   proof    BalancedCopyProof.measurement(original:balanced:) → the outcome
//            word, the named difference kinds, the discarded channel's peak,
//            and the EVIDENCE as words and numbers (`CorpusProofEvidence`):
//            which rule fired and on which file, each file's packet, frame
//            and sample counts (listed, read, decoded, stated, stored), the
//            sound's runs on the timeline, and every display field the two
//            headers state differently. Needs a ref whose engine has
//            `measurement`, `estimatedSeconds`, `statesRangeOnOneSideOnly`
//            and `earlyEndingHeader` (2026-11-18); an older ref does not build.
// The balanced copy is removed from work/ as soon as its proof is recorded,
// so at most one copy is on disk (worst case: the size of the largest
// one-sided corpus file plus its PCM sound).

import Foundation
import XCTest
import VideoScanCore
@testable import VideoScan

final class CorpusProofDriver: XCTestCase {

    /// The CATEGORY of a "could not check" sentence, never the sentence: the first fixed
    /// phrase of the engine's that it contains, and which file it is about. A sentence
    /// with none of them is `other`.
    nonisolated static func category(ofCouldNotCheck reason: String) -> [String] {
        let phrases: [(String, String)] = [
            ("was not read to the end", "not_read_to_the_end"),
            ("could not be decoded to the end", "not_decoded_to_the_end"),
            ("did not decode cleanly", "did_not_decode_cleanly"),
            ("did not all arrive", "frames_did_not_all_arrive"),
            ("ran out of time", "ran_out_of_time"),
            ("packet by packet", "packets_unreadable"),
            ("could not be lined up", "streams_not_lined_up"),
            ("not on disk", "not_on_disk"),
            ("symbolic link", "symbolic_link"),
            ("the same file", "same_file"),
            ("changed while", "file_changed"),
            ("partly measured", "sound_partly_measured"),
            ("not measured", "sound_not_measured"),
            ("could not be measured", "sound_not_measured"),
            ("gave no", "gave_nothing"),
            ("channels, which", "channel_count"),
            ("could not be read", "unreadable"),
            ("not found", "tool_unavailable"),
            ("stopped", "stopped")
        ]
        let category = phrases.first { reason.contains($0.0) }?.1 ?? "other"
        let holder = reason.hasPrefix("the balanced copy") ? "balanced_copy"
            : reason.hasPrefix("the original") ? "original" : nil
        return [category] + (holder.map { [$0] } ?? [])
    }

    @MainActor
    func testProofLane() async throws {
        let run: CorpusRun
        let records: [String: VideoRecord]
        do {
            run = try CorpusRun.open(lane: "proof")
            let loaded = try await run.loadCatalog()
            records = Dictionary(loaded.records.map { ($0.fullPath, $0) }, uniquingKeysWith: { first, _ in first })
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }

        for item in run.config.pending {
            run.begin(item)
            guard let record = records[item.path] else {
                await run.engine(item, "balance") { ("no_record", []) }
                run.end(item)
                continue
            }
            var balanced: URL?
            await run.engine(item, "balance") {
                let analysis = try await AudioBalanceProbe.analyze(path: item.path)
                run.facts(item, ["container": CorpusWords.word(analysis.shape.containerFormat),
                                 "vcodec": CorpusWords.word(analysis.shape.videoCodec ?? "none"),
                                 "acodec": CorpusWords.word(analysis.shape.audioCodec.isEmpty ? "none" : analysis.shape.audioCodec),
                                 "duration": analysis.shape.durationSeconds])
                let classWord = analysis.classification.rawValue
                let stem = String(item.sha.prefix(12))
                let ext = URL(fileURLWithPath: item.path).pathExtension
                let named = run.config.work + "/" + stem + (ext.isEmpty ? "" : "." + ext)
                let planned = BalanceAudioFix.balancedOutputURL(forSourcePath: named,
                                                                containerFormat: analysis.shape.containerFormat)
                guard CorpusRun.isUnder(planned.path, run.config.work) else { return ("refused_by_harness", [classWord]) }
                let model = VideoScanModel()
                model.records = [record]
                let job = BalanceAudioJob(record: record, analysis: analysis, model: model, plannedOutput: planned)
                job.start()
                await job.task?.value
                if case .finished = job.state, let published = job.publishedURL,
                   CorpusRun.isUnder(published.path, run.config.work) {
                    balanced = published
                    return ("balanced", [classWord])
                }
                return (job.wasRefused ? "refused" : "failed", [classWord])
            }
            if let balanced {
                await run.engine(item, "proof") {
                    let measured = await BalancedCopyProof.measurement(original: item.path, balanced: balanced.path)
                    let evidence = CorpusProofEvidence.words(measured)
                    switch measured.outcome {
                    case .proven(let held):
                        if let peak = held.discarded?.peakDBFS, peak.isFinite { run.facts(item, ["peak_dbfs": peak]) }
                        return ("proven", evidence)
                    case .sameContent(let held, let differs):
                        if let peak = held.discarded?.peakDBFS, peak.isFinite { run.facts(item, ["peak_dbfs": peak]) }
                        return ("same_content", Array(Set(differs.map { $0.kind.rawValue })).sorted() + evidence)
                    case .notProven(let why):
                        return ("not_proven", [CorpusWords.caseName(why)] + evidence)
                    case .couldNotCheck(let reason):
                        return ("could_not_check", CorpusProofDriver.category(ofCouldNotCheck: reason) + evidence)
                    }
                }
                try? FileManager.default.removeItem(at: balanced)
            }
            run.end(item)
        }
        run.done()
    }
}

/// The proof's evidence as WORDS: `key:number` or `key:codec-or-enum-word`, each at most
/// 64 characters of `A-Z a-z 0-9 _ , : + -`. Built only from the engine's measured facts
/// (counts, lengths, sample rates, codec and container names, header fields such as pixel
/// format or field order) — never from a sentence, a tag, a path or a tool's message.
/// Prefix `o_` = the original, `c_` = the balanced copy. Lengths are microseconds (`_us`)
/// or samples.
enum CorpusProofEvidence {
    typealias Proof = BalancedCopyProof

    static func words(_ measured: Proof.Measurement) -> [String] {
        guard let facts = measured.facts else { return ["facts:none"] }
        let kept = Proof.keptSound(facts), copySound = facts.balanced.sound.first
        var out = ["facts:" + (facts.balancedRead != nil ? "decoded" : facts.originalRead != nil ? "original_decoded" : "headers")]
        out += file("o", facts.original, read: facts.originalRead, sound: kept)
        out += file("c", facts.balanced, read: facts.balancedRead, sound: copySound)
        switch measured.outcome {
        case .couldNotCheck(let reason):
            out += variant(reason, facts: facts, kept: kept, copySound: copySound)
        case .notProven(.pictureConfigurationDiffers):
            out += configuration(facts, kept: kept, copySound: copySound)
        case .sameContent:
            // A colour range only one file states, displayed the same: which file, and the range.
            if case .success(let pairing) = Proof.pairing(original: facts.original.carried, balanced: facts.balanced.carried) {
                for (n, pair) in pairing.pictures.enumerated() {
                    let original = facts.original.carried[pair.original].configuration
                    let copy = facts.balanced.carried[pair.balanced].configuration
                    guard original.statesRangeOnOneSideOnly(against: copy) else { continue }
                    out += ["v\(n)_named:colour_range", "v\(n)_colour_range_o:" + CorpusWords.word(original.colorRange),
                            "v\(n)_colour_range_c:" + CorpusWords.word(copy.colorRange)]
                }
            }
        default: break
        }
        if let estimate = facts.original.estimatedSeconds { out.append("o_estimated_us:" + micros(estimate)) }
        if let kept, facts.originalRead != nil {
            let early = Proof.earlyEndingHeader(of: facts.original, read: facts.originalRead, kept: kept).count
            if early > 0 { out.append("o_header_ends_early:\(early)") }
        }
        return out
    }

    private static func micros(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, abs(seconds) < 1e12 else { return "none" }
        return String(Int64((seconds * 1_000_000).rounded()))
    }

    private static func samples(_ seconds: Double?, rate: Int) -> String {
        guard let seconds, seconds.isFinite, abs(seconds) < 1e9, rate > 0 else { return "none" }
        return String(Int64((seconds * Double(rate)).rounded()))
    }

    private static func count(_ value: Int?) -> String { value.map(String.init) ?? "none" }

    /// One file: its container, each picture's and the kept sound's counts.
    static func file(_ p: String, _ layout: Proof.FileLayout, read: Proof.ReadReport?, sound: Proof.SoundStream?) -> [String] {
        var out = ["\(p)_container:" + CorpusWords.word(layout.container.split(separator: ",").first.map(String.init) ?? "none"),
                   "\(p)_pictures:\(layout.pictures.count)", "\(p)_sound_tracks:\(layout.sound.count)",
                   "\(p)_other_tracks:\(layout.carried.count - layout.pictures.count)"]
        for (n, picture) in layout.pictures.enumerated() {
            let v = "\(p)_v\(n)"
            out += ["\(v)_codec:" + CorpusWords.word(picture.codec),
                    "\(v)_tb:" + CorpusWords.word(picture.timeBase.replacingOccurrences(of: "/", with: ":")),
                    "\(v)_listed:" + count(picture.packets), "\(v)_read:" + count(read?.streams[picture.index]?.packets),
                    "\(v)_errors:" + count(read?.streams[picture.index]?.decodeErrors),
                    "\(v)_stated_us:" + micros(picture.statedSeconds), "\(v)_stored_us:" + micros(picture.storedSeconds)]
            if let played = read?.pictures[picture.index] {
                out += ["\(v)_frames:\(played.frames)", "\(v)_first_us:" + micros(played.firstSeconds),
                        "\(v)_played_us:" + micros(played.endSeconds - played.firstSeconds)]
            }
        }
        guard let sound else { return out }
        let a = "\(p)_a"
        out += ["\(a)_codec:" + CorpusWords.word(sound.codec), "\(a)_rate:\(sound.sampleRateHz)", "\(a)_channels:\(sound.channels)",
                "\(a)_listed:" + count(sound.packets), "\(a)_read:" + count(read?.streams[sound.index]?.packets),
                "\(a)_errors:" + count(read?.streams[sound.index]?.decodeErrors),
                "\(a)_stated:" + samples(sound.statedSeconds, rate: sound.sampleRateHz),
                "\(a)_stored:" + samples(sound.storedSeconds, rate: sound.sampleRateHz)]
        if let read, let runs = read.soundSegments {
            // Where a run starts against the end of the one before it: before = the two overlap, after = a gap.
            var overlap: Int64 = 0, gap: Int64 = 0
            for (before, after) in zip(runs, runs.dropFirst()) {
                let (end, o1) = before.start.addingReportingOverflow(before.samples)
                let (delta, o2) = after.start.subtractingReportingOverflow(end)
                guard !o1, !o2 else { continue }
                if delta < 0 { overlap &+= -delta } else { gap &+= delta }
            }
            out += ["\(a)_decoded:" + (read.soundSamples.map { String($0) } ?? "none"),
                    "\(a)_hashed:" + (read.channelSamples.first.map { String($0) } ?? "none"),
                    "\(a)_runs:\(runs.count)", "\(a)_start:" + (runs.first.map { String($0.start) } ?? "none"),
                    "\(a)_overlap:\(overlap)", "\(a)_gap:\(gap)",
                    "\(a)_muxed:\(read.muxed.values.reduce(0, &+))", "\(a)_folded:\(read.folded.values.reduce(0, &+))"]
        }
        return out
    }

    /// WHICH "could not check" it is — only when the engine's own read rule, asked again over
    /// the same facts, gives exactly the sentence the outcome carries.
    static func variant(_ reason: String, facts: Proof.Facts, kept: Proof.SoundStream?, copySound: Proof.SoundStream?) -> [String] {
        let files: [(String, Proof.FileLayout, Proof.ReadReport?, Proof.SoundStream?, String)] = [
            ("original", facts.original, facts.originalRead, kept, "the original"),
            ("balanced_copy", facts.balanced, facts.balancedRead, copySound, "the balanced copy")]
        for (word, layout, read, sound, name) in files {
            // The engine's own asymmetry: the original's decode may run under one frame or packet past its header.
            guard let shortfall = Proof.readShortfall(layout, read: read, kept: sound, overReadIsWhole: word == "original"),
                  shortfall.sentence(called: name) == reason else { continue }
            var out = ["variant:" + CorpusWords.caseName(shortfall), "variant_file:" + word]
            switch shortfall {
            case .packetsNotCounted(let stream), .decodeErrors(let stream), .noPictureFrames(let stream):
                out += ["variant_stream:\(stream)"]
            case .packetCount(let stream, let got, let listed):
                out += ["variant_stream:\(stream)", "variant_read:\(got)", "variant_listed:\(listed)"]
            case .framesNotAllFolded(let muxed, let folded):
                out += ["variant_muxed:\(muxed)", "variant_folded:\(folded)"]
            case .pictureLength(let stream, let decoded, let stated):
                let slack = layout.pictures.first { $0.index == stream }?.timingSlackSeconds
                out += ["variant_stream:\(stream)", "variant_decoded_us:" + micros(decoded), "variant_stated_us:" + micros(stated),
                        "variant_slack_us:" + micros(slack)]
            case .soundLength(let decoded, let stated):
                out += ["variant_decoded:\(decoded)", "variant_stated:" + samples(stated, rate: sound?.sampleRateHz ?? 0),
                        "variant_stated_us:" + micros(stated), "variant_slack_us:" + micros(sound?.statedLengthSlackSeconds)]
            case .noAccount, .noSoundSamples: break
            }
            return out
        }
        // Not the read rule's sentence. One of ffmpeg's own fixed phrases is worth a word of its own: a raw DV
        // tape whose sound is re-anchored back past the packet before it cannot be written as a timeline.
        return ["variant:not_the_read_rule"] + (reason.contains("Non-monotonic DTS") ? ["decode_fault:non_monotonic_dts"] : [])
    }

    /// The `side_data_type` names in a stream's side data (canonical JSON), as words.
    private static func sideDataTypes(_ json: String) -> String {
        guard !json.isEmpty else { return "none" }
        guard let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return "unreadable" }
        let names = list.map { CorpusWords.word(($0["side_data_type"] as? String) ?? "unnamed") }
        return String(names.joined(separator: "+").prefix(24))
    }

    /// EVERY display field the two headers state differently, and the "plays by default" flag.
    static func configuration(_ facts: Proof.Facts, kept: Proof.SoundStream?, copySound: Proof.SoundStream?) -> [String] {
        var out: [String] = []
        if case .success(let pairing) = Proof.pairing(original: facts.original.carried, balanced: facts.balanced.carried) {
            for (n, pair) in pairing.pictures.enumerated() {
                let original = facts.original.carried[pair.original], copy = facts.balanced.carried[pair.balanced]
                for field in original.configuration.displayDifferences(from: copy.configuration) {
                    let name = field.name.replacingOccurrences(of: " ", with: "_")
                    func value(_ text: String) -> String {
                        field.name == "side data" ? sideDataTypes(text) : (text.isEmpty ? "none" : String(CorpusWords.word(text).prefix(12)))
                    }
                    out += ["v\(n)_differs:\(name)", "v\(n)_\(name)_o:" + value(field.original), "v\(n)_\(name)_c:" + value(field.copy)]
                }
                if Proof.switchedOff(original.flags, copy.flags) { out.append("v\(n)_differs:default_flag_lost") }
            }
        }
        if let kept, let copySound {
            if kept.sideData != copySound.sideData {
                out += ["a_differs:side_data", "a_side_data_o:" + sideDataTypes(kept.sideData), "a_side_data_c:" + sideDataTypes(copySound.sideData)]
            }
            if Proof.switchedOff(kept.flags, copySound.flags) { out.append("a_differs:default_flag_lost") }
        }
        return out.isEmpty ? ["differs:nothing_found_again"] : out
    }
}
