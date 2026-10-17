// ScanStillBeingWrittenTests.swift
// Verify Catalog bug 3 (2026-10-17): a combined archive output was catalogued
// at 450 MB at the same second as its mtime; on disk it is 944 MB. The scan
// built a row from a stat and an ffprobe of a file that was still being
// written. Rule (ScanWriteInProgress): stat before and after ffprobe; a size
// or mtime that differs, or an mtime inside the settle window (60 s), means
// the file is SKIPPED this scan — "still being written — rescan later" — in
// the discovery audit, the console line and nowhere in the catalog.
//
// The settle window is 0 under the test host (every scan test writes its
// fixtures seconds before scanning); the pins below set it to the production
// value explicitly, and one test pins both defaults.
//
// Dimensions: LOGIC (the pure rule; the end-to-end skip and its words; a
// settled file still catalogued), ISOLATION (the second stat through the
// seam on a real file that grows between the two stats; a file gone after
// the probe), SENSOR (production/test-host defaults).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Scan — a file still being written is skipped, not catalogued", .serialized)
@MainActor
struct ScanStillBeingWrittenTests {

    private struct Sandbox {
        let root: URL
        let model: VideoScanModel
        var files: URL { root.appendingPathComponent("files", isDirectory: true) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func catalogLogText() -> String {
            (try? String(contentsOf: root.appendingPathComponent("logs/catalog.log"), encoding: .utf8)) ?? ""
        }
    }

    private static func sandbox(_ label: String) throws -> Sandbox {
        var root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_stillwriting_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        if let canonical = try root.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            root = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        let model = VideoScanModel(logDirectory: root.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: root.appendingPathComponent("ledger", isDirectory: true))
        var opts = ScanOptions()
        opts.skipSmallFiles = false
        opts.skipChecksums = true
        model.scanOptions = opts
        model.scanTargets.removeAll()
        // The production window; the test host's default is 0 (see `defaults`).
        model.scanSettleSeconds = ScanWriteInProgress.settleSeconds
        return Sandbox(root: root, model: model)
    }

    /// A real (tiny) QuickTime file ffprobe can read, moved into `sb.files`.
    private static func movie(in sb: Sandbox, named name: String) throws -> String {
        let generated = try TestMediaGenerator.generate(container: "mov", streams: .videoOnly, duration: 1.0, prefix: "test_stillwriting")
        let path = sb.files.appendingPathComponent(name).path
        try FileManager.default.moveItem(atPath: generated, toPath: path)
        return path
    }

