// PromoteSoundGateSensorTests.swift
// SENSOR dimension for the Promote sound gate (Rick 2026-11-10). Source
// scans that pin the SHAPE the gate's safety depends on, so a later edit
// that moves, bypasses or weakens it goes red in the pre-merge lane:
//
//   1. one call of the gate, reached from `copyOrAdopt`, after the source-digest proof
//      and before the destination is chosen or the journal intent written
//      (refuse before mutating);
//   2. the rule never reads a header field — not the stream type, not the
//      channel count, not a codec name (DECISIONS 2026-10-16: a header never
//      says "has sound");
//   3. no production file assigns the job's `soundMeasure` test seam;
//   4. the gate reads nothing stored about sound and stores nothing (2b, 4);
//   5. the only ungated catalog links are the two recovery adoptions;
//   6. the words on the sheet are true.
//
// Plus one end-to-end behaviour sensor (canned measurements, real job).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Promote sound gate — sensors")
@MainActor
struct PromoteSoundGateSensorTests {

    typealias H = PromoteIntegrityHarness
    typealias S = MasterArchiveTestSupport

    static var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    static func source(_ rel: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(rel), encoding: .utf8)
    }

    /// The file's code: comment-only lines dropped.
    static func code(_ text: String) -> [Substring] {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Every app source file: (path relative to the app folder, code lines).
    static func appFiles() throws -> [(rel: String, code: [Substring])] {
        var out: [(String, [Substring])] = []
        let base = appRoot
        let it = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = it?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            out.append((String(path.dropFirst(base.path.count + 1)), code(try String(contentsOf: url, encoding: .utf8))))
        }
        return out
    }

    @Test("1 — the gate is called once, in copyOrAdopt, after the proof and before the first archive write")
    func oneCallBeforeTheFirstWrite() throws {
        var callers: [String] = []
        for file in try Self.appFiles() {
            for line in file.code where line.contains("soundGate(") && !line.contains("func soundGate(") {
                callers.append(file.rel)
            }
        }
        #expect(callers == ["Archive/PromoteToArchiveJob+Guards.swift"], "the gate has exactly one call site: \(callers)")

        // The gate runs inside `provenBytesGuards`: digest proof, then the sound gate.
        let guards = try Self.source("Archive/PromoteToArchiveJob+Guards.swift")
        let gStart = try #require(guards.range(of: "func provenBytesGuards("))
        let gEnd = try #require(guards.range(of: "\n    }\n", range: gStart.upperBound..<guards.endIndex))
        let guardBody = String(guards[gStart.upperBound..<gEnd.lowerBound])
        let proof = try #require(guardBody.range(of: "proveSourceDigest("), "the proof left provenBytesGuards").lowerBound
        let gate = try #require(guardBody.range(of: "try await soundGate("), "the gate left provenBytesGuards").lowerBound
        #expect(proof < gate, "the gate judges PROVEN bytes")
        #expect(guardBody.contains("if let refusal = sound.refusal { return .refused(refusal) }"), "a refusal is returned")

        // copyOrAdopt calls that step after the duplicate claim and before every write.
        let steps = try Self.source("Archive/PromoteToArchiveJob+Steps.swift")
        let start = try #require(steps.range(of: "private func copyOrAdopt("))
        let end = try #require(steps.range(of: "\n    }\n", range: start.upperBound..<steps.endIndex))
        let body = String(steps[start.upperBound..<end.lowerBound])
        func at(_ needle: String) throws -> String.Index {
            try #require(body.range(of: needle), "copyOrAdopt no longer contains \(needle)").lowerBound
        }
        let step = try at("try await provenBytesGuards(")
        let refusedReturn = try at("case .refused(let refusal): return .refused(refusal)")
        #expect(try at("claimSourceDigest(") < step, "the duplicate claim comes first")
        #expect(step < refusedReturn, "a refusal returns at once")
        for write in ["chooseDestinationOffMain(", "claimedNames.insert(", "ArchivePromoteJournal.append(",
                      "ArchivePromoteJournal.appendRetractable(", "copyRollingBackOnChange(", "finishPublished("] {
            #expect(refusedReturn < (try at(write)), "the guards come before \(write)")
        }
        var guardCallers: [String] = []
        for file in try Self.appFiles() {
            for line in file.code where line.contains("provenBytesGuards(") && !line.contains("func provenBytesGuards(") {
                guardCallers.append(file.rel)
            }
        }
        #expect(guardCallers == ["Archive/PromoteToArchiveJob+Steps.swift"], "\(guardCallers)")
    }

    @Test("2 — the rule never reads a header field: no stream type, channel count or codec name in PromoteSoundGate")
    func theRuleReadsNoHeader() throws {
        let code = Self.code(try Self.source("Archive/PromoteSoundGate.swift")).joined(separator: "\n")
        for header in ["streamType", "audioChannels", "audioCodec", "audioSampleRate", "isPlayable", "videoCodec",
                       "VideoRecord", "mediaReportCard"] {
            #expect(!code.contains(header), "PromoteSoundGate must not read \(header) — a header never says 'has sound'")
        }
        #expect(code.contains("AudioBalanceClassifier.programFloorDBFS"), "one silence line, the app's")
        #expect(code.contains("analysis.measuredSilent"), "one silence test, shared with Check Media")
        let probe = try Self.source("Media/AudioBalanceProbe.swift")
        let ms = try #require(probe.range(of: "var measuredSilent: Bool? {"))
        let msEnd = try #require(probe.range(of: "\n    }\n", range: ms.upperBound..<probe.endIndex))
        let msBody = String(probe[ms.upperBound..<msEnd.lowerBound])
        #expect(msBody.contains("levelsComplete") && msBody.contains("allSatisfy(\\.rmsMeasured)")
                && msBody.contains("AudioBalanceClassifier.carriesProgram"), "complete, every channel read, the classifier's comparison")
        #expect(!code.contains("-60"), "no second copy of the threshold")
        // And the guard hands it nothing header-shaped to pass on.
        let guards = try Self.source("Archive/PromoteToArchiveJob+Guards.swift")
        let start = try #require(guards.range(of: "func soundGate("))
        let end = try #require(guards.range(of: "nonisolated static func stampOffMain", range: start.upperBound..<guards.endIndex))
        let gateCode = Self.code(String(guards[start.upperBound..<end.lowerBound])).joined(separator: "\n")
        for header in ["streamType", "audioChannels", "audioCodec", "mediaReportCard", "soundMeasuredSilent"] {
            #expect(!gateCode.contains(header), "the sound gate's guard must not read \(header)")
        }
    }

    @Test("2b — the gate reads NOTHING stored about sound (no media_checks verdict, no report card) and writes nothing: the owner's tag is its only stored input")
    func theGateReadsNoStoredVerdict() throws {
        let rule = Self.code(try Self.source("Archive/PromoteSoundGate.swift")).joined(separator: "\n")
        let guards = try Self.source("Archive/PromoteToArchiveJob+Guards.swift")
        let start = try #require(guards.range(of: "func soundGate("))
        let end = try #require(guards.range(of: "nonisolated static func stampOffMain", range: start.upperBound..<guards.endIndex))
        let gate = Self.code(String(guards[start.upperBound..<end.lowerBound])).joined(separator: "\n")
        for stored in ["audioVerifyStatus", "audioVerifyNote", "audioVerifyDate", "mediaReportCard", "media_checks",
                       "storedPass", "VerifyAudioJob.write", "saveCatalog", "verifyDiagnosis(", "audioFingerprint"] {
            #expect(!rule.contains(stored), "PromoteSoundGate must not use \(stored)")
            #expect(!gate.contains(stored), "the sound gate's guard must not use \(stored)")
        }
        #expect(gate.contains("current.tags"), "the owner's tag is the one stored input")
    }

    @Test("3 — no production file assigns the measurement seam: it is `.live` everywhere outside tests")
    func theSeamIsNeverAssignedInProduction() throws {
        var uses: [String] = []
        for file in try Self.appFiles() {
            for line in file.code where line.range(of: #"\bsoundMeasure\b"#, options: .regularExpression) != nil {
                uses.append("\(file.rel): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(uses.sorted() == [
            "Archive/PromoteToArchiveJob+Guards.swift: diagnosis = try await soundMeasure.diagnose(path)",
            "Archive/PromoteToArchiveJob.swift: var soundMeasure: PromoteSoundGate.Measure = .live",
        ], "soundMeasure is declared once (= .live) and used once: \(uses)")
        // The two test hooks around the guards are declared and called, never assigned.
        for file in try Self.appFiles() {
            for line in file.code where line.contains("testHookBeforeSoundCheck =") || line.contains("testHookAfterSourceProof =") {
                Issue.record("a production file assigns a Promote test hook: \(file.rel): \(line)")
            }
        }
        let gate = Self.code(try Self.source("Archive/PromoteSoundGate.swift")).joined(separator: "\n")
        #expect(gate.contains("static let live = Measure { try await VerifyAudioProbe.diagnose(path: $0) }"),
                "the live measurement is Verify Audio's probe — no second measurement engine")
    }

    @Test("4 — the persisted sound verdict has ONE writer, and Promote is not one of its callers")
    func oneVerdictWriter() throws {
        var writers: Set<String> = []
        var callers: Set<String> = []
        for file in try Self.appFiles() {
            for line in file.code {
                // A write of the verdict: an assignment whose right side is not
                // simply another value's same field (a snapshot or a copy).
                if let assign = line.range(of: ".audioVerifyStatus = "),
                   !line[assign.upperBound...].contains("audioVerifyStatus") {
                    writers.insert(file.rel)
                }
                if line.contains("VerifyAudioJob.write(") { callers.insert(file.rel) }
            }
        }
        #expect(writers == ["MediaOps/VerifyAudioJob.swift"], "one writer of the audio verdict: \(writers.sorted())")
        #expect(callers == ["MediaOps/CheckMedia/CheckMediaJob.swift"],
                "VerifyAudioJob.write is called from Check Media only — never from Promote: \(callers.sorted())")
    }

    @Test("5 — a catalog link to an archive copy is made in one place, reached by the gated copy and the two recovery adoptions only")
    func onlyRecoveryIsUngated() throws {
        var linkers: [String] = []
        var publishers: [String] = []
        for file in try Self.appFiles() {
            for line in file.code {
                if line.contains("registerPromotedCopy(") && !line.contains("func registerPromotedCopy(") { linkers.append(file.rel) }
                if line.contains("finishPublished(") && !line.contains("func finishPublished(") { publishers.append(file.rel) }
            }
        }
        #expect(Set(linkers) == ["Archive/PromoteToArchiveJob+Steps.swift"], "\(linkers)")
        #expect(publishers == Array(repeating: "Archive/PromoteToArchiveJob+Steps.swift", count: 3),
                "finishPublished has three callers — reconcileJournal, adoptFromManifest (both recovery: the bytes were published by an earlier run) and copyOrAdopt (gated): \(publishers)")
    }

    @Test("6 — TRUTH: the sheet and the readiness lines no longer say un-probeable is the only stop, or 'run Verify Audio first'")
    func theWordsAreTrue() throws {
        let sheet = try Self.source("Archive/PromoteToArchiveSheet+Readiness.swift")
        #expect(!sheet.contains("the only thing that stops a promotion"))
        let readiness = try Self.source("Archive/ArchiveReadiness.swift")
        #expect(!readiness.contains("run Verify Audio first"), "Promote checks the sound itself now")
        #expect(!readiness.contains("pair its audio before or after promoting"), "after is no longer possible")
        var i = ArchiveReadiness.Inputs()
        i.streamTypeRaw = StreamType.videoAndAudio.rawValue; i.isPlayable = "Yes"; i.videoCodec = "h264"; i.audioCodec = "aac"
        #expect(ArchiveReadiness.assess(i).warnings.first == "Sound not checked yet — Promote checks it before copying (missing, silent or damaged sound is refused)")
        i.streamTypeRaw = StreamType.videoOnly.rawValue
        #expect(ArchiveReadiness.assess(i).warnings.first?.contains("tagged “Silent — checked”") == true)
    }

    @Test("7 — END TO END: 12 mixed sources promoted in three batches → the archive holds exactly the sound-bearing and the tagged ones")
    func endToEnd() async throws {
        let (sb, model) = try H.setup("sg_sensor"); defer { sb.cleanup() }
        enum Kind: CaseIterable { case stereo, left, silent, silentTagged, none, noneTagged, damaged, damagedTagged, unchecked, mono, surroundSilent, surroundLive }
        var recs: [(kind: Kind, rec: VideoRecord)] = []
        var answers: [String: Result<AudioVerifyDiagnosis, AudioVerifyProbeError>] = [:]
        for (i, kind) in Kind.allCases.enumerated() {
            let name = "test_e2e_\(i).mov"
            let rec = try H.source(sb, model, name: name, seed: UInt64(800 + i))
            switch kind {
            case .stereo: answers[name] = .success(S.soundDiagnosis(channels: [-18, -20]))
            case .left: answers[name] = .success(S.soundDiagnosis(channels: [-18, -.infinity]))
            case .mono: answers[name] = .success(S.soundDiagnosis(channels: [-25]))
            case .surroundLive: answers[name] = .success(S.soundDiagnosis(channels: [-70, -70, -22, -70, -70, -70]))
            case .surroundSilent: answers[name] = .success(S.soundDiagnosis(channels: [-70, -70, -72, -70, -70, -70]))
            case .silent, .silentTagged: answers[name] = .success(S.soundDiagnosis(channels: [-68, -68]))
            case .none, .noneTagged: answers[name] = .success(S.soundDiagnosis(channels: [], audioStreams: 0))
            case .damaged, .damagedTagged:
                answers[name] = .success(S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: false)]))
            case .unchecked: answers[name] = .failure(.probeFailed("ffprobe exited with status 1"))
            }
            if [.silentTagged, .noneTagged, .damagedTagged].contains(kind) { rec.tags = [WorkflowTags.silentChecked] }
            recs.append((kind, rec))
        }
        let table = answers
        let measure = PromoteSoundGate.Measure { path in
            try table[(path as NSString).lastPathComponent, default: .failure(.probeFailed("unknown"))].get()
        }
        let ids = recs.map(\.rec.id)
        for batch in [Array(ids[0..<5]), Array(ids[3..<9]), ids] {     // overlapping, so refused files are offered again
            let job = try H.job(model, ids: batch)
            job.soundMeasure = measure
            job.start(); await job.task?.value; await job.completionTask?.value
        }
        let shouldLand: Set<Kind> = [.stereo, .left, .mono, .surroundLive, .silentTagged, .noneTagged]
        for (kind, rec) in recs {
            #expect((model.masterArchiveCopy(of: rec) != nil) == shouldLand.contains(kind), "\(kind)")
        }
        #expect(S.archivedFiles(sb).count == shouldLand.count, "\(S.archivedFiles(sb))")
        #expect(S.manifestRows(sb).count == shouldLand.count)
        #expect(H.partials(sb).isEmpty)
    }
}
