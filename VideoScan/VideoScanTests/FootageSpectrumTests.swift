// FootageSpectrumTests.swift
// "Compare Footage…" (Footage Spectrum trial, 2026-10-03).
//
// Dimensions (feature-test checklist):
//   Logic     — the planner (order, cap 8, reference = archive copy else the
//               longest, offline left out, < 2 refused), sets.json, the
//               helper's lines, time left, words, the navigation rule.
//   Lifecycle — the job with a STUB launcher (no Python, no ffmpeg, no
//               media): progress → row text and bar; DONE → summary + page;
//               ERROR / non-zero exit → failed with the reason; Stop → the
//               launcher sees cancellation, the row says Stopped; missing
//               helper → a friendly failure; START/OUTCOME written once.
//   Isolation — the store root is injected; a tripwire proves nothing is
//               written outside it, the "media" are untouched, and the prune
//               removes only old UUID run folders under <root>/runs.
//   Scale     — 100k records: resolving the chosen ids goes through the
//               model's index, within a budget.
//   Sensor    — no delete / trash / move anywhere in the new files except the
//               one run-folder prune; no file opened for writing; the window
//               refuses the network.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

private func candidate(_ name: String, size: Int64 = 1_000, duration: Double = 60, archive: Bool = false,
                       readable: Bool = true, volume: String = "Alpha", id: UUID = UUID()) -> FootageSpectrumCandidate {
    FootageSpectrumCandidate(id: id, filename: name, path: "/Volumes/\(volume)/\(name)", sizeBytes: size,
                             durationSeconds: duration, volumeLabel: volume, isArchiveCopy: archive,
                             isReadable: readable)
}

private func plan(_ c: [FootageSpectrumCandidate], first: UUID? = nil) throws -> FootageSpectrumPlan {
    try FootageSpectrumPlanner.plan(candidates: c, title: "test", preferredFirst: first).get()
}

// MARK: - Planner

@Suite("Footage Spectrum — planner")
struct FootageSpectrumPlannerTests {

    @Test func theLongestIsTheReferenceWhenThereIsNoArchiveCopy() throws {
        let p = try plan([candidate("test_a.mov", size: 10, duration: 30),
                          candidate("test_b.mov", size: 5, duration: 90),
                          candidate("test_c.mov", size: 20, duration: 60)])
        #expect(p.members.map(\.filename) == ["test_c.mov", "test_a.mov", "test_b.mov"], "biggest first")
        #expect(p.reference.filename == "test_b.mov")
        #expect(p.leftOut.isEmpty)
    }

    @Test func anArchiveCopyGoesFirstAndIsTheReference() throws {
        let p = try plan([candidate("test_long.mov", size: 50, duration: 600),
                          candidate("test_archive.mov", size: 1, duration: 10, archive: true)])
        #expect(p.referenceIndex == 0 && p.reference.filename == "test_archive.mov")
    }

    @Test func thePreferredFirstComesAfterArchiveCopiesAndBeforeSize() throws {
        let original = UUID()
        let p = try plan([candidate("test_big.mov", size: 99), candidate("test_orig.mov", size: 1, id: original),
                          candidate("test_arch.mov", size: 2, archive: true)], first: original)
        #expect(p.members.map(\.filename) == ["test_arch.mov", "test_orig.mov", "test_big.mov"])
    }

    @Test func offlineFilesAreLeftOutWithAReason() throws {
        let p = try plan([candidate("test_a.mov"), candidate("test_off.mov", readable: false), candidate("test_b.mov")])
        #expect(p.members.count == 2)
        #expect(p.leftOut.map(\.filename) == ["test_off.mov"])
        #expect(p.leftOut[0].reason.contains("not connected"))
    }

    @Test func atMostEightAreCompared() throws {
        let many = (0..<11).map { candidate("test_\($0).mov", size: Int64(100 - $0)) }
        let p = try plan(many)
        #expect(p.members.count == FootageSpectrumPlanner.maxFiles)
        #expect(p.leftOut.count == 3 && p.leftOut.allSatisfy { $0.reason.contains("over the limit") })
        #expect(p.members.map { $0.label.prefix(1) } == ["A", "B", "C", "D", "E", "F", "G", "H"])
    }

    @Test func fewerThanTwoReadableIsRefusedWithTheReason() {
        let none = FootageSpectrumPlanner.plan(candidates: [candidate("test_a.mov", readable: false),
                                                            candidate("test_b.mov", readable: false)], title: "t")
        guard case .failure(let r0) = none else { Issue.record("expected a refusal"); return }
        #expect(r0.reason.contains("None of the 2"))
        let one = FootageSpectrumPlanner.plan(candidates: [candidate("test_a.mov"),
                                                           candidate("test_b.mov", readable: false)], title: "t")
        guard case .failure(let r1) = one else { Issue.record("expected a refusal"); return }
        #expect(r1.reason.contains("Only 1 of the 2"))
        let single = FootageSpectrumPlanner.plan(candidates: [candidate("test_a.mov")], title: "t")
        guard case .failure(let r2) = single else { Issue.record("expected a refusal"); return }
        #expect(r2.reason.contains("only one was chosen"))
    }

