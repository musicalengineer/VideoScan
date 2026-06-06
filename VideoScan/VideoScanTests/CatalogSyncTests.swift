// CatalogSyncTests.swift
// Tests for the read-only catalog-sync feature on feature/catalog-sync-readonly.
//
// Covers the seams the feature-dev agent surfaced:
//   - hostnameMatches (.local-insensitive, case-insensitive)
//   - mode resolution via injected HostnameSource
//   - computeManifestLines + sha256Hex (pure, stable output)
//   - verifyManifest (all four typed-error paths + happy path)
//   - CatalogStore.isReadOnly guard for saveNow + scheduleSave
//   - CatalogStoreObserver fire-once contract
//   - End-to-end sync round-trip via stub RsyncRunner
//   - Manifest-mismatch rejection: corrupt staging → live unchanged
//   - atomicSwap rotation: live → .sync-previous, staging → live
//
// Tests use Swift Testing (`import Testing`, @Test, #expect) to match the
// new-tests-go-here convention established by WorkbenchActionsTests.
//
// `// `#expect` ≈ EXPECT_TRUE in GoogleTest — non-fatal assertion,
// the test keeps running so a single run reports every failure in one pass.
//
// All I/O is confined to NSTemporaryDirectory() subdirectories named with
// a UUID. Nothing touches ~/Library/Application Support/VideoScan/.

import Testing
import Foundation
import CryptoKit
@testable import VideoScan

// MARK: - Test helpers

/// Stub hostname source — returns whatever string the test supplied.
private struct FixedHostname: HostnameSource {
    let value: String
    func currentHostname() -> String { value }
}

/// Stub rsync runner that mirrors a source directory tree into the
/// destination using `cp -R`. Used in place of /usr/bin/rsync so tests
/// don't need SSH or network. Tracks invocations for assertion.
private final class StubRsync: RsyncRunner, @unchecked Sendable {
    let sourceTree: URL
    let succeed: Bool
    var invocations: Int = 0
    /// Optional hook called after the copy, before returning. Lets a test
    /// corrupt the staging dir to simulate in-flight tampering.
    var postCopyHook: ((URL) -> Void)?

    init(sourceTree: URL, succeed: Bool = true) {
        self.sourceTree = sourceTree
        self.succeed = succeed
    }

    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        invocations += 1
        if !succeed {
            return RsyncOutcome(succeeded: false, exitCode: 255,
                                stderr: "stub failure")
        }
        let fm = FileManager.default
        // Mirror semantics — wipe dest first, then copy each top-level
        // entry from source.
        try? fm.removeItem(at: destDir)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        if let kids = try? fm.contentsOfDirectory(at: sourceTree,
                                                  includingPropertiesForKeys: nil) {
            for k in kids {
                let dest = destDir.appendingPathComponent(k.lastPathComponent)
                try? fm.copyItem(at: k, to: dest)
            }
        }
        postCopyHook?(destDir)
        return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
    }
}

/// Observer that counts invocations of catalogStoreDidWrite.
@MainActor
private final class CountingObserver: CatalogStoreObserver {
    var fireCount: Int = 0
    func catalogStoreDidWrite(_ store: CatalogStore) {
        fireCount += 1
    }
}

@MainActor
private func scratchDir(_ tag: String = "sync") -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("videoscan_\(tag)_\(UUID().uuidString)",
                                isDirectory: true)
}

@MainActor
private func makePaths(under root: URL) -> CatalogSyncPaths {
    CatalogSyncPaths(
        liveDir: root.appendingPathComponent("live", isDirectory: true),
        stagingDir: root.appendingPathComponent("staging", isDirectory: true),
        previousDir: root.appendingPathComponent("previous", isDirectory: true),
        lastSyncFile: root.appendingPathComponent("last_sync.txt")
    )
}

/// Populate a "master" tree: catalog.json, catalog.json.prev, POI/face_1.jpg.
@MainActor
private func populateMasterTree(at url: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("{\"version\":4,\"records\":[]}".utf8).write(
        to: url.appendingPathComponent("catalog.json"))
    try Data("{\"version\":4,\"records\":[],\"prev\":true}".utf8).write(
        to: url.appendingPathComponent("catalog.json.prev"))
    let poi = url.appendingPathComponent("POI", isDirectory: true)
    try fm.createDirectory(at: poi, withIntermediateDirectories: true)
    // Two POI files to exercise the recursive walk + sort order.
    try Data("fake-jpeg-bytes-A".utf8).write(
        to: poi.appendingPathComponent("face_a.jpg"))
    try Data("fake-jpeg-bytes-B".utf8).write(
        to: poi.appendingPathComponent("face_b.jpg"))
}

