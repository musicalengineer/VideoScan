import Testing
import Darwin
import Foundation
@testable import VideoScan

// MARK: - CombineOutputPublishTests
//
// Logic + scale tests for the no-clobber publish Combine uses (see
// CombineOutputPublish.swift and CombineNeverOverwritesTests for the
// end-to-end ffmpeg cases). All files are `test_` prefixed in a per-test
// temp dir.

@Suite(.serialized) @MainActor
struct CombineOutputPublishTests {

    static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_combine_publish_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    // MARK: partial naming

    @Test func partial_isBesideDestination_keepsExtension_andIsRecognised() {
        let final = URL(fileURLWithPath: "/Volumes/X/out/test_clip_combined.mov")
        let a = CombineOutputPublish.uniquePartialURL(for: final)
        let b = CombineOutputPublish.uniquePartialURL(for: final)
        #expect(a != b)
        #expect(a.deletingLastPathComponent() == final.deletingLastPathComponent())
        #expect(a.pathExtension == "mov")
        #expect(a.lastPathComponent.hasPrefix("test_clip_combined."))
        #expect(CombineOutputPublish.isPartialName(a.lastPathComponent))
        // A final name — or a lookalike — is never a partial.
        #expect(!CombineOutputPublish.isPartialName("test_clip_combined.mov"))
        #expect(!CombineOutputPublish.isPartialName("test_clip_combined 2.mov"))
        #expect(!CombineOutputPublish.isPartialName("vs-partial.mov"))
        #expect(!CombineOutputPublish.isPartialName("test.notahex!.vs-partial.mov"))
    }

