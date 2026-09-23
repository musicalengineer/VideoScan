import Testing
import Darwin
import Foundation
@testable import VideoScan

// MARK: - PublishNeverOverwritesOrLosesOutputTests
//
// codex #1642 (review of main 7e0503a3, 2026-09-23) — two P1 data-safety
// bugs in the shared Combine / Transcode / Reformat publish path, turned
// into red tests from codex's probe
// (~/Library/Logs/VideoScan/review_1633_1638_20260923/review_1633_validation/main.swift):
//
//   D1  RENAME_EXCL unsupported (exFAT / msdos / some SMB): the fallback
//       reserved an O_EXCL placeholder, lstat-checked it, then rename(2)d
//       over it. A second writer replacing the placeholder between the
//       check and the rename was OVERWRITTEN while publish reported
//       success. Now: link(2) (atomic EEXIST) or refuse — never a
//       check-then-rename.
//   D2  keepUnpublished released the reservation even when the keep rename
//       failed or the `.vs-kept.` name was taken; the completed output kept
//       its `.vs-partial.` name and the 24 h sweep deleted it. Transcode's
//       `defer` released it too. Now: a durable `<partial>.keep` marker the
//       ONE sweep honours (survives restart), the next free kept name on a
//       collision, and an in-process pin when even the marker can't be
//       written.
//
// The seams: ExclusivePublish.renameExclSyscall / linkSyscall simulate an
// unsupported volume (an exFAT image can't be made in the test host);
// ExclusivePublish.beforeFallbackPublish runs just before the fallback's
// publishing syscall — the exact point codex injected "OTHER WRITER".
// All files are `test_` prefixed in a per-test temp dir.

@Suite("Publish — never overwrites, never loses a finished output (codex #1642)", .serialized)
@MainActor
struct PublishNeverOverwritesOrLosesOutputTests {

    enum Publisher: String, CaseIterable, Sendable { case combine, derivative }