@MainActor
private func makeSync(paths: CatalogSyncPaths,
                      localHost: String,
                      masterHost: String,
                      runner: RsyncRunner) -> CatalogSync {
    try? FileManager.default.createDirectory(
        at: paths.liveDir, withIntermediateDirectories: true)
    return CatalogSync(
        paths: paths,
        hostnameSource: FixedHostname(value: localHost),
        rsyncRunner: runner,
        masterHostname: masterHost,
        remoteUser: "rickb",
        log: { _ in }
    )
}

// MARK: - Hostname matching

@MainActor
struct HostnameMatchTests {

    @Test
    func identicalHostnamesMatch() {
        #expect(CatalogSync.hostnameMatches(
            local: "RicksM4.local", master: "RicksM4.local"))
    }

    @Test
    func bareLocalEquivalence() {
        // localizedName returns bare; defaultMasterHostname has .local.
        // Both directions must match.
        #expect(CatalogSync.hostnameMatches(
            local: "RicksM4", master: "RicksM4.local"))
        #expect(CatalogSync.hostnameMatches(
            local: "RicksM4.local", master: "RicksM4"))
    }

    @Test
    func caseInsensitive() {
        #expect(CatalogSync.hostnameMatches(
            local: "ricksm4.LOCAL", master: "RicksM4.local"))
    }

    @Test
    func clearlyDifferentHostsDoNotMatch() {
        #expect(!CatalogSync.hostnameMatches(
            local: "ricksmacbookpro.local", master: "RicksM4.local"))
        #expect(!CatalogSync.hostnameMatches(
            local: "intelmacbookpro", master: "RicksM4"))
    }

    @Test
    func emptyStringsDoNotMatchRealHost() {
        #expect(!CatalogSync.hostnameMatches(
            local: "", master: "RicksM4.local"))
    }
}

@MainActor
struct ModeResolutionTests {

