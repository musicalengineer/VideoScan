import Foundation
import Testing
@testable import VideoScan

// MARK: - Repair… on a raw DV / several-sound-track file (regression 2026-10-28)
//
// Rick's raw DV clip (dvvideo + pcm_s16le, right channel only): the card's
// sound row said "Repair… shows the fix (Balance Audio)", the Repair sheet
// ticked Balance Audio — and Repair Now was greyed out, because the combined
// pass refuses raw DV and Balance was the only fix, so the recipe was empty.
// Repair… is the one repair door: Balance ticked alone must run the
// dedicated Balance Audio job (BalanceAudioJob — the one engine for the
// verb). Synthetic values only; no file is read.

private func rawDVRightOnlyDiagnosis(containerFormat: String = "dv", audioStreams: Int = 1) -> AudioVerifyDiagnosis {
    var shape = AudioBalanceStreamShape(
        videoCodec: "dvvideo", totalStreams: 1 + audioStreams, videoStreams: 1, audioStreams: audioStreams,
        audioCodec: "pcm_s16le", audioChannels: 2, audioBitRate: nil, durationSeconds: 60,
        audioStreamInfos: (0..<audioStreams).map {
            AudioBalanceStreamInfo(absoluteIndex: 1 + $0, codec: "pcm_s16le", channels: 2, bitRate: nil)
        })
    shape.containerFormat = containerFormat
    shape.videoRFrameRate = "30000/1001"
    let analysis = AudioBalanceAnalysis(
        classification: .rightOnly,
        measurements: AudioBalanceMeasurements(
            channels: [AudioChannelLevels(rmsDBFS: -.infinity, peakDBFS: -.infinity),
                       AudioChannelLevels(rmsDBFS: -18, peakDBFS: -6)],
            differenceRMSDBFS: nil),
        shape: shape, programStreamCount: 1, programStreamIndex: 1, droppedStreamIndices: [])
    var vshape = AudioVerifyShape()
    vshape.audioStreams = audioStreams
    vshape.audioCodec = "pcm_s16le"
    vshape.audioChannels = 2
    vshape.containerDurationSeconds = 60
    return AudioVerifyDiagnosis(findings: [.channelImbalance(.rightOnly)], shape: vshape, balanceAnalysis: analysis)
}

private func soundWarningCard() -> MediaReportCard {
    MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1,
                    headline: "One-sided audio.",
                    checks: [MediaCheck(kind: .sound, verdict: .warning, sentence: "one-sided audio (right only)")])
}

private func selection(for diagnosis: AudioVerifyDiagnosis) -> MediaRepairSelection {
    MediaRepairSelection(offers: MediaRepairPlan.allOffers(
        for: soundWarningCard(), sound: MediaRepairSoundFacts(diagnosis: diagnosis),
        hasPicture: true, hasSound: true))
}

@Suite struct MediaRepairDedicatedBalanceTests {

    /// THE regression: raw DV + right-only + a balance measurement →
    /// Balance is ticked and Repair Now runs the dedicated job.
    @Test func rawDV_balanceAlone_routesToTheDedicatedJob() {
        let d = rawDVRightOnlyDiagnosis()
        let sel = selection(for: d)
        #expect(sel.chosen == [.balanceAudio], "the card's sound row earns Balance Audio")
        let balance = MediaRepairBalanceInput(diagnosis: d)
        #expect(balance?.rawDV == true)
        #expect(sel.repairNow(balance: balance, soundFile: nil, pictureReady: false) == .dedicatedBalance)
    }

