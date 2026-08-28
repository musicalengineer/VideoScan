// FamilySearchPullMergeTests.swift
// "Add to current tree" on the Get Family Tree sheet (2026-08-27): the
// coordinator merges the verified export with the tree the loader reads,
// writes ONE new .ged next to the current one, and leaves both sources
// byte-for-byte untouched. ISOLATION: a temp GEDCOM folder; nothing near
// the archive. Same harness shape as FamilySearchPullLifecycleTests.

import CryptoKit
import Foundation
import XCTest
@testable import VideoScan
import VideoScanCore

@MainActor
final class FamilySearchPullMergeTests: XCTestCase {
    private struct SilentLauncher: FamilySearchPullLauncher { func open(_ url: URL) {} }

    private var root: URL!
    private var gedcomDirectory: URL!
    private var staging: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("fs-merge-\(UUID().uuidString)", isDirectory: true)
        gedcomDirectory = root.appendingPathComponent("GEDCOM", isDirectory: true)
        staging = root.appendingPathComponent("Downloads", isDirectory: true)
        for dir in [gedcomDirectory!, staging!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let rickPull = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID GVQV-NW3
    0 @I2@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 FAMS @F1@
    1 _FSFTID G2CL-86B
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I2@
    0 TRLR
    """
    private static let donnaPull = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 FAMC @F1@
    1 _FSFTID G2CL-86B
    0 @I2@ INDI
    1 NAME Walter /Hudson/
    1 SEX M
    1 FAMS @F1@
    1 _FSFTID DON1-DAD
    0 @F1@ FAM
    1 HUSB @I2@
    1 CHIL @I1@
    0 TRLR
    """

    private var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }

    private func makeCoordinator(parseDelay: Duration = .zero) -> FamilySearchPullCoordinator {
        FamilySearchPullCoordinator(
            gedcomDirectory: gedcomDirectory,
            defaultUsername: "rick@example.com",
            scriptURL: staging.appendingPathComponent("get-family-tree.command"),
            stagingDirectory: stagingRoot,
            locator: FamilySearchToolLocator(overridePath: "/nonexistent/getmyancestors"),
            launcher: SilentLauncher(),
            pollInterval: .milliseconds(30),
            parseDelay: parseDelay)
    }