    @Test
    func viewerWhenHostnameDiffers() {
        let root = scratchDir("mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StubRsync(sourceTree: root) // unused for mode check
        let sync = makeSync(paths: makePaths(under: root),
                            localHost: "ricksmacbookpro.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        #expect(sync.mode == .viewer)
        #expect(sync.isReadOnly == true)
    }

    @Test
    func masterWhenHostnameMatches() {
        let root = scratchDir("mode")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = StubRsync(sourceTree: root)
        let sync = makeSync(paths: makePaths(under: root),
                            localHost: "RicksM4",
                            masterHost: "RicksM4.local",
                            runner: runner)
        #expect(sync.mode == .master)
        #expect(sync.isReadOnly == false)
    }
}

// MARK: - sha256 + manifest computation

@MainActor
struct ManifestComputeTests {

    @Test
    func sha256MatchesGoldenForKnownInput() throws {
        // Golden vector: SHA-256("abc") =
        //   ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        // Confirmed via `echo -n abc | shasum -a 256`.
        let dir = scratchDir("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        let hex = try CatalogSync.sha256Hex(of: file)
        #expect(hex ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func sha256MatchesCryptoKitForBinaryBlob() throws {
        // Compare against a fresh CryptoKit hash of the same bytes — proves
        // the streaming-chunk implementation in CatalogSync produces the same
        // digest as a one-shot hash.
        let dir = scratchDir("sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes = Data(count: 3 * 1024 * 1024 + 17)  // span >2 chunks
        for i in 0..<bytes.count { bytes[i] = UInt8(i & 0xff) }
        let file = dir.appendingPathComponent("blob.bin")
        try bytes.write(to: file)
        let streamed = try CatalogSync.sha256Hex(of: file)
        let oneShot = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()
        #expect(streamed == oneShot)
    }

    @Test
    func computeManifestLinesIsSortedAndCoversAllTargets() throws {
        let root = scratchDir("compute")
        defer { try? FileManager.default.removeItem(at: root) }
        try populateMasterTree(at: root)

        let lines = try CatalogSync.computeManifestLines(rootDir: root)

        // 4 files: catalog.json, catalog.json.prev, POI/face_a.jpg, POI/face_b.jpg
        #expect(lines.count == 4)

        // Sorted by relpath (NOT by hash — lines start with the hash, but
        // the sort key is the path after the two-space separator).
        let relpaths = lines.map { line -> String in
            if let sep = line.range(of: "  ") {
                return String(line[sep.upperBound...])
            }
            return line
        }
        #expect(relpaths == relpaths.sorted(),
                "computeManifestLines must return entries sorted by relpath")

        // Each line is "<64 hex>  <relpath>".
        for line in lines {
            guard let sep = line.range(of: "  ") else {
                Issue.record("line missing two-space separator: \(line)")
                continue
            }
            let hash = String(line[..<sep.lowerBound])
            #expect(hash.count == 64, "hash hex must be 64 chars: \(hash)")
            #expect(hash.allSatisfy { $0.isHexDigit })
        }

        // All four expected relpaths present.
        let paths = lines.compactMap { $0.split(separator: " ", maxSplits: 1,
                                                omittingEmptySubsequences: true).last }
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(paths.contains("catalog.json"))
        #expect(paths.contains("catalog.json.prev"))
        #expect(paths.contains("POI/face_a.jpg"))
        #expect(paths.contains("POI/face_b.jpg"))
    }

    @Test
    func computeManifestLinesIsStableAcrossInvocations() throws {
        let root = scratchDir("compute")
        defer { try? FileManager.default.removeItem(at: root) }
        try populateMasterTree(at: root)
        let first = try CatalogSync.computeManifestLines(rootDir: root)
        let second = try CatalogSync.computeManifestLines(rootDir: root)
        #expect(first == second)
    }
}

// MARK: - Manifest write + verify round-trip

@MainActor
struct ManifestVerifyTests {

    /// Build a master-mode sync engine, populate the live dir, write a
    /// manifest. Returns the sync engine so tests can call verifyManifest.
    private func masterWithManifest(tag: String) throws -> (CatalogSync, URL) {
        let root = scratchDir(tag)
        let paths = makePaths(under: root)
        try populateMasterTree(at: paths.liveDir)
        let runner = StubRsync(sourceTree: paths.liveDir)
        let sync = makeSync(paths: paths,
                            localHost: "RicksM4.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        sync.writeManifestIfMaster()
        return (sync, root)
    }

    @Test
    func writeAndVerifyRoundTripSucceeds() throws {
        let (sync, root) = try masterWithManifest(tag: "verify-happy")
        defer { try? FileManager.default.removeItem(at: root) }
        // Manifest should now exist next to catalog.json.
        let manifestURL = root.appendingPathComponent("live/manifest.sha256")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        // And verify should pass for the dir it was written into.
        #expect(throws: Never.self) {
            try sync.verifyManifest(in: root.appendingPathComponent("live"))
        }
    }

    @Test
    func writeManifestIsNoOpOnViewer() throws {
        let root = scratchDir("verify-viewer")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(under: root)
        try populateMasterTree(at: paths.liveDir)
        let runner = StubRsync(sourceTree: paths.liveDir)
        let sync = makeSync(paths: paths,
                            localHost: "ricksmacbookpro.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        sync.writeManifestIfMaster()
        let manifestURL = paths.liveDir.appendingPathComponent("manifest.sha256")
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path),
                "viewer must not write manifest.sha256 — that's the master's job")
    }

    @Test
    func verifyThrowsMissingManifest() throws {
        let root = scratchDir("verify-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(under: root)
        try populateMasterTree(at: paths.liveDir)
        // Don't call writeManifestIfMaster — manifest absent.
        let runner = StubRsync(sourceTree: paths.liveDir)
        let sync = makeSync(paths: paths,
                            localHost: "RicksM4.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        #expect(throws: CatalogSync.ManifestVerifyError.missingManifest) {
            try sync.verifyManifest(in: paths.liveDir)
        }
    }

    @Test
    func verifyThrowsMalformedManifest() throws {
        let (sync, root) = try masterWithManifest(tag: "verify-malformed")
        defer { try? FileManager.default.removeItem(at: root) }
        let liveDir = root.appendingPathComponent("live")
        // Clobber the manifest with a garbage line — no double-space separator.
        let bad = "this-line-has-no-double-space-separator-at-all\n"
        try bad.write(to: liveDir.appendingPathComponent("manifest.sha256"),
                      atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try sync.verifyManifest(in: liveDir)
        }
        // And confirm it's the right typed error.
        do {
            try sync.verifyManifest(in: liveDir)
            Issue.record("expected verifyManifest to throw")
        } catch let err as CatalogSync.ManifestVerifyError {
            if case .malformedManifest = err {
                // expected
            } else {
                Issue.record("expected .malformedManifest, got \(err)")
            }
        } catch {
            Issue.record("expected ManifestVerifyError, got \(error)")
        }
    }

    @Test
    func verifyThrowsMissingFileWhenManifestEntryIsAbsent() throws {
        let (sync, root) = try masterWithManifest(tag: "verify-missing-file")
        defer { try? FileManager.default.removeItem(at: root) }
        let liveDir = root.appendingPathComponent("live")
        // Delete one of the files the manifest covers.
        try FileManager.default.removeItem(
            at: liveDir.appendingPathComponent("POI/face_a.jpg"))
        do {
            try sync.verifyManifest(in: liveDir)
            Issue.record("expected verifyManifest to throw")
        } catch let err as CatalogSync.ManifestVerifyError {
            if case .missingFile(let p) = err {
                #expect(p == "POI/face_a.jpg")
            } else {
                Issue.record("expected .missingFile, got \(err)")
            }
        } catch {
            Issue.record("expected ManifestVerifyError, got \(error)")
        }
    }

    @Test
    func verifyThrowsHashMismatchWhenFileWasTamperedWith() throws {
        let (sync, root) = try masterWithManifest(tag: "verify-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        let liveDir = root.appendingPathComponent("live")
        // Overwrite one of the manifest-covered files with different bytes,
        // leaving the manifest in place.
        try Data("TAMPERED".utf8).write(
            to: liveDir.appendingPathComponent("POI/face_b.jpg"))
        do {
            try sync.verifyManifest(in: liveDir)
            Issue.record("expected verifyManifest to throw")
        } catch let err as CatalogSync.ManifestVerifyError {
            if case .hashMismatch(let p) = err {
                #expect(p == "POI/face_b.jpg")
            } else {
                Issue.record("expected .hashMismatch, got \(err)")
            }
        } catch {
            Issue.record("expected ManifestVerifyError, got \(error)")
        }
    }
}

// MARK: - CatalogStore read-only guard

@MainActor
struct CatalogStoreReadOnlyTests {

    private func makeRecord(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        return r
    }

    @Test
    func writableStorePersistsRecordsByDefault() throws {
        let dir = scratchDir("rw")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        #expect(store.isReadOnly == false, "default mode must be writable")
        store.saveNow(records: [makeRecord("a.mov")])
        #expect(FileManager.default.fileExists(atPath: store.fileLocation))
    }

    @Test
    func readOnlyStoreRefusesSaveNow() throws {
        let dir = scratchDir("ro-now")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.isReadOnly = true
        store.saveNow(records: [makeRecord("a.mov")])
        #expect(!FileManager.default.fileExists(atPath: store.fileLocation),
                "readOnly store must not write catalog.json")
    }

    @Test
    func readOnlyStoreRefusesScheduleSave() async throws {
        let dir = scratchDir("ro-sched")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.isReadOnly = true
        store.scheduleSave(records: [makeRecord("a.mov")])
        // Debounce window in CatalogStore is 2s; wait longer than that.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(!FileManager.default.fileExists(atPath: store.fileLocation),
                "readOnly scheduleSave must not fire the debounced write")
    }

    @Test
    func togglingReadOnlyOffReEnablesWrites() throws {
        let dir = scratchDir("ro-toggle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.isReadOnly = true
        store.saveNow(records: [makeRecord("a.mov")])
        #expect(!FileManager.default.fileExists(atPath: store.fileLocation))
        // Flip it back and the next save lands on disk.
        store.isReadOnly = false
        store.saveNow(records: [makeRecord("b.mov")])
        #expect(FileManager.default.fileExists(atPath: store.fileLocation))
    }

    @Test
    func readOnlyDoesNotClobberExistingFile() throws {
        // Start writable, save once. Flip to read-only. Save again with
        // different records. The on-disk file's mtime must NOT advance.
        let dir = scratchDir("ro-noclobber")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.saveNow(records: [makeRecord("first.mov")])
        let url = URL(fileURLWithPath: store.fileLocation)
        let mtime1 = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        // Force at least one second of separation so any HFS+/APFS mtime
        // granularity doesn't make this race-prone.
        Thread.sleep(forTimeInterval: 1.1)
        store.isReadOnly = true
        store.saveNow(records: [makeRecord("second.mov")])
        let mtime2 = try FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(mtime1 == mtime2,
                "readOnly save must not rewrite the existing catalog.json")
    }
}

// MARK: - CatalogStoreObserver hook

@MainActor
struct CatalogStoreObserverTests {

    private func makeRecord(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        return r
    }

    @Test
    func observerFiresOncePerSuccessfulWrite() throws {
        let dir = scratchDir("obs-once")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let obs = CountingObserver()
        store.observer = obs
        store.saveNow(records: [makeRecord("a.mov")])
        #expect(obs.fireCount == 1)
    }

    @Test
    func observerFiresPerCall() throws {
        let dir = scratchDir("obs-multi")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let obs = CountingObserver()
        store.observer = obs
        store.saveNow(records: [makeRecord("a.mov")])
        store.saveNow(records: [makeRecord("b.mov")])
        store.saveNow(records: [makeRecord("c.mov")])
        #expect(obs.fireCount == 3)
    }

    @Test
    func observerDoesNotFireWhenReadOnlyRefusesWrite() throws {
        let dir = scratchDir("obs-ro")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        store.isReadOnly = true
        let obs = CountingObserver()
        store.observer = obs
        store.saveNow(records: [makeRecord("a.mov")])
        #expect(obs.fireCount == 0,
                "observer is the post-write hook; if the write is refused the hook must not run")
    }
}

// MARK: - End-to-end sync round-trip

@MainActor
struct SyncRoundTripTests {

    /// Helper — recursively compute (relpath, sha256) for every regular
    /// file under root using the same logic the manifest uses. Lets the
    /// round-trip test assert byte-for-byte equivalence without trusting
    /// the very code under test (it walks with FileManager.enumerator,
    /// hashes with SHA256.hash, not the streaming impl).
    private func tree(at root: URL) throws -> [(String, String)] {
        let fm = FileManager.default
        var out: [(String, String)] = []
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles]) else { return [] }
        for case let url as URL in walker {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
            if vals.isRegularFile != true { continue }
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }.joined()
            out.append((rel, hash))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    @Test
    func happyPathRsyncVerifyAndSwap() async throws {
        let root = scratchDir("rt-happy")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Build the "master" tree in a separate dir + write its manifest.
        let masterRoot = root.appendingPathComponent("master", isDirectory: true)
        try populateMasterTree(at: masterRoot)
        do {
            // Use a master-mode sync engine pointed at masterRoot to write
            // the manifest there.
            let masterPaths = CatalogSyncPaths(
                liveDir: masterRoot,
                stagingDir: root.appendingPathComponent("master-staging"),
                previousDir: root.appendingPathComponent("master-previous"),
                lastSyncFile: root.appendingPathComponent("master-last_sync.txt"))
            let masterSync = makeSync(paths: masterPaths,
                                      localHost: "RicksM4.local",
                                      masterHost: "RicksM4.local",
                                      runner: StubRsync(sourceTree: masterRoot))
            masterSync.writeManifestIfMaster()
        }

        // 2. Build a viewer-mode sync engine whose stub rsync mirrors
        //    masterRoot into the viewer's staging dir.
        let viewerPaths = makePaths(under: root)
        let runner = StubRsync(sourceTree: masterRoot)
        let viewer = makeSync(paths: viewerPaths,
                              localHost: "ricksmacbookpro.local",
                              masterHost: "RicksM4.local",
                              runner: runner)

        // 3. Sync.
        await viewer.syncFromMaster()

        // 4. The viewer's live dir should now match master byte-for-byte
        //    for everything covered by the manifest.
        let masterTree = try tree(at: masterRoot).filter {
            $0.0 != "manifest.sha256"  // manifest itself is allowed to differ in mtime
        }
        let liveTree = try tree(at: viewerPaths.liveDir).filter {
            $0.0 != "manifest.sha256"
        }
        #expect(masterTree.count == liveTree.count)
        #expect(masterTree.map { $0.0 } == liveTree.map { $0.0 })
        #expect(masterTree.map { $0.1 } == liveTree.map { $0.1 })

        // 5. Phase should be .synced.
        if case .synced = viewer.state.phase {
            // good
        } else {
            Issue.record("expected .synced phase, got \(viewer.state.phase)")
        }
        #expect(viewer.state.lastSuccessfulSync != nil)
        #expect(runner.invocations == 1)
    }

    @Test
    func manifestMismatchRejectsTheSwap() async throws {
        let root = scratchDir("rt-mismatch")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Master tree + manifest.
        let masterRoot = root.appendingPathComponent("master", isDirectory: true)
        try populateMasterTree(at: masterRoot)
        let masterPaths = CatalogSyncPaths(
            liveDir: masterRoot,
            stagingDir: root.appendingPathComponent("master-staging"),
            previousDir: root.appendingPathComponent("master-previous"),
            lastSyncFile: root.appendingPathComponent("master-last_sync.txt"))
        let masterSync = makeSync(paths: masterPaths,
                                  localHost: "RicksM4.local",
                                  masterHost: "RicksM4.local",
                                  runner: StubRsync(sourceTree: masterRoot))
        masterSync.writeManifestIfMaster()

        // 2. Pre-populate the viewer's live dir with "old, good" data so we
        //    can later prove the swap did NOT happen.
        let viewerPaths = makePaths(under: root)
        try FileManager.default.createDirectory(
            at: viewerPaths.liveDir, withIntermediateDirectories: true)
        let oldCatalog = viewerPaths.liveDir.appendingPathComponent("catalog.json")
        try Data("OLD-GOOD-CATALOG".utf8).write(to: oldCatalog)

        // 3. Stub rsync that mirrors master → staging, then corrupts one
        //    of the staged files before returning success.
        let runner = StubRsync(sourceTree: masterRoot)
        runner.postCopyHook = { staging in
            let target = staging.appendingPathComponent("POI/face_a.jpg")
            try? Data("CORRUPTED-IN-FLIGHT".utf8).write(to: target)
        }
        let viewer = makeSync(paths: viewerPaths,
                              localHost: "ricksmacbookpro.local",
                              masterHost: "RicksM4.local",
                              runner: runner)

        await viewer.syncFromMaster()

        // 4. Phase must be .failed.
        if case .failed(let reason) = viewer.state.phase {
            #expect(reason.contains("manifest verify failed"))
        } else {
            Issue.record("expected .failed phase, got \(viewer.state.phase)")
        }

        // 5. Live dir is UNCHANGED — old catalog is still there with its
        //    original contents.
        let after = try Data(contentsOf: oldCatalog)
        #expect(after == Data("OLD-GOOD-CATALOG".utf8),
                "swap must not have happened; last-good snapshot must be intact")

        // 6. lastSuccessfulSync must NOT have been bumped.
        #expect(viewer.state.lastSuccessfulSync == nil,
                "a failed sync must not advance lastSuccessfulSync")
    }

    @Test
    func rsyncFailureLeavesLiveDirUnchanged() async throws {
        let root = scratchDir("rt-rsyncfail")
        defer { try? FileManager.default.removeItem(at: root) }
        let viewerPaths = makePaths(under: root)
        try FileManager.default.createDirectory(
            at: viewerPaths.liveDir, withIntermediateDirectories: true)
        let oldCatalog = viewerPaths.liveDir.appendingPathComponent("catalog.json")
        try Data("OLD-GOOD-CATALOG".utf8).write(to: oldCatalog)

        let runner = StubRsync(sourceTree: root, succeed: false)
        let viewer = makeSync(paths: viewerPaths,
                              localHost: "ricksmacbookpro.local",
                              masterHost: "RicksM4.local",
                              runner: runner)
        await viewer.syncFromMaster()

        if case .failed = viewer.state.phase {
            // good
        } else {
            Issue.record("expected .failed phase on rsync failure, got \(viewer.state.phase)")
        }
        let after = try Data(contentsOf: oldCatalog)
        #expect(after == Data("OLD-GOOD-CATALOG".utf8))
    }

    @Test
    func syncIsNoOpInMasterMode() async throws {
        let root = scratchDir("rt-master")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(under: root)
        let runner = StubRsync(sourceTree: root)
        let master = makeSync(paths: paths,
                              localHost: "RicksM4.local",
                              masterHost: "RicksM4.local",
                              runner: runner)
        await master.syncFromMaster()
        #expect(runner.invocations == 0,
                "master must never rsync from itself")
    }
}