    @Test func theSameFileTwiceIsComparedOnce() throws {
        let c = candidate("test_a.mov")
        let result = FootageSpectrumPlanner.plan(candidates: [c, c], title: "t")
        guard case .failure = result else { Issue.record("one file twice is still one file"); return }
        let p = try plan([c, c, candidate("test_b.mov")])
        #expect(p.members.count == 2)
    }

    @Test func repeatedNamesGetTheirVolumeInTheLabel() throws {
        let p = try plan([candidate("test_x.mov", size: 2, volume: "Alpha"),
                          candidate("test_x.mov", size: 1, volume: "Beta")])
        #expect(p.members.map(\.label) == ["A · test_x.mov (Alpha)", "B · test_x.mov (Beta)"])
    }

    @Test func theSelectionRule() {
        #expect(!FootageSpectrumPlanner.selectionAllowed(0) && !FootageSpectrumPlanner.selectionAllowed(1))
        #expect(FootageSpectrumPlanner.selectionAllowed(2) && FootageSpectrumPlanner.selectionAllowed(8))
        #expect(!FootageSpectrumPlanner.selectionAllowed(9))
        #expect(FootageSpectrumPlanner.selectionHelp(9).contains("up to 8"))
    }

    @Test func setsJSONCarriesTheReferenceIndexAndEveryFile() throws {
        let p = try plan([candidate("test_a.mov", size: 9, duration: 10),
                          candidate("test_b.mov", size: 1, duration: 99)])
        let obj = try JSONSerialization.jsonObject(with: FootageSpectrumSets.json(for: p)) as? [[String: Any]]
        let set = try #require(obj?.first)
        #expect(set["reference"] as? Int == 1)
        let files = try #require(set["files"] as? [[String: String]])
        #expect(files.map { $0["path"] } == ["/Volumes/Alpha/test_a.mov", "/Volumes/Alpha/test_b.mov"])
        #expect((set["note"] as? String)?.contains("the longest") == true)
    }
}

// MARK: - Lines, time left, words

@Suite("Footage Spectrum — helper lines and words")
struct FootageSpectrumProtocolTests {

