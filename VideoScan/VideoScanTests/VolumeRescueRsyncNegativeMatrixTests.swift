// VolumeRescueRsyncNegativeMatrixTests.swift — the negative matrix for
// Compare Volumes → "Verified (rsync --checksum)" rescue
// (Volumes/VolumeCompare.swift, VolumeRescueOperation.rsyncCopy), which
// COPIES FAMILY MEDIA to another volume. Until 2026-11-21 its `/bin/mkdir`
// and `/usr/bin/rsync` were hand-rolled Process() sites no test could
// reach; they now go through ProcessRunner, so a ScriptedExecutor answers
// them. Workflow, in Rick's words: "copy the files this volume is missing
// onto that one, checked."
//
// RULE 10: this is a relocate/copy path. The matrix was written against the
// mechanically converted spawn and PARKED five misbehaviours RED under
// `withKnownIssue` (GH #506). They are fixed and green (Rick 2026-11-21):
//   P0  rsync's exit 0 was believed without evidence → a file counts as
//       copied only when a FRESH stat shows a regular file at the
//       destination whose size equals the source's ("copied (size
//       checked)" — size equality is not content verification)
//   P1  a failed transfer left a truncated file at the FINAL name
//       (`--partial`) → rsync writes only a staged copy in
//       `.videoscan-partial` (Codex r1 #2: published by the app with
//       RENAME_EXCL), and every failure line says what is at the destination
//   P2  a child killed by a signal with no stderr named no reason → "rsync
//       exit N"
//   P2  a Stop was reported as "done, 1 failed" → stopped, the file in
//       flight is "interrupted", the rest "not attempted"
//   P2  no START / OUTCOME through the one log sink → both, with counts
//
// What every row asserts (rules 1 and 2):
//   • the outcome is named truthfully (counters, the lines);
//   • nothing is reported copied / written that was not;
//   • no source is touched (same SHA-256, same mtime; the source is only
//     ever rsync's SOURCE argument);
//   • what is left at the destination is said, and nothing truncated sits
//     at a final name because of this run.
//
// Rows: the command lines + a positive control with the REAL mkdir and
// rsync · a REAL rsync interrupted mid-transfer (the partial lands in
// .videoscan-partial, never at the final name; the next run completes it) ·
// exit 23 / 24 · killed by a signal · hang + Stop · Stop before the first
// file · launch failure · exit 0 with nothing (or a short file, or a
// directory) at the destination · a source the REAL rsync skips with exit 0
// · one file of three fails · mkdir cannot start · mkdir exits nonzero ·
// the log.
//
// Parallel by design: each test has its own scratch tree and mock.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Volume rescue (rsync) — negative matrix through a scripted mkdir/rsync", .timeLimit(.minutes(1)))
@MainActor
struct VolumeRescueRsyncNegativeMatrixTests {

    struct Source {
        let record: VideoRecord
        let url: URL
        let relative: String
        let sha: String
        let mtime: Date
        let size: Int64
    }

    @MainActor
    struct Bench {
        let root: URL
        let sourceVolume: URL
        let destVolume: URL
        let sources: [Source]
        let op = VolumeRescueOperation()
        var rescued: URL { destVolume.appendingPathComponent("Rescued", isDirectory: true) }
        func dest(_ i: Int) -> URL { rescued.appendingPathComponent(sources[i].relative) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// Strict mock; mkdir is the REAL /bin/mkdir on the scratch tree.
        func mock() -> ScriptedExecutor {
            ScriptedExecutor(claiming: [root.path]).on("mkdir", .passThrough)
        }

        /// Rule 2: every source is byte-for-byte and mtime-for-mtime as it was.
        func expectSourcesUntouched(sourceLocation: SourceLocation = #_sourceLocation) {
            for s in sources {
                #expect(VolumeRescueRsyncNegativeMatrixTests.sha(s.url) == s.sha, "source changed: \(s.relative)", sourceLocation: sourceLocation)
                let mtime = (try? FileManager.default.attributesOfItem(atPath: s.url.path)[.modificationDate]) as? Date
                #expect(mtime == s.mtime, "source mtime changed: \(s.relative)", sourceLocation: sourceLocation)
            }
        }

        /// The only commands are mkdir -p <dir under the destination> and
        /// rsync <three flags> <a source> <its STAGED copy>: the source is
        /// never written to, and rsync never writes a final name (Codex r1 #2).
        func expectOnlyTheTwoCommands(_ mock: ScriptedExecutor, sourceLocation: SourceLocation = #_sourceLocation) {
            for call in mock.calls {
                switch call.tool {
                case "mkdir":
                    #expect(call.executable == "/bin/mkdir" && call.arguments.count == 2 && call.arguments[0] == "-p"
                            && call.arguments[1].hasPrefix(rescued.path), "\(call)", sourceLocation: sourceLocation)
                case "rsync":
                    let ok = call.executable == "/usr/bin/rsync" && call.arguments.count == 5
                        && Array(call.arguments.prefix(3)) == ["--checksum", "--partial", "--times"]
                        && sources.contains { $0.url.path == call.arguments[3]
                            && VolumeRescueRsyncNegativeMatrixTests.partial(of: rescued.appendingPathComponent($0.relative)).path == call.arguments[4] }
                    #expect(ok, "\(call)", sourceLocation: sourceLocation)
                default:
                    Issue.record("an unexpected command: \(call)", sourceLocation: sourceLocation)
                }
                #expect(call.environment == nil, "the app's own environment, as before", sourceLocation: sourceLocation)
            }
        }
    }