    /// Same for several sound tracks (the other layout the pass refuses).
    @Test func severalSoundTracks_balanceAlone_routesToTheDedicatedJob() {
        let d = rawDVRightOnlyDiagnosis(containerFormat: "mov,mp4,m4a,3gp,3g2,mj2", audioStreams: 2)
        let sel = selection(for: d)
        #expect(sel.repairNow(balance: MediaRepairBalanceInput(diagnosis: d), soundFile: nil,
                              pictureReady: true) == .dedicatedBalance)
    }

    /// Balance ticked with another fix: no two-job chain. The combined
    /// pass runs the other fix and says why Balance is not in it.
    @Test func rawDV_balanceWithRemux_runsThePass_andSaysWhy() {
        let d = rawDVRightOnlyDiagnosis()
        var sel = selection(for: d)
        sel.set(.remux, on: true)
        guard case .combined(let recipe) = sel.repairNow(balance: MediaRepairBalanceInput(diagnosis: d),
                                                         soundFile: nil, pictureReady: true) else {
            Issue.record("expected the combined pass"); return
        }
        #expect(recipe.applied == [.remux])
        let skip = try? #require(recipe.skipped.first { $0.fix == .balanceAudio })
        #expect(skip?.reason.contains("Balance Audio on its own") == true, "\(skip?.reason ?? "")")
    }

    /// An ordinary single-track QuickTime file still balances in the pass.
    @Test func singleTrackMov_balanceRidesTheCombinedPass() {
        let d = rawDVRightOnlyDiagnosis(containerFormat: "mov,mp4,m4a,3gp,3g2,mj2")
        let sel = selection(for: d)
        guard case .combined(let recipe) = sel.repairNow(balance: MediaRepairBalanceInput(diagnosis: d),
                                                         soundFile: nil, pictureReady: true) else {
            Issue.record("expected the combined pass"); return
        }
        #expect(recipe.applied == [.balanceAudio])
    }

    /// No channel measurement: nothing to run (never the dedicated job).
    @Test func noMeasurement_nothingRuns() {
        let offers = [MediaRepairOffer(fix: .balanceAudio, answers: .sound, unavailableReason: nil)]
        let sel = MediaRepairSelection(offers: offers)
        #expect(sel.repairNow(balance: nil, soundFile: nil, pictureReady: true) == .nothing)
    }

    /// The banner must not call a raw DV balance "a lossless remux".
    @Test func bannerFixLine_namesTheBalance_notARemux() {
        let d = rawDVRightOnlyDiagnosis()
        let recipe = MediaRepairRecipe(fixes: [.balanceAudio], balance: MediaRepairBalanceInput(diagnosis: d))
        let line = MediaRepairAdvice.fixLine(recipe)
        #expect(!line.contains("lossless remux"), "\(line)")
        #expect(line.contains("balances the sound"), "\(line)")
    }

    /// The menu still enables Repair… for this file (via canBalance).
    @Test func menuEnablesRepair() {
        let d = rawDVRightOnlyDiagnosis()
        let state = MediaRepairPlan.menuState(card: soundWarningCard(), fileSizeBytes: 1,
                                              sound: MediaRepairSoundFacts(diagnosis: d),
                                              reachable: true, selectionCount: 1)
        #expect(state == .ready(count: 1))
    }

    /// The dedicated job's own name: raw DV → `<stem>_balanced.mov`.
    @Test func dedicatedOutputName_rawDVIsQuickTime() {
        #expect(MediaRepairOutput.dedicatedBalanceFileName(sourcePath: "/x/clip28.dv", containerFormat: "dv")
                == "clip28_balanced.mov")
    }

    /// A protected original's copy goes to a chosen folder; when that name
    /// is taken at publish, the fallback must stay in the chosen folder —
    /// never beside the (protected) original.
    @Test func publishFallback_staysInThePlannedFolder() {
        let planned = URL(fileURLWithPath: "/Users/x/Movies/clip28_balanced.mov")
        let url = BalanceAudioFix.publishFallbackURL(planned: planned, sourcePath: "/Volumes/Archive/clip28.dv",
                                                     containerFormat: "dv",
                                                     taken: { $0 == planned.path })
        #expect(url.deletingLastPathComponent().path == "/Users/x/Movies")
        #expect(url.lastPathComponent == "clip28_balanced 2.mov")
    }
}

// MARK: - The class invariant: the menu and Repair Now never disagree
//
// Root cause of the raw DV bug: menuState judged runnability from the
// OFFERS, the sheet from the RECIPE, and the two disagreed. For every
// container in the media matrix (plus raw .dv) × every sound finding that
// earns a fix: when the row menu shows Repair… enabled with fixes to run,
// the sheet's default selection must start something — never a ticked fix
// with Repair Now greyed out. Pure: synthetic diagnoses, no files.

@Suite @MainActor struct MediaRepairMenuSheetAgreementTests {

