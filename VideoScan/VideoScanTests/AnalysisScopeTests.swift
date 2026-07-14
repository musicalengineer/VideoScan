import Foundation
import Testing
@testable import VideoScan

// MARK: - Analysis Scope tests (2026-07-14)
//
// The scope gate decides which catalog records Analyze spends GPU time
// on, from METADATA ONLY (streamTypeRaw + filename extension — zero
// disk I/O). Motivating incidents pinned here:
//   - 81,213 of 91,784 "remaining" files were music-archive audio
//     (aif/caf/wav) — audio-only must be OUT by default, reversibly.
//   - mp3s with embedded cover art and Canon .CR3 raws probe as having
//     a video stream, snuck into frame extraction, and burned ~3.1 h
//     of a nightly batch across 1,097 doomed attempts. Extension
//     classification must beat stream-type classification.
//   - Extensionless recovered Avid essence must STAY eligible.
//
// Dimensions covered per the feature-test checklist:
//   Logic (classification + includes + filters), Scale (100k records
//   with a time budget — the gate iterates `records`), Isolation
//   (persistence round-trips through an injected suite, never
//   standard), Sensor (the cover-art mp3 / CR3 / extensionless pins).
// Media matrix: N/A — the gate never opens files by design.

@MainActor
private func scopeRecord(
    filename: String,
    streamTypeRaw: String,
    fullPath: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.fullPath = fullPath ?? "/Volumes/T/\(filename)"
    r.streamTypeRaw = streamTypeRaw
    r.durationSeconds = 3.0
    r.lifecycleStage = .cataloged
    return r
}

@MainActor
@Suite("AnalysisScope classification")
struct AnalysisScopeClassificationTests {

    @Test("sensor: mp3 with cover-art video stream classifies as audio, not analyzable")
    func coverArtMp3IsAudio() {
        // The exact failure signature of the 2026-07-14 nightly waste:
        // ffprobe reports Video+Audio because of the embedded JPEG.
        let c = AnalysisScope.classify(
            streamTypeRaw: StreamType.videoAndAudio.rawValue,
            filename: "Highway Star.mp3")
        #expect(c == .audio(ext: "mp3"))
    }

    @Test("sensor: camera raw (CR3) classifies as photo even with a video stream type")
    func cr3IsPhoto() {
        let c = AnalysisScope.classify(
            streamTypeRaw: StreamType.videoOnly.rawValue,
            filename: "IMG_0042.CR3")
        #expect(c == .photo)
    }

    @Test("sensor: extensionless recovered Avid essence stays analyzable")
    func extensionlessStaysAnalyzable() {
        // Recovered Avid video-only essence is often extensionless and
        // may even fail ffprobe — exactly the files this app exists to
        // rescue. They must never be scoped out.
        #expect(AnalysisScope.classify(streamTypeRaw: StreamType.ffprobeFailed.rawValue,
                                       filename: "V1234567.MXF_ORPHAN") == .analyzable)
        #expect(AnalysisScope.classify(streamTypeRaw: "",
                                       filename: "recovered_essence") == .analyzable)
    }

    @Test("stream-type 'Audio only' classifies audio regardless of extension")
    func audioOnlyStreamIsAudio() {
        #expect(AnalysisScope.classify(streamTypeRaw: StreamType.audioOnly.rawValue,
                                       filename: "weird.mov") == .audio(ext: "mov"))
    }

    @Test("ordinary video files classify analyzable")
    func videoIsAnalyzable() {
        for name in ["clip.mp4", "master.MOV", "orphan.mxf", "tape.avi", "family.mkv"] {
            #expect(AnalysisScope.classify(streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                           filename: name) == .analyzable,
                    "expected \(name) analyzable")
        }
    }

    @Test("default scope: audio out, photos out, analyzable in")
    func defaultScopeGate() {
        let scope = AnalysisScope()
        #expect(scope.includeAudioOnly == false, "audio-only must default OFF")
        #expect(!scope.includes(streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                filename: "song.aif"))
        #expect(!scope.includes(streamTypeRaw: StreamType.videoOnly.rawValue,
                                filename: "photo.cr3"))
        #expect(scope.includes(streamTypeRaw: StreamType.videoAndAudio.rawValue,
                               filename: "clip.mp4"))
        #expect(scope.includes(streamTypeRaw: "", filename: "recovered_essence"))
    }

    @Test("audio toggle ON includes audio except per-extension opt-outs")
    func audioToggleAndOptOuts() {
        var scope = AnalysisScope()
        scope.includeAudioOnly = true
        #expect(scope.includes(streamTypeRaw: StreamType.audioOnly.rawValue,
                               filename: "voice memo.wav"))
        scope.excludedAudioExtensions = ["wav"]
        #expect(!scope.includes(streamTypeRaw: StreamType.audioOnly.rawValue,
                                filename: "voice memo.wav"))
        #expect(scope.includes(streamTypeRaw: StreamType.audioOnly.rawValue,
                               filename: "interview.aif"))
        // Photos stay out no matter what the audio toggle says.
        #expect(!scope.includes(streamTypeRaw: StreamType.videoOnly.rawValue,
                                filename: "scan.tiff"))
    }
}