    static func makeDir(_ purpose: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_publish1642_\(purpose)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: url.path)
    }

    static func reserve(_ p: Publisher, for out: URL) throws -> URL {
        switch p {
        case .combine: return try CombineOutputPublish.reservePartial(for: out)
        case .derivative: return try DerivativeOutputPublish.reservePartial(for: out)
        }
    }

    static func publish(_ p: Publisher, _ partial: URL, as out: URL) throws -> URL {
        switch p {
        case .combine:
            return try CombineOutputPublish.publish(partial: partial.path, as: out).url
        case .derivative:
            return try DerivativeOutputPublish.publish(partial: partial.path, as: out,
                                                       policy: .keep(reason: "test"),
                                                       archiveCheck: nil, trash: { _ in nil }).url
        }
    }

    static func keep(_ p: Publisher, _ partial: URL) -> URL {
        switch p {
        case .combine: return CombineOutputPublish.keepUnpublished(partial)
        case .derivative: return DerivativeOutputPublish.keepUnpublished(partial)
        }
    }

    /// Both sweeps, run as if 25 h had passed (codex's clock advance).
    static func sweepBoth(_ dir: URL, beside out: URL) {
        let later = Date().addingTimeInterval(25 * 3600)
        _ = CombineOutputPublish.sweepStalePartials(in: dir, now: later)
        _ = DerivativeOutputPublish.sweepStalePartials(beside: out, now: later)
    }

    /// Fires once, for exactly one destination.
    nonisolated final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
    }

    static let enotsup: @Sendable (String, String) -> Int32 = { _, _ in ENOTSUP }

    // MARK: D1 — a racing writer is never overwritten

    /// codex's probe, both publishers: RENAME_EXCL unsupported, and a second
    /// writer puts its file at the destination just before the fallback's
    /// publishing syscall. Its bytes must survive; ours land beside.
    @Test(arguments: Publisher.allCases)
    func aSecondWriterAtTheNameIsNeverOverwritten(_ p: Publisher) throws {
        let dir = try Self.makeDir("race_\(p.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_race.mov")
        let partial = try Self.reserve(p, for: out)
        try Data("NEW OUTPUT".utf8).write(to: partial)
        let once = Once()
        let racePath = out.path
        let secondWriter: @Sendable (String) -> Void = { dst in
            guard dst == racePath, once.take() else { return }
            _ = Darwin.unlink(dst)   // the old placeholder, if any
            try? Data("OTHER WRITER".utf8).write(to: URL(fileURLWithPath: dst))
        }
        let published = try ExclusivePublish.$renameExclSyscall.withValue(Self.enotsup) {
            try ExclusivePublish.$beforeFallbackPublish.withValue(secondWriter) {
                try Self.publish(p, partial, as: out)
            }
        }
        #expect(Self.text(out) == "OTHER WRITER", "the second writer's file was overwritten")
        #expect(published.lastPathComponent == "test_race 2.mov", "\(published.lastPathComponent)")
        #expect(Self.text(published) == "NEW OUTPUT")
        #expect(!Self.exists(partial))
        #expect(Self.names(in: dir) == ["test_race 2.mov", "test_race.mov"])
    }

    /// The link(2) fallback, both publishers, on a volume where hard links
    /// work: free name → published there, nothing left behind.
    @Test(arguments: Publisher.allCases)
    func withoutRenameExclAFreeNameIsPublishedByLink(_ p: Publisher) throws {
        let dir = try Self.makeDir("link_\(p.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_link.mov")
        let partial = try Self.reserve(p, for: out)
        try Data("NEW".utf8).write(to: partial)
        let published = try ExclusivePublish.$renameExclSyscall.withValue(Self.enotsup) {
            try Self.publish(p, partial, as: out)
        }
        #expect(published == out)
        #expect(Self.text(out) == "NEW")
        #expect(Self.names(in: dir) == ["test_link.mov"])
        #expect(!PartialFileNaming.isLive(partial))
    }

    // MARK: D1 — no exclusive primitive at all → refuse, preserve, protect

    /// Neither RENAME_EXCL nor hard links (exFAT): publish REFUSES — the
    /// destination is never created or touched — and the verified output
    /// stays where it is, protected from the sweep through a +25 h sweep
    /// after the job released it.
    @Test(arguments: Publisher.allCases, [ENOTSUP, EPERM])
    func noExclusivePrimitiveRefusesAndPreservesTheOutput(_ p: Publisher, _ linkErr: Int32) throws {
        let dir = try Self.makeDir("refuse_\(p.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_exfat.mov")
        try Data("ORIGINAL".utf8).write(to: dir.appendingPathComponent("test_exfat 2.mov"))
        let partial = try Self.reserve(p, for: out)
        try Data("VERIFIED".utf8).write(to: partial)
        let noLink: @Sendable (String, String) -> Int32 = { _, _ in linkErr }

        var message = ""
        var kept = partial
        ExclusivePublish.$renameExclSyscall.withValue(Self.enotsup) {
            ExclusivePublish.$linkSyscall.withValue(noLink) {
                do {
                    _ = try Self.publish(p, partial, as: out)
                    Issue.record("publish must refuse when the drive can't publish exclusively")
                } catch {
                    message = error.localizedDescription
                }
                kept = Self.keep(p, partial)
            }
        }
        #expect(message.contains(ExclusivePublish.cannotPublishSafelyNote), "\(message)")
        #expect(!Self.exists(out), "nothing may be created at the destination")
        #expect(Self.text(dir.appendingPathComponent("test_exfat 2.mov")) == "ORIGINAL")
        #expect(kept == partial, "no rename is possible on this drive — kept in place")
        #expect(Self.text(kept) == "VERIFIED")
        #expect(PartialFileNaming.isProtected(partial), "a durable marker protects the kept output")

        PartialFileNaming.unregisterLive(partial)   // the job's own defer
        try Self.age(partial, hours: 48)
        Self.sweepBoth(dir, beside: out)
        #expect(Self.text(partial) == "VERIFIED", "the sweep deleted a finished output")
    }

    // MARK: D2 — keeping never loses the output

    /// codex's probe verbatim, extended through the sweep: the `.vs-kept.`
    /// name is taken. The older kept file is never overwritten, the new
    /// output goes to the NEXT free kept name, and after the job released
    /// it and 25 h pass, a sweep leaves both.
    @Test func keptNameCollisionThenATwentyFiveHourSweepLosesNothing() throws {
        let dir = try Self.makeDir("keep_collision")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_output.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        try Data("VERIFIED ENCODE".utf8).write(to: partial)
        let taken = dir.appendingPathComponent(partial.lastPathComponent
            .replacingOccurrences(of: ".vs-partial.", with: ".vs-kept."))
        try Data("OLDER VERIFIED ENCODE".utf8).write(to: taken)

        let kept = DerivativeOutputPublish.keepUnpublished(partial)
        PartialFileNaming.unregisterLive(partial)   // Transcode's defer
        for name in Self.names(in: dir) { try Self.age(dir.appendingPathComponent(name), hours: 48) }
        Self.sweepBoth(dir, beside: out)

        #expect(Self.text(taken) == "OLDER VERIFIED ENCODE")
        #expect(Self.text(kept) == "VERIFIED ENCODE", "the completed output was lost: \(Self.names(in: dir))")
        #expect(kept != taken)
        #expect(!PartialFileNaming.isPartialName(kept.lastPathComponent), "\(kept.lastPathComponent)")
        #expect(kept.pathExtension == "mov")
    }

    /// The keep rename fails with a hard error (not a collision): the output
    /// stays at its partial name, and it must STILL survive the job's
    /// release + a 25 h sweep. (The other half of codex's D2.)
    @Test(arguments: Publisher.allCases)
    func aFailedKeepRenameStillSurvivesTheSweep(_ p: Publisher) throws {
        let dir = try Self.makeDir("keep_fails_\(p.rawValue)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_eio.mov")
        let partial = try Self.reserve(p, for: out)
        try Data("VERIFIED".utf8).write(to: partial)
        let kept = ExclusivePublish.$renameExclSyscall.withValue({ _, _ in EIO }) {
            Self.keep(p, partial)
        }
        #expect(kept == partial)
        PartialFileNaming.unregisterLive(partial)
        try Self.age(partial, hours: 48)
        Self.sweepBoth(dir, beside: out)
        #expect(Self.text(partial) == "VERIFIED", "a completed output was swept: \(Self.names(in: dir))")
    }

    /// Restart: nothing in memory, only what is on disk — a 48 h old file
    /// at a partial name WITH its `.keep` marker. Neither sweep, and not
    /// remove(), may delete it; the marker itself is never swept.
    @Test func aProtectedPartialSurvivesAfterRestart() throws {
        let dir = try Self.makeDir("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_restart.mov")
        let partial = PartialFileNaming.uniquePartialURL(for: out)   // never registered
        try Data("VERIFIED".utf8).write(to: partial)
        let marker = PartialFileNaming.protectionMarkerURL(for: partial)
        try Data("kept".utf8).write(to: marker)
        #expect(!PartialFileNaming.isPartialName(marker.lastPathComponent), "the marker is not sweepable")
        try Self.age(partial, hours: 48)
        try Self.age(marker, hours: 48)
        #expect(!PartialFileNaming.isLive(partial))

        Self.sweepBoth(dir, beside: out)
        #expect(throws: PartialFileNaming.Failure.self) { try PartialFileNaming.remove(partial) }
        #expect(Self.text(partial) == "VERIFIED")
        #expect(Self.exists(marker))

        // Control: the same file without a marker IS a crash leftover.
        let leftover = PartialFileNaming.uniquePartialURL(for: out)
        try Data("junk".utf8).write(to: leftover)
        try Self.age(leftover, hours: 48)
        Self.sweepBoth(dir, beside: out)
        #expect(!Self.exists(leftover))
        #expect(Self.text(partial) == "VERIFIED")
    }

    /// When even the marker can't be written (the folder became read-only),
    /// the output is pinned for the life of the process: the job's release
    /// does not un-pin it, and the sweep skips it.
    @Test func whenNothingCanBeWrittenTheOutputIsPinnedInProcess() throws {
        let dir = try Self.makeDir("readonly")
        defer {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        let out = dir.appendingPathComponent("test_ro.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        try Data("VERIFIED".utf8).write(to: partial)
        try #require(chmod(dir.path, 0o555) == 0)
        let kept = DerivativeOutputPublish.keepUnpublished(partial)
        #expect(kept == partial)
        #expect(!PartialFileNaming.isProtected(partial))
        PartialFileNaming.unregisterLive(partial)
        #expect(PartialFileNaming.isLive(partial), "a pinned kept output stays live after the job ends")
        #expect(chmod(dir.path, 0o755) == 0)
        try Self.age(partial, hours: 48)
        Self.sweepBoth(dir, beside: out)
        #expect(Self.text(partial) == "VERIFIED")
    }

    // MARK: Replace on a drive without RENAME_EXCL

    /// Transcode "Replace" must not Trash the existing file when the drive
    /// can't take the name back exclusively: it keeps it and goes beside.
    @Test func replaceWithoutRenameExclNeverTrashesTheExistingFile() throws {
        let dir = try Self.makeDir("replace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_replace.mov")
        try Data("EXISTING".utf8).write(to: out)
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        try Data("NEW".utf8).write(to: partial)
        let trashed = Once()
        let outcome = try ExclusivePublish.$renameExclSyscall.withValue(Self.enotsup) {
            try DerivativeOutputPublish.publish(partial: partial.path, as: out, policy: .replaceViaTrash,
                                                archiveCheck: nil,
                                                trash: { _ in _ = trashed.take(); return nil })
        }
        #expect(trashed.take(), "the Trash step must not run")
        #expect(Self.text(out) == "EXISTING")
        guard case .publishedBeside(let url, _, let reason) = outcome else {
            Issue.record("expected publishedBeside, got \(outcome)"); return
        }
        #expect(Self.text(url) == "NEW")
        #expect(reason.contains("replace"), "\(reason)")
    }
}