// MARK: - Atomic swap rotation

@MainActor
struct AtomicSwapTests {

    @Test
    func swapMovesLiveToPreviousAndStagingToLive() throws {
        let root = scratchDir("swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(under: root)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)

        // Pre-populate live with an "old" catalog.
        try Data("OLD".utf8).write(
            to: paths.liveDir.appendingPathComponent("catalog.json"))
        try Data("OLD-PREV".utf8).write(
            to: paths.liveDir.appendingPathComponent("catalog.json.prev"))
        // Pre-populate staging with a "new" catalog + matching manifest.
        try Data("NEW".utf8).write(
            to: paths.stagingDir.appendingPathComponent("catalog.json"))
        try Data("NEW-PREV".utf8).write(
            to: paths.stagingDir.appendingPathComponent("catalog.json.prev"))
        try Data("NEW-MANIFEST".utf8).write(
            to: paths.stagingDir.appendingPathComponent("manifest.sha256"))

        let runner = StubRsync(sourceTree: paths.liveDir)
        let sync = makeSync(paths: paths,
                            localHost: "ricksmacbookpro.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        try sync.atomicSwap()

        // Live now has the new bytes.
        let liveCatalog = try Data(contentsOf:
            paths.liveDir.appendingPathComponent("catalog.json"))
        #expect(liveCatalog == Data("NEW".utf8))
        let liveManifest = try Data(contentsOf:
            paths.liveDir.appendingPathComponent("manifest.sha256"))
        #expect(liveManifest == Data("NEW-MANIFEST".utf8))

        // Previous holds the old bytes.
        let prevCatalog = try Data(contentsOf:
            paths.previousDir.appendingPathComponent("catalog.json"))
        #expect(prevCatalog == Data("OLD".utf8))

        // Staging dir is gone.
        #expect(!fm.fileExists(atPath: paths.stagingDir.path),
                "staging dir should be removed after a successful swap")
    }

    @Test
    func swapWipesPreviousFromPriorGeneration() throws {
        let root = scratchDir("swap-rot")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = makePaths(under: root)
        let fm = FileManager.default
        try fm.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.stagingDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.previousDir, withIntermediateDirectories: true)
        // Stale leftover from a previous swap that should be wiped.
        try Data("STALE-FROM-2-GENERATIONS-AGO".utf8).write(
            to: paths.previousDir.appendingPathComponent("catalog.json"))

        try Data("LIVE-NOW".utf8).write(
            to: paths.liveDir.appendingPathComponent("catalog.json"))
        try Data("STAGED-NEW".utf8).write(
            to: paths.stagingDir.appendingPathComponent("catalog.json"))

        let runner = StubRsync(sourceTree: paths.liveDir)
        let sync = makeSync(paths: paths,
                            localHost: "ricksmacbookpro.local",
                            masterHost: "RicksM4.local",
                            runner: runner)
        try sync.atomicSwap()

        // Previous now holds the prior LIVE-NOW, not the stale 2-generations-ago.
        let prev = try Data(contentsOf:
            paths.previousDir.appendingPathComponent("catalog.json"))
        #expect(prev == Data("LIVE-NOW".utf8),
                "previous must be reset to the just-prior live, not pile up generations")
    }
}

