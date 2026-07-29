// PreviewCatalogSourceParityTests.swift
// PARITY: the file-backed catalog source (VideoScanCore, the linchpin of
// the out-of-process design) must yield the SAME eligible sweep work-list
// as the model-backed source for a representative catalog — SAME paths,
// SAME fields. This guards Stage 1: a CLI helper driving the engine from
// catalog.json must see exactly what the in-app model sees.
//
// The eligibility RULE can't drift (both sources call the shared
// previewSweepCandidates mapping); what this pins is the READ path — a
// real CatalogStore.saveNow round-trip (the production persistence) decodes
// back into the same eligible set the live records produce.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("Preview catalog-source parity (file-backed vs model-backed)")
struct PreviewCatalogSourceParityTests {

    private func record(path: String, stream: StreamType,
                        container: String, codec: String,
                        duration: Double, unanalyzable: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.ext = (path as NSString).pathExtension
        r.streamTypeRaw = stream.rawValue
        r.container = container
        r.videoCodec = codec
        r.durationSeconds = duration
        if unanalyzable { r.needsReformat = true }
        return r
    }

    /// Representative mixed catalog: A/V, video-only ffv1 (ffmpegDirect),
    /// audio-only (excluded), ffprobe-failed (excluded), an unanalyzable
    /// legacy-codec record (still video-bearing → included), across two
    /// volumes.
    private func fixtureRecords() -> [VideoRecord] {
        [
            record(path: "/Volumes/LaCie/1998/birthday.mov", stream: .videoAndAudio,
                   container: "QuickTime / MOV", codec: "h264", duration: 612.5),
            record(path: "/Volumes/LaCie/1998/tape-cap.mkv", stream: .videoOnly,
                   container: "Matroska / WebM", codec: "ffv1", duration: 3600),
            record(path: "/Volumes/LaCie/music/song.wav", stream: .audioOnly,
                   container: "WAV", codec: "", duration: 240),
            record(path: "/Volumes/X9/broken.bin", stream: .ffprobeFailed,
                   container: "", codec: "", duration: 0),
            record(path: "/Volumes/X9/old/sorenson.mov", stream: .videoAndAudio,
                   container: "QuickTime / MOV", codec: "svq3", duration: 95, unanalyzable: true),
            record(path: "/Volumes/X9/no-streams.dat", stream: .noStreams,
                   container: "", codec: "", duration: 0),
        ]
    }

    @Test("file-backed and model-backed sources agree on the eligible set (all reachable)")
    func parityAllReachable() async throws {
        let records = fixtureRecords()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Persist through the REAL production path.
        let store = CatalogStore(directory: dir)
        store.saveNow(records: records)

        let reachable: @Sendable (String) -> Bool = { _ in true }
        let fileSource = FileBackedCatalogSource(
            catalogURL: dir.appendingPathComponent("catalog.json"),
            isReachable: reachable)
        // The model-backed snapshot is taken on the main actor (as it is in
        // production, from VideoScanModel.records) and captured as a
        // Sendable value array.
        let expected = previewSweepCandidates(from: records, isReachable: reachable)
        let modelSource = ModelBackedCatalogSource(snapshot: { expected })

        let fileCandidates = await fileSource.eligibleCandidates()
        let modelCandidates = await modelSource.eligibleCandidates()

        // Same eligible set — video-bearing only, both volumes.
        #expect(Set(fileCandidates) == Set(modelCandidates))
        #expect(Set(fileCandidates.map(\.path)) == [
            "/Volumes/LaCie/1998/birthday.mov",
            "/Volumes/LaCie/1998/tape-cap.mkv",
            "/Volumes/X9/old/sorenson.mov",
        ])
        // Field fidelity survived the round-trip (route-affecting fields).
        let sorenson = fileCandidates.first { $0.path.hasSuffix("sorenson.mov") }
        #expect(sorenson?.likelyUnanalyzable == true)
        #expect(sorenson?.videoCodec == "svq3")
    }

    @Test("parity holds under a partial-reachability runtime check")
    func parityPartialReachability() async throws {
        let records = fixtureRecords()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.saveNow(records: records)

        // Only the LaCie volume is mounted right now.
        let reachable: @Sendable (String) -> Bool = { $0.hasPrefix("/Volumes/LaCie/") }
        let fileSource = FileBackedCatalogSource(
            catalogURL: dir.appendingPathComponent("catalog.json"),
            isReachable: reachable)
        let expected = previewSweepCandidates(from: records, isReachable: reachable)
        let modelSource = ModelBackedCatalogSource(snapshot: { expected })

        let fileCandidates = await fileSource.eligibleCandidates()
        let modelCandidates = await modelSource.eligibleCandidates()

        #expect(Set(fileCandidates) == Set(modelCandidates))
        #expect(Set(fileCandidates.map(\.path)) == [
            "/Volumes/LaCie/1998/birthday.mov",
            "/Volumes/LaCie/1998/tape-cap.mkv",
        ])
    }
}
