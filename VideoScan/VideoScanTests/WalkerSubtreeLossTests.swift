import Testing
import Foundation
import Darwin
@testable import VideoScan

// MARK: - Walker subtree-loss regression suite (2026-07-02 incident)
//
// Incident shape: an InternalRaid scan discovered 4,007 of 37,855 files.
// Seven ENTIRE top-level subtrees were never entered. Mechanism: process-wide
// fd exhaustion (see ProcessRunnerFdLifecycleTests) made contentsOfDirectory
// fail with Cocoa error 256 on directories that read fine in isolation. The
// walker recorded each failure honestly (the audit honesty hook worked — no
// records were pruned), but one TRANSIENT enumeration failure still cost the
// whole subtree for that scan.
//
// Defenses pinned here:
//   1. `listDirectoryWithRetry` — a transient enumeration failure (the
//      EMFILE/fd-pressure class) is retried with a short backoff before the
//      subtree is declared unreadable. External fd pressure (June-30: a 7h
//      PersonFinder job in the same process) can still starve the walker;
//      retry rides out the transient case.
//   2. Stack integrity — an unreadable directory mid-stack never costs any
//      SIBLING subtree, and lands in the audit exactly once.
//   3. No silent classification hole — an entry that is neither a directory
//      nor a regular file (symlink, fifo, socket) is COUNTED in the audit
//      instead of vanishing with no trace.
//   4. Real-volume sensor (gated on the LaCie being mounted) — the walker
//      must see every subtree of the directory that lost
//      TripAcrossCountry_1995_video-only in the incident.

// MARK: 1. Bounded retry for directory enumeration

@Suite("Directory-listing retry — transient enumeration failures")
struct DirectoryListingRetryTests {

    private struct FakeListingError: Error {}

    /// The incident signature: Cocoa 256 (NSFileReadUnknownError), which is
    /// what `contentsOfDirectory` throws under process-wide fd pressure —
    /// optionally wrapping the underlying POSIX EMFILE.
    private static func fdPressureError(underlyingPosixCode: Int32? = EMFILE) -> NSError {
        var userInfo: [String: Any] = [:]
        if let code = underlyingPosixCode {
            userInfo[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain,
                                                     code: Int(code))
        }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                       userInfo: userInfo)
    }

    /// Deterministic failure: Cocoa 257 (NSFileReadNoPermissionError) with
    /// underlying EACCES — a genuinely permission-denied directory. Retrying
    /// this can never succeed.
    private static func permissionDeniedError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain,
                                                         code: Int(EACCES))])
    }

    @Test("Transient fd-pressure failure (Cocoa 256) recovers on retry — subtree is NOT lost")
    func transientFailureRecoversOnRetry() throws {
        let dir = URL(fileURLWithPath: "/tmp/fake")
        let expected = [URL(fileURLWithPath: "/tmp/fake/a.mov")]
        var attempts = 0
        let contents = try FilesystemWalker.listDirectoryWithRetry(
            at: dir,
            retryDelaysMicroseconds: [1, 1]   // keep the test fast
        ) { _ in
            attempts += 1
            if attempts == 1 { throw Self.fdPressureError() }
            return expected
        }
        #expect(contents == expected)
        #expect(attempts == 2)
    }

    @Test("Bare Cocoa 256 with no underlying error is still retried")
    func bareCocoa256IsRetried() throws {
        var attempts = 0
        let contents = try FilesystemWalker.listDirectoryWithRetry(
            at: URL(fileURLWithPath: "/tmp/fake"),
            retryDelaysMicroseconds: [1, 1]
        ) { _ in
            attempts += 1
            if attempts == 1 { throw Self.fdPressureError(underlyingPosixCode: nil) }
            return []
        }
        #expect(contents.isEmpty)
        #expect(attempts == 2)
    }

    @Test("Persistent fd-pressure failure throws after the bounded attempt budget")
    func persistentFailureThrowsAfterBoundedAttempts() {
        let dir = URL(fileURLWithPath: "/tmp/fake")
        var attempts = 0
        #expect(throws: (any Error).self) {
            try FilesystemWalker.listDirectoryWithRetry(
                at: dir,
                retryDelaysMicroseconds: [1, 1]
            ) { _ in
                attempts += 1
                throw Self.fdPressureError()
            }
        }
        #expect(attempts == 3, "one initial attempt + one per retry delay")
    }

    /// regression: QA 2026-07-02 — retry is for the TRANSIENT fd-pressure
    /// class only. A permission-denied directory (Cocoa 257 / EACCES) is
    /// deterministic; retrying burns 3 attempts + 0.5 s of sleep per
    /// directory, which adds up to minutes on foreign-ownership volumes.
    /// It must fail straight to the audit on the first attempt.
    @Test("Permission-denied (Cocoa 257) fails immediately — no retry, no sleep")
    func permissionDeniedFailsImmediately() {
        var attempts = 0
        #expect(throws: (any Error).self) {
            try FilesystemWalker.listDirectoryWithRetry(
                at: URL(fileURLWithPath: "/tmp/fake"),
                retryDelaysMicroseconds: [1, 1]
            ) { _ in
                attempts += 1
                throw Self.permissionDeniedError()
            }
        }
        #expect(attempts == 1,
                "deterministic errors must not consume the retry budget")
    }

    @Test("Unrecognized error classes fail immediately — retry is 256/EMFILE-only")
    func unknownErrorClassFailsImmediately() {
        var attempts = 0
        #expect(throws: FakeListingError.self) {
            try FilesystemWalker.listDirectoryWithRetry(
                at: URL(fileURLWithPath: "/tmp/fake"),
                retryDelaysMicroseconds: [1, 1]
            ) { _ in
                attempts += 1
                throw FakeListingError()
            }
        }
        #expect(attempts == 1)
    }

    @Test("First-try success never sleeps or retries")
    func firstTrySuccessDoesNotRetry() throws {
        var attempts = 0
        let contents = try FilesystemWalker.listDirectoryWithRetry(
            at: URL(fileURLWithPath: "/tmp/fake"),
            retryDelaysMicroseconds: [1, 1]
        ) { _ in
            attempts += 1
            return []
        }
        #expect(contents.isEmpty)
        #expect(attempts == 1)
    }
}