    nonisolated static func sha(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url) else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func bench(files: Int = 2) throws -> Bench {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescue-rsync-\(UUID().uuidString)", isDirectory: true)
        let sourceVolume = root.appendingPathComponent("SourceVol", isDirectory: true)
        let destVolume = root.appendingPathComponent("DestVol", isDirectory: true)
        try FileManager.default.createDirectory(at: destVolume, withIntermediateDirectories: true)
        var sources: [Source] = []
        for i in 0..<files {
            let relative = "Tapes/1994/tape \(i + 1).mov"
            let url = sourceVolume.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try MasterArchiveTestSupport.writeBlob(at: url, bytes: 8192 + i * 1024, seed: UInt64(70 + i))
            // An old mtime: `--times` must carry it, and "untouched" must see a change.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 800_000_000 + Double(i))], ofItemAtPath: url.path)
            let mtime = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            sources.append(Source(record: MasterArchiveTestSupport.makeRecord(path: url.path), url: url, relative: relative,
                                  sha: Self.sha(url), mtime: mtime, size: Int64(8192 + i * 1024)))
        }
        return Bench(root: root, sourceVolume: sourceVolume, destVolume: destVolume, sources: sources)
    }

    /// Start the verified rescue inside the mock's scope and wait for it to
    /// say it is done. False when it never did.
    @discardableResult
    func run(_ b: Bench, _ mock: ScriptedExecutor, limit: Duration = .seconds(20)) async -> Bool {
        await mock.scoped {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            return await waitUntilDone(b, limit: limit)
        }
    }

    func waitUntilDone(_ b: Bench, limit: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !b.op.isDone, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return b.op.isDone
    }

    static let partialDirName = ".videoscan-partial"

    /// Where an interrupted transfer of `dest` is parked.
    static func partial(of dest: URL) -> URL {
        dest.deletingLastPathComponent().appendingPathComponent(partialDirName, isDirectory: true)
            .appendingPathComponent(dest.lastPathComponent)
    }

    /// An rsync that leaves `fraction` of the source behind, prints
    /// `stderr`, and exits `exit`. WHERE it leaves it is what the real tool
    /// does with `--partial`: at its destination argument — the app's
    /// STAGED copy in `.videoscan-partial` (Codex r1 #2). `atFinalName`
    /// writes the FINAL name instead (a tool, or a filesystem, that lies).
    static func rsyncLeaving(fraction: Double, stderr: String, exit: Int32, atFinalName: Bool = false) -> ScriptedExecutor.Behaviour {
        .custom { request in
            let (src, dst) = (request.arguments[request.arguments.count - 2], request.arguments[request.arguments.count - 1])
            if fraction > 0, let data = try? Data(contentsOf: URL(fileURLWithPath: src)) {
                let staged = URL(fileURLWithPath: dst)
                let target = atFinalName
                    ? staged.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(staged.lastPathComponent) : staged
                try? data.prefix(Int(Double(data.count) * fraction)).write(to: target)
            }
            for line in stderr.split(separator: "\n") { request.stderrLine?(String(line)) }
            return ProcessRunner.Result(stdout: "", stderr: stderr, exitCode: exit, launched: true)
        }
    }

    // MARK: - The command lines, and a positive control with the real tools

    @Test("COMMAND + CONTROL: the real mkdir and rsync copy both files; the exact command lines; counters are what landed")
    func theCommandLinesAndARealCopy() async throws {
        let b = try bench()
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", .passThrough)
        #expect(await run(b, mock))

        let expected: [[String]] = b.sources.flatMap { s -> [[String]] in
            let dst = b.rescued.appendingPathComponent(s.relative).path
            return [["/bin/mkdir", "-p", (dst as NSString).deletingLastPathComponent],
                    ["/usr/bin/rsync", "--checksum", "--partial", "--times", s.url.path, Self.partial(of: URL(fileURLWithPath: dst)).path]]
        }
        #expect(mock.calls.map { [$0.executable] + $0.arguments } == expected)
        b.expectOnlyTheTwoCommands(mock)

        #expect(b.op.filesCopied == 2 && b.op.filesFailed == 0 && b.op.errors.isEmpty)
        #expect(!b.op.wasStopped && b.op.filesPlanned == 2 && b.op.filesInterrupted == 0 && b.op.filesNotAttempted == 0)
        #expect(b.op.bytesWritten == b.sources.reduce(0) { $0 + $1.size })
        #expect(b.op.isRunning == false && b.op.progress == 1.0)
        for (i, s) in b.sources.enumerated() {
            #expect(Self.sha(b.dest(i)) == s.sha, "the copy is not the source: \(s.relative)")
            let mtime = (try? FileManager.default.attributesOfItem(atPath: b.dest(i).path)[.modificationDate]) as? Date
            #expect(mtime == s.mtime, "--times did not carry the mtime")
        }
        let landed = ((try? FileManager.default.contentsOfDirectory(atPath: b.dest(0).deletingLastPathComponent().path)) ?? []).sorted()
        #expect(landed == ["tape 1.mov", "tape 2.mov"], "something besides the two copies is in the destination folder: \(landed)")
        b.expectSourcesUntouched()
    }