    @Test func parsesEveryKindOfLine() throws {
        let est = FootageSpectrumProtocol.parse(#"ESTIMATE {"files":[{"file":1,"label":"A · x","seconds":2.5,"cached":false}],"total_seconds":2.5}"#)
        #expect(est == .estimate([.init(file: 1, label: "A · x", seconds: 2.5, cached: false)], totalSeconds: 2.5))
        let p = FootageSpectrumProtocol.parse(#"PROGRESS {"file":2,"of":5,"label":"B · y.mov","phase":"reading","fraction":1.4}"#)
        #expect(p == .progress(.init(file: 2, of: 5, label: "B · y.mov", phase: .reading, fraction: 1)))
        let done = FootageSpectrumProtocol.parse(#"DONE {"html":"/r/page.html","files":3,"skipped":[{"label":"C","reason":"gone"}],"summary":{"same":1,"close":1,"part":0,"different":0,"covered":0.5},"results":[{"label":"B","verdict":"same","offset":12}]}"#)
        guard case .done(let d)? = done else { Issue.record("DONE not parsed"); return }
        #expect(d.files == 3 && d.skipped == [.init(label: "C", reason: "gone")] && d.summary?.same == 1)
        #expect(d.results == [.init(label: "B", verdict: "same", offset: 12)])
        let err = FootageSpectrumProtocol.parse(#"ERROR {"message":"no","missing":"numpy","skipped":[]}"#)
        #expect(err == .error(.init(message: "no", missing: "numpy", skipped: [])))
        #expect(FootageSpectrumProtocol.parse("   extracting A …") == nil)
        #expect(FootageSpectrumProtocol.parse("PROGRESS {not json") == nil)
        #expect(FootageSpectrumProtocol.parse(#"PROGRESS {"phase":"dancing"}"#) == nil)
    }

    @Test func timeLeftUsesTheEstimatesThenTheObservedRate() {
        let est = [10.0, 30.0]
        let early = FootageSpectrumETA.Position(file: 1, fraction: 0.5, phase: .reading)
        #expect(FootageSpectrumETA.secondsLeft(estimates: est, at: early, elapsed: 1) == 35)
        // 5 of 40 units done in 10 s → twice as slow as estimated: 70 s left.
        #expect(FootageSpectrumETA.secondsLeft(estimates: est, at: early, elapsed: 10) == 70)
        let fraction = FootageSpectrumETA.overallFraction(estimates: est, at: .init(file: 2, fraction: 0.5, phase: .reading))
        #expect(abs(fraction - 0.94 * 25 / 40) < 1e-9)
        #expect(FootageSpectrumETA.overallFraction(estimates: est, at: .init(file: 2, fraction: 1, phase: .writing)) == 0.98)
        #expect(FootageSpectrumETA.secondsLeft(estimates: [], at: early, elapsed: 5) == nil)
        #expect(FootageSpectrumETA.text(secondsLeft: 70) == "about 1:10 left")
        #expect(FootageSpectrumETA.text(secondsLeft: 17) == "about 20 s left")
        #expect(FootageSpectrumETA.text(secondsLeft: 2) == "almost done")
        #expect(FootageSpectrumETA.text(secondsLeft: 3_700) == "about 1 h 1 min left")
    }

    @Test func theRowTextAndTheSummary() {
        let p = FootageSpectrumProtocol.Progress(file: 2, of: 5, label: "B · test_clip.mov", phase: .reading, fraction: 0.3)
        #expect(FootageSpectrumWords.rowText(p, timeLeft: "about 1:10 left") == "Reading 2 of 5 · test_clip.mov · about 1:10 left")
        #expect(FootageSpectrumWords.rowText(.init(file: 5, of: 5, label: "", phase: .aligning, fraction: 0), timeLeft: "")
                == "Lining up 5 videos")
        let s = FootageSpectrumProtocol.Summary(same: 3, close: 1, part: 0, different: 1, covered: 0.9)
        #expect(FootageSpectrumWords.summary(files: 5, summary: s, leftOut: 0)
                == "Compared 5 videos — 3 the same footage, 1 close, 1 different")
        #expect(FootageSpectrumWords.summary(files: 2, summary: nil, leftOut: 1) == "Compared 2 videos · 1 left out")
        #expect(FootageSpectrumWords.verdictWords("same", offset: 70) == "the same footage, starting 1:10 into the reference")
    }

    @Test func theWindowGoesNowhereButItsRunFolder() {
        let run = URL(fileURLWithPath: "/tmp/spectrum-test/runs/\(UUID().uuidString)")
        #expect(FootageSpectrumNavigationPolicy.allows(run.appendingPathComponent("page.html"), runFolder: run))
        #expect(FootageSpectrumNavigationPolicy.allows(URL(string: "about:blank"), runFolder: run))
        #expect(!FootageSpectrumNavigationPolicy.allows(URL(string: "https://example.com/"), runFolder: run))
        #expect(!FootageSpectrumNavigationPolicy.allows(URL(fileURLWithPath: "/etc/hosts"), runFolder: run))
        #expect(!FootageSpectrumNavigationPolicy.allows(run.appendingPathComponent("../other/page.html"), runFolder: run))
        #expect(!FootageSpectrumNavigationPolicy.allows(nil, runFolder: run))
        #expect(FootageSpectrumNavigationPolicy.blockNetworkRules.contains("https?"))
    }

    @Test func aMissingHelperIsNamed() throws {
        let missing = FootageSpectrumHelper.locate(python: "/nonexistent/python3", script: "/nonexistent.py",
                                                   ffmpeg: "/nonexistent/ffmpeg", ffprobe: "/nonexistent/ffprobe")
        guard case .failure(let r) = missing else { Issue.record("expected missing"); return }
        #expect(r.reason.contains("Python helper"))
        let noScript = FootageSpectrumHelper.locate(python: "/bin/sh", script: "", ffmpeg: "/bin/sh", ffprobe: "/bin/sh")
        guard case .failure(let r2) = noScript else { Issue.record("expected missing script"); return }
        #expect(r2.reason.contains("footage_spectrum.py"))
        let noFFmpeg = FootageSpectrumHelper.locate(python: "/bin/sh", script: "/bin/sh", ffmpeg: "/nonexistent", ffprobe: "/bin/sh")
        guard case .failure(let r3) = noFFmpeg else { Issue.record("expected missing ffmpeg"); return }
        #expect(r3.reason.contains("ffmpeg"))
        let ok = try FootageSpectrumHelper.locate(python: "/bin/sh", script: "/bin/sh", ffmpeg: "/bin/sh", ffprobe: "/bin/sh").get()
        let inv = FootageSpectrumHelper.Invocation(tools: ok, setsFile: URL(fileURLWithPath: "/r/sets.json"),
                                                   outputPage: URL(fileURLWithPath: "/r/page.html"),
                                                   cacheDir: URL(fileURLWithPath: "/c"))
        #expect(inv.arguments.contains("--progress") && inv.arguments.contains("--cache-dir"))
        #expect(inv.environment["PYTHONUNBUFFERED"] == "1")
        #expect(inv.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }
}

// MARK: - Job lifecycle (stub launcher)

/// A thread-safe flag the stub launcher sets.
private final class StubFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _sawCancel = false
    private var _launches = 0
    var sawCancel: Bool { lock.lock(); defer { lock.unlock() }; return _sawCancel }
    var launches: Int { lock.lock(); defer { lock.unlock() }; return _launches }
    func cancelled() { lock.lock(); _sawCancel = true; lock.unlock() }
    func launched() { lock.lock(); _launches += 1; lock.unlock() }
}

@MainActor
@Suite("Footage Spectrum — job lifecycle", .serialized)
struct FootageSpectrumJobTests {

    private let fakeTools = FootageSpectrumTools(python: "/bin/sh", script: "/bin/sh", ffmpeg: "/bin/sh", ffprobe: "/bin/sh")

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func candidates(_ tag: String) -> [FootageSpectrumCandidate] {
        // Internal paths: no volume gate is created for them.
        [FootageSpectrumCandidate(id: UUID(), filename: "test_\(tag)_a.mov", path: "/tmp/test_\(tag)_a.mov", sizeBytes: 9,
                                  durationSeconds: 90, volumeLabel: "", isArchiveCopy: false, isReadable: true),
         FootageSpectrumCandidate(id: UUID(), filename: "test_\(tag)_b.mov", path: "/tmp/test_\(tag)_b.mov", sizeBytes: 5,
                                  durationSeconds: 30, volumeLabel: "", isArchiveCopy: false, isReadable: true)]
    }

    private func waitUntilDone(_ job: FootageSpectrumJob) async {
        for _ in 0..<400 where job.state.isActive {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Plays the lines a successful run prints, writing the page like the
    /// helper does (inside the run folder it was given).
    private func successLauncher(flags: StubFlags) -> FootageSpectrumHelper.Launcher {
        { invocation, onLine in
            flags.launched()
            onLine(#"ESTIMATE {"files":[{"file":1,"label":"A · test_a","seconds":4,"cached":false},{"file":2,"label":"B · test_b","seconds":4,"cached":false}],"total_seconds":8}"#)
            onLine("   extracting A … (human chatter is ignored)")
            onLine(#"PROGRESS {"file":1,"of":2,"label":"A · test_life_a.mov","phase":"reading","fraction":0.5}"#)
            onLine(#"PROGRESS {"file":2,"of":2,"label":"B · test_life_b.mov","phase":"reading","fraction":0.5}"#)
            onLine(#"PROGRESS {"file":2,"of":2,"label":"","phase":"writing","fraction":0}"#)
            try? "<html></html>".write(to: invocation.outputPage, atomically: true, encoding: .utf8)
            onLine(#"DONE {"html":"\#(invocation.outputPage.path)","files":2,"skipped":[],"summary":{"same":1,"close":0,"part":0,"different":0,"covered":1},"results":[{"label":"A · test_life_a.mov","verdict":"reference","offset":0},{"label":"B · test_life_b.mov","verdict":"same","offset":12}]}"#)
            return FootageSpectrumHelper.Exit(code: 0, stderrTail: "")
        }
    }

    @Test func aSuccessfulRunEndsWithTheSummaryAndThePageAndLogsOnce() async throws {
        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = StubFlags()
        let center = MediaFileOperationsCenter()
        var console: [String] = []
        let title = "life-\(UUID().uuidString)"
        let job = center.startFootageSpectrum(candidates: candidates("life"), title: title,
                                              store: FootageSpectrumStore(root: root), tools: .success(fakeTools),
                                              launcher: successLauncher(flags: flags), console: { console.append($0) })
        await waitUntilDone(job)
        for _ in 0..<100 where !sink.lines.contains(where: { $0.hasPrefix("compare footage done: \(title)") }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(job.state == .finished(summary: "Compared 2 videos — 1 the same footage"))
        #expect(job.pageURL == FootageSpectrumStore(root: root).pageFile(job.id))
        #expect(job.fraction == 1)
        #expect(flags.launches == 1)
        #expect(job.detailLines.map(\.text) == ["the reference", "the same footage, starting 0:12 into the reference"])
        let mine = sink.lines.filter { $0.contains(title) }
        #expect(mine.filter { $0.hasPrefix("compare footage: \(title) — read 2 videos") }.count == 1, "\(mine)")
        #expect(mine.filter { $0.hasPrefix("compare footage done: \(title)") }.count == 1, "\(mine)")
        #expect(mine.filter { $0.contains("— reading ") }.count == 2, "one line per file: \(mine)")
        #expect(console.contains { $0.hasPrefix("compare footage done: \(title)") })
        #expect(job.handledEvents == 5, "four kinds of line understood, the chatter ignored")
    }

    @Test func progressLinesDriveTheRowText() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The stub parks after one progress line until Stop.
        let launcher: FootageSpectrumHelper.Launcher = { _, onLine in
            onLine(#"ESTIMATE {"files":[{"file":1,"label":"A · test_p_a.mov","seconds":100,"cached":false}],"total_seconds":100}"#)
            onLine(#"PROGRESS {"file":1,"of":2,"label":"A · test_p_a.mov","phase":"reading","fraction":0.25}"#)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            return FootageSpectrumHelper.Exit(code: 143, stderrTail: "")
        }
        let center = MediaFileOperationsCenter()
        let job = center.startFootageSpectrum(candidates: candidates("p"), title: "progress",
                                              store: FootageSpectrumStore(root: root), tools: .success(fakeTools),
                                              launcher: launcher)
        for _ in 0..<200 where !job.subtitle.hasPrefix("Reading") {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(job.subtitle.hasPrefix("Reading 1 of 2 · test_p_a.mov · about"), "\(job.subtitle)")
        #expect(!job.isIndeterminate && job.fraction > 0.2 && job.fraction < 0.3)
        #expect(job.detailLines.first?.text.contains("reading") == true)
        job.cancel()
        await waitUntilDone(job)
        #expect(job.state == .cancelled)
    }

    @Test func stopTerminatesTheHelperAndTheRowSaysStopped() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = StubFlags()
        let launcher: FootageSpectrumHelper.Launcher = { _, onLine in
            flags.launched()
            onLine(#"PROGRESS {"file":1,"of":2,"label":"A","phase":"reading","fraction":0.1}"#)
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            flags.cancelled()   // what ProcessRunner's cancellation handler turns into SIGTERM
            return FootageSpectrumHelper.Exit(code: 143, stderrTail: "Terminated")
        }
        let center = MediaFileOperationsCenter()
        let job = center.startFootageSpectrum(candidates: candidates("stop"), title: "stop",
                                              store: FootageSpectrumStore(root: root), tools: .success(fakeTools),
                                              launcher: launcher)
        for _ in 0..<200 where flags.launches == 0 { try? await Task.sleep(nanoseconds: 5_000_000) }
        job.cancel()
        #expect(job.state == .cancelling)
        await waitUntilDone(job)
        #expect(flags.sawCancel, "the launcher must see the cancellation (→ SIGTERM)")
        #expect(job.state == .cancelled, "a Stop is never painted as Failed")
        #expect(job.subtitle.contains("cache is kept"))
    }

    @Test func anErrorLineFailsWithTheFriendlyReason() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher: FootageSpectrumHelper.Launcher = { _, onLine in
            onLine(#"ERROR {"message":"numpy is not installed","missing":"numpy","skipped":[]}"#)
            return FootageSpectrumHelper.Exit(code: 3, stderrTail: "")
        }
        let job = MediaFileOperationsCenter().startFootageSpectrum(
            candidates: candidates("err"), title: "err", store: FootageSpectrumStore(root: root),
            tools: .success(fakeTools), launcher: launcher)
        await waitUntilDone(job)
        #expect(job.state == .failed(message: FootageSpectrumWords.missingDependency("numpy")))
        #expect(job.pageURL == nil)
    }

    @Test func aSilentNonZeroExitFailsWithTheExitCode() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher: FootageSpectrumHelper.Launcher = { _, _ in FootageSpectrumHelper.Exit(code: 1, stderrTail: "Traceback") }
        let job = MediaFileOperationsCenter().startFootageSpectrum(
            candidates: candidates("exit"), title: "exit", store: FootageSpectrumStore(root: root),
            tools: .success(fakeTools), launcher: launcher)
        await waitUntilDone(job)
        guard case .failed(let message) = job.state else { Issue.record("expected failed, got \(job.state)"); return }
        #expect(message.contains("exit 1") && message.contains("Traceback"))
    }

    @Test func aMissingHelperFailsWithoutLaunchingAnything() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = StubFlags()
        let job = MediaFileOperationsCenter().startFootageSpectrum(
            candidates: candidates("miss"), title: "miss", store: FootageSpectrumStore(root: root),
            tools: .failure(.init(reason: FootageSpectrumWords.missingDependency("python"))),
            launcher: successLauncher(flags: flags))
        await waitUntilDone(job)
        #expect(job.state == .failed(message: FootageSpectrumWords.missingDependency("python")))
        #expect(flags.launches == 0)
    }

    @Test func fewerThanTwoReadableIsARefusedRowAndNothingRuns() async throws {
        let sink = InMemoryLogSink()
        let previous = appLog
        appLog = sink
        defer { appLog = previous }
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let flags = StubFlags()
        var c = candidates("ref")
        c[1].isReadable = false
        let title = "refused-\(UUID().uuidString)"
        let center = MediaFileOperationsCenter()
        let job = center.startFootageSpectrum(candidates: c, title: title, store: FootageSpectrumStore(root: root),
                                              tools: .success(fakeTools), launcher: successLauncher(flags: flags))
        #expect(job.wasRefused && !job.state.isActive)
        #expect(center.jobs.contains { $0.id == job.id })
        for _ in 0..<100 where !sink.lines.contains(where: { $0.contains(title) }) {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(sink.lines.filter { $0.contains(title) } == ["compare footage refused: \(title) — \(job.subtitle)"])
        #expect(flags.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runs").path), "nothing written")
    }
}

// MARK: - Isolation

@MainActor
@Suite("Footage Spectrum — isolation", .serialized)
struct FootageSpectrumIsolationTests {

    /// Every file under `dir` with its size and modification date.
    private func inventory(_ dir: URL) -> [String: String] {
        var out: [String: String] = [:]
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        while let u = e?.nextObject() as? URL {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out[Self.canon(u.path)] = "\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        return out
    }

    /// The enumerator may report /private/var/… for a /var/… temp folder.
    static func canon(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }

    @Test func theJobWritesOnlyUnderItsRootAndLeavesTheMediaAlone() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-trip-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let media = base.appendingPathComponent("media")
        let outside = base.appendingPathComponent("outside")
        for dir in [root, media, outside] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        // Poisoned state: an OLD run folder (pruned), an old non-run folder
        // and an old folder outside the store (both kept).
        let old = Date().addingTimeInterval(-30 * 86_400)
        let staleRun = root.appendingPathComponent("runs/\(UUID().uuidString)")
        let notARun = root.appendingPathComponent("runs/keep-me")
        let freshRun = root.appendingPathComponent("runs/\(UUID().uuidString)")
        for dir in [staleRun, notARun, freshRun, outside.appendingPathComponent("old")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dir in [staleRun, notARun, outside.appendingPathComponent("old")] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }
        let a = media.appendingPathComponent("test_a.mov"), b = media.appendingPathComponent("test_b.mov")
        try Data(repeating: 1, count: 4_096).write(to: a)
        try Data(repeating: 2, count: 2_048).write(to: b)
        let mediaBefore = inventory(media), outsideBefore = inventory(outside)

        let launcher: FootageSpectrumHelper.Launcher = { inv, onLine in
            try? "<html></html>".write(to: inv.outputPage, atomically: true, encoding: .utf8)
            onLine(#"DONE {"html":"x","files":2,"skipped":[],"results":[]}"#)
            return FootageSpectrumHelper.Exit(code: 0, stderrTail: "")
        }
        let cands = [a, b].map { url in
            FootageSpectrumCandidate(id: UUID(), filename: url.lastPathComponent, path: url.path, sizeBytes: 1,
                                     durationSeconds: 1, volumeLabel: "", isArchiveCopy: false, isReadable: true)
        }
        let store = FootageSpectrumStore(root: root)
        let job = MediaFileOperationsCenter().startFootageSpectrum(
            candidates: cands, title: "trip", store: store,
            tools: .success(.init(python: "/bin/sh", script: "/bin/sh", ffmpeg: "/bin/sh", ffprobe: "/bin/sh")),
            launcher: launcher)
        for _ in 0..<400 where job.state.isActive { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(job.state == .finished(summary: "Compared 2 videos"))

        #expect(inventory(media) == mediaBefore, "a media file was touched")
        #expect(inventory(outside) == outsideBefore, "something outside the store root changed")
        // Everything the run wrote is inside <root>.
        let written = inventory(base).keys.filter { !$0.hasPrefix(Self.canon(media.path)) && !$0.hasPrefix(Self.canon(outside.path)) }
        #expect(!written.isEmpty && written.allSatisfy { $0.hasPrefix(Self.canon(root.path)) }, "\(written)")
        #expect(FileManager.default.fileExists(atPath: store.setsFile(job.id).path))
        #expect(FileManager.default.fileExists(atPath: store.cacheDir.path))
        #expect(!FileManager.default.fileExists(atPath: staleRun.path), "a 30-day-old run is pruned")
        #expect(FileManager.default.fileExists(atPath: freshRun.path), "a fresh run is kept")
        #expect(FileManager.default.fileExists(atPath: notARun.path), "only UUID run folders are pruned")
    }

    /// QA P3-1: a `runs` folder that is a symlink is never followed — the
    /// prune must not delete anything at its destination.
    @Test func aSymlinkedRunsFolderIsNeverFollowedByThePrune() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-link-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root"), outside = base.appendingPathComponent("outside")
        let victim = outside.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60 * 86_400)],
                                              ofItemAtPath: victim.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("runs"), withDestinationURL: outside)
        #expect(FootageSpectrumStore(root: root).pruneOldRuns() == 0)
        #expect(FileManager.default.fileExists(atPath: victim.path), "the prune followed a symlinked runs folder")
    }

    /// QA P3-2: two offline copies with one name are two rows, not one id.
    @Test func twoOfflineCopiesWithOneNameGetDistinctDetailRows() throws {
        let cands = [candidate("test_a.mov", size: 3), candidate("test_b.mov", size: 2),
                     candidate("test_same.mov", readable: false, volume: "Alpha"),
                     candidate("test_same.mov", readable: false, volume: "Beta")]
        let p = try FootageSpectrumPlanner.plan(candidates: cands, title: "t").get()
        let unused = FileManager.default.temporaryDirectory.appendingPathComponent("spectrum-unused-\(UUID().uuidString)")
        let job = FootageSpectrumJob(plan: p, requestedIDs: cands.map(\.id), preferredFirst: nil,
                                     tools: .failure(.init(reason: "unused")), store: FootageSpectrumStore(root: unused),
                                     gates: [], launcher: { _, _ in FootageSpectrumHelper.Exit(code: 0, stderrTail: "") })
        let ids = job.detailLines.map(\.id)
        #expect(ids.count == 4 && Set(ids).count == 4, "\(job.detailLines)")
    }

    @Test func thePruneRuleIsPure() {
        let now = Date()
        let runs: [(url: URL, modified: Date)] = [
            (URL(fileURLWithPath: "/r/a"), now.addingTimeInterval(-15 * 86_400)),
            (URL(fileURLWithPath: "/r/b"), now.addingTimeInterval(-13 * 86_400)),
        ]
        #expect(FootageSpectrumStore.runsToPrune(runs, now: now) == [URL(fileURLWithPath: "/r/a")])
        #expect(FootageSpectrumStore.defaultRoot.path.hasSuffix("Library/Caches/VideoScan/spectrum"))
    }
}

// MARK: - Scale

@MainActor
@Suite("Footage Spectrum — scale")
struct FootageSpectrumScaleTests {

    private final class Probes { var count = 0 }

    /// QA P2-3: a steward group can be hundreds of clips; the main actor
    /// stats only as many as one run can compare (in the planner's order),
    /// and keeps going past offline ones until it has eight.
    @Test func aBigStewardGroupStatsAtMostWhatOneRunCanCompare() throws {
        let model = VideoScanModel()
        model.records = TriageFixture.records(40)
        let ids = model.records.map(\.id)
        let probes = Probes()
        let all = model.footageSpectrumCandidates(forIDs: ids, readable: { _ in probes.count += 1; return true })
        #expect(probes.count <= FootageSpectrumPlanner.maxFiles, "stat'ed \(probes.count) of \(ids.count)")
        #expect(all.count == 40)
        let plan = try FootageSpectrumPlanner.plan(candidates: all, title: "big").get()
        #expect(plan.members.count == 8 && plan.leftOut.count == 32)
        // Every third probe is offline: 11 probes find 8 readable, then stop.
        let some = Probes()
        let mixed = model.footageSpectrumCandidates(forIDs: ids, readable: { _ in some.count += 1; return some.count % 3 != 0 })
        #expect(some.count == 11)
        let p2 = try FootageSpectrumPlanner.plan(candidates: mixed, title: "mixed").get()
        #expect(p2.members.count == 8)
        #expect(p2.leftOut.filter { $0.reason.contains("not connected") }.count == 3)
    }

    /// 100k records, 8 chosen: candidates come through the id index (one
    /// index build, then O(chosen)) — a per-id catalog scan would be 800k
    /// comparisons and show up here.
    @Test func resolvingTheChosenIdsIsAnIndexReadNotAWalk() throws {
        let model = VideoScanModel()
        model.records = TriageFixture.records(100_000)
        let ids = stride(from: 5, to: 100_000, by: 12_500).map { model.records[$0].id }
        #expect(ids.count == 8)
        let start = ContinuousClock.now
        var candidates: [FootageSpectrumCandidate] = []
        for _ in 0..<50 {
            candidates = model.footageSpectrumCandidates(forIDs: ids, readable: { _ in true })
        }
        let elapsed = ContinuousClock.now - start
        #expect(candidates.count == 8)
        #expect(Set(candidates.map(\.id)) == Set(ids))
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_500)), "50 resolutions of 8 ids took \(elapsed)")
        let plan = try FootageSpectrumPlanner.plan(candidates: candidates, title: "scale").get()
        #expect(plan.members.count == 8)
    }
}

// MARK: - Source sensors

@Suite("Footage Spectrum — source sensors")
struct FootageSpectrumSensorTests {

    private static let files = ["FootageSpectrumPlan.swift", "FootageSpectrumHelper.swift", "FootageSpectrumJob.swift",
                                "FootageSpectrumWindow.swift", "FootageSpectrumDetailView.swift",
                                "VideoScanModel+FootageSpectrum.swift"]

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
            .joined(separator: "\n")
    }

    @Test func noDeleteTrashOrMoveExceptTheOneRunFolderPrune() throws {
        var removeItems = 0
        for name in Self.files {
            let src = try code(name)
            #expect(src.count > 500, "\(name) reads as empty")
            // ".moveItem(" with its dot: a bare "moveItem" is inside "removeItem".
            for word in [".trashItem(", ".moveItem(", "unlink(", "recycle(", "replaceItem", "DeleteDuplicates", "removeFile",
                         "FileHandle(forWriting", "FileHandle(forUpdating", "forWritingTo", "forUpdating"] {
                #expect(!src.contains(word), "\(name) contains `\(word)`")
            }
            removeItems += src.components(separatedBy: "removeItem(").count - 1
        }
        #expect(removeItems == 1, "the only deletion is FootageSpectrumStore.pruneOldRuns")
        let helper = try code("FootageSpectrumHelper.swift")
        let prune = try #require(helper.range(of: "func pruneOldRuns("))
        let removal = try #require(helper.range(of: "removeItem("))
        #expect(prune.lowerBound < removal.lowerBound)
        #expect(helper.contains("canonical.deletingLastPathComponent().path == runsPath"), "the prune re-checks the folder")
        #expect(helper.contains("UUID(uuidString: canonical.lastPathComponent) != nil"))
    }

    @Test func theJobWritesOnlyItsSetsFileAndLaunchesThroughTheRunner() throws {
        let job = try code("FootageSpectrumJob.swift")
        #expect(job.components(separatedBy: ".write(to:").count - 1 == 1)
        #expect(job.contains("FootageSpectrumSets.json(for: plan).write(to: store.setsFile(id), options: .atomic)"))
        #expect(!job.contains("Process()"), "launch only through the injected launcher")
        let helper = try code("FootageSpectrumHelper.swift")
        #expect(helper.contains("ProcessRunner.runProcess("))
        #expect(!helper.contains("Process()"))
        #expect(helper.contains("ToolLocator.pythonPath") && helper.contains("ToolLocator.ffmpegPath"))
        #expect(helper.contains("ToolLocator.resolveExistingFile(envVar: scriptEnvVar"))
    }

    @Test func theWindowLoadsOnlyItsRunFolder() throws {
        let window = try code("FootageSpectrumWindow.swift")
        #expect(window.contains("web.loadFileURL(page, allowingReadAccessTo: runFolder)"))
        #expect(window.contains("decisionHandler(.cancel)"))
        #expect(window.contains("compileContentRuleList("))
        #expect(!window.contains("URLSession") && !window.contains("load(URLRequest"))
    }

    /// QA P3-5: on a viewer the Center refuses the job — the row says why
    /// and no window opens over a job that will never run.
    @Test func aViewerRefusalNeverOpensTheWindow() throws {
        let job = try code("FootageSpectrumJob.swift")
        #expect(job.contains("guard add(job) else {") && job.contains("job.refuseToStart(reason:"))
        let model = try code("VideoScanModel+FootageSpectrum.swift")
        #expect(model.contains("guard !job.refusedOnViewer else"))
        #expect(try code("TriageView.swift").contains("guard model.startFootageSpectrum("))
        #expect(try code("StewardPaneView.swift").contains("guard model.startFootageSpectrum("))
        #expect(try code("FootageSpectrumWindow.swift").contains("model.startFootageSpectrum("))
    }

    @Test func theKindAndTheEntryPointsAreWired() throws {
        #expect(MediaFileOperationKind.compareFootage.badgeText == "Spectrum")
        #expect(MediaFileOperationKind.compareFootage.logVerb == "compare footage")
        #expect(MediaFileOperationKind.compareFootage.hasDetailView)
        let triage = try code("TriageView.swift")
        #expect(triage.contains("compareFootage(selectedIDs)") && triage.contains("compareFootage(ids)"))
        #expect(triage.contains("model.startFootageSpectrum(ids: Array(ids)"))
        let app = try code("VideoScanApp.swift")
        #expect(app.contains("Window(FootageSpectrumWindowOpener.windowTitle, id: FootageSpectrumWindowOpener.sceneID)"))
        #expect(app.contains("\"Footage Spectrum\"]"), "the auxiliary-title list knows the window")
        let card = try code("StewardCardView.swift")
        #expect(card.contains("compareFootageButton(id: \"steward.event.compareFootage\")"))
        #expect(card.contains("compareFootageButton(id: \"steward.action.compareFootage\")"))
    }
}