// MARK: - Shared fixture helpers

private func makeTempTree(_ name: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_walkloss_\(name)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func collectStream(
    root: URL,
    audit: DiscoveryAuditCollector,
    videoExtensions: Set<String> = ["mov", "mpg", "mp4", "m2v"],
    probeExtensionless: Bool = false
) async -> [String] {
    var found: [String] = []
    let stream = FilesystemWalker.walkDirectoryStream(
        root: root.path,
        videoExtensions: videoExtensions,
        skipDirs: [],
        skipBundleExtensions: [],
        skipSmallFiles: false,
        probeExtensionless: probeExtensionless,
        audit: audit
    )
    for await url in stream {
        found.append(url.path)
    }
    return found
}

// MARK: 2 + 3. Walk integrity over a synthetic tree

@Suite("Walk integrity — unreadable directories and non-regular entries")
struct WalkIntegrityTests {

    /// regression: 2026-07-02 InternalRaid — an unreadable directory in the
    /// middle of the DFS stack must not cost any sibling subtree, and must
    /// land in the audit exactly once (after the retry budget).
    @Test("Unreadable directory loses only itself; siblings walk fully; audit says why")
    func unreadableDirectoryDoesNotLoseSiblings() async throws {
        let fm = FileManager.default
        let root = try makeTempTree("locked")
        defer {
            chmod(root.appendingPathComponent("locked").path, 0o755)
            try? fm.removeItem(at: root)
        }
        let payload = Data(repeating: 0x42, count: 32)

        // Siblings around the locked directory, one with a nested level so
        // the DFS stack holds pending entries when the failure hits.
        for sub in ["a_before", "z_after"] {
            let d = root.appendingPathComponent(sub)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            try payload.write(to: d.appendingPathComponent("\(sub).mov"))
        }
        let deep = root.appendingPathComponent("z_after/deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try payload.write(to: deep.appendingPathComponent("deep.mov"))

        let locked = root.appendingPathComponent("locked")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try payload.write(to: locked.appendingPathComponent("hidden.mov"))
        #expect(chmod(locked.path, 0o000) == 0)

        let audit = DiscoveryAuditCollector(scanRoot: root.path, volumeName: "test")
        let found = await collectStream(root: root, audit: audit)

        #expect(found.contains { $0.hasSuffix("a_before/a_before.mov") })
        #expect(found.contains { $0.hasSuffix("z_after/z_after.mov") })
        #expect(found.contains { $0.hasSuffix("deep/deep.mov") })
        #expect(!found.contains { $0.hasSuffix("hidden.mov") })

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.directoryEnumerationErrors == 1,
                "the unreadable directory must be recorded exactly once")
        #expect(snapshot.unreadableDirectories.first?.contains("locked") == true)
    }

    /// regression: silent classification hole — an entry that is neither a
    /// directory nor a regular file used to vanish with no audit trace.
    @Test("Non-regular entries (fifo, symlink) are audited, never silently dropped")
    func nonRegularEntriesAreAudited() async throws {
        let fm = FileManager.default
        let root = try makeTempTree("nonreg")
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0x42, count: 32)
            .write(to: root.appendingPathComponent("real.mov"))
        #expect(mkfifo(root.appendingPathComponent("pipe.mov").path, 0o644) == 0)
        try fm.createSymbolicLink(
            at: root.appendingPathComponent("link.mov"),
            withDestinationURL: root.appendingPathComponent("real.mov")
        )

        let audit = DiscoveryAuditCollector(scanRoot: root.path, volumeName: "test")
        let found = await collectStream(root: root, audit: audit)

        #expect(found.count == 1, "only the regular file is admitted")
        #expect(found.first?.hasSuffix("real.mov") == true)

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.skippedNonRegularEntries == 2,
                "fifo + symlink must both be counted")
        #expect(snapshot.directoryEnumerationErrors == 0)
        #expect(snapshot.unreadableFiles == 0)
    }
}