    struct Container { let name, format, videoCodec, ext, soundCodec: String }
    static let containers: [Container] = [
        Container(name: "mp4/h264", format: "mov,mp4,m4a,3gp,3g2,mj2", videoCodec: "h264", ext: "mp4", soundCodec: "aac"),
        Container(name: "mov/prores", format: "mov,mp4,m4a,3gp,3g2,mj2", videoCodec: "prores", ext: "mov", soundCodec: "pcm_s24le"),
        Container(name: "mkv/ffv1+pcm", format: "matroska,webm", videoCodec: "ffv1", ext: "mkv", soundCodec: "pcm_s16le"),
        Container(name: "mxf", format: "mxf", videoCodec: "mpeg2video", ext: "mxf", soundCodec: "pcm_s24le"),
        Container(name: "avi/dv", format: "avi", videoCodec: "dvvideo", ext: "avi", soundCodec: "pcm_s16le"),
        Container(name: "raw .dv", format: "dv", videoCodec: "dvvideo", ext: "dv", soundCodec: "pcm_s16le"),
    ]

    enum Finding: String, CaseIterable { case leftOnly, rightOnly, mono, unsupportedCodec, severalSoundTracks }

    static func diagnosis(_ c: Container, _ f: Finding) -> AudioVerifyDiagnosis {
        let streams = f == .severalSoundTracks ? 2 : 1
        let cls: AudioChannelClass = f == .leftOnly ? .leftOnly : f == .mono ? .mono : .rightOnly
        var shape = AudioBalanceStreamShape(
            videoCodec: c.videoCodec, totalStreams: 1 + streams, videoStreams: 1, audioStreams: streams,
            audioCodec: c.soundCodec, audioChannels: cls == .mono ? 1 : 2, audioBitRate: nil, durationSeconds: 60,
            audioStreamInfos: (0..<streams).map {
                AudioBalanceStreamInfo(absoluteIndex: 1 + $0, codec: c.soundCodec, channels: 2, bitRate: nil)
            })
        shape.containerFormat = c.format
        shape.videoRFrameRate = "30000/1001"
        var vshape = AudioVerifyShape()
        vshape.audioStreams = streams
        vshape.audioCodec = c.soundCodec
        vshape.audioChannels = 2
        vshape.containerDurationSeconds = 60
        if f == .unsupportedCodec {
            return AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "adpcm_ima_qt", decodable: false)],
                                        shape: vshape, balanceAnalysis: nil)
        }
        let analysis = AudioBalanceAnalysis(
            classification: cls,
            measurements: AudioBalanceMeasurements(
                channels: [AudioChannelLevels(rmsDBFS: -18, peakDBFS: -6)],
                differenceRMSDBFS: nil),
            shape: shape, programStreamCount: 1, programStreamIndex: 1, droppedStreamIndices: [])
        return AudioVerifyDiagnosis(findings: [.channelImbalance(cls)], shape: vshape, balanceAnalysis: analysis)
    }

    static func record(_ c: Container, _ f: Finding) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip.\(c.ext)"
        r.fullPath = "/Volumes/Synthetic/clip.\(c.ext)"
        r.directory = "/Volumes/Synthetic"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = 1_000
        let verdict: MediaCheckVerdict = f == .unsupportedCodec ? .problem : .warning
        r.mediaReportCard = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1_000, headline: "",
                                            checks: [MediaCheck(kind: .sound, verdict: verdict, sentence: f.rawValue)])
        return r
    }

    @Test func menuEnabledWithFixes_impliesRepairNowRuns() {
        var red: [String] = []
        var cells = 0
        for c in Self.containers {
            for f in Finding.allCases {
                let d = Self.diagnosis(c, f)
                let rec = Self.record(c, f)
                let menu = MediaRepairPlan.menuState(card: rec.mediaReportCard, fileSizeBytes: rec.sizeBytes,
                                                     sound: MediaRepairSoundFacts(diagnosis: d),
                                                     reachable: true, selectionCount: 1)
                guard case .ready(let n) = menu, n > 0 else { continue }
                cells += 1
                let request = MediaRepairSheetRequest(record: rec, audioDiagnosis: d, onVerify: {})
                let sel = MediaRepairSelection(offers: MediaRepairSheet.offers(for: request, soundSource: nil))
                let now = sel.repairNow(balance: MediaRepairBalanceInput(diagnosis: d), soundFile: nil, pictureReady: false)
                if now == .nothing { red.append("\(c.name) × \(f.rawValue) (ticked \(sel.chosen.map(\.rawValue).sorted()))") }
            }
        }
        #expect(cells == Self.containers.count * Finding.allCases.count, "every cell earns a fix (got \(cells))")
        #expect(red.isEmpty, "Repair… enabled but Repair Now dead: \(red.joined(separator: "; "))")
    }
}