// MARK: - rsync argument construction (regression: master-offline space bug)
//
// Verified 2026-06-05: Apple's openrsync (protocol 29, default on
// macOS 26.x) space-splits the remote source path so a literal space
// in "/Users/rickb/Library/Application Support/VideoScan/" gets
// treated as two separate source paths and both fail with "No such
// file or directory" — manifesting in the UI as "master offline."
// The fix is to backslash-escape spaces in the remote root. These
// tests pin that escape into place so it can't silently regress.

@MainActor
struct RsyncArgumentsSpaceEscapeTests {

    /// Build a CatalogSync configured as a viewer pointing at a typical
    /// master. We don't need a real runner — we just want to inspect
    /// the args. Pass through whatever path the test cares about as
    /// stagingDir.
    private func makeViewer(masterHost: String = "RicksM4.local") -> CatalogSync {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-rsync-args-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = CatalogSyncPaths(
            liveDir: root.appendingPathComponent("live"),
            stagingDir: root.appendingPathComponent("staging"),
            previousDir: root.appendingPathComponent("previous"),
            lastSyncFile: root.appendingPathComponent("last_sync.txt")
        )
        return makeSync(
            paths: paths,
            localHost: "ricksm5.local",   // viewer
            masterHost: masterHost,
            runner: StubRsync(sourceTree: paths.liveDir)
        )
    }

