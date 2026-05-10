import Testing
import Foundation
@testable import VideoScan

@Suite("PersonFinderCache")
struct PersonFinderCacheTests {

    private func makeTempCache() -> PersonFinderCache {
        let path = NSTemporaryDirectory() + "pf_cache_test_\(UUID().uuidString).sqlite"
        return PersonFinderCache(path: path)
    }

    private func sampleResult(hits: Int = 3) -> pfVideoResult {
        let segs = (0..<hits).map { i in
            pfSegment(
                startSecs: Double(i) * 10.0,
                endSecs: Double(i) * 10.0 + 5.0,
                bestDistance: 0.35,
                avgDistance: 0.42
            )
        }
        return pfVideoResult(
            filename: "clip.MTS",
            filePath: "/Volumes/TestDrive/clip.MTS",
            durationSeconds: 120.0,
            fps: 29.97,
            totalHits: hits,
            segments: segs
        )
    }

    private func makeKey(
        videoPath: String = "/Volumes/TestDrive/clip.MTS",
        fileSize: Int64 = 500_000_000,
        modDate: Date = Date(timeIntervalSince1970: 1260665694.0),
        personName: String = "donna",
        engine: String = "ArcFace (CoreML)",
        threshold: Float = 0.4,
        refHash: String = "18511299587774b7"
    ) -> PersonFinderCache.CacheKey {
        PersonFinderCache.CacheKey(
            videoPath: videoPath,
            fileSize: fileSize,
            modDate: modDate,
            personName: personName,
            engine: engine,
            threshold: threshold,
            refHash: refHash
        )
    }

    // MARK: - Round-trip: store then lookup

    @Test("Store and lookup returns cached result")
    func storeAndLookup() {
        let cache = makeTempCache()
        let key = makeKey()
        let result = sampleResult(hits: 3)

        cache.store(key: key, result: result)
        let hit = cache.lookup(key: key)

        #expect(hit != nil, "Expected cache hit")
        #expect(hit?.totalHits == 3)
        #expect(hit?.segments.count == 3)
        #expect(hit?.durationSeconds == 120.0)
        #expect(hit?.fps == 29.97)
        #expect(hit?.filename == "clip.MTS")
        #expect(hit?.filePath == "/Volumes/TestDrive/clip.MTS")
    }

    @Test("Segment round-trip preserves values")
    func segmentRoundTrip() {
        let cache = makeTempCache()
        let key = makeKey()
        let result = sampleResult(hits: 2)

        cache.store(key: key, result: result)
        let hit = cache.lookup(key: key)!

        #expect(hit.segments[0].startSecs == 0.0)
        #expect(hit.segments[0].endSecs == 5.0)
        #expect(abs(hit.segments[0].bestDistance - 0.35) < 0.001)
        #expect(abs(hit.segments[0].avgDistance - 0.42) < 0.001)
        #expect(hit.segments[1].startSecs == 10.0)
        #expect(hit.segments[1].endSecs == 15.0)
    }

    @Test("Zero-hit result is cached and retrievable")
    func zeroHitsCached() {
        let cache = makeTempCache()
        let key = makeKey()
        let result = sampleResult(hits: 0)

        cache.store(key: key, result: result)
        let hit = cache.lookup(key: key)

        #expect(hit != nil, "Zero-hit results must be cached")
        #expect(hit?.totalHits == 0)
        #expect(hit?.segments.isEmpty == true)
    }

    // MARK: - Key component mismatches (each must miss)