    private func gedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: gedcomDirectory.path).filter { $0.hasSuffix(".ged") }.sorted()
    }

    /// Both sources written, coordinator parsed and .ready.
    private func readyCoordinator(parseDelay: Duration = .zero) async throws -> (FamilySearchPullCoordinator, URL, URL) {
        let current = gedcomDirectory.appendingPathComponent("familysearch-tree-20generations.ged")
        try Self.rickPull.write(to: current, atomically: true, encoding: .utf8)
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: download, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator(parseDelay: parseDelay)
        coordinator.installFromFile(download)
        await waitForReady(coordinator)
        return (coordinator, current, download)
    }

    private func waitForReady(_ coordinator: FamilySearchPullCoordinator) async {
        for _ in 0..<400 {
            if case .ready = coordinator.phase { return }
            if case .failed = coordinator.phase { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAddToCurrentTreeWritesANewMergedFileAndLeavesSourcesUntouched() async throws {
        let fm = FileManager.default
        let current = gedcomDirectory.appendingPathComponent("familysearch-tree-20generations.ged")
        try Self.rickPull.write(to: current, atomically: true, encoding: .utf8)
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: download, atomically: true, encoding: .utf8)
        let currentBytes = try Data(contentsOf: current)
        let downloadBytes = try Data(contentsOf: download)

        let coordinator = makeCoordinator()
        coordinator.installFromFile(download)
        await waitForReady(coordinator)
        guard case .ready(_, _, let existing, _) = coordinator.phase else {
            return XCTFail("expected .ready, got \(coordinator.phase)")
        }
        XCTAssertEqual(existing?.people, 2)

        await coordinator.installMerged().value
        guard case .installed(let merged, let people) = coordinator.phase else {
            return XCTFail("expected .installed, got \(coordinator.phase)")
        }
        XCTAssertEqual(people, 3, "Rick + Donna (once) + Walter")
        XCTAssertTrue(merged.lastPathComponent.hasPrefix("familysearch-merged-"))
        XCTAssertEqual(merged.deletingLastPathComponent().path, gedcomDirectory.path)
        // Sources untouched, byte for byte.
        XCTAssertEqual(try Data(contentsOf: current), currentBytes)
        XCTAssertEqual(try Data(contentsOf: download), downloadBytes)
        XCTAssertEqual(try gedFiles().count, 2)
        // SHA-256 sidecars beside BOTH raw sources; no staging left behind.
        let currentSidecar = try String(contentsOf: current.appendingPathExtension("sha256"), encoding: .utf8)
        let downloadSidecar = try String(contentsOf: download.appendingPathExtension("sha256"), encoding: .utf8)
        XCTAssertEqual(currentSidecar.split(separator: " ").first?.count, 64)
        XCTAssertTrue(downloadSidecar.hasSuffix("familysearch-donna-20generations.ged\n"))
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: stagingRoot.path))?.count ?? 0, 0, "staging cleaned up")
        XCTAssertFalse(fm.fileExists(atPath: merged.appendingPathExtension("partial").path))

        // The loader now reads the merged tree: Donna has her father, both roots named.
        let loaded = try XCTUnwrap(FamilyGraphFileLoader(originalsDirectory: gedcomDirectory).loadNewestOutcome())
        // /var vs /private/var: compare the resolved paths.
        XCTAssertEqual(loaded.selectedURL?.resolvingSymlinksInPath().path, merged.resolvingSymlinksInPath().path)
        let graph = try XCTUnwrap(loaded.graph)
        XCTAssertEqual(graph.roots.map(\.name), ["Richard Harding Breen Jr", "Donna Hudson"])
        XCTAssertEqual(graph.sourceFileNames, ["familysearch-tree-20generations.ged", "familysearch-donna-20generations.ged"])
        let donna = try XCTUnwrap(graph.person(familySearchID: "G2CL-86B"))
        XCTAssertEqual(graph.relatives(.father, of: donna).map(\.name), ["Walter Hudson"])
        XCTAssertEqual(graph.relatives(.husband, of: donna).map(\.name), ["Richard Harding Breen Jr"])
        let text = try String(contentsOf: merged, encoding: .utf8)
        XCTAssertTrue(text.contains("1 NOTE Derived VideoScan merge artifact (lossy: names, vitals, links, FSIDs)"))
        XCTAssertTrue(text.contains("2 CONT sources: familysearch-tree-20generations.ged (sha256 " + String(currentSidecar.prefix(64))))
        XCTAssertTrue(text.contains("conflict familyKeptSeparate") == false, "nothing to keep separate in this fixture")
        XCTAssertTrue(text.contains("2 CONT Loss: 0 source lines"))
        XCTAssertTrue(text.contains("1 _VS_MERGED Y"))
        // codex #780: names + SHA-256 only, never an absolute path.
        XCTAssertFalse(text.contains(staging.path), "absolute path of the download leaked into the artifact")
        XCTAssertFalse(text.contains(gedcomDirectory.path))
        // The sources line is longer than one GEDCOM line (CONC-split in
        // `text`); check the parsed, re-joined HEAD NOTE.
        let note = try XCTUnwrap(graph.headNote)
        XCTAssertTrue(note.contains("familysearch-donna-20generations.ged (sha256 " + String(downloadSidecar.prefix(64)) + "; 2 people; added)"), note)
        XCTAssertTrue(note.hasPrefix("Derived VideoScan merge artifact (lossy: names, vitals, links, FSIDs)"))
        XCTAssertFalse(note.contains("/"), "no path separators at all in the provenance")
        XCTAssertTrue(graph.isMergedArtifact)
        XCTAssertTrue(text.contains("1 _VS_ROOT @I1@\n1 _VS_ROOT @I2@"))
        XCTAssertTrue(text.contains("1 _FSFTID DON1-DAD"))
    }

    /// codex #773: Keep current AFTER the staged write must leave the
    /// active folder exactly as it was.
    func testCancelAfterStagedWriteLeavesActiveDirectoryUnchanged() async throws {
        let (coordinator, _, _) = try await readyCoordinator(parseDelay: .milliseconds(400))
        guard case .ready = coordinator.phase else { return XCTFail("expected .ready, got \(coordinator.phase)") }
        let before = try gedFiles()
        let task = coordinator.installMerged()
        XCTAssertTrue(coordinator.isInstalling)
        // The staged write is quick; the 400 ms pacing sits between it and
        // the activation check. Cancel inside that window.
        try await Task.sleep(for: .milliseconds(150))
        coordinator.cancel()
        await task.value
        XCTAssertEqual(try gedFiles(), before)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.count ?? 0, 0)
        XCTAssertFalse(coordinator.isInstalling)
        if case .installed = coordinator.phase { XCTFail("cancelled merge must not activate") }
    }

    func testDoubleAddProducesOneFile() async throws {
        let (coordinator, _, _) = try await readyCoordinator()
        let first = coordinator.installMerged()
        let second = coordinator.installMerged()
        await first.value
        await second.value
        XCTAssertEqual(try gedFiles().filter { $0.hasPrefix("familysearch-merged-") }.count, 1)
        guard case .installed = coordinator.phase else { return XCTFail("expected .installed, got \(coordinator.phase)") }
        // A third Add after settling is refused: the phase is no longer .ready.
        await coordinator.installMerged().value
        XCTAssertEqual(try gedFiles().filter { $0.hasPrefix("familysearch-merged-") }.count, 1)
    }

    func testAddRacingReplaceIsSerializedAddWins() async throws {
        let (coordinator, _, _) = try await readyCoordinator(parseDelay: .milliseconds(200))
        let task = coordinator.installMerged()      // synchronously claims the install
        coordinator.install()                        // Replace while Add is in flight → refused
        await task.value
        let files = try gedFiles()
        XCTAssertEqual(files.count, 2, "current + merged only; Replace never copied")
        XCTAssertEqual(files.filter { $0.hasPrefix("familysearch-merged-") }.count, 1)
        XCTAssertEqual(files.filter { $0.hasPrefix("familysearch-2") }.count, 0)
        guard case .installed(let url, _) = coordinator.phase else { return XCTFail("expected .installed, got \(coordinator.phase)") }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("familysearch-merged-"))
    }

    func testReplaceThenAddIsSerializedReplaceWins() async throws {
        let (coordinator, _, _) = try await readyCoordinator()
        coordinator.install()                        // Replace settles synchronously
        await coordinator.installMerged().value      // phase is .installed → refused
        let files = try gedFiles()
        XCTAssertEqual(files.filter { $0.hasPrefix("familysearch-merged-") }.count, 0)
        XCTAssertEqual(files.filter { $0.hasPrefix("familysearch-2") }.count, 1)
    }

    func testAddToCurrentTreeWithNoCurrentTreeFailsHonestly() async throws {
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: download, atomically: true, encoding: .utf8)
        let coordinator = makeCoordinator()
        coordinator.installFromFile(download)
        await waitForReady(coordinator)
        await coordinator.installMerged().value
        guard case .failed(let message) = coordinator.phase else {
            return XCTFail("expected .failed, got \(coordinator.phase)")
        }
        XCTAssertTrue(message.contains("no current tree"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gedcomDirectory.path).count, 0)
    }

    // MARK: - codex #790: the fingerprint is the bytes, never the sidecar

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Same path, replaced bytes, stale sidecar → the NEW digest, and the
    /// sidecar is corrected to match.
    func testStaleSidecarIsNeverTrustedWhenBytesChange() throws {
        let fm = FileManager.default
        let file = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.rickPull.write(to: file, atomically: true, encoding: .utf8)
        let first = try XCTUnwrap(FamilySearchPullCoordinator.sha256Sidecar(for: file, fileManager: fm))
        XCTAssertEqual(first, sha256Hex(Data(Self.rickPull.utf8)))
        let sidecar = file.appendingPathExtension("sha256")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "\(first)  familysearch-donna-20generations.ged\n")

        // The reused-download path: a new export lands on the same name.
        try Self.donnaPull.write(to: file, atomically: true, encoding: .utf8)
        let second = try XCTUnwrap(FamilySearchPullCoordinator.sha256Sidecar(for: file, fileManager: fm))
        XCTAssertNotEqual(second, first, "old fingerprint handed to new bytes")
        XCTAssertEqual(second, sha256Hex(Data(Self.donnaPull.utf8)))
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "\(second)  familysearch-donna-20generations.ged\n", "sidecar corrected")

        // A hand-edited (garbage but well-formed) sidecar is ignored too.
        let bogus = String(repeating: "ab", count: 32)
        try "\(bogus)  familysearch-donna-20generations.ged\n".write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(FamilySearchPullCoordinator.sha256Sidecar(for: file, fileManager: fm), second)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "\(second)  familysearch-donna-20generations.ged\n")
    }

    /// A read failure mid-file → NO fingerprint (nil), never the hash of
    /// the prefix that did arrive; the sidecar is left as it was.
    func testReadFailureMidFileYieldsNoFingerprintNotAPrefixHash() throws {
        struct Injected: Error {}
        let fm = FileManager.default
        let file = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        try Self.donnaPull.write(to: file, atomically: true, encoding: .utf8)
        let bytes = Data(Self.donnaPull.utf8)
        let prefix = bytes.prefix(bytes.count / 2)
        var calls = 0
        let result = FamilySearchPullCoordinator.sha256Sidecar(for: file, fileManager: fm) { _ in
            return {
                calls += 1
                if calls == 1 { return Data(prefix) }
                throw Injected()
            }
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 2)
        XCTAssertNotEqual(result, sha256Hex(Data(prefix)), "a partial read must never yield a digest")
        XCTAssertFalse(fm.fileExists(atPath: file.appendingPathExtension("sha256").path), "no sidecar for a failed read")

        // Open failure and a directory (open succeeds, first read throws EISDIR): nil, not the empty-data hash.
        XCTAssertNil(FamilySearchPullCoordinator.sha256Sidecar(for: staging.appendingPathComponent("missing.ged"), fileManager: fm))
        XCTAssertNil(FamilySearchPullCoordinator.sha256Sidecar(for: staging, fileManager: fm))
        XCTAssertFalse(fm.fileExists(atPath: staging.appendingPathExtension("sha256").path))
    }

    /// End to end: a stale sidecar from a previous pull sits beside the
    /// reused download path. The merged artifact's provenance must carry
    /// the digest of the bytes actually merged, and the loader's graph must
    /// carry that same fingerprint — not the stale one that would make
    /// `sameSource` true against an unrelated file.
    func testMergeUsesTheDigestOfTheActualDownloadBytesNotAStaleSidecar() async throws {
        let download = staging.appendingPathComponent("familysearch-donna-20generations.ged")
        let staleHex = String(repeating: "0", count: 64)
        try "\(staleHex)  familysearch-donna-20generations.ged\n".write(to: download.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
        let (coordinator, _, _) = try await readyCoordinator()
        await coordinator.installMerged().value
        guard case .installed(let merged, _) = coordinator.phase else {
            return XCTFail("expected .installed, got \(coordinator.phase)")
        }
        let expected = sha256Hex(Data(Self.donnaPull.utf8))
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: merged))
        let note = try XCTUnwrap(graph.headNote)
        XCTAssertTrue(note.contains("familysearch-donna-20generations.ged (sha256 \(expected); 2 people; added)"), note)
        XCTAssertFalse(note.contains(staleHex), "stale sidecar digest leaked into provenance")
        XCTAssertEqual(try String(contentsOf: download.appendingPathExtension("sha256"), encoding: .utf8), "\(expected)  familysearch-donna-20generations.ged\n")
    }

    /// Sensor for the merge fallback: with no fingerprint on one side,
    /// FSID-less records are NOT pointer-matched (FSID-only matching).
    func testMissingFingerprintFallsBackToFamilySearchIDOnlyMatching() {
        let a = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Alice /Nolan/
        0 @I2@ INDI
        1 NAME Bob /Nolan/
        1 _FSFTID BOB1-111
        0 TRLR
        """
        let b = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Zed /Other/
        0 @I2@ INDI
        1 NAME Bob /Nolan/
        1 _FSFTID BOB1-111
        0 TRLR
        """
        var current = GedcomFamilyGraph(gedcomText: a)
        var added = GedcomFamilyGraph(gedcomText: b)
        current.sourceFingerprint = "deadbeef"
        added.sourceFingerprint = nil          // read failed → no digest
        let outcome = current.merge(with: added)
        XCTAssertEqual(outcome.sharedPeopleCount, 1, "Bob by FSID only")
        XCTAssertEqual(outcome.addedPeopleCount, 1, "Zed must NOT be pointer-matched onto Alice")
        XCTAssertEqual(outcome.graph.people.count, 3)
        // And the positive control: equal fingerprints DO pointer-match.
        added.sourceFingerprint = "deadbeef"
        XCTAssertEqual(current.merge(with: added).graph.people.count, 2)
    }

}
