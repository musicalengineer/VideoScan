// VolumeRescueRsyncNegativeMatrixTests.swift — the negative matrix for
// Compare Volumes → "Verified (rsync --checksum)" rescue
// (Volumes/VolumeCompare.swift, VolumeRescueOperation.rsyncCopy), which
// COPIES FAMILY MEDIA to another volume. Until 2026-11-21 its `/bin/mkdir`
// and `/usr/bin/rsync` were hand-rolled Process() sites no test could
// reach; they now go through ProcessRunner, so a ScriptedExecutor answers
// them. Workflow, in Rick's words: "copy the files this volume is missing
// onto that one, checked."
//
// RULE 10: this is a relocate/copy path. The spawn was converted
// mechanically — its behaviour is UNCHANGED — so every misbehaviour this
// matrix finds is PARKED RED under `withKnownIssue`, with its severity and
// a proposed fix, for Rick and Codex. Nothing is fixed here.
//
// What every row asserts (rules 1 and 2):
//   • the outcome is named truthfully (counters, the error lines);
//   • nothing is reported copied / safe / written that was not;
//   • no source is touched (same SHA-256, same mtime; the source is only
//     ever rsync's SOURCE argument);
//   • what is left at the destination is said.
//
// Rows: the command lines + a positive control with the REAL mkdir and
// rsync · exit 23 / 24 with a truncated file left at the final name · killed
// by a signal · hang + Stop · Stop before the first file · launch failure ·
// exit 0 with nothing (or a truncated file) at the destination · one file of
// three fails · mkdir cannot start · mkdir exits nonzero · the log.
//
// PARKED RED (withKnownIssue), highest first:
//   P0  exit 0 is believed without evidence: a missing or short destination
//       is counted "safe" (rule 1; Codex r1: the REAL rsync skipped a
//       directory, exited 0 and created no destination)
//   P1  a failed transfer's truncated file stays at the FINAL name and the
//       report does not say so (--partial; known since 2026-09-13)
//   P2  a child killed by a signal with no stderr is reported with no reason
//   P2  a Stop is reported as "done, 1 failed" — it never says it was
//       stopped or how many files were never attempted
//   P2  no START / OUTCOME through the one log sink (rule 5: not an MFO job)
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
        /// rsync <three flags> <a source> <its destination>: the source is
        /// never written to, the destination never read from.
        func expectOnlyTheTwoCommands(_ mock: ScriptedExecutor, sourceLocation: SourceLocation = #_sourceLocation) {
            for call in mock.calls {
                switch call.tool {
                case "mkdir":
                    #expect(call.executable == "/bin/mkdir" && call.arguments.count == 2 && call.arguments[0] == "-p"
                            && call.arguments[1].hasPrefix(rescued.path), "\(call)", sourceLocation: sourceLocation)
                case "rsync":
                    let ok = call.executable == "/usr/bin/rsync" && call.arguments.count == 5
                        && Array(call.arguments.prefix(3)) == ["--checksum", "--partial", "--times"]
                        && sources.contains { $0.url.path == call.arguments[3] && rescued.appendingPathComponent($0.relative).path == call.arguments[4] }
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

    /// An rsync that leaves `fraction` of the source at the FINAL name (what
    /// `--partial` does on an interrupted transfer), prints `stderr`, and
    /// exits `exit`.
    static func rsyncLeaving(fraction: Double, stderr: String, exit: Int32) -> ScriptedExecutor.Behaviour {
        .custom { request in
            let (src, dst) = (request.arguments[3], request.arguments[4])
            if fraction > 0, let data = try? Data(contentsOf: URL(fileURLWithPath: src)) {
                try? data.prefix(Int(Double(data.count) * fraction)).write(to: URL(fileURLWithPath: dst))
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
                    ["/usr/bin/rsync", "--checksum", "--partial", "--times", s.url.path, dst]]
        }
        #expect(mock.calls.map { [$0.executable] + $0.arguments } == expected)
        b.expectOnlyTheTwoCommands(mock)

        #expect(b.op.filesCopied == 2 && b.op.filesFailed == 0 && b.op.errors.isEmpty)
        #expect(b.op.bytesWritten == b.sources.reduce(0) { $0 + $1.size })
        #expect(b.op.isRunning == false && b.op.progress == 1.0)
        for (i, s) in b.sources.enumerated() {
            #expect(Self.sha(b.dest(i)) == s.sha, "the copy is not the source: \(s.relative)")
            let mtime = (try? FileManager.default.attributesOfItem(atPath: b.dest(i).path)[.modificationDate]) as? Date
            #expect(mtime == s.mtime, "--times did not carry the mtime")
        }
        b.expectSourcesUntouched()
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
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync: rsync: write failed: Input/output error (5)\n\(words)"])
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()

        // What is left at the destination: half a file, under the final name.
        let left = VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path)
        #expect(left == b.sources[0].size / 2, "the bench did not leave the truncated file this row is about")
        // P1 — a truncated file named like a good one stays at the
        // destination and the report does not mention it; a catalog scan of
        // the destination before the next rescue would record it as a file.
        // (VolumeCompare.swift's own NOTE of 2026-09-13.) Proposed fix:
        // `--partial-dir=.videoscan-partial` so an interrupted transfer never
        // sits at the final name, AND the error line says what is at the
        // destination ("nothing left" / "N of M bytes in .videoscan-partial").
        // VALIDATION NOTE (Codex r1): this bench's rsync is a mock that
        // writes the truncated file at the final name whatever flags it is
        // given, so this row can go green only on the report half; the
        // `--partial-dir` half must be proven with an ACTUAL interrupted
        // transfer by the real rsync.
        withKnownIssue("P1: a failed rsync leaves a truncated file at the FINAL name and the report does not say so") {
            #expect(left == nil, "a truncated \(left ?? 0)-byte file is at the final name \(b.dest(0).lastPathComponent)")
            #expect(b.op.errors.first?.localizedCaseInsensitiveContains("destination") == true,
                    "the error line does not say what is left at the destination")
        }
    }

    @Test("rsync is killed by a signal: the file is FAILED, nothing counted copied")
    func killedBySignal() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", .crash(signal: 9))
        #expect(await run(b, mock))

        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors.count == 1)
        #expect(b.op.errors.first?.hasPrefix("\(b.sources[0].relative) — rsync: ") == true)
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path) == nil)
        b.expectSourcesUntouched()
        // P2 — the reason is EMPTY: "tape 1.mov — rsync: ". The code falls
        // back to "exit N" only when stderr is not UTF-8, never when it is
        // empty, so a SIGKILL (the out-of-memory killer, a force-quit) reads
        // as a failure with no cause. Proposed fix: an empty stderr →
        // "killed by signal N" / "exit N".
        withKnownIssue("P2: an rsync killed by a signal with no stderr is reported with no reason at all") {
            let reason = b.op.errors.first?.components(separatedBy: " — rsync: ").last ?? ""
            #expect(!reason.isEmpty, "the error line names no reason: \(b.op.errors)")
        }
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

        // Today's words for it (pinned so a change is seen):
        #expect(b.op.filesFailed == 1)
        #expect(b.op.errors == ["\(b.sources[0].relative) — rsync: rsync error: received SIGINT, SIGTERM, or SIGHUP (code 20)"])
        // P2 — a Stop is reported exactly like a finished rescue with one
        // bad file: "0 safe · 1 failed", isDone. It never says it was
        // STOPPED, and the two files never attempted are in no count.
        // Proposed fix: a named outcome (stopped: N copied, M not attempted;
        // the in-flight file is not "failed") and the banner says "Stopped".
        withKnownIssue("P2: a stopped rescue is reported as done with a failed file — never as stopped, and the unattempted files are not counted") {
            #expect(b.op.errors.contains { $0.localizedCaseInsensitiveContains("stopped") },
                    "nothing says the rescue was stopped: \(b.op.errors)")
            #expect(b.op.filesFailed == 0, "the file in flight at Stop is counted as a failed copy")
        }
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

    @Test("rsync prints errors yet exits 0 and the destination is missing or short: today that is counted SAFE",
          arguments: ["missing", "truncated"])
    func exitZeroWithoutTheFile(_ shape: String) async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = b.mock().on("rsync", Self.rsyncLeaving(fraction: shape == "missing" ? 0 : 0.5,
                                                         stderr: "rsync: write failed on \"tape 1.mov\": No space left on device (28)\n", exit: 0))
        #expect(await run(b, mock))

        let left = VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path)
        #expect(left == (shape == "missing" ? nil : b.sources[0].size / 2))
        // Bytes are honest either way: only what is measured at the destination.
        #expect(b.op.bytesWritten == (left ?? 0))
        b.expectOnlyTheTwoCommands(mock)
        b.expectSourcesUntouched()
        // P0 — rule 1: "safe" is shown from an exit status, not from
        // evidence. (Re-ranked from P1 by Codex r1, 2026-11-21: this is not
        // only a mock's story — the installed rsync, given a directory,
        // skipped it, exited 0 and created no destination. The
        // ENOSPC-with-exit-0 line this row prints is synthetic.) The code measures the destination for the BYTES and
        // still counts the file copied when there is nothing (or half a
        // file) there, and rsync's stderr is dropped on exit 0. Proposed
        // fix: after exit 0, require the destination's measured size to
        // equal the source's (fstat both); otherwise FAILED — "rsync exited
        // 0 but the destination is missing / N of M bytes" — and keep
        // stderr in the line. NOTE (Codex): a fresh regular-file + size
        // check closes the missing and short cases only; size equality is
        // NOT content verification (that is what --checksum, or a hash of
        // the destination, is for).
        withKnownIssue("P0: rsync's exit 0 is believed without evidence — a \(shape) destination is counted as a safe copy") {
            #expect(b.op.filesCopied == 0, "\(b.op.filesCopied) file reported safe with \(left.map { "\($0) of \(b.sources[0].size) bytes" } ?? "nothing") at the destination")
            #expect(b.op.filesFailed == 1)
            #expect(!b.op.errors.isEmpty, "rsync's own error line was dropped")
        }
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
        #expect(b.op.errors.first?.hasPrefix("Tapes/1994/tape 2.mov — rsync: ") == true)
        #expect(Self.sha(b.dest(0)) == b.sources[0].sha && Self.sha(b.dest(2)) == b.sources[2].sha)
        #expect(mock.calls(to: "rsync").count == 3, "the run stopped at the failure instead of going on")
        // Said here, parked in partialTransferExit: file 2 is at its final
        // name with a quarter of its bytes.
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(1).path) == b.sources[1].size / 4)
        #expect(Self.sha(b.dest(1)) != b.sources[1].sha)
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

    @Test("mkdir exits nonzero: its status is not read (as before) — rsync runs, fails on the missing directory, and names it")
    func mkdirExitsNonzero() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let mock = ScriptedExecutor(claiming: [b.root.path])
            .on("mkdir", .output(stderr: "mkdir: \(b.rescued.path)/Tapes: Permission denied\n", exit: 1))
            .on("rsync", .passThrough)                       // the REAL rsync, into a directory that was never made
        #expect(await run(b, mock))

        #expect(mock.calls(to: "rsync").count == 1)
        #expect(b.op.filesFailed == 1 && b.op.filesCopied == 0 && b.op.bytesWritten == 0)
        #expect(b.op.errors.first?.hasPrefix("\(b.sources[0].relative) — rsync: ") == true, "\(b.op.errors)")
        #expect(b.op.errors.first?.contains("No such file or directory") == true, "\(b.op.errors)")
        #expect(VolumeRescueOperation.measuredSize(ofFileAt: b.dest(0).path) == nil)
        b.expectSourcesUntouched()
    }

    // MARK: - The log

    @Test("PARKED (P2): a rescue writes no START / OUTCOME line through the one log sink")
    func noStartOutcomeInTheLog() async throws {
        let b = try bench(files: 1)
        defer { b.cleanup() }
        let sink = InMemoryLogSink()
        let mock = b.mock().on("rsync", .passThrough)
        let done = await withAppLog(sink) { await run(b, mock) }
        #expect(done && b.op.filesCopied == 1)
        // P2 — rule 5 ("long work is an MFO job: progress, Pause/Stop,
        // START/OUTCOME through the one log sink; nothing runs silently").
        // A rescue that copies family media for hours logs only to os_log:
        // videoscan.log has no trace of what was copied where, or how it
        // ended. Proposed fix: run it as an MFO job (which also gives it
        // Pause, the stall watchdog and a named outcome).
        withKnownIssue("P2: Volume rescue is not an MFO job — no START/OUTCOME in videoscan.log") {
            #expect(sink.contains("START"), "\(sink.lines)")
            #expect(sink.contains("OUTCOME"), "\(sink.lines)")
        }
    }
}