    /// GH #506 item 2, validated with an ACTUAL interrupted transfer (Codex
    /// r1: "not only the mock"). The real /usr/bin/rsync copies a 3 MB file,
    /// slowed by `--bwlimit` (added by the bench in front of the production
    /// arguments, which are otherwise passed through untouched), and is
    /// stopped mid-file by the production Stop (task cancel → SIGTERM).
    /// rsync then parks what it had in `.videoscan-partial/`: nothing is at
    /// the final name. A second, unthrottled run completes the file, and
    /// the partial folder is gone.
    @Test("REAL rsync interrupted mid-transfer: nothing at the final name, the partial is in .videoscan-partial and said; the next run completes the copy")
    func aRealInterruptedTransferNeverLeavesATruncatedFileAtTheFinalName() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let big = b.sources[0]
        _ = try MasterArchiveTestSupport.writeBlob(at: big.url, bytes: 3 * 1024 * 1024, seed: 99)
        let bigSHA = Self.sha(big.url)
        let record = MasterArchiveTestSupport.makeRecord(path: big.url.path)
        let destDir = b.dest(0).deletingLastPathComponent()
        let slow = b.mock().on("rsync", .custom { request in
            var throttled = request
            throttled.arguments.insert("--bwlimit=128", at: 0)     // KB/s: ~24 s for 3 MB — Stop lands long before
            return await ScriptedExecutor().on("*", .passThrough).run(throttled)
        })
        let stopped = await slow.scoped {
            b.op.start(files: [record], sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            // Wait until rsync's temporary file exists in the staging
            // folder (the transfer is under way), then press Stop.
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: destDir.appendingPathComponent(Self.partialDirName).path)) ?? []
                if names.contains(where: { $0.hasPrefix(".tape 1.mov.") }) { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(700))          // some bytes have been written
            b.op.cancel()
            return await waitUntilDone(b, limit: .seconds(20))
        }
        #expect(stopped, "Stop did not end the rescue")
        #expect(b.op.filesCopied == 0 && b.op.bytesWritten == 0, "an interrupted transfer was reported copied")
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path) == nil, "a file is at the FINAL name after an interrupted transfer")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: destDir.path)) ?? []).sorted()
        #expect(names == [Self.partialDirName], "the destination folder holds: \(names)")
        let parked = VolumeRescueOperation.measuredSize(ofFileAt: Self.partial(of: b.dest(0)).path)
        #expect(parked != nil && (parked ?? 0) < 3 * 1024 * 1024, "the partial is not in \(Self.partialDirName): \(String(describing: parked))")
        #expect(b.op.errors.count == 1 && b.op.errors[0].contains(Self.partialDirName), "the line does not say where the partial is: \(b.op.errors)")
        #expect(Self.sha(big.url) == bigSHA, "the source changed")

        // The next run (unthrottled) completes it from the partial.
        b.op.acknowledgeCompletion()
        let again = b.mock().on("rsync", .passThrough)
        let done = await again.scoped {
            b.op.start(files: [record], sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            return await waitUntilDone(b)
        }
        #expect(done && b.op.filesCopied == 1 && b.op.filesFailed == 0 && b.op.errors.isEmpty, "\(b.op.errors)")
        #expect(Self.sha(b.dest(0)) == bigSHA, "the completed copy is not the source")
        #expect(b.op.bytesWritten == 3 * 1024 * 1024)
        let after = ((try? FileManager.default.contentsOfDirectory(atPath: destDir.path)) ?? []).sorted()
        #expect(after == ["tape 1.mov"], "the emptied partial folder was not cleaned up: \(after)")
        #expect(Self.sha(big.url) == bigSHA, "the source changed")
    }

    /// GH #506 item 1, the case Codex confirmed with the installed rsync:
    /// given a DIRECTORY as its source it skips it ("skipping directory")
    /// and exits 0 without copying anything. That was counted "safe".
    /// What is at the destination afterwards is NOT a copy either way it
    /// has been observed: nothing at all (Codex's run, and the tool run by
    /// hand), or — run from the app on this Mac — an empty directory under
    /// the file's name. Both are FAILED, and what is there is said.
    @Test("REAL rsync skips a source it will not copy (a directory) and exits 0: the file is FAILED — no regular file is at the destination, and the line says what is")
    func aSourceTheRealRsyncSkipsIsNotCountedCopied() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        // The catalogued file has been replaced by a folder of the same name.
        try FileManager.default.removeItem(at: b.sources[0].url)
        try FileManager.default.createDirectory(at: b.sources[0].url, withIntermediateDirectories: false)
        let mock = b.mock().on("rsync", .passThrough)
        #expect(await run(b, mock))
        #expect(mock.calls(to: "rsync").count == 1)
        #expect(b.op.filesCopied == 0, "a file was reported copied on rsync's exit 0 alone")
        #expect(b.op.filesFailed == 1 && b.op.bytesWritten == 0)
        let at = VolumeRescueOperation.entry(at: b.dest(0).path)
        #expect(at == .absent, "something appeared at the final name: \(at)")
        let staged = VolumeRescueOperation.entry(at: Self.partial(of: b.dest(0)).path)
        let said = staged == .absent
            ? "nothing was staged, and the source is not a regular file rsync would copy"
            : "the staged copy is not a regular file; it was left in .videoscan-partial"
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync exited 0 but the copy is not whole: \(said); nothing was published at the final name."], "\(b.op.errors)")
    }

    // MARK: - rsync exits nonzero

    @Test("rsync exits 23 / 24 (partial transfer): the file is FAILED with rsync's words, nothing is counted copied or written",
          arguments: [Int32(23), Int32(24)])
    func partialTransferExit(_ code: Int32) async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let words = code == 23 ? "rsync error: some files could not be transferred (code 23)"
                               : "rsync warning: some files vanished before they could be transferred (code 24)"
        let mock = b.mock().on("rsync", Self.rsyncLeaving(fraction: 0.5, stderr: "rsync: write failed: Input/output error (5)\n\(words)\n", exit: code))
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0)
        #expect(b.op.bytesWritten == 0, "bytes of a FAILED transfer were reported written")
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()

        // GH #506 item 2 (was parked RED): nothing truncated is at the
        // FINAL name — the half file is parked in .videoscan-partial — and
        // the line says rsync's exit code, its words, and what is at the
        // destination. (The mock parks it where the flag says; that the
        // REAL rsync does is aRealInterruptedTransferNeverLeaves….)
        let left = VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path)
        #expect(left == nil, "a truncated \(left ?? 0)-byte file is at the final name \(b.dest(0).lastPathComponent)")
        let half = b.sources[0].size / 2
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: Self.partial(of: b.dest(0)).path) == half)
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync exit \(code): rsync: write failed: Input/output error (5) · \(words). "
                               + "At the destination: nothing at the final name; \(half) of \(b.sources[0].size) bytes kept in .videoscan-partial for the next run."],
                "\(b.op.errors)")
    }

    @Test("rsync is killed by a signal: the file is FAILED, nothing counted copied")
    func killedBySignal() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", .crash(signal: 9))
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors.count == 1)
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path) == nil)
        b.expectSourcesUntouched()
        // GH #506 item 3 (was parked RED: "tape 1.mov — rsync: " and
        // nothing after it). The runner reports a signal death as the
        // signal number in the exit code, so the fallback is "rsync exit N".
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync exit 9 (it printed no message). At the destination: nothing was left."],
                "\(b.op.errors)")
    }

    // MARK: - rsync hangs

    @Test("rsync hangs and the user presses Stop: rsync is stopped, the next file is never started, nothing is reported copied")
    func hangThenStop() async throws {
        let b = try bench(files: 3)
        defer { b.cleanup() }
        // rsync's own answer to SIGTERM: a line on stderr, exit 20.
        let mock = b.mock().on("rsync", .hang(stderr: "rsync error: received SIGINT, SIGTERM, or SIGHUP (code 20)", exitOnTERM: 20, maxSeconds: 30))
        let started = ContinuousClock.now
        let done = await mock.scoped {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            for _ in 0..<2000 where mock.calls(to: "rsync").isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
            // There is no deadline on a copy (a 60 GB tape takes what it
            // takes): a hung rsync runs until Stop.
            try? await Task.sleep(for: .milliseconds(300))
            #expect(b.op.isRunning && !b.op.isDone, "a hung rsync ended by itself")
            b.op.cancel()
            return await waitUntilDone(b, limit: .seconds(15))
        }
        #expect(done, "Stop did not end the rescue")
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(mock.calls(to: "rsync").count == 1, "a file was started after Stop: \(mock.calls)")
        #expect(b.op.filesCopied == 0 && b.op.bytesWritten == 0, "a stopped rescue reported something copied")
        #expect(b.op.isRunning == false)
        for i in 0..<3 { #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(i).path) == nil) }
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()

        // GH #506 item 4 (was parked RED: "0 safe · 1 failed", done). A
        // Stop is not a failed copy: the file in flight is named as
        // stopped, and it is not in the failed count.
        #expect(b.op.filesFailed == 0, "the file in flight at Stop is counted as a failed copy")
        #expect(b.op.errors == ["\(b.sources[0].relative) — stopped during the transfer (rsync exit 20: rsync error: received SIGINT, SIGTERM, or SIGHUP (code 20)). "
                               + "At the destination: nothing was left."], "\(b.op.errors)")
        // …and the run is STOPPED, with every planned file in exactly one count.
        #expect(b.op.wasStopped, "nothing says the rescue was stopped")
        #expect(b.op.filesInterrupted == 1 && b.op.filesNotAttempted == 2, "interrupted \(b.op.filesInterrupted), not attempted \(b.op.filesNotAttempted)")
        #expect(b.op.filesCopied + b.op.filesFailed + b.op.filesInterrupted + b.op.filesNotAttempted == b.op.filesPlanned && b.op.filesPlanned == 3)
        #expect(VolumeRescueOperation.doneTitle(stopped: b.op.wasStopped, failed: b.op.filesFailed) == "Copy stopped")
    }

    @Test("Stop before the first file: no command is issued at all, nothing is reported copied or failed")
    func stopBeforeTheFirstFile() async throws {
        let b = try bench()
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", .passThrough)
        let done = await mock.scoped {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .verified)
            b.op.cancel()                 // same main-actor turn: the task has not run yet
            return await waitUntilDone(b)
        }
        #expect(done)
        #expect(mock.calls.isEmpty, "\(mock.calls)")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 0 && b.op.bytesWritten == 0 && b.op.errors.isEmpty)
        #expect(b.op.wasStopped && b.op.filesInterrupted == 0 && b.op.filesNotAttempted == 2 && b.op.filesPlanned == 2,
                "stopped before anything: both files are 'not attempted', none failed")
        b.expectSourcesUntouched()
    }

    @Test("Stop before the first file in FAST mode: the same named outcome — stopped, 2 not attempted, nothing failed")
    func stopBeforeTheFirstFileInFastMode() async throws {
        let b = try bench()
        defer { b.cleanup() }
        let sink = InMemoryLogSink()
        await withAppLog(sink) {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: .fast)
            b.op.cancel()
            _ = await waitUntilDone(b)
        }
        #expect(b.op.isDone && b.op.wasStopped && b.op.filesNotAttempted == 2 && b.op.filesFailed == 0 && b.op.filesCopied == 0)
        #expect(sink.lines.contains { $0.contains("rescue OUTCOME: stopped — 2 planned: 0 at the destination (size checked) · 0 failed") && $0.contains("2 not attempted") },
                "\(sink.lines)")
        b.expectSourcesUntouched()
    }

    // MARK: - Stop and a launch failure, in both orders (Codex r1 P2)

    /// A launch failure (`Process.run()` threw) that is reported only after
    /// `gate` has run — the test's handle on "what else happened first".
    static func launchFailure(after gate: @escaping @Sendable () async -> Void) -> ScriptedExecutor.Behaviour {
        .custom { request in
            await gate()
            return ProcessRunner.Result(stdout: nil, stderr: "The file “\(request.tool)” doesn’t exist.", exitCode: -1)
        }
    }

    @Test("rsync genuinely cannot start and THEN Stop lands: the failure is still counted and named — Stop does not erase it")
    func launchFailureThenStop() async throws {
        let b = try bench(files: 2)
        defer { b.cleanup() }
        let op = b.op
        // The launch fails; before the result is read, the user presses Stop.
        let mock = b.mock().on("rsync", Self.launchFailure(after: { await MainActor.run { op.cancel() } }))
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 1, "a genuine launch failure vanished because Stop arrived after it")
        #expect(b.op.errors == ["\(b.sources[0].relative) — The file “rsync” doesn’t exist."])
        #expect(b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(mock.calls(to: "rsync").count == 1, "the second file was started after Stop")
        b.expectSourcesUntouched()
    }

    @Test("mkdir genuinely cannot start and THEN Stop lands: \"mkdir failed\" is still counted and named")
    func mkdirLaunchFailureThenStop() async throws {
        let b = try bench(files: 2)
        defer { b.cleanup() }
        let op = b.op
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", Self.launchFailure(after: { await MainActor.run { op.cancel() } }))
            .on("rsync", .passThrough)
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 1, "a genuine mkdir launch failure vanished because Stop arrived after it")
        #expect(b.op.errors == ["mkdir failed: \(b.sources[0].relative) — The file “mkdir” doesn’t exist."])
        #expect(mock.calls(to: "rsync").isEmpty && mock.calls(to: "mkdir").count == 1)
        b.expectSourcesUntouched()
    }

    @Test("Stop lands FIRST (between mkdir and rsync): rsync is never launched, and the file is not counted failed — it was not attempted")
    func stopThenNoLaunch() async throws {
        let b = try bench(files: 2)
        defer { b.cleanup() }
        let op = b.op
        // mkdir succeeds for real, and Stop is pressed before it returns:
        // the runner then refuses to launch rsync (cancelledBeforeLaunch).
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .custom { request in
                try? FileManager.default.createDirectory(atPath: request.arguments[1], withIntermediateDirectories: true)
                await MainActor.run { op.cancel() }
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
            })
            .on("rsync", .passThrough)
        #expect(await run(b, mock))

        #expect(mock.calls(to: "rsync").count == 1, "the mock records the refused command once")
        #expect(b.op.filesFailed == 0 && b.op.errors.isEmpty, "a file that was never attempted is reported as failed: \(b.op.errors)")
        #expect(b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        for i in 0..<2 { #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(i).path) == nil) }
        b.expectSourcesUntouched()
    }

    // MARK: - rsync cannot be started

    @Test("rsync cannot be started: every file is FAILED with the launch error, nothing counted copied, the run still ends")
    func launchFailure() async throws {
        let b = try bench()
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", .launchFailure)
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 2 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors.count == 2)
        for (i, s) in b.sources.enumerated() {
            #expect(b.op.errors[i].hasPrefix("\(s.relative) — "), "\(b.op.errors[i])")
            #expect(!b.op.errors[i].contains("rsync: "), "a launch failure is not rsync's own words: \(b.op.errors[i])")
            #expect(b.op.errors[i].count > "\(s.relative) — ".count, "no reason given")
            #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(i).path) == nil)
        }
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()
    }

    // MARK: - rsync says 0 but the destination disagrees

    /// GH #506 item 1 (P0, was parked RED: counted SAFE). "Copied" is shown
    /// from a fresh stat of the destination, never from an exit status.
    /// NOTE (Codex): a regular file of equal size closes the missing and
    /// short cases only; size equality is NOT content verification.
    @Test("rsync exits 0 but the staged copy is missing / short / a directory: the file is FAILED with what is there, nothing published, counted or written",
          arguments: ["missing", "truncated", "directory"])
    func exitZeroWithoutTheFile(_ shape: String) async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let said = "rsync: write failed on \"tape 1.mov\": No space left on device (28)"
        let mock = b.mock().on("rsync", shape == "directory"
            ? .custom { request in
                try? FileManager.default.createDirectory(atPath: request.arguments[request.arguments.count - 1], withIntermediateDirectories: true)
                return ProcessRunner.Result(stdout: "", stderr: "", exitCode: 0, launched: true)
            }
            : Self.rsyncLeaving(fraction: shape == "missing" ? 0 : 0.5, stderr: said + "\n", exit: 0))
        #expect(await run(b, mock))

        #expect(b.op.filesCopied == 0, "a file was reported copied on rsync's exit 0 alone")
        #expect(b.op.filesFailed == 1)
        #expect(b.op.bytesWritten == 0, "bytes of a file that is not a copy were reported written")
        let size = b.sources[0].size
        let wanted: String
        switch shape {
        case "missing": wanted = "nothing was staged; nothing was published at the final name (rsync said: \(said))."
        case "truncated": wanted = "the staged copy is \(size / 2) bytes, the source is \(size) bytes; it is kept in .videoscan-partial for the next run; "
            + "nothing was published at the final name (rsync said: \(said))."
        default: wanted = "the staged copy is not a regular file; it was left in .videoscan-partial; nothing was published at the final name."
        }
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync exited 0 but the copy is not whole: \(wanted)"], "\(b.op.errors)")
        // Nothing reaches the final name; a short staged copy stays for the next run.
        #expect(VolumeRescueOperation.entry(at: b.dest(0).path) == .absent)
        if shape == "truncated" { #expect(VolumeRescueOperation.measuredSize(ofFileAt: Self.partial(of: b.dest(0)).path) == size / 2) }
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()
    }

    // MARK: - Partial progress, then a failure

    @Test("one file of three fails: the other two are copied by the real rsync and counted; only their bytes are reported")
    func oneOfThreeFails() async throws {
        let b = try bench(files: 3)
        defer { b.cleanup() }
        let mock = b.mock()
            .on("rsync", containing: ["tape 2.mov"], Self.rsyncLeaving(fraction: 0.25, stderr: "rsync: read errors mapping \"tape 2.mov\": Input/output error (5)\nrsync error: some files could not be transferred (code 23)\n", exit: 23))
            .on("rsync", .passThrough)
        #expect(await run(b, mock))

        #expect(b.op.filesCopied == 2 && b.op.filesFailed == 1)
        #expect(b.op.bytesWritten == b.sources[0].size + b.sources[2].size, "the failed file's bytes were counted")
        #expect(b.op.errors.count == 1)
        #expect(b.op.errors.first?.hasPrefix("Tapes/1994/tape 2.mov — rsync exit 23: ") == true, "\(b.op.errors)")
        #expect(Self.sha(b.dest(0)) == b.sources[0].sha && Self.sha(b.dest(2)) == b.sources[2].sha)
        #expect(mock.calls(to: "rsync").count == 3, "the run stopped at the failure instead of going on")
        // File 2's quarter is parked, not at its final name — and the line says so.
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(1).path) == nil)
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: Self.partial(of: b.dest(1)).path) == b.sources[1].size / 4)
        #expect(b.op.errors.first?.hasSuffix("At the destination: nothing at the final name; \(b.sources[1].size / 4) of \(b.sources[1].size) bytes kept in .videoscan-partial for the next run.") == true,
                "\(b.op.errors)")
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()
    }

    // MARK: - mkdir

    @Test("mkdir cannot be started: the file is FAILED as \"mkdir failed\", and rsync is never run for it")
    func mkdirCannotStart() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = ScriptedExecutor(claiming: [b.root.path]).on("mkdir", .launchFailure).on("rsync", .passThrough)
        #expect(await run(b, mock))

        #expect(mock.calls(to: "rsync").isEmpty)
        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors.first?.hasPrefix("mkdir failed: \(b.sources[0].relative) — ") == true, "\(b.op.errors)")
        b.expectSourcesUntouched()
    }

    @Test("mkdir exits nonzero: its status is not read — the folder it did not make cannot be opened, so the file FAILS naming it; rsync is never run")
    func mkdirExitsNonzero() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .output(stderr: "mkdir: \(b.rescued.path)/Tapes: Permission denied\n", exit: 1))
            .on("rsync", .passThrough)
        #expect(await run(b, mock))

        #expect(mock.calls(to: "rsync").isEmpty, "refuse before mutating: \(mock.calls)")
        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors == ["\(b.sources[0].relative) — the destination folder at \(b.rescued.path)/Tapes could not be opened (No such file or directory) — "
                               + "nothing was touched, and the file is still on the source."], "\(b.op.errors)")
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path) == nil)
        b.expectSourcesUntouched()
    }

    // MARK: - Nothing at the destination is touched; bounded reporting; the words

    @Test("a wrong-size file ALREADY at the final name (old --partial debris, or someone's file): no transfer is started; reported with both sizes, never counted, never touched")
    func aFileAlreadyAtTheFinalNameIsReportedAndLeftAlone() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        try FileManager.default.createDirectory(at: b.dest(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try MasterArchiveTestSupport.writeBlob(at: b.dest(0), bytes: 3000, seed: 5)
        let leftSHA = Self.sha(b.dest(0))
        let mock = ScriptedExecutor(claiming: [b.root.path])     // strict and EMPTY: any command is a failure
        #expect(await run(b, mock))
        #expect(mock.calls.isEmpty, "refuse before mutating: \(mock.calls)")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1 && b.op.filesNameTaken == 1 && b.op.bytesWritten == 0)
        #expect(b.op.errors == ["\(b.sources[0].relative) — a different file is already at Rescued/\(b.sources[0].relative) "
                               + "(3000 bytes there, \(b.sources[0].size) bytes on the source) — not replaced; nothing was touched, and the file is still on the source."],
                "\(b.op.errors)")
        #expect(Self.sha(b.dest(0)) == leftSHA, "the file at the destination was changed or removed")
        b.expectSourcesUntouched()
    }

    @Test("60 files fail: every one is counted and listed, the app log carries 50 FAILED lines and the OUTCOME carries the count")
    func manyFailuresAreCountedAndTheLogIsBounded() async throws {
        let b = try bench(files: 60)
        defer { b.cleanup() }
        let sink = InMemoryLogSink()
        let flood = (0..<200).map { "rsync: line \($0) " + String(repeating: "x", count: 200) }.joined(separator: "\n")
        let mock = b.mock().on("rsync", Self.rsyncLeaving(fraction: 0, stderr: flood, exit: 12))
        let done = await withAppLog(sink) { await run(b, mock, limit: .seconds(40)) }
        #expect(done && b.op.filesFailed == 60 && b.op.filesCopied == 0 && b.op.errors.count == 60)
        #expect(sink.lines.filter { $0.hasPrefix("rescue FAILED: ") }.count == VolumeRescueOperation.failureLogLimit)
        #expect(sink.lines.contains { $0.hasPrefix("rescue OUTCOME: done — 60 planned: 0 at the destination (size checked) · 60 failed") }, "\(sink.lines.last ?? "")")
        #expect(b.op.errors.allSatisfy { $0.count < 700 }, "a line is not bounded: \(b.op.errors.map(\.count).max() ?? 0)")
        #expect(VolumeRescueOperation.doneDetail(errors: b.op.errors)?.hasSuffix("— and 59 more; every line is in videoscan.log (rescue FAILED).") == true)
    }

    @Test("the words (pure): what a fresh lstat finds, rsync's reason, what is left, the banner — never \"safe\" or \"verified\"")
    func theWords() throws {
        typealias R = VolumeRescueOperation
        // entry(at:): absent / a regular file with its size / anything else — a symlink is NOT followed.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rescue-words-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.mov")
        try Data(count: 1234).write(to: file)
        let link = dir.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(R.entry(at: file.path) == .regular(1234))
        #expect(R.entry(at: dir.appendingPathComponent("none.mov").path) == .absent)
        #expect(R.entry(at: dir.path) == .notRegular)
        #expect(R.entry(at: link.path) == .notRegular, "a link to a full-size file is not a copy of it")
        #expect(R.partialPath(forDestination: "/Volumes/D/Rescued/Tapes/a.mov") == "/Volumes/D/Rescued/Tapes/.videoscan-partial/a.mov")

        #expect(R.rsyncReason(exitCode: 9, stderr: " \n") == "rsync exit 9 (it printed no message)")
        #expect(R.rsyncReason(exitCode: 23, stderr: "one\n\n two \n") == "rsync exit 23: one · two")
        #expect(R.flat(String(repeating: "y", count: 5000)).count == 301)

        #expect(R.leftAtDestination(final: .absent, partialBytes: nil, sourceSize: 10) == "nothing was left.")
        #expect(R.leftAtDestination(final: .absent, partialBytes: 4, sourceSize: 10)
                == "nothing at the final name; 4 of 10 bytes kept in .videoscan-partial for the next run.")
        #expect(R.leftAtDestination(final: .absent, partialBytes: 4, sourceSize: nil)
                == "nothing at the final name; 4 bytes kept in .videoscan-partial for the next run.")
        #expect(R.leftAtDestination(final: .notRegular, partialBytes: nil, sourceSize: 10)
                == "the final name is not a regular file; it was left untouched.")
        #expect(R.leftAtDestination(final: .regular(10), partialBytes: 4, sourceSize: 10)
                == "a file of 10 bytes is at the final name (the source is 10 bytes) — it is not counted as a copy and was left untouched; 4 of 10 bytes kept in .videoscan-partial for the next run.")
        #expect(R.notCopiedLine(relative: "a.mov", source: .notRegular, staged: .absent, stderr: "")
                == "a.mov — rsync exited 0 but the copy is not whole: nothing was staged, and the source is not a regular file rsync would copy; nothing was published at the final name.")
        #expect(R.notCopiedLine(relative: "a.mov", source: .absent, staged: .regular(7), stderr: "")
                == "a.mov — rsync exited 0 but the copy is not whole: the staged copy is 7 bytes but the source could not be measured to compare; it is kept in .videoscan-partial; nothing was published at the final name.")
        #expect(R.stagedCopyFate(removed: true) == "The copy VideoScan staged in .videoscan-partial was removed (it was its own).")
        #expect(R.stagedCopyFate(removed: false) == "The copy VideoScan staged in .videoscan-partial could not be removed and is still there.")

        let written = R.doneSummary(safe: 0, failed: 0, bytesWritten: 0, alreadyPresent: 0).components(separatedBy: " · ")[2]
        #expect(R.doneSummary(safe: 3, failed: 1, bytesWritten: 0, alreadyPresent: 0, interrupted: 1, notAttempted: 5)
                == "3 at the destination (size checked) · 1 failed · \(written) · 1 interrupted by Stop · 5 not attempted")
        #expect(R.doneSummary(safe: 3, failed: 2, bytesWritten: 0, alreadyPresent: 1, nameTaken: 1)
                == "3 at the destination (size checked) · 2 failed (1 not replaced: a different file was already there) · \(written) · 1 already there")
        // The name check (pure): free / already there (same size — content is not compared) / taken.
        #expect(R.nameCheck(relative: "a/b.mov", folder: "Rescued", source: .regular(10), final: .absent) == .free)
        #expect(R.nameCheck(relative: "a/b.mov", folder: "Rescued", source: .regular(10), final: .regular(10)) == .alreadyThere(10))
        #expect(R.nameCheck(relative: "a/b.mov", folder: "Rescued", source: .regular(10), final: .regular(7))
                == .taken("a/b.mov — a different file is already at Rescued/a/b.mov (7 bytes there, 10 bytes on the source) — not replaced; nothing was touched, and the file is still on the source."))
        #expect(R.nameCheck(relative: "a/b.mov", folder: "Rescued", source: .regular(10), final: .notRegular)
                == .taken("a/b.mov — a different file is already at Rescued/a/b.mov (not a regular file there — a folder or a link, 10 bytes on the source) — not replaced; nothing was touched, and the file is still on the source."))
        #expect(R.nameCheck(relative: "a/b.mov", folder: "Rescued", source: .absent, final: .regular(7))
                == .taken("a/b.mov — a different file is already at Rescued/a/b.mov (7 bytes there, the source could not be measured) — not replaced; nothing was touched."))
        #expect(R.isNameTaken(RescueFileCopier.Failure.differentFileAtDestination("/x", thereBytes: 1, sourceBytes: 2))
                && R.isNameTaken(RescueFileCopier.Failure.destinationAppearedDuringCopy("/x"))
                && R.isNameTaken(RescueFileCopier.Failure.destinationNotRegularFile("/x"))
                && !R.isNameTaken(RescueFileCopier.Failure.cancelled))
        #expect(R.doneTitle(stopped: false, failed: 0) == "Copy finished")
        #expect(R.doneTitle(stopped: false, failed: 2) == "Copy finished — 2 files failed")
        #expect(R.doneTitle(stopped: true, failed: 2) == "Copy stopped")
        #expect(R.doneDetail(errors: []) == nil && R.doneDetail(errors: ["one"]) == "one")
        #expect(R.outcomeLine(stopped: true, planned: 9, summary: "S", destination: "/D/Rescued", elapsedSeconds: 4)
                == "rescue OUTCOME: stopped — 9 planned: S — destination /D/Rescued, 4 s")
        for mode in RescueCopyMode.allCases {
            #expect(!mode.rawValue.localizedCaseInsensitiveContains("verified") || mode == .fast, "the label claims verification: \(mode.rawValue)")
            #expect(!mode.description.localizedCaseInsensitiveContains("guarantee"), "\(mode.description)")
        }
        #expect(RescueCopyMode.verified.rawValue == "rsync --checksum (size checked)")
    }

    /// Sensor: the shape of the fix in the source (Codex r1 #1, #2, #7).
    @Test("sensor: rsync writes only the STAGED copy; the one publish is an exclusive rename after the fresh size check; only the own staged copy is ever removed")
    func theShapeInTheSource() throws {
        let source = try SourceTree.appSource(named: "VolumeCompare.swift")
        let start = try #require(source.range(of: "private nonisolated func rsyncCopy("))
        let end = try #require(source.range(of: "// MARK: - What happened to one file (GH #506)", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(body.contains("\"--partial\",") && body.contains("staging.stagedPath\n"), "rsync's destination is the staged copy, kept on interruption")
        #expect(!body.contains("--partial-dir") && !body.contains("destFile\n                ],"), "rsync is given a final name")
        // Refuse before mutating: the name check, mkdir, the staging (no link followed), rsync, the publish — in that order.
        let check = try #require(body.range(of: "switch Self.nameCheck("))
        let mkdir = try #require(body.range(of: "executable: \"/bin/mkdir\""))
        let staged = try #require(body.range(of: "RsyncStaging.open(relative: relative, rescueDir: rescueDir, destFile: destFile)"))
        let rsync = try #require(body.range(of: "executable: \"/usr/bin/rsync\""))
        let sizeCheck = try #require(body.range(of: "guard let size = source.regularSize, staged == .regular(size) else {"))
        let publish = try #require(body.range(of: "switch staging.publish() {"))
        #expect(check.lowerBound < mkdir.lowerBound && mkdir.lowerBound < staged.lowerBound && staged.lowerBound < rsync.lowerBound
                && rsync.lowerBound < sizeCheck.lowerBound && sizeCheck.lowerBound < publish.lowerBound)
        // …and in the fast loop before its createDirectory.
        let fastStart = try #require(source.range(of: "private nonisolated func fastCopy("))
        let fast = String(source[fastStart.upperBound..<start.lowerBound])
        let fastCheck = try #require(fast.range(of: "Self.nameCheck("))
        let fastMkdir = try #require(fast.range(of: "fm.createDirectory(atPath: destDir"))
        #expect(fastCheck.lowerBound < fastMkdir.lowerBound)
        #expect(!source.contains("recopiedIncomplete") && !source.contains("filesRepaired"), "the replace-an-incomplete-file path is back")
        #expect(!body.contains("--remove-source-files") && !body.contains("--delete"), "nothing at the source or destination is removed")
        // One place counts (record): .copied only from a publish that landed, .alreadyThere from a same-size file at the name.
        #expect(body.components(separatedBy: "filesCopied += 1").count == 3, "a new place counts a file at the destination")
        #expect(body.components(separatedBy: "return .copied(").count == 2, "copied is returned anywhere but after the publish")
        let published = try #require(body.range(of: "case .published:"))
        let copied = try #require(body.range(of: "return .copied(size)", range: published.upperBound..<body.endIndex))
        #expect(body.distance(from: published.upperBound, to: copied.lowerBound) < 40, "copied is not directly under the publish")
        let taken = try #require(body.range(of: "case .nameTaken:"))
        #expect(body.components(separatedBy: "staging.removeStaged()").count == 2
                && body.range(of: "staging.removeStaged()")!.lowerBound > taken.lowerBound, "the staged copy is removed anywhere but after a taken name")
        #expect(!body.contains("unlink(") && !body.contains("removeItem") && !body.contains("rename("), "the rescue deletes or renames outside the staging type")
        // The staging type: folders opened without following a link; the one publish is RENAME_EXCL; removals relative to the staging fd.
        let typeStart = try #require(source.range(of: "struct RsyncStaging: Sendable {"))
        let type = String(source[typeStart.lowerBound...])
        #expect(type.contains("O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC"))
        #expect(type.contains("renameatx_np(stagingDir, name, destDir, name, UInt32(RENAME_EXCL))"))
        #expect(type.contains("unlinkat(stagingDir, name, 0)") && type.contains("unlinkat(destDir, VolumeRescueOperation.partialDirName, AT_REMOVEDIR)"))
    }

    // MARK: - A different file already at a destination name (was PARKED RED)

    /// Was PARKED RED (found 2026-11-21 while fixing GH #506); fixed the
    /// same day — rule 2: "Trash, never unlink … refuse rather than guess."
    /// The rescue keyed a file by its path RELATIVE to the source volume and
    /// never asked what was already at that name: a successful rsync
    /// replaced it, and the fast copier took any different-size file for
    /// "an incomplete copy from an earlier run" and replaced it too — the
    /// previous bytes unlinked, not trashed. The full matrix (same size,
    /// directory, symlink, a file that appears mid-way, two camera cards)
    /// is VolumeRescueNeverReplacesTests; this is the original row.
    @Test("a DIFFERENT file already at the destination name is never replaced by a rescue: its bytes survive, and the source file is reported, not lost",
          arguments: [RescueCopyMode.verified, .fast])
    func aDifferentFileAlreadyAtTheDestinationIsDestroyed(_ mode: RescueCopyMode) async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        // Another volume's file, rescued earlier under the same relative path.
        try FileManager.default.createDirectory(at: b.dest(0).deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try MasterArchiveTestSupport.writeBlob(at: b.dest(0), bytes: 30_000, seed: 404)
        let earlierSHA = Self.sha(b.dest(0))
        #expect(earlierSHA != b.sources[0].sha, "the bench: two different files")
        let mock = b.mock().on("rsync", .passThrough)
        let done = await mock.scoped {
            b.op.start(files: b.sources.map(\.record), sourcePath: b.sourceVolume.path, destPath: b.destVolume.path, mode: mode)
            return await waitUntilDone(b)
        }
        #expect(done)
        b.expectSourcesUntouched()
        #expect(Self.sha(b.dest(0)) == earlierSHA, "the file that was at \(b.dest(0).lastPathComponent) was replaced — its bytes are gone, not in the Trash")
        #expect(b.op.filesCopied == 0 && b.op.filesFailed == 1, "reported as a copy: at destination \(b.op.filesCopied), failed \(b.op.filesFailed)")
        #expect(b.op.errors.first?.contains("a different file is already at") == true, "\(b.op.errors)")
    }

    // MARK: - The log

    /// GH #506 item 5 (was parked RED). The rescue is still not an MFO job
    /// (no Pause, no stall watchdog — a bigger design, noted in the issue);
    /// what it now has is the audit trail: one START and one OUTCOME line
    /// through the one log sink, with counts.
    @Test("a rescue writes one START and one OUTCOME line through the one log sink, with the counts and the words \"size checked\"")
    func theRescueWritesStartAndOutcome() async throws {
        let b = try bench(files: 2)
        defer { b.cleanup() }
        let sink = InMemoryLogSink()
        let mock = b.mock()
            .on("rsync", containing: ["tape 2.mov"], Self.rsyncLeaving(fraction: 0, stderr: "rsync: read errors mapping \"tape 2.mov\": Input/output error (5)\n", exit: 23))
            .on("rsync", .passThrough)
        let done = await withAppLog(sink) { await run(b, mock) }
        #expect(done && b.op.filesCopied == 1 && b.op.filesFailed == 1)
        let starts = sink.lines.filter { $0.contains("rescue START") }
        let outcomes = sink.lines.filter { $0.contains("rescue OUTCOME") }
        #expect(starts.count == 1 && outcomes.count == 1, "\(sink.lines)")
        #expect(starts.first?.contains("2 file(s)") == true && starts.first?.contains(b.rescued.path) == true, "\(starts)")
        #expect(outcomes.first?.contains("done — 2 planned: 1 at the destination (size checked) · 1 failed") == true, "\(outcomes)")
        #expect(outcomes.first?.contains("1 failed") == true, "\(outcomes)")
        #expect(outcomes.first?.localizedCaseInsensitiveContains("verified") == false, "size equality is not verification: \(outcomes)")
        // The failed file's own line is in the log too.
        #expect(sink.lines.contains { $0.contains("rescue FAILED") && $0.contains("tape 2.mov") && $0.contains("rsync exit 23") }, "\(sink.lines)")
    }
}