    @Test
    func remoteSourcePathEscapesTheSpaceInApplicationSupport() {
        let sync = makeViewer()
        let staging = URL(fileURLWithPath: "/tmp/staging")
        let args = sync.rsyncArguments(stagingDir: staging)

        // The remote source is the argument that ends with VideoScan/
        // (and contains an @ for user@host:).
        guard let source = args.first(where: { $0.contains("@") && $0.hasSuffix("VideoScan/") }) else {
            Issue.record("Expected a remote source arg ending in VideoScan/")
            return
        }

        // Regression: openrsync space-splits without the escape. Pin
        // the backslash-escape into the args so future refactors can't
        // silently reintroduce the "master offline" bug.
        #expect(source.contains(#"Application\ Support"#),
                "Remote source must have a backslash-escaped space in \"Application Support\" so openrsync doesn't split the path: got \(source)")
        #expect(!source.contains("Application Support") || source.contains(#"Application\ Support"#),
                "Unescaped space must not appear in the remote source path")
    }

    @Test
    func remoteSourceTargetsMasterHostnameAndRemoteUser() {
        let sync = makeViewer(masterHost: "RicksM4.local")
        let staging = URL(fileURLWithPath: "/tmp/staging")
        let args = sync.rsyncArguments(stagingDir: staging)
        let source = args.first(where: { $0.contains("@") })
        #expect(source != nil)
        #expect(source?.hasPrefix("rickb@RicksM4.local:") == true,
                "Remote source must be rickb@<master>:; got \(source ?? "nil")")
    }

    @Test
    func sshOptionsIncludeBatchModeAndConnectTimeout() {
        // Tight reachability gate so a master-offline viewer doesn't
        // hang the launch; BatchMode so a missing key fails fast
        // instead of prompting.
        let sync = makeViewer()
        let args = sync.rsyncArguments(stagingDir: URL(fileURLWithPath: "/tmp/staging"))
        guard let dashE = args.firstIndex(of: "-e"), dashE + 1 < args.count else {
            Issue.record("Expected -e <ssh opts> in rsync args")
            return
        }
        let sshOpts = args[dashE + 1]
        #expect(sshOpts.contains("BatchMode=yes"))
        #expect(sshOpts.contains("ConnectTimeout="))
    }

    @Test
    func includesCatalogJsonAndManifestAndPoiTree() {
        let sync = makeViewer()
        let args = sync.rsyncArguments(stagingDir: URL(fileURLWithPath: "/tmp/staging"))
        #expect(args.contains("--include=catalog.json"))
        #expect(args.contains("--include=catalog.json.prev"))
        #expect(args.contains("--include=manifest.sha256"))
        #expect(args.contains("--include=POI/"))
        #expect(args.contains("--include=POI/**"))
        #expect(args.contains("--exclude=*"),
                "Excludes-all-else must come AFTER the includes so they win.")
    }

    @Test
    func stagingDestEndsWithTrailingSlash() {
        // rsync semantics: trailing slash on the source mirrors the
        // *contents*, not the directory itself. Same convention on
        // dest avoids the "VideoScan/VideoScan/" mistake.
        let sync = makeViewer()
        let staging = URL(fileURLWithPath: "/tmp/staging")
        let args = sync.rsyncArguments(stagingDir: staging)
        #expect(args.last == "/tmp/staging/")
    }
}