@MainActor
@Suite("AnalysisScope candidate filters")
struct AnalysisScopeFilterTests {

    @Test("pfAnalysisScopeCandidates keeps analyzable, drops audio + photos by default")
    func filterAndTally() {
        let recs = [
            scopeRecord(filename: "clip.mp4", streamTypeRaw: StreamType.videoAndAudio.rawValue),
            scopeRecord(filename: "song.mp3", streamTypeRaw: StreamType.videoAndAudio.rawValue),
            scopeRecord(filename: "take.caf", streamTypeRaw: StreamType.audioOnly.rawValue),
            scopeRecord(filename: "IMG_1.cr3", streamTypeRaw: StreamType.videoOnly.rawValue),
            scopeRecord(filename: "recovered_essence", streamTypeRaw: ""),
        ]
        let scope = AnalysisScope()
        let kept = pfAnalysisScopeCandidates(recs, scope: scope)
        #expect(kept.map(\.filename) == ["clip.mp4", "recovered_essence"])
        let tally = pfAnalysisScopeExclusionTally(recs, scope: scope)
        #expect(tally.audio == 2)
        #expect(tally.photos == 1)
    }

    @Test("scale sensor: 100k-record scope pass stays inside the time budget")
    func scaleHundredThousand() {
        // The gate iterates `records` → per the feature-test checklist
        // it needs a 100k synthetic pass with an explicit budget. Real
        // catalog is ~103k records; the gate runs at candidate-filter
        // time (not per render), so a generous 2 s budget still pins
        // "this can never become an accidental O(n²) or per-record
        // disk probe."
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        let exts = ["mp4", "mp3", "wav", "cr3", "", "mov", "aif", "mxf"]
        for i in 0..<100_000 {
            let ext = exts[i % exts.count]
            let name = ext.isEmpty ? "file\(i)" : "file\(i).\(ext)"
            recs.append(scopeRecord(filename: name,
                                    streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                    fullPath: "/Volumes/Big/\(name)"))
        }
        let scope = AnalysisScope()
        let clock = ContinuousClock()
        var keptCount = 0
        var tally = (audio: 0, photos: 0)
        let elapsed = clock.measure {
            keptCount = pfAnalysisScopeCandidates(recs, scope: scope).count
            tally = pfAnalysisScopeExclusionTally(recs, scope: scope)
        }
        // 8-way extension cycle: mp4 / "" / mov / mxf analyzable (4),
        // mp3 / wav / aif audio (3), cr3 photo (1).
        #expect(keptCount == 50_000)
        #expect(tally.audio == 37_500)
        #expect(tally.photos == 12_500)
        #expect(elapsed < .seconds(2),
                "100k scope pass took \(elapsed) — budget 2s")
    }

    @Test("scale sensor: 100k-record CatalogCoverage stays inside the time budget")
    func coverageScaleHundredThousand() {
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = scopeRecord(
                filename: i % 4 == 0 ? "a\(i).wav" : "v\(i).mp4",
                streamTypeRaw: StreamType.videoAndAudio.rawValue,
                fullPath: "/Volumes/Big/f\(i)")
            if i % 10 == 0 { r.dossierProcessedAt = Date() }
            recs.append(r)
        }
        let clock = ContinuousClock()
        var cov = CatalogCoverage.empty
        let elapsed = clock.measure {
            cov = CatalogCoverage(records: recs, scope: AnalysisScope())
        }
        #expect(cov.total == 100_000)
        #expect(cov.eligible == 75_000, "audio quarter must be out of eligible")
        #expect(cov.outOfScopeCount == 25_000)
        #expect(elapsed < .seconds(2),
                "100k coverage pass took \(elapsed) — budget 2s")
    }
}