    @Test func reservePartial_createsAnEmptyExclusiveFile() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let reserved = try (0..<50).map { _ in try CombineOutputPublish.reservePartial(for: final) }
        #expect(Set(reserved).count == 50, "two reservations shared a name")
        for url in reserved {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
            #expect(size == 0)
        }
        #expect(!FileManager.default.fileExists(atPath: final.path))
    }

    @Test func removePartial_refusesAFinalName() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("keep me".utf8).write(to: final)
        #expect(throws: CombineOutputPublish.Failure.self) {
            try CombineOutputPublish.removePartial(final)
        }
        #expect(FileManager.default.fileExists(atPath: final.path))

        let partial = try CombineOutputPublish.reservePartial(for: final)
        try CombineOutputPublish.removePartial(partial)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        try CombineOutputPublish.removePartial(partial)   // already gone = fine
    }

    // MARK: publish

    @Test func publish_freeName_takesIt() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.publish(partial: partial.path, as: final)
        #expect(outcome == .published(final))
        #expect(try Data(contentsOf: final) == Data("new".utf8))
        #expect(Self.names(in: dir) == ["test_clip_combined.mov"])
    }

    @Test func publish_takenNames_goBeside_andNeverTouchExisting() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let two = dir.appendingPathComponent("test_clip_combined 2.mov")
        try Data("original".utf8).write(to: final)
        try Data("second".utf8).write(to: two)

        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.publish(partial: partial.path, as: final)
        let three = dir.appendingPathComponent("test_clip_combined 3.mov")
        guard case .publishedBeside(let url, let kept, _) = outcome else {
            Issue.record("expected publishedBeside, got \(outcome)"); return
        }
        #expect(url == three)
        #expect(kept == final)
        #expect(try Data(contentsOf: final) == Data("original".utf8))
        #expect(try Data(contentsOf: two) == Data("second".utf8))
        #expect(try Data(contentsOf: three) == Data("new".utf8))
    }

    @Test func publish_missingPartial_throws_andTouchesNothing() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("original".utf8).write(to: final)
        let ghost = CombineOutputPublish.uniquePartialURL(for: final)
        #expect(throws: CombineOutputPublish.Failure.self) {
            _ = try CombineOutputPublish.publish(partial: ghost.path, as: final)
        }
        #expect(try Data(contentsOf: final) == Data("original".utf8))
    }

    @Test func publish_concurrentPartials_neverShareAFinalName() async throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let n = 24
        var partials: [URL] = []
        for i in 0..<n {
            let p = try CombineOutputPublish.reservePartial(for: final)
            try Data("payload \(i)".utf8).write(to: p)
            partials.append(p)
        }
        let urls = await withTaskGroup(of: URL?.self) { group in
            for p in partials {
                group.addTask { try? CombineOutputPublish.publish(partial: p.path, as: final).url }
            }
            var out: [URL] = []
            for await u in group { if let u { out.append(u) } }
            return out
        }
        #expect(urls.count == n)
        #expect(Set(urls).count == n, "two publishes landed on one name")
        #expect(Self.names(in: dir).count == n)
        #expect(!Self.names(in: dir).contains { $0.contains("vs-partial") })
    }

    // MARK: prior-output map (the only valid "already done" signal)

    static func combined(dir: String, name: String, group: UUID?) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.directory = dir
        r.fullPath = (dir as NSString).appendingPathComponent(name)
        r.combinedFromPairID = group
        return r
    }

    @Test func priorCombinedOutputs_matchesOnlyThisFolderAndPairGroup() {
        let g1 = UUID(), g2 = UUID()
        let out = URL(fileURLWithPath: "/Volumes/X/out")
        let recs = [
            Self.combined(dir: "/Volumes/X/out", name: "test_a_combined.mov", group: g1),
            Self.combined(dir: "/Volumes/X/elsewhere", name: "test_b_combined.mov", group: g2),
            Self.combined(dir: "/Volumes/X/out", name: "test_c_combined.mov", group: nil),
        ]
        let map = VideoScanModel.priorCombinedOutputs(records: recs, outputFolder: out)
        #expect(map == [g1: "/Volumes/X/out/test_a_combined.mov"])
    }

    /// Scale: one pass per batch over a 100k catalog stays well inside a
    /// click's budget (it runs on the main actor when Combine starts).
    @Test func priorCombinedOutputs_100kRecords_underBudget() {
        let out = URL(fileURLWithPath: "/Volumes/X/out")
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let inOut = i % 10 == 0
            recs.append(Self.combined(dir: inOut ? "/Volumes/X/out" : "/Volumes/X/src\(i % 7)",
                                      name: "test_\(i)_combined.mov",
                                      group: i % 3 == 0 ? UUID() : nil))
        }
        let start = Date()
        let map = VideoScanModel.priorCombinedOutputs(records: recs, outputFolder: out)
        let elapsed = Date().timeIntervalSince(start)
        #expect(map.count == (0..<100_000).filter { $0 % 10 == 0 && $0 % 3 == 0 }.count)
        #expect(elapsed < 1.0, "priorCombinedOutputs took \(elapsed)s for 100k records")
    }
    // MARK: skip decision (Manager ruling 2026-09-22 — unknown provenance → skip)

    @Test func skipDecision_rules() {
        let out = URL(fileURLWithPath: "/Volumes/X/out/test_clip_combined.mov")
        let two = "/Volumes/X/out/test_clip_combined 2.mov"
        let mine = UUID(), other = UUID()
        func decide(_ existing: Set<String>, owners: [String: UUID], group: UUID? = mine,
                    prior: String? = nil) -> VideoScanModel.CombineSkipDecision {
            VideoScanModel.combineSkipDecision(outURL: out, priorOutputPath: prior, pairGroupID: group,
                                               owners: owners, fileExists: { existing.contains($0) })
        }
        // Nothing there → make it.
        #expect(decide([], owners: [:]) == .proceed)
        // This pair's catalogued output still on disk → skip.
        #expect(decide([two], owners: [:], prior: two) == .skipAlreadyCombined(path: two))
        // Unattributed file at the name → skip (legacy / nil group / no record).
        #expect(decide([out.path], owners: [:]) == .skipNameExists(path: out.path))
        #expect(decide([out.path], owners: [:], group: nil) == .skipNameExists(path: out.path))
        // Proven to be this pair's → skip.
        #expect(decide([out.path], owners: [out.path: mine]) == .skipNameExists(path: out.path))
        // Proven to be ANOTHER pair's → proceed (publish lands beside).
        #expect(decide([out.path], owners: [out.path: other]) == .proceed)
        // Other pair's at the name, unattributed " 2" (an earlier run of an
        // ungrouped pair) → skip, don't make " 3".
        #expect(decide([out.path, two], owners: [out.path: other]) == .skipNameExists(path: two))
        #expect(decide([out.path, two], owners: [out.path: other, two: UUID()]) == .proceed)
    }

    // MARK: RENAME_EXCL unsupported (exFAT / msdos / SMB) fallback

    static let enotsup: @Sendable (String, String) -> Int32 = { _, _ in ENOTSUP }

    @Test(arguments: [ENOTSUP, EINVAL])
    func fallback_freeName_publishesViaPlaceholder(_ err: Int32) throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.$renameExclSyscall.withValue({ _, _ in err }) {
            try CombineOutputPublish.publish(partial: partial.path, as: final)
        }
        #expect(outcome == .published(final))
        #expect(try Data(contentsOf: final) == Data("new".utf8))
        #expect(Self.names(in: dir) == ["test_clip_combined.mov"])
        #expect(!PartialFileNaming.isLive(partial))
    }

    @Test func fallback_takenName_goesBeside_andNeverTouchesExisting() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("original".utf8).write(to: final)
        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("new".utf8).write(to: partial)
        let outcome = try CombineOutputPublish.$renameExclSyscall.withValue(Self.enotsup) {
            try CombineOutputPublish.publish(partial: partial.path, as: final)
        }
        #expect(outcome.url.lastPathComponent == "test_clip_combined 2.mov")
        #expect(try Data(contentsOf: final) == Data("original".utf8))
        #expect(try Data(contentsOf: outcome.url) == Data("new".utf8))
    }

    @Test func hardRenameError_throws_andLeavesPartialInPlace() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        let partial = try CombineOutputPublish.reservePartial(for: final)
        try Data("verified".utf8).write(to: partial)
        #expect(throws: CombineOutputPublish.Failure.self) {
            try CombineOutputPublish.$renameExclSyscall.withValue({ _, _ in EIO }) {
                _ = try CombineOutputPublish.publish(partial: partial.path, as: final)
            }
        }
        #expect(try Data(contentsOf: partial) == Data("verified".utf8))
        #expect(!FileManager.default.fileExists(atPath: final.path))
        let kept = CombineOutputPublish.keepUnpublished(partial)
        #expect(kept.lastPathComponent.contains(".vs-kept."))
        #expect(!CombineOutputPublish.isPartialName(kept.lastPathComponent))
        #expect(try Data(contentsOf: kept) == Data("verified".utf8))
    }

    /// The real thing on a real exFAT volume. hdiutil needs to be allowed
    /// in the test host; when it isn't (sandboxed runner), the test says so
    /// and the seam-based fallback tests above carry the coverage.
    @Test func exFAT_realVolume_publishNeverClobbers() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = dir.appendingPathComponent("test_exfat_combine.dmg")
        func hdiutil(_ args: [String]) -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, "\(error)") }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
        }
        let (cs, cOut) = hdiutil(["create", "-size", "64m", "-fs", "ExFAT", "-volname", "test_exfat_combine", dmg.path])
        guard cs == 0 else {
            print("[exFAT] SKIPPED — hdiutil create not permitted in this host: \(cOut)")
            return
        }
        let mountPoint = dir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let (as_, aOut) = hdiutil(["attach", "-nobrowse", "-mountpoint", mountPoint.path, dmg.path])
        guard as_ == 0 else {
            print("[exFAT] SKIPPED — hdiutil attach not permitted in this host: \(aOut)")
            return
        }
        defer { _ = hdiutil(["detach", mountPoint.path, "-force"]) }
        print("[exFAT] RAN on a real exFAT volume at \(mountPoint.path)")

        let final = mountPoint.appendingPathComponent("test_clip_combined.mov")
        try Data("original".utf8).write(to: final)
        let p1 = try CombineOutputPublish.reservePartial(for: final)
        try Data("first".utf8).write(to: p1)
        let o1 = try CombineOutputPublish.publish(partial: p1.path, as: final)
        #expect(o1.url.lastPathComponent == "test_clip_combined 2.mov")
        #expect(try Data(contentsOf: final) == Data("original".utf8))
        #expect(try Data(contentsOf: o1.url) == Data("first".utf8))

        let free = mountPoint.appendingPathComponent("test_other_combined.mov")
        let p2 = try CombineOutputPublish.reservePartial(for: free)
        try Data("second".utf8).write(to: p2)
        #expect(try CombineOutputPublish.publish(partial: p2.path, as: free) == .published(free))
        #expect(try Data(contentsOf: free) == Data("second".utf8))
    }

    // MARK: stale-partial sweep

    static func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: url.path)
    }

    @Test func sweep_removesOnlyOldUnreservedPartials() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let final = dir.appendingPathComponent("test_clip_combined.mov")
        try Data("final".utf8).write(to: final)
        try Self.age(final, hours: 48)

        // Old, not live → removed.
        let stale = CombineOutputPublish.uniquePartialURL(for: final)
        try Data(count: 1234).write(to: stale)
        try Self.age(stale, hours: 7)
        // Fresh → kept.
        let fresh = CombineOutputPublish.uniquePartialURL(for: final)
        try Data("fresh".utf8).write(to: fresh)
        // Old but reserved by a running job → kept.
        let live = try CombineOutputPublish.reservePartial(for: final)
        defer { PartialFileNaming.unregisterLive(live) }
        try Self.age(live, hours: 7)
        // Old lookalikes → kept.
        let kept = dir.appendingPathComponent("test_clip_combined.abcdef12.vs-kept.mov")
        let noToken = dir.appendingPathComponent("test_clip_combined.vs-partial.mov")
        let folderLike = dir.appendingPathComponent("test_dir.abcdef12.vs-partial.mov", isDirectory: true)
        for u in [kept, noToken] { try Data("x".utf8).write(to: u); try Self.age(u, hours: 7) }
        try FileManager.default.createDirectory(at: folderLike, withIntermediateDirectories: true)
        try Self.age(folderLike, hours: 7)

        let result = CombineOutputPublish.sweepStalePartials(in: dir)
        #expect(result.removed == [.init(name: stale.lastPathComponent, sizeBytes: 1234)])
        #expect(result.errors.isEmpty)
        let left = Set(Self.names(in: dir))
        #expect(!left.contains(stale.lastPathComponent))
        for u in [final, fresh, live, kept, noToken, folderLike] {
            #expect(left.contains(u.lastPathComponent), "\(u.lastPathComponent) must survive the sweep")
        }
    }
}