    @Test("Different videoPath → miss")
    func differentPath() {
        let cache = makeTempCache()
        let storeKey = makeKey(videoPath: "/Volumes/TestDrive/clip.MTS")
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(videoPath: "/Volumes/TestDrive/other.MTS")
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different fileSize → miss")
    func differentSize() {
        let cache = makeTempCache()
        let storeKey = makeKey(fileSize: 500_000_000)
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(fileSize: 500_000_001)
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different modDate → miss")
    func differentModDate() {
        let cache = makeTempCache()
        let storeKey = makeKey(modDate: Date(timeIntervalSince1970: 1260665694.0))
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(modDate: Date(timeIntervalSince1970: 1260665695.0))
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different personName → miss")
    func differentPerson() {
        let cache = makeTempCache()
        let storeKey = makeKey(personName: "donna")
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(personName: "rick")
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different engine → miss")
    func differentEngine() {
        let cache = makeTempCache()
        let storeKey = makeKey(engine: "ArcFace (CoreML)")
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(engine: "Vision (fast)")
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different threshold → miss")
    func differentThreshold() {
        let cache = makeTempCache()
        let storeKey = makeKey(threshold: 0.4)
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(threshold: 0.5)
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    @Test("Different refHash → miss")
    func differentRefHash() {
        let cache = makeTempCache()
        let storeKey = makeKey(refHash: "18511299587774b7")
        cache.store(key: storeKey, result: sampleResult())

        let lookupKey = makeKey(refHash: "aaaaaaaaaaaaaaaa")
        #expect(cache.lookup(key: lookupKey) == nil)
    }

    // MARK: - Float threshold precision

    @Test("Float threshold round-trips through Double without precision loss")
    func thresholdPrecision() {
        let cache = makeTempCache()
        let key = makeKey(threshold: 0.4)
        cache.store(key: key, result: sampleResult())

        let sameKey = makeKey(threshold: 0.4)
        #expect(cache.lookup(key: sameKey) != nil, "Same Float(0.4) must hit cache")

        let nearKey = makeKey(threshold: Float(bitPattern: Float(0.4).bitPattern + 1))
        #expect(cache.lookup(key: nearKey) == nil, "Adjacent float must miss")
    }

    // MARK: - Overwrite (INSERT OR REPLACE)

    @Test("Re-storing with same key overwrites result")
    func overwrite() {
        let cache = makeTempCache()
        let key = makeKey()

        cache.store(key: key, result: sampleResult(hits: 1))
        let first = cache.lookup(key: key)
        #expect(first?.totalHits == 1)

        cache.store(key: key, result: sampleResult(hits: 7))
        let second = cache.lookup(key: key)
        #expect(second?.totalHits == 7)
        #expect(cache.count == 1)
    }

    // MARK: - clearAll

    @Test("clearAll removes all entries")
    func clearAll() {
        let cache = makeTempCache()
        cache.store(key: makeKey(videoPath: "/a"), result: sampleResult())
        cache.store(key: makeKey(videoPath: "/b"), result: sampleResult())
        #expect(cache.count == 2)

        cache.clearAll()
        #expect(cache.count < 1)
    }

    // MARK: - stableHash regression

    private func withTempFile(_ body: (String) throws -> Void) rethrows {
        let path = NSTemporaryDirectory() + "pf_cache_hash_test_\(UUID().uuidString).txt"
        FileManager.default.createFile(atPath: path, contents: Data("test".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try body(path)
    }

    private func withTempDirectory(_ body: (URL) throws -> Void) rethrows {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pf_cache_refs_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    @Test("stableHash is order-independent for sorted filenames")
    func stableHashDeterministic() {
        withTempFile { tmpPath in
            let refsA = ["donna_1990.jpg", "donna_2005.jpg", "donna_2020.jpg"]
            let refsB = ["donna_2020.jpg", "donna_1990.jpg", "donna_2005.jpg"]

            let hashA = PersonFinderCache.makeKey(
                videoPath: tmpPath, personName: "donna", engine: .arcface,
                threshold: 0.4, refFilenames: refsA
            )?.refHash

            let hashB = PersonFinderCache.makeKey(
                videoPath: tmpPath, personName: "donna", engine: .arcface,
                threshold: 0.4, refFilenames: refsB
            )?.refHash

            #expect(hashA != nil)
            #expect(hashA == hashB, "Ref hash must be stable regardless of input order")
        }
    }

    @Test("Adding a reference photo changes the hash")
    func refHashChangesWithNewPhoto() {
        withTempFile { tmpPath in
            let refsSmall = ["donna_1990.jpg", "donna_2005.jpg"]
            let refsBig = ["donna_1990.jpg", "donna_2005.jpg", "donna_2020.jpg"]

            let hashSmall = PersonFinderCache.makeKey(
                videoPath: tmpPath, personName: "donna", engine: .arcface,
                threshold: 0.4, refFilenames: refsSmall
            )?.refHash

            let hashBig = PersonFinderCache.makeKey(
                videoPath: tmpPath, personName: "donna", engine: .arcface,
                threshold: 0.4, refFilenames: refsBig
            )?.refHash

            #expect(hashSmall != hashBig, "Different ref photo set must produce different hash")
        }
    }

    @Test("Changing reference photo contents with the same filename invalidates cache")
    func refHashChangesWhenReferenceFileContentsChange() throws {
        try withTempFile { videoPath in
            try withTempDirectory { refDir in
                let refURL = refDir.appendingPathComponent("donna.jpg")
                let firstBytes = Data("reference-image-A-0001".utf8)
                let replacementBytes = Data("reference-image-B-0001".utf8)
                #expect(firstBytes.count == replacementBytes.count)

                try firstBytes.write(to: refURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 2_000)],
                    ofItemAtPath: refURL.path
                )

                let firstKey = PersonFinderCache.makeKey(
                    videoPath: videoPath, personName: "donna", engine: .arcface,
                    threshold: 0.4, refFilenames: [refURL.path]
                )
                #expect(firstKey != nil)
                guard let firstKey else { return }

                let cache = makeTempCache()
                cache.store(key: firstKey, result: sampleResult(hits: 1))

                try replacementBytes.write(to: refURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 3_000)],
                    ofItemAtPath: refURL.path
                )
                let secondKey = PersonFinderCache.makeKey(
                    videoPath: videoPath, personName: "donna", engine: .arcface,
                    threshold: 0.4, refFilenames: [refURL.path]
                )
                #expect(secondKey != nil)
                guard let secondKey else { return }

                #expect(firstKey.refHash != secondKey.refHash)
                #expect(cache.lookup(key: secondKey) == nil)
            }
        }
    }
}
