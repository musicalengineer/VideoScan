import Testing
import Foundation
@testable import VideoScan

// MARK: - RecoveredExtensionTests
//
// Punch-list #3 — recovered extensionless media files should land on the
// destination volume WITH a correct, OS-openable extension derived from the
// probed container. Two pure surfaces under test (mirrors RelocateScopeTests
// style — hermetic, no disk for the pure pieces):
//
//   - VideoScanModel.canonicalContainerExtension(forProbedContainer:)
//   - VideoScanModel.inferredRecoveryExtension(forDestinationPath:probedContainer:enabled:)
//
// Plus one collision test that proves we REUSE RelocateEngine.runOne's
// existing dest-collision policy rather than inventing a new scheme.

@MainActor
struct RecoveredExtensionTests {

    // MARK: - canonicalContainerExtension: unambiguous maps

    @Test
    func movFamilyShortListMapsToMov() {
        // ffprobe short format_name for QuickTime/MP4 essence.
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "mov,mp4,m4a,3gp,3g2,mj2") == "mov")
    }

    @Test
    func quicktimeLongNameMapsToMov() {
        // The real spot-test case stores format_long_name "QuickTime / MOV".
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "QuickTime / MOV") == "mov")
    }

    @Test
    func matroskaMapsToMkv() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "matroska,webm") == "mkv")
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "Matroska / WebM") == "mkv")
    }

    @Test
    func aviMaps() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "avi") == "avi")
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "AVI (Audio Video Interleaved)") == "avi")
    }

    @Test
    func mpegtsMapsToTsAndBeatsGenericMpeg() {
        // Long name tokenizes to include both "ts" AND "mpeg"; the ts rule
        // must win (priority order) — otherwise an .mpg would be wrong.
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "mpegts") == "ts")
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "MPEG-TS (MPEG-2 Transport Stream)") == "ts")
    }

    @Test
    func mxfShortAndSyntheticMap() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "mxf") == "mxf")
        // The MXF header-fallback path stores e.g. "MXF (D10Video)".
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "MXF (D10Video)") == "mxf")
    }

    @Test
    func asfMapsToWmv() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "asf") == "wmv")
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "ASF (Advanced / Active Streaming Format)") == "wmv")
    }

    @Test
    func flvMaps() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "flv") == "flv")
    }

    @Test
    func mpegProgramStreamMapsToMpg() {
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "mpeg") == "mpg")
        #expect(VideoScanModel.canonicalContainerExtension(
            forProbedContainer: "MPEG-PS (MPEG-2 Program Stream)") == "mpg")
    }

    // MARK: - canonicalContainerExtension: refuse to guess

    @Test
    func unknownOrAmbiguousOrEmptyMapsToNil() {
        #expect(VideoScanModel.canonicalContainerExtension(forProbedContainer: "") == nil)
        #expect(VideoScanModel.canonicalContainerExtension(forProbedContainer: "   ") == nil)
        #expect(VideoScanModel.canonicalContainerExtension(forProbedContainer: "image2") == nil)
        #expect(VideoScanModel.canonicalContainerExtension(forProbedContainer: "nut") == nil)
        #expect(VideoScanModel.canonicalContainerExtension(forProbedContainer: "data") == nil)
    }

    // MARK: - inferredRecoveryExtension: destination-naming decision

    @Test
    func extensionlessSourceWithKnownContainerGetsExtensionAppended() {
        // Real spot-test path shape: no dot anywhere in the leaf.
        let dest = "/Volumes/LaCie/from-iPhoto/Donna-MyGirl-1984-Final"
        let decision = VideoScanModel.inferredRecoveryExtension(
            forDestinationPath: dest,
            probedContainer: "QuickTime / MOV",
            enabled: true)
        #expect(decision == .append(
            newPath: dest + ".mov", fromExt: "", toExt: "mov"))
    }

    @Test
    func extensionedSourceIsLeftUnchanged() {
        let dest = "/Volumes/LaCie/from-X/clip.mov"
        let decision = VideoScanModel.inferredRecoveryExtension(
            forDestinationPath: dest,
            probedContainer: "QuickTime / MOV",
            enabled: true)
        #expect(decision == .unchanged(.alreadyOpenable))
    }

    @Test
    func unknownPseudoExtensionGetsRealExtensionAppended() {
        // Avid junk pseudo-extension "t2-v" is not OS-openable; append .mov.
        let dest = "/Volumes/LaCie/from-X/clip.t2-v"
        let decision = VideoScanModel.inferredRecoveryExtension(
            forDestinationPath: dest,
            probedContainer: "mov,mp4,m4a,3gp,3g2,mj2",
            enabled: true)
        #expect(decision == .append(
            newPath: dest + ".mov", fromExt: "t2-v", toExt: "mov"))
    }

    @Test
    func unknownContainerLeavesExtensionlessSourceUnchanged() {
        let dest = "/Volumes/LaCie/from-X/mystery-file"
        let decision = VideoScanModel.inferredRecoveryExtension(
            forDestinationPath: dest,
            probedContainer: "nut",
            enabled: true)
        #expect(decision == .unchanged(.noConfidentMapping))
    }

    @Test
    func disabledFlagSuppressesRename() {
        let dest = "/Volumes/LaCie/from-X/Donna-MyGirl-1984-Final"
        let decision = VideoScanModel.inferredRecoveryExtension(
            forDestinationPath: dest,
            probedContainer: "QuickTime / MOV",
            enabled: false)
        #expect(decision == .unchanged(.disabled))
    }

    // MARK: - Collision reuse

    @Test
    func appendedPathCollisionReusesExistingEnginePolicy() async throws {
        // Prove the extension-appended destination flows through the SAME
        // collision handling as any other relocate: a pre-existing X.mov at
        // the appended path makes RelocateEngine.runOne return
        // .salvageFailed(.copy) — no special-casing in the new code.
        let tmp = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-recovered-ext-collide-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Source has no extension; decide the destination name.
        let src = tmp.appendingPathComponent("src-no-ext")
        try Data("payload".utf8).write(to: src)
        let baseDest = tmp.appendingPathComponent("Donna-MyGirl-1984-Final").path

        guard case let .append(appendedDest, _, toExt) =
            VideoScanModel.inferredRecoveryExtension(
                forDestinationPath: baseDest,
                probedContainer: "QuickTime / MOV",
                enabled: true)
        else {
            Issue.record("Expected an append decision")
            return
        }
        #expect(toExt == "mov")

        // Squat the appended destination so the copy must collide.
        try Data("squatter".utf8).write(to: URL(fileURLWithPath: appendedDest))

        let job = RelocateJob(recordID: UUID(),
                              sourcePath: src.path,
                              destPath: appendedDest,
                              expectedBytes: Int64("payload".utf8.count),
                              expectedPartialMD5: "")
        let outcome = await RelocateEngine.runOne(job)
        if case .salvageFailed(_, let stage) = outcome {
            #expect(stage == .copy)
            // Squatter untouched — same guarantee as the generic collision test.
            let after = try Data(contentsOf: URL(fileURLWithPath: appendedDest))
            #expect(after == Data("squatter".utf8))
        } else {
            Issue.record("Expected copy-stage salvageFailed on collision, got \(outcome)")
        }
    }
}