@MainActor
@Suite("AnalysisScope persistence")
struct AnalysisScopePersistenceTests {

    @Test("save/restore round-trips through an injected suite")
    func roundTrip() throws {
        let suiteName = "vs-test-scope-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var scope = AnalysisScope()
        scope.includeAudioOnly = true
        scope.excludedAudioExtensions = ["CAF", "wav"]   // mixed case in
        scope.save(to: defaults)

        let restored = AnalysisScope.restored(from: defaults)
        #expect(restored.includeAudioOnly == true)
        #expect(restored.excludedAudioExtensions == ["caf", "wav"],
                "extensions must normalize to lowercase")
    }

    @Test("fresh defaults restore the built-in defaults (audio OFF)")
    func freshDefaults() throws {
        let suiteName = "vs-test-scope-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restored = AnalysisScope.restored(from: defaults)
        #expect(restored == AnalysisScope())
    }
}

// MARK: - Coverage skip-reason tallies

@MainActor
@Suite("CatalogCoverage skip-reason tallies")
struct CatalogCoverageTallyTests {

    @Test("each exclusion reason lands in its own tally")
    func perReasonTallies() {
        let eligibleDone = scopeRecord(filename: "done.mp4",
                                       streamTypeRaw: StreamType.videoAndAudio.rawValue)
        eligibleDone.dossierProcessedAt = Date()
        let eligibleTodo = scopeRecord(filename: "todo.mov",
                                       streamTypeRaw: StreamType.videoAndAudio.rawValue)
        let extensionless = scopeRecord(filename: "recovered_essence",
                                        streamTypeRaw: StreamType.ffprobeFailed.rawValue)
        let audio = scopeRecord(filename: "song.mp3",
                                streamTypeRaw: StreamType.videoAndAudio.rawValue)
        let photo = scopeRecord(filename: "scan.cr3",
                                streamTypeRaw: StreamType.videoOnly.rawValue)
        let drm = scopeRecord(filename: "movie.m4v",
                              streamTypeRaw: StreamType.videoAndAudio.rawValue)
        drm.drmProtected = true
        let archived = scopeRecord(filename: "old.mp4",
                                   streamTypeRaw: StreamType.videoAndAudio.rawValue)
        archived.lifecycleStage = .archived
        let junk = scopeRecord(filename: "junk.mp4",
                               streamTypeRaw: StreamType.videoAndAudio.rawValue)
        junk.mediaDisposition = .confirmedJunk

        let cov = CatalogCoverage(records: [eligibleDone, eligibleTodo, extensionless,
                                            audio, photo, drm, archived, junk])
        #expect(cov.eligible == 3, "done + todo + extensionless")
        #expect(cov.dossiered == 1)
        #expect(cov.remaining == 2)
        #expect(cov.outOfScopeCount == 1)
        #expect(cov.photoCount == 1)
        #expect(cov.drmCount == 1)
        #expect(cov.archivedCount == 1)
        #expect(cov.junkCount == 1)
        #expect(cov.total == 7, "junk stays out of total (pre-existing rule)")
    }

    @Test("audio toggle ON moves set-aside audio into eligible")
    func scopeOnMovesAudioIntoEligible() {
        let audio = scopeRecord(filename: "take.wav",
                                streamTypeRaw: StreamType.audioOnly.rawValue)
        var scope = AnalysisScope()
        let offCov = CatalogCoverage(records: [audio], scope: scope)
        #expect(offCov.eligible == 0)
        #expect(offCov.outOfScopeCount == 1)

        scope.includeAudioOnly = true
        let onCov = CatalogCoverage(records: [audio], scope: scope)
        #expect(onCov.eligible == 1)
        #expect(onCov.outOfScopeCount == 0)
    }
}