// MARK: 4. Real-volume sensor (gated)

@Suite("Real-volume walk sensor — InternalRaid incident directory")
struct RealVolumeWalkSensorTests {

    static let incidentRoot =
        "/Volumes/LaCieWorkspace/CheesegraterArchive/InternalRaid/MiscVideoProjects"

    /// Read-only sensor against the directory the 2026-07-02 incident lost.
    /// Runs only when the LaCie archive is mounted (M4 Studio); asserts the
    /// walker sees every subtree — including TripAcrossCountry_1995_video-only,
    /// whose extensionless video-only exports (t2-v, t3-v) were the headline
    /// casualties.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: incidentRoot)))
    func walkerSeesEverySubtreeOfIncidentDirectory() async throws {
        let audit = DiscoveryAuditCollector(scanRoot: Self.incidentRoot, volumeName: "MiscVideoProjects")
        let found = await collectStream(
            root: URL(fileURLWithPath: Self.incidentRoot),
            audit: audit,
            videoExtensions: ["mov", "mpg", "mp4", "m2v", "dv", "avi"],
            probeExtensionless: true
        )

        #expect(found.contains { $0.contains("TripAcrossCountry_1995_video-only/") },
                "the walker must discover files inside TripAcrossCountry_1995_video-only")

        let prefix = Self.incidentRoot + "/"
        let subtrees = Set(found.compactMap { path -> String? in
            guard path.hasPrefix(prefix) else { return nil }
            let rel = path.dropFirst(prefix.count)
            guard rel.contains("/") else { return nil }
            return rel.split(separator: "/").first.map(String.init)
        })
        for expected in ["Christmas2006-video-only",
                         "Kids & Gerbels Oct 2007",
                         "Old1960sMovie-with3-song.mpg",
                         "TripAcrossCountry_1995_video-only"] {
            #expect(subtrees.contains(expected), "subtree \(expected) was not walked")
        }

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.directoryEnumerationErrors == 0,
                "every subtree of the incident directory is readable in isolation")
    }
}
