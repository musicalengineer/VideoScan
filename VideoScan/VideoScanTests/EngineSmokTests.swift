import Testing
import Foundation
import Vision
import AVFoundation
import CoreImage
@testable import VideoScan

// MARK: - Engine Smoke Tests
//
// Integration tests that exercise the real Vision, ArcFace, and ffprobe
// pipelines against actual media fixtures (rick_face_3s.mp4 and
// rick_reference.jpg). These prove our app code touches the frameworks
// correctly — they do NOT test the frameworks themselves.
//
// Fixtures live in tests/fixtures/videos/ and tests/fixtures/photos/.
// The face video is 86 KB H.264 640x360, 3 seconds, with one detectable
// face at ~0.87 confidence. The reference photo is 45 KB JPEG extracted
// from the same source.

@Suite("Engine Smoke Tests")
struct EngineSmokTests {

    nonisolated static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.path
    }()

    static let faceVideoPath = fixturesDir + "/tests/fixtures/videos/test_face_3s.mp4"
    static let guitarVideoPath = fixturesDir + "/tests/fixtures/videos/test_guitar_3s.mp4"
    static let referencePhotoPath = fixturesDir + "/tests/fixtures/photos/rick_reference.jpg"

    // MARK: - Vision face detection on real video frames

    @Test(.disabled(if: isCI, "AVFoundation frame decoding unavailable on virtualized CI runner"))
    func visionDetectsFaceInVideoFrame() async throws {
        let url = URL(fileURLWithPath: Self.faceVideoPath)
        guard FileManager.default.fileExists(atPath: Self.faceVideoPath) else { return }

        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first,
                                 "Video should have a video track")

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        #expect(reader.startReading(), "AVAssetReader should start")

        var facesFound = 0
        var framesRead = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            framesRead += 1
            let faces = pfDetectFacesInBuffer(buffer, orientation: .up)
            facesFound += faces.count
            if framesRead >= 30 { break }
        }
        reader.cancelReading()

        #expect(framesRead > 0, "Should have read at least one frame")
        #expect(facesFound > 0, "Vision should detect at least one face in rick_face_3s.mp4")
    }

    @Test(.disabled(if: isCI, "AVFoundation frame decoding unavailable on virtualized CI runner"))
    func visionDetectsNoFaceInGuitarVideo() async throws {
        let url = URL(fileURLWithPath: Self.guitarVideoPath)
        guard FileManager.default.fileExists(atPath: Self.guitarVideoPath) else { return }

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }

        var facesFound = 0
        var framesRead = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            framesRead += 1
            let faces = pfDetectFacesInBuffer(buffer, orientation: .up)
            facesFound += faces.count
            if framesRead >= 30 { break }
        }
        reader.cancelReading()

        #expect(framesRead > 0, "Should have read at least one frame")
        #expect(facesFound == 0, "Guitar video has no visible face — Vision should detect 0 faces")
    }

    // MARK: - Reference photo loading (Vision pipeline)

    @Test func loadReferencePhotoDetectsFace() {
        guard FileManager.default.fileExists(atPath: Self.referencePhotoPath) else { return }

        let (faces, failures, error) = pfLoadReferencePhotos(
            from: Self.referencePhotoPath, largestFaceOnly: true
        )

        #expect(error == nil, "Should load without error: \(error ?? "")")
        #expect(failures.isEmpty, "Should have no failures: \(failures.map(\.reason))")
        #expect(faces.count == 1, "Should detect exactly one face in reference photo")

        if let face = faces.first {
            #expect(face.confidence >= 0.5, "Face confidence should be >= 0.5, got \(face.confidence)")
            #expect(face.thumbnail != nil, "Should produce a face thumbnail")
            #expect(face.featurePrint != nil, "Should produce a Vision feature print")
        }
    }

    @Test func loadReferenceFromDirectoryFindsPhoto() throws {
        let dir = (Self.referencePhotoPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: dir) else { return }

        let (faces, _, error) = pfLoadReferencePhotos(from: dir, largestFaceOnly: true)
        #expect(error == nil, "Directory load should succeed")
        #expect(!faces.isEmpty, "Should find at least one face in photos directory")
    }

    // MARK: - Feature print matching (Vision face comparison)

    @Test(.disabled(if: isCI, "AVFoundation frame decoding unavailable on virtualized CI runner"))
    func featurePrintMatchesSamePerson() async throws {
        guard FileManager.default.fileExists(atPath: Self.faceVideoPath),
              FileManager.default.fileExists(atPath: Self.referencePhotoPath) else { return }

        let (refFaces, _, _) = pfLoadReferencePhotos(
            from: Self.referencePhotoPath, largestFaceOnly: true
        )
        let refPrint = try #require(refFaces.first?.featurePrint,
                                    "Need a reference feature print")

        let url = URL(fileURLWithPath: Self.faceVideoPath)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }

        var bestDistance: Float = .greatestFiniteMagnitude
        var framesWithFace = 0
        var framesChecked = 0

        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            framesChecked += 1

            let ciImage = CIImage(cvPixelBuffer: buffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { continue }

            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([req])

            for obs in (req.results ?? []) where obs.confidence >= 0.5 {
                guard let cropped = pfNormalizeFaceCrop(from: cgImage, observation: obs) else { continue }
                let fpReq = VNGenerateImageFeaturePrintRequest()
                let fpHandler = VNImageRequestHandler(cgImage: cropped, options: [:])
                try? fpHandler.perform([fpReq])
                guard let fp = fpReq.results?.first as? VNFeaturePrintObservation else { continue }

                var distance: Float = 0
                try fp.computeDistance(&distance, to: refPrint)
                framesWithFace += 1
                if distance < bestDistance { bestDistance = distance }
            }

            if framesChecked >= 30 { break }
        }
        reader.cancelReading()

        #expect(framesWithFace > 0, "Should find faces in video frames to compare")
        #expect(bestDistance < 0.7,
                "Same person should match within 0.7 distance, got \(bestDistance)")
    }

    // MARK: - ffprobe integration with real media

    @MainActor
    @Test func ffprobeRealVideoWithFace() async throws {
        guard FileManager.default.fileExists(atPath: Self.faceVideoPath) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: Self.faceVideoPath)
        let (output, stderr) = await model.runFFProbe(url: url)
        let probe = try #require(output, "ffprobe should parse rick_face_3s.mp4: \(stderr)")

        let rec = VideoRecord()
        ScanEngine.extractMetadata(probe: probe, into: rec)
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.videoCodec == "h264")
        #expect(rec.resolution == "640x360")
        #expect(rec.durationSeconds > 2.0 && rec.durationSeconds < 4.0)
        #expect(!rec.audioCodec.isEmpty)
    }

    @MainActor
    @Test func probeFilePipelineRealVideo() async {
        guard FileManager.default.fileExists(atPath: Self.faceVideoPath) else { return }

        let model = VideoScanModel()
        let url = URL(fileURLWithPath: Self.faceVideoPath)
        let rec = await model.probeFile(url: url)
        #expect(rec.filename == "test_face_3s.mp4")
        #expect(rec.ext == "MP4")
        #expect(rec.streamType == .videoAndAudio)
        #expect(rec.sizeBytes > 0)
        #expect(!rec.partialMD5.isEmpty)
    }

    // MARK: - ArcFace on real face image (skip-gated on model presence)

    @Test func arcfaceProducesEmbeddingFromRealFace() async throws {
        let (model, _) = await ArcFaceModelLoader.shared.getModel()
        guard let model else { return }
        guard FileManager.default.fileExists(atPath: Self.referencePhotoPath) else { return }

        guard let src = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: Self.referencePhotoPath) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            Issue.record("Could not load reference photo as CGImage")
            return
        }

        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try handler.perform([req])
        let obs = try #require(req.results?.first, "Should detect a face in reference photo")

        guard let cropped = pfNormalizeFaceCrop(from: img, observation: obs, outputSize: 112) else {
            Issue.record("Face crop failed")
            return
        }

        let embedding = arcfaceEmbedding(from: cropped, model: model)
        let emb = try #require(embedding, "ArcFace should produce an embedding from a real face")
        #expect(emb.count == 512, "ArcFace embedding should be 512-dimensional, got \(emb.count)")

        let norm = sqrt(emb.reduce(0) { $0 + $1 * $1 })
        #expect(norm > 0.5, "Embedding should have meaningful magnitude, got \(norm)")
    }

    // MARK: - AVFoundation video reader (asset loading)

    @Test func avFoundationOpensRealVideo() async throws {
        guard FileManager.default.fileExists(atPath: Self.faceVideoPath) else { return }

        let url = URL(fileURLWithPath: Self.faceVideoPath)
        let asset = AVURLAsset(url: url,
                               options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(!tracks.isEmpty, "Should have at least one video track")

        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        #expect(duration > 2.0 && duration < 4.0,
                "Duration should be ~3s, got \(duration)")

        let fps = try await Double(tracks[0].load(.nominalFrameRate))
        #expect(fps > 20 && fps < 35, "FPS should be ~29.97, got \(fps)")
    }

    // MARK: - Orientation transform helper

    @Test func orientationFromIdentityTransformIsUp() {
        let t = CGAffineTransform.identity
        #expect(pfOrientationFromTransform(t) == .up)
    }

    @Test func orientationFrom90CWIsRight() {
        let t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        #expect(pfOrientationFromTransform(t) == .right)
    }
}
