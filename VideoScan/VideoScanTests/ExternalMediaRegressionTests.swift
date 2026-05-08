import Foundation
import Testing
@testable import VideoScan

// Manifest-driven tests for local-only media files that are too large or too
// private to commit. The manifest and media live outside git by default under
// tests/fixtures/external/.
@MainActor
struct ExternalMediaManifestDecodingTests {

    @Test func decodesManifestAndExpectedFields() throws {
        let json = """
        {
          "version": 1,
          "cases": [
            {
              "id": "avchd-kitty-mts",
              "category": "regression",
              "path": "avchd/kitty.MTS",
              "description": "AVCHD camera clip",
              "expected": {
                "streamType": "Video+Audio",
                "videoCodec": "h264",
                "audioCodec": "ac3",
                "resolution": "1920x1080",
                "minDuration": 1.0,
                "isPlayable": "Yes"
              }
            }
          ]
        }
        """

        let manifest = try JSONDecoder().decode(
            ExternalMediaManifest.self,
            from: Data(json.utf8)
        )

        #expect(manifest.version == 1)
        let testCase = try #require(manifest.cases.first)
        #expect(testCase.id == "avchd-kitty-mts")
        #expect(testCase.category == "regression")
        #expect(testCase.path == "avchd/kitty.MTS")
        #expect(testCase.expected.streamType == .videoAndAudio)
        #expect(testCase.expected.videoCodec == "h264")
        #expect(testCase.expected.audioCodec == "ac3")
        #expect(testCase.expected.resolution == "1920x1080")
        #expect(testCase.expected.minDuration == 1.0)
        #expect(testCase.expected.isPlayable == "Yes")
    }

    @Test func rejectsPathTraversalOutsideMediaRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/videoscan_external_media_root", isDirectory: true)
        let testCase = ExternalMediaCase(
            id: "escape",
            category: "regression",
            path: "../secret.mov",
            description: nil,
            expected: ExternalMediaExpectation(streamType: .videoAndAudio)
        )

        #expect(testCase.resolvedURL(mediaRoot: root) == nil)
    }
}

@MainActor
struct ExternalMediaRegressionTests {

    @Test(.timeLimit(.minutes(10)))
    func externalManifestCasesMatchExpectedMetadata() async throws {
        guard let suite = ExternalMediaSuite.loadIfPresent() else {
            return
        }
        guard !suite.manifest.cases.isEmpty else {
            return
        }

        let model = VideoScanModel()

        for testCase in suite.manifest.cases {
            guard let url = testCase.resolvedURL(mediaRoot: suite.mediaRoot) else {
                Issue.record("External media case \(testCase.id) has unsafe path: \(testCase.path)")
                continue
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                Issue.record("External media case \(testCase.id) missing file: \(url.path)")
                continue
            }

            let record = await model.probeFile(url: url, skipHashing: true)
            assertRecord(record, matches: testCase.expected, id: testCase.id)
        }
    }

    private func assertRecord(
        _ record: VideoRecord,
        matches expected: ExternalMediaExpectation,
        id: String
    ) {
        if let streamType = expected.streamType {
            #expect(record.streamType == streamType, "\(id): expected streamType \(streamType.rawValue), got \(record.streamTypeRaw)")
        }
        if let videoCodec = expected.videoCodec {
            #expect(record.videoCodec == videoCodec, "\(id): expected videoCodec \(videoCodec), got \(record.videoCodec)")
        }
        if let audioCodec = expected.audioCodec {
            #expect(record.audioCodec == audioCodec, "\(id): expected audioCodec \(audioCodec), got \(record.audioCodec)")
        }
        if let resolution = expected.resolution {
            #expect(record.resolution == resolution, "\(id): expected resolution \(resolution), got \(record.resolution)")
        }
        if let minDuration = expected.minDuration {
            #expect(record.durationSeconds >= minDuration, "\(id): expected duration >= \(minDuration), got \(record.durationSeconds)")
        }
        if let maxDuration = expected.maxDuration {
            #expect(record.durationSeconds <= maxDuration, "\(id): expected duration <= \(maxDuration), got \(record.durationSeconds)")
        }
        if let isPlayable = expected.isPlayable {
            #expect(record.isPlayable == isPlayable, "\(id): expected isPlayable \(isPlayable), got \(record.isPlayable)")
        }
        if let isPlayableContains = expected.isPlayableContains {
            #expect(record.isPlayable.contains(isPlayableContains), "\(id): expected isPlayable to contain \(isPlayableContains), got \(record.isPlayable)")
        }
        if let notesContains = expected.notesContains {
            #expect(record.notes.contains(notesContains), "\(id): expected notes to contain \(notesContains), got \(record.notes)")
        }
    }
}

struct ExternalMediaSuite {
    let mediaRoot: URL
    let manifest: ExternalMediaManifest

    static func loadIfPresent(
        filePath: String = #filePath,
        fileManager: FileManager = .default
    ) -> ExternalMediaSuite? {
        let mediaRoot = configuredMediaRoot(filePath: filePath)
        let manifestURL = configuredManifestURL(mediaRoot: mediaRoot)
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ExternalMediaManifest.self, from: data) else {
            return nil
        }
        return ExternalMediaSuite(mediaRoot: mediaRoot, manifest: manifest)
    }

    private static func configuredMediaRoot(filePath: String) -> URL {
        if let path = ProcessInfo.processInfo.environment["VIDEOSCAN_EXTERNAL_MEDIA_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = readConfig(path: "/tmp/videoscan_external_media_root"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let repoRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/external", isDirectory: true)
    }

    private static func configuredManifestURL(mediaRoot: URL) -> URL {
        if let path = ProcessInfo.processInfo.environment["VIDEOSCAN_EXTERNAL_MEDIA_MANIFEST"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        if let path = readConfig(path: "/tmp/videoscan_external_media_manifest"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return mediaRoot.appendingPathComponent("manifest.json")
    }

    private static func readConfig(path: String) -> String? {
        try? String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ExternalMediaManifest: Decodable {
    let version: Int
    let cases: [ExternalMediaCase]
}

struct ExternalMediaCase: Decodable {
    let id: String
    let category: String
    let path: String
    let description: String?
    let expected: ExternalMediaExpectation

    func resolvedURL(mediaRoot: URL) -> URL? {
        guard !path.hasPrefix("/") else { return nil }
        let root = mediaRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }
}

struct ExternalMediaExpectation: Decodable {
    let streamType: StreamType?
    let videoCodec: String?
    let audioCodec: String?
    let resolution: String?
    let minDuration: Double?
    let maxDuration: Double?
    let isPlayable: String?
    let isPlayableContains: String?
    let notesContains: String?

    init(
        streamType: StreamType? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        resolution: String? = nil,
        minDuration: Double? = nil,
        maxDuration: Double? = nil,
        isPlayable: String? = nil,
        isPlayableContains: String? = nil,
        notesContains: String? = nil
    ) {
        self.streamType = streamType
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.isPlayable = isPlayable
        self.isPlayableContains = isPlayableContains
        self.notesContains = notesContains
    }
}