    /// Backdate the file so the settle window does not apply to it.
    private static func settle(_ path: String) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: path)
    }

    private static func runScan(_ model: VideoScanModel, root: String) async {
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets.append(target)
        model.startTarget(target)
        await ScanTaskAwait.value(of: target)
    }

    private static func stat(_ size: Int64, ago: TimeInterval, now: Date) -> ScanFileStat {
        ScanFileStat(sizeBytes: size, modifiedAt: now.addingTimeInterval(-ago))
    }

    // MARK: Logic — the rule

    @Test("the rule: a size or mtime that differs between the two stats, an mtime inside the settle window, or a file gone after the probe → a reason; otherwise nil")
    func rule() {
        let now = Date()
        let settled = Self.stat(450_000_000, ago: 600, now: now)
        #expect(ScanWriteInProgress.reason(before: settled, after: settled, now: now, settleSeconds: 60) == nil)
        let grew = ScanWriteInProgress.reason(before: settled, after: Self.stat(944_000_000, ago: 600, now: now), now: now, settleSeconds: 60)
        #expect(grew?.contains("size changed under the probe") == true, Comment(rawValue: grew ?? "nil"))
        #expect(grew?.contains("944,000,000") == true, Comment(rawValue: grew ?? "nil"))
        let touched = ScanWriteInProgress.reason(before: settled, after: Self.stat(450_000_000, ago: 599, now: now), now: now, settleSeconds: 60)
        #expect(touched == "modified under the probe")
        let recent = Self.stat(450_000_000, ago: 10, now: now)
        let young = ScanWriteInProgress.reason(before: recent, after: recent, now: now, settleSeconds: 60)
        #expect(young == "modified 10 s ago (inside the 60 s settle window)")
        #expect(ScanWriteInProgress.reason(before: recent, after: recent, now: now, settleSeconds: 0) == nil, "a 0 s window never fires")
        #expect(ScanWriteInProgress.reason(before: settled, after: nil, now: now, settleSeconds: 60) == "gone after the probe")
    }

    // MARK: Logic — the scan

    @Test("RED 2026-10-17: a file whose mtime is inside the settle window is left out of the catalog, counted in the audit and said on the console")
    func justWrittenFileIsLeftOut() async throws {
        let sb = try Self.sandbox("recent"); defer { sb.cleanup() }
        let path = try Self.movie(in: sb, named: "combined_output.mov")
        await Self.runScan(sb.model, root: sb.files.path)
        #expect(!sb.model.records.contains { $0.fullPath == path }, "catalogued a file written seconds ago")
        let audit = try #require(sb.model.lastDiscoveryAudit)
        #expect(audit.filesCataloged == 0)
        #expect(audit.stillBeingWritten == 1)
        #expect(audit.stillBeingWrittenPaths == [path])
        let console = sb.catalogLogText()
        #expect(console.contains("SKIPPED: combined_output.mov — still being written — rescan later"), Comment(rawValue: console))
        #expect(console.contains("1 file(s) still being written — rescan later — not cataloged"), Comment(rawValue: console))
        #expect(!console.contains("FAILED: combined_output.mov"), "a skip is not a probe failure")
    }

    @Test("a settled file (mtime outside the window, unchanged under the probe) is catalogued as before and the audit counts nothing")
    func settledFileIsCatalogued() async throws {
        let sb = try Self.sandbox("settled"); defer { sb.cleanup() }
        let path = try Self.movie(in: sb, named: "settled.mov")
        try Self.settle(path)
        await Self.runScan(sb.model, root: sb.files.path)
        #expect(sb.model.records.contains { $0.fullPath == path })
        let audit = try #require(sb.model.lastDiscoveryAudit)
        #expect(audit.stillBeingWritten == 0)
        #expect(audit.filesCataloged == 1)
    }

    // MARK: Isolation — the second stat through the seam

    @Test("a file that grows between the stat before and the stat after ffprobe is skipped with the size in the reason, and the probe cache never learns it")
    func fileThatGrowsUnderTheProbeIsSkipped() async throws {
        let sb = try Self.sandbox("grows"); defer { sb.cleanup() }
        let path = try Self.movie(in: sb, named: "growing.mov")
        try Self.settle(path)
        let url = URL(fileURLWithPath: path)
        let sizeBefore = try #require(ScanFileStat.of(path: path)).sizeBytes
        sb.model.scanSecondStatForTesting = { p in
            // The writer is still going: a megabyte lands between the two stats.
            if let h = FileHandle(forWritingAtPath: p) {
                h.seekToEndOfFile()
                h.write(Data(repeating: 0x5A, count: 1_000_000))
                h.closeFile()
            }
            return ScanFileStat.of(path: p)
        }
        let outcome = await sb.model.probeFileOutcome(url: url)
        #expect(outcome.stillBeingWritten)
        #expect(outcome.probe.streamTypeRaw == StreamType.ffprobeFailed.rawValue)
        #expect(outcome.probe.isPlayable == "Still being written")
        #expect(outcome.notes.contains("still being written — rescan later — size changed under the probe"), Comment(rawValue: outcome.notes))
        #expect(outcome.sizeBytes == sizeBefore, "the outcome carries the first stat, never a half-written size")
        // Nothing was cached for it: a later probe (file settled again) reads the file.
        sb.model.scanSecondStatForTesting = nil
        try Self.settle(path)
        let again = await sb.model.probeFileOutcome(url: url)
        #expect(!again.wasCacheHit)
        #expect(!again.stillBeingWritten)
    }

    @Test("a file gone after the probe is skipped, not catalogued from the stale first stat")
    func fileGoneAfterTheProbeIsSkipped() async throws {
        let sb = try Self.sandbox("gone"); defer { sb.cleanup() }
        let path = try Self.movie(in: sb, named: "gone.mov")
        try Self.settle(path)
        sb.model.scanSecondStatForTesting = { _ in nil }
        let outcome = await sb.model.probeFileOutcome(url: URL(fileURLWithPath: path))
        #expect(outcome.stillBeingWritten)
        #expect(outcome.notes.contains("gone after the probe"), Comment(rawValue: outcome.notes))
    }

    // MARK: Sensor — the defaults

    @Test("defaults: the app settles for 60 s; a test host for 0 (its scans fixture-then-scan at once); this process is a test host")
    func defaults() {
        #expect(ScanWriteInProgress.settleSeconds == 60)
        #expect(ScanWriteInProgress.defaultSettleSeconds(isTestHost: false) == 60)
        #expect(ScanWriteInProgress.defaultSettleSeconds(isTestHost: true) == 0)
        #expect(TestEnvironment.isTestHost, "fixture sanity")
        #expect(VideoScanModel(logDirectory: FileManager.default.temporaryDirectory).scanSettleSeconds == 0)
        #expect(ScanWriteInProgress.skipWords == "still being written — rescan later")
    }
}
